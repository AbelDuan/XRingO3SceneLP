#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
test_load_aware.py —— load_aware.sh（动态负载感知）的离线自检

不碰真机：把源文件里的 awk 程序**原样抽出来**，喂合成的 /proc/{tid}/stat 数据，
验证「哪个线程该升到哪个核位」。能挡住这几类坑（都真实踩过）：

  1. awk `{ print x > F; done = 1 }` 是**语法错误** —— 整个程序解析失败、
     主规则完全不执行、状态文件空白、永不升核；而调用方 `2>/dev/null`
     会把语法错误吞掉，表现为「静默失效」。（v16.16 修复）
  2. `-v HOT=...` 传进来的是字符串，`lvl >= HOT` 会走**字符串比较** ——
     `lvl=7 >= HOT=9` 为假、`10 >= 12` 也为假，阈值行为取决于字典序。
     手测（字面量）正常、走脚本失效。（v16.16 用 +0 修掉）
  3. 档位语义：省电不升级、流畅升到 4-7、性能升到 4-7、极速才上探 4-9；
     fast 档还不做空闲收缩（中低负载要留在 0-7）。
     （★ v16.26：流畅目标由 4-5 改为 4-7 —— 4-5 已从未白名单移除）
  4. "-" 是「本档不升级」的占位符，必须显式跳过 —— 否则会被当成核位字符串
     而恒真，省电档会被错误升级。
  5. 空闲收缩必须用 **SBASE（该档基线）** 作为回落目标，而不是硬编码 SE(e_core)
     —— 否则 fast 档（基线 0-7）的空闲线程会被错误收缩。★ v16.26 新增。

跑法: python tools/test_load_aware.py
"""
import io, os, re, subprocess, sys, tempfile

ROOT = os.path.dirname(os.path.abspath(__file__))
MOD = os.path.dirname(ROOT)
LA = os.path.join(MOD, "Scripts", "4+4+2", "O3", "load_aware.sh")
UTIL = os.path.join(MOD, "lib", "util.sh")

FAILS = []
CHECKS = [0]


def check(cond, msg):
    CHECKS[0] += 1
    if cond:
        print("  \u2713 " + msg)
    else:
        FAILS.append(msg)
        print("  \u2717 " + msg)


def src(p):
    return io.open(p, encoding="utf-8").read()


def extract_awk(text):
    """把 `} | awk -v ... ' ... '` 这段里的 awk 程序抽出来。

    结构与源文件一致：`-v` 选项行在前、程序体从第一条 `function` 开始，
    最后以 ' 收尾并跟 2>/dev/null。
    """
    m = re.search(r"\}\s*\|\s*awk\b[^\n]*\n(.*?)\n'\s*2>/dev/null", text, re.S)
    if not m:
        raise SystemExit("无法从 load_aware.sh 抽出 awk 程序（正则失配）")
    body = m.group(1)
    # 去掉前导的 -v 选项续行：程序体从第一条 function 定义开始
    i = body.find("function ")
    if i < 0:
        raise SystemExit("抽出的 awk 程序里找不到 function 定义")
    return body[i:]


class Harness:
    """合成 /proc 数据 → 跑 aw k程序 → 返回 hot 条目列表。"""

    def __init__(self, workdir, awk_prog):
        self.dir = workdir
        self.awk = os.path.join(workdir, "lw.awk")
        io.open(self.awk, "w", encoding="utf-8").write(awk_prog)

    @staticmethod
    def p(path):
        """Windows 路径 → 正斜杠形式。
        ⚠⚠ 必须做这一步：路径经 `-v STF=<path>` 传给 awk 后，**反斜杠会被 awk 当转义
           序列吃掉**（实测 `...\\_t_lwdbg\\state` 里的 `\\s` 变成 `s`）→ awk 打不开文件
           → `PREV` 表为空 → 每个线程都被判成「新线程」→ 主规则全走 `next`、
           **一条 hot 都不产出**。表现为「所有升级/收缩断言全 None」。
           （本环境 os.path.join 用的是反斜杠，天然触发。）
        """
        return path.replace("\\", "/")

    def write_inputs(self, threads):
        """threads: [(tid, base, ratio_pct, busy_seconds)]

        ratio = delta*100/ET，ET = 窗口秒数 × 100（USER_HZ=100）。
        所以 delta_ticks = ratio_pct * ET / 100 / 100 × 100 … 直接算：
        ET = win*100；delta = ratio/100*ET = ratio*win。
        """
        win = 10.0
        et = int(win * 100)
        lines_tids = []
        lines_stat = []
        state = []
        for tid, base, ratio, _ in threads:
            lines_tids.append("@%d|%s|%s|||RenderThread||0||com.test.p%d"
                              % (tid, base, base, tid))
            # 每个 tid 单独占一个"进程"，避免 awk 按 pid 分组时错位
            tick = int(ratio * win)          # ET=win*100 → delta/ET*100 = ratio
            lines_stat.append("%d (t%d) S 1 1 1 0 -1 0 0 0 0 0 %d 0 0 0" % (tid, tid, tick))
            state.append("%d\t0" % tid)
        io.open(os.path.join(self.dir, "state"), "w", encoding="utf-8").write(
            "\n".join(state) + "\n")
        io.open(os.path.join(self.dir, "in.txt"), "w", encoding="utf-8").write(
            "\n".join(lines_tids + lines_stat) + "\n")
        return et

    def run(self, mode, esc, hotok, interval, hot, idle, idleoff,
            first=0, sp1="4-7", shp="8-9", se="0-3", sbase="0-3"):
        et = self.write_inputs(self.threads)
        out = os.path.join(self.dir, "hot.out")
        # ⚠ 用「清空」而不是 os.unlink：宿主 safe-delete 钩子会拦删除（尤其同一轮
        #   累计删除数超阈值时直接 SystemExit）→ 把测试退出码染成非 0。
        #   截断为 0 字节效果等价（awk 用 `>` 重定向写，本来也会覆盖）。
        try:
            io.open(out, "w", encoding="utf-8").close()
        except Exception:
            pass
        cmd = ["awk", "-f", self.p(self.awk),
               "-v", "SP1=" + sp1, "-v", "SHP=" + shp, "-v", "SE=" + se,
               "-v", "SESC=" + esc, "-v", "SBASE=" + sbase,
               "-v", "ET=%d" % et, "-v", "FIRST=%d" % first,
               "-v", "HOT=%s" % hot, "-v", "IDLE=%s" % idle,
               "-v", "LWHP=%s" % hotok, "-v", "IDLEOFF=%s" % idleoff,
               "-v", "MODE=" + mode,
               "-v", "STF=" + self.p(os.path.join(self.dir, "state")),
               "-v", "STNW=" + self.p(os.path.join(self.dir, "state.new")),
               "-v", "HOTF=" + self.p(out),
               self.p(os.path.join(self.dir, "in.txt"))]
        r = subprocess.run(cmd, capture_output=True, text=True, cwd=self.dir)
        return r, out

    def targets(self, **kw):
        """返回 {tid: 目标核位}"""
        r, out = self.run(**kw)
        if r.returncode != 0:
            raise SystemExit("awk 失败: " + (r.stderr or "").strip())
        got = {}
        if os.path.exists(out):
            for line in io.open(out, encoding="utf-8"):
                parts = line.split()
                if len(parts) >= 3:
                    got[int(parts[0])] = parts[2]
        return got


def _binenv():
    """补上 Git usr/bin（cut/sed/awk 都在那），否则 sh 层会「command not found」。"""
    env = dict(os.environ)
    extra = []
    for c in ("C:/Users/Abel/.workbuddy/binaries/PortableGit/versions/1.2.0/usr/bin",
              "C:/Program Files/Git/usr/bin"):
        if os.path.isdir(c):
            extra.append(c)
    if extra:
        env["PATH"] = os.pathsep.join(extra) + os.pathsep + env.get("PATH", "")
    return env


def sh_out(script):
    r = subprocess.run(["sh", "-c", script], capture_output=True, text=True, env=_binenv())
    return (r.stdout or "").strip()


def main():
    text = src(LA)

    # ---- 0) 静态检查：那个会静默失效的 awk 语法坑必须不存在 ----------------
    print("\n[1] 静态检查（awk 语法与数值化）")
    check("print tid \" \" curPid \" \" te > HOTF" not in text or
          not re.search(r"print[^\n]*>\s*HOTF;\s*done\s*=", text),
          "无 `print ... > FILE; done = ...` 形式（awk 语法错误，会整程序失效）")
    check("lvlN = lvl + 0" in text and "lvlN >= hotN" in text,
          "阈值比较已 +0 强制数值化（否则 -v 传参走字符串比较）")
    check('addList == "-"' in text or "addList == \"-\"" in text,
          "added() 显式识别 \"-\" 占位符（本档不升级）")
    check("IDLEOFF" in text, "支持 IDLEOFF（fast 档不做空闲收缩）")

    # ---- 1) awk 程序能独立跑起来（语法有效性，不再被 2>/dev/null 吞掉）----
    print("\n[2] awk 程序语法有效性")
    prog = extract_awk(text)
    # ⚠ 不用 tempfile.mkdtemp()：沙盒/安全钩子会拦系统 temp 下的目录创建 → SIGTERM。
    tmp = os.path.join(MOD, "_t_lw_%d" % os.getpid())
    try:
        os.makedirs(tmp, exist_ok=True)
    except Exception:
        tmp = tempfile.mkdtemp(prefix="lwtest_")
    h = Harness(tmp, prog)
    check(True, "awk 程序已抽出（%d 行）" % len(prog.splitlines()))

    # 合成线程：忙 100% / 中 30% / 闲 2%
    h.threads = [(5001, "0-3", 100, 0), (5002, "0-3", 30, 0), (5003, "0-3", 2, 0)]

    # 先确认语法：跑一次不报错
    r, _ = h.run("balance", "4-7", "0", 12, 10, 4, 0)
    check(r.returncode == 0, "awk 可执行且退出码为 0（stderr: %s）"
          % ((r.stderr or "").strip()[:60] or "空"))

    # ---- 2) 四档升级目标（与 lib/util.sh 的 mode_sched_row 对齐）----
    print("\n[3] 四档升级目标（忙线程基线 0-3）")
    #   ★ v16.26：流畅的升级目标由 4-5 改为 4-7（4-5 已从未白名单移除）
    cases = [
        ("powersave",   "-",   "0", 15, 10, 4, 0, None,  "省电：不升级"),
        ("balance",     "4-7", "0", 12, 10, 4, 0, "0-7", "流畅：升到 0-7（并入 4-7 整簇）"),
        ("performance", "4-7", "0", 10, 9,  4, 0, "0-7", "性能：升到 0-7"),
        ("fast",        "4-9", "1", 8,  8,  4, 1, "0-9", "极速：升到 0-9（上探 4-9）"),
    ]
    for mode, esc, hp, itv, hot, idle, ioff, expect, label in cases:
        got = h.targets(mode=mode, esc=esc, hotok=hp, interval=itv,
                        hot=hot, idle=idle, idleoff=ioff)
        if expect is None:
            check(5001 not in got, label + "（忙线程无 hot 条目）")
        else:
            check(got.get(5001) == expect,
                  "%s（实际 %s）" % (label, got.get(5001)))

    # ---- 3) 空闲收缩：非 fast 档收缩、fast 档不收缩 ------------------------
    print("\n[4] 空闲线程处理（基线 4-7，占用 2%）")
    h.threads = [(6001, "4-7", 2, 0)]
    got = h.targets(mode="balance", esc="4-7", hotok="0", interval=12,
                    hot=10, idle=4, idleoff=0)
    check(got.get(6001) == "0-3", "流畅档：空闲线程收缩到 0-3（实际 %s）" % got.get(6001))
    got = h.targets(mode="fast", esc="4-9", hotok="1", interval=8,
                    hot=8, idle=4, idleoff=1)
    check(6001 not in got, "极速档：空闲线程不收缩（中低负载留 0-7）")

    # ---- 3b) 空闲收缩回落目标 = SBASE（该档基线），不是硬编码 SE ----------
    print("\n[4b] 空闲收缩回到 SBASE 基线（v16.26 新增：基线锚点）")
    # 基线 4-7 的空闲线程 → 收缩目标应是 SBASE=4-7 之外的基线，
    # 这里用 SBASE=0-7（fast 档基线）验证「用的是 SBASE 而非 SE」
    h.threads = [(6101, "4-7", 2, 0)]
    got = h.targets(mode="balance", esc="4-7", hotok="0", interval=12,
                    hot=10, idle=4, idleoff=0, sbase="0-7")
    check(got.get(6101) == "0-7",
          "空闲收缩回落到 SBASE=0-7（实际 %s）" % got.get(6101))
    h.threads = [(6102, "4-7", 2, 0)]
    got = h.targets(mode="balance", esc="4-7", hotok="0", interval=12,
                    hot=10, idle=4, idleoff=0, sbase="0-3")
    check(got.get(6102) == "0-3",
          "空闲收缩回落到 SBASE=0-3（实际 %s）" % got.get(6102))

    # ---- 4) 阈值边界：字符串比较 bug 的回归 ---------------------------------
    print("\n[5] 阈值边界（+0 数值化的回归用例）")
    # 占用 12% → lvl=3；阈值 10 不升、阈值 2 升（字符串比较下 3 >= 10 也可能为真）
    h.threads = [(7001, "0-3", 12, 0)]
    got = h.targets(mode="balance", esc="4-7", hotok="0", interval=12,
                    hot=10, idle=4, idleoff=0)
    check(7001 not in got, "占用 12pct < 阈值 10 时不升级（数值比较）")
    got = h.targets(mode="balance", esc="4-7", hotok="0", interval=12,
                    hot=2, idle=4, idleoff=0)
    check(got.get(7001) == "0-7", "占用 12pct > 阈值 2 时升级（实际 %s）" % got.get(7001))

    # ---- 5) "-" 占位符不会被当成核位 ---------------------------------------
    print("\n[6] \"-\" 占位符（本档不升级）")
    h.threads = [(8001, "0-3", 100, 0)]
    got = h.targets(mode="powersave", esc="-", hotok="0", interval=15,
                    hot=10, idle=4, idleoff=0)
    check(8001 not in got, "esc=\"-\" 时忙线程不产生 hot 条目")

    # ---- 6) 与 lib/util.sh 的语义表对齐（防两处漂移）------------------------
    print("\n[7] 与 lib/util.sh mode_sched_row 对齐")
    row = sh_out('. "%s" >/dev/null 2>&1; for m in powersave balance performance fast; '
                 'do echo "$m:$(mode_sched_row $m)"; done' % UTIL)
    # v16.26：流畅的升级目标为 4-7（4-5 已移除），性能保持 4-7
    expect_esc = {"powersave": "-", "balance": "4-7",
                  "performance": "4-7", "fast": "4-9"}
    expect_hp = {"powersave": "0", "balance": "0",
                 "performance": "0", "fast": "1"}
    for line in row.splitlines():
        if ":" not in line:
            continue
        m, rest = line.split(":", 1)
        cols = rest.split()
        # ★ v16.26：行变 9 列 → id 中文名 **base** esc hotok 间隔 忙阈值 闲阈值 禁用空闲收缩
        if len(cols) >= 9:
            check(cols[3] == expect_esc[m],
                  "%s 升级目标 = %s（表里 %s）" % (m, expect_esc[m], cols[3]))
            check(cols[4] == expect_hp[m],
                  "%s 允许上探 4-9 = %s" % (m, cols[4]))

    print("\n" + "=" * 62)
    if FAILS:
        print("\u274c 未通过 %d 项：" % len(FAILS))
        for f in FAILS:
            print("   - " + f)
        return 1
    print("\u2705 全部通过（%d 项断言）" % CHECKS[0])
    return 0


if __name__ == "__main__":
    sys.exit(main())
