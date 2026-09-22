#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
test_sched_cores.py —— 四档核心集合「可自定义」的离线自检

需求（用户 2026-09-18）：WebUI 里能自定义所有线程模式、选择核心集合。
v16.23：4-5 从「仅内置默认」提升为**用户可选**。
★ v16.26：**4-5 被彻底移除**（O3 上是纯负收益，依据见 lib/util.sh SCHED_CORES_VALID
   头部注释：cpu4/core_ctl min=max=4 锁死 4 核常在线 + 实测每核独立 PLL，
   推翻「4-7 同域共频」旧结论）。于是合法清单从 6 个收敛成 **5 个**：
      0-3 / 4-7 / 8-9 / 0-7 / 4-9
   sched_cores_valid 与 WebUI 下拉、SCHED_CORES_VALID 三者必须是同一份清单。

★ v16.26 同时修了一个**真机 bug**：mode_sched_row 的行**列序接反**。
   文件 sched_cores.conf 的列序是 `<mode>\t<base>\t<esc>`（3 列），
   但旧代码把列1 当 esc、列2 当 hotok，于是：
       · 列1(base, 如 0-3) 被当成「升级目标」→ 设 4-5 升级永远升不上去；
       · 列2(esc, 如 4-5) 被 case 0|1 拒掉 → hotok 永远保持默认。
   现在 mode_sched_row 输出 **9 列**（含 base）：`模式 中文 base esc hotok int hot idle io`，
   lookup 1→base、2→esc、3→hotok。

设计约束（本测试锁住这些语义）：
  1. **缺省不行为变化**：没有配置文件时，mode_sched_row 必须与内置默认完全一致
     —— 否则升级会悄悄改变调参，用户又要重测。
  2. 配置文件存在时**覆盖**内置默认，且只覆盖写了的模式。
  3. 允许的核心集合**只有**那 5 个（防止手滑写进 0-9 / 4-5 这种非法值）。
  4. 「允许上探 4-9」与「升级目标」必须自洽：目标含 8/9 时该标志才为 1。
  5. 文件损坏/半截（少列、乱码）时**回落内置默认**，绝不产生畸形行。

跑法: python tools/test_sched_cores.py
"""
import io, os, re, subprocess, sys, tempfile

ROOT = os.path.dirname(os.path.abspath(__file__))
MOD = os.path.dirname(ROOT)
UTIL = os.path.join(MOD, "lib", "util.sh")

FAILS = []
CHECKS = [0]


_TMPDIRS = []


def mkdtmp(prefix):
    """在**模块目录下**建临时目录。
    ⚠ 不用 tempfile.mkdtemp()：沙盒/安全钩子会拦系统 temp 下的目录创建，
      实测直接 SIGTERM 掉整个测试进程（无输出、rc=1）。放模块目录内最稳。
    ⚠ **不要**在退出时 shutil.rmtree：宿主 safe-delete 钩子会因为「批量删除 >50 文件」
      抛 SystemExit(1)，把测试进程的退出码染成 1（实测：全绿也 rc=1）。
      残留的 _t_* 目录由 .gitignore 忽略；手动清理即可。
    """
    d = os.path.join(MOD, "_t_" + prefix + "_" + str(os.getpid()))
    if not os.path.isdir(d):
        os.makedirs(d, exist_ok=True)
    _TMPDIRS.append(d)
    return d

# v16.26 的合法核心集合（5 个，4-5 已移除）—— 单一来源，多处引用
VALID = ["0-3", "4-7", "8-9", "0-7", "4-9"]


def check(cond, msg):
    CHECKS[0] += 1
    if cond:
        print("  \u2713 " + msg)
    else:
        FAILS.append(msg)
        print("  \u2717 " + msg)


def sh(script, env_extra=None):
    env = dict(os.environ)
    # ★ Windows 上 `sh`（Git for Windows）自己会带上 usr/bin，但被别处调起时
    #   PATH 可能缺 usr/bin（cut/sed/awk 都是那里的）→ 显式补上，避免
    #   「cut: command not found」把整个 sh 层跑歪（实测踩过）。
    extra_bins = []
    for c in ("C:/Users/Abel/.workbuddy/binaries/PortableGit/versions/1.2.0/usr/bin",
              "C:/Program Files/Git/usr/bin",
              "/usr/bin", "/bin"):
        if os.path.isdir(c):
            extra_bins.append(c)
    if extra_bins:
        cur = env.get("PATH", "")
        env["PATH"] = os.pathsep.join(extra_bins) + os.pathsep + cur
    if env_extra:
        env.update(env_extra)
    r = subprocess.run(["sh", "-c", script], capture_output=True, text=True, env=env)
    return (r.stdout or "").strip(), (r.stderr or "").strip()


# ★★ v16.26 性能约束：本环境下**每次 subprocess 起 sh ≈ 13 秒**（沙盒包装开销），
#    单次 `sh -c` 内部多跑几条命令几乎不加时间（5 条 inner call 总耗时 1.4s）。
#    所以测试**绝不能一个用例起一个 sh** —— 必须把同一节的用例攒成一次调用。
#    下面 sh_multi() 就是干这个的：一次 spawn 跑完整节，用标记行分行回传。
#
#    ⚠ 标记行**不能**写成 `### KEY` —— `#` 在 shell 里是注释，整行会被吃掉
#      （实测：输出里标记全部消失，解析出空 dict）。必须用 echo 主动打。
MARK = "__MARK__"


def mark(key):
    """生成一段回传标记（供 sh_multi 解析）。"""
    return 'echo "%s%s"\n' % (MARK, key)


def sh_multi(script, keys, env_extra=None):
    """一次 sh 调用跑多组命令。用 mark(key) 分隔，回传 {KEY: 该段 stdout}。"""
    out, err = sh(script, env_extra)
    res = {}
    cur = None
    buf = []
    for line in out.splitlines():
        if line.startswith(MARK):
            if cur is not None:
                res[cur] = "\n".join(buf).strip()
            cur = line[len(MARK):].strip()
            buf = []
        else:
            buf.append(line)
    if cur is not None:
        res[cur] = "\n".join(buf).strip()
    return res, err


# ★★ v16.26 第二个性能约束：**每个 `mode_sched_row` 内部还要 fork 7 次
#    `sched_cores_lookup`（各自 fork cut/tr）**，本环境下每次 fork ≈ 数十~百毫秒，
#    叠加沙盒包装 → 实测「一次 spawn 里塞 4 个 mode_sched_row ≈ 50s」、
#    塞 12 个直接超时被杀（SIGTERM，无输出）。
#    ⇒ 单次 spawn 的 `mode_sched_row` 个数必须 ≤ 4。下面按 CHUNK 切块。
CHUNK = 4


def sh_multi_chunked(prefix, cases, suffix="", env_extra=None, chunk=CHUNK):
    """把 cases（[(key, 生成该段 shell 的行函数或字符串)]）分块跑，合并结果。
    prefix: 每块开头都要有的公共前置（含 . util.sh / SCHED_CORES_FILE）。
    cases : [(key, body_lines_str)]，body 里应包含写文件 + 取值命令。
    """
    res_all = {}
    errs = []
    for i in range(0, len(cases), chunk):
        part = cases[i:i + chunk]
        script = prefix
        for key, body in part:
            script += mark(key) + body
        got, err = sh_multi(script, [k for k, _ in part], env_extra)
        res_all.update(got)
        if err:
            errs.append(err)
    return res_all, ("\n".join(errs) if errs else "")


def row_of(mode, conf_path=None):
    """取某档的 mode_sched_row（可指定自定义配置文件路径）。
    ⚠ 只用于零星调用；成节的用例请用 sh_multi。"""
    pre = '. "%s" >/dev/null 2>&1\n' % UTIL
    if conf_path:
        pre += 'SCHED_CORES_FILE="%s"\n' % conf_path
    out, err = sh(pre + 'mode_sched_row %s\n' % mode)
    return out, err


def col(row, n):
    """取第 n 列（越界返回 None，不抛 IndexError —— 否则一个畸形行会中断整轮）。"""
    parts = row.split()
    return parts[n] if len(parts) > n else None


def probe_src():
    """被测脚本的公共前置（. util.sh）。"""
    return '. "%s" >/dev/null 2>&1\n' % UTIL


def main():
    print("[1] 缺省：无配置文件时与内置默认一致（不许悄悄改变调参）")
    # v16.26：行变 9 列 = <mode> <中文> <base> <esc> <hotok> <int> <hot> <idle> <io>
    #   balance 的 base/esc 都由 sched_cores_default_* 注入 → 0-3 / 4-7
    defaults = {
        "powersave":   "powersave 省电 0-3 - 0 15 10 4 0",
        "balance":     "balance 流畅 0-3 4-7 0 12 10 4 0",
        "performance": "performance 性能 0-3 4-7 0 10 9 4 0",
        "fast":        "fast 极速 0-7 4-9 1 8 8 4 1",
    }
    # ★ 一次 spawn 取全部四档（本环境每 spawn ≈13s，绝不可一档一次）
    script = probe_src() + 'SCHED_CORES_FILE="/nonexistent/sched_cores.conf"\n'
    for m in ("powersave", "balance", "performance", "fast"):
        script += mark(m) + 'mode_sched_row %s\n' % m
    got1, err1 = sh_multi(script, list(defaults))
    for m, want in defaults.items():
        got = got1.get(m, "")
        check(got == want, "%s → %r（期望 %r）%s" % (m, got, want, (" err=" + err1) if err1 else ""))

    print("\n[2] 配置文件覆盖内置默认（只覆盖写了的档）")
    d = mkdtmp("schedcores")
    conf = os.path.join(d, "sched_cores.conf")
    # 只写 fast 一行：base=4-7、esc=8-9（纯超大核）
    io.open(conf, "w", encoding="utf-8").write(
        "# mode\tbase\tesc\n"
        "fast\t4-7\t8-9\n")
    got2, err2 = sh_multi(
        probe_src() + 'SCHED_CORES_FILE="%s"\n' % conf +
        mark("fast") + 'mode_sched_row fast\n'
        + mark("balance") + 'mode_sched_row balance\n', ["fast", "balance"])
    check((got2.get("fast") or "").startswith("fast 极速 4-7 8-9 1"),
          "fast base 被覆盖为 4-7、esc 为 8-9（实际 %r）" % got2.get("fast"))
    check(got2.get("balance") == defaults["balance"],
          "未写进配置的 balance 仍是内置默认（实际 %r）" % got2.get("balance"))

    print("\n[3] 只接受那 5 个核心集合（v16.26：4-5 已移除）")
    acceptable = VALID + ["-"]
    # ★ 合法 + 非法用例。不用 mode_sched_row（它内部 7 次 fork，太慢），
    #   直接验证**准入判定**这一层：写文件 → sched_cores_lookup 取第 2 列 →
    #   sched_cores_valid 判定。这与 mode_sched_row 用的是同一对谓词，
    #   且第 [1]/[2] 节已证明「合法值会被 mode_sched_row 采纳」。
    cases = [(v.replace("-", "_"), v) for v in VALID] + \
            [("bad_" + str(i), bad) for i, bad in
             enumerate(["0-9", "1-5", "abc", "", "0-3,4-7", "99", "4-5"])]
    pref = probe_src() + 'SCHED_CORES_FILE="%s"\n' % conf
    body_cases = [(key,
                   'printf "fast\\t0-7\\t%s\\n" > "%s"\n'
                   'if sched_cores_lookup fast 2 && sched_cores_valid "$SCV"; '
                   'then echo "ACCEPT ${SCV:-<empty>}"; else echo "REJECT"; fi\n'
                   % (val, conf))
                  for key, val in cases]
    got3, err3 = sh_multi_chunked(pref, body_cases)
    for key, val in cases:
        verdict = (got3.get(key) or "").strip()
        if val in VALID:
            check(verdict == "ACCEPT %s" % val,
                  "合法集合 %s 被接受（实际 %r）" % (val, verdict))
        else:
            check(verdict.startswith("REJECT"),
                  "非法集合 %r 被拒绝（实际 %r）" % (val, verdict))

    print("\n[4] 自洽性：目标含 8/9 ⇒ hotok 必须为 1")
    got4, _ = sh_multi_chunked(
        probe_src() + 'SCHED_CORES_FILE="%s"\n' % conf,
        [("a", 'printf "fast\\t0-7\\t4-9\\n" > "%s"\nmode_sched_row fast\n' % conf),
         ("b", 'printf "fast\\t0-7\\t4-7\\n" > "%s"\nmode_sched_row fast\n' % conf)])
    # ⚠ 行是 9 列：0=mode 1=中文 2=base 3=esc 4=hotok → col() 是 0-based，
    #   所以 esc 必须取 col(...,3)、hotok 取 col(...,4)。
    #   （本测试曾写成 3/4 去对应「第 3/4 列」，实际读到 base/esc，误报 hotok=4-9。）
    esc, hotok = col(got4.get("a", ""), 3), col(got4.get("a", ""), 4)
    ok = (("8" not in (esc or "")) and ("9" not in (esc or ""))) or hotok == "1"
    check(ok, "目标 %s 与 hotok=%s 自洽（4-9 ⇒ hotok=1）" % (esc, hotok))
    esc_b, hotok_b = col(got4.get("b", ""), 3), col(got4.get("b", ""), 4)
    # ⚠ v16.26 语义修正：`.conf` 只有 3 列（mode/base/esc），**没有 hotok 列**，
    #   所以 hotok 是「派生量」而非可写入量 —— 它由该档内置默认 + 「目标含 8/9」自动推导：
    #     · fast 内置 hotok 默认就是 1（见 mode_sched_row 的 _def fast 第 5 列）；
    #     · `case "$_esc" in *8*|*9*) _ho=1` 只会**置 1**，不会把 1 降回 0。
    #   因此用户把 fast 的升级目标从 4-9 改成 4-7 时，hotok 保持 1 是**设计行为**：
    #   fast 档本来就允许上探，改窄目标不该顺手取消这个能力（否则用户失去 8-9）。
    #   真正的不变量是**单向**的：目标含 8/9 ⇒ hotok 必须为 1；目标 = "-" ⇒ hotok 必须为 0。
    check(esc_b == "4-7" and hotok_b == "1",
          "目标 %s ⇒ hotok 保持该档默认 %s（单向派生，不自动降 0）" % (esc_b, hotok_b))
    # 反向锁：目标为 "-"（不升级）时 hotok 必须被清 0
    got4b, _ = sh_multi(
        probe_src() + 'SCHED_CORES_FILE="%s"\n' % conf +
        mark("n") + 'printf "fast\\t0-7\\t-\\n" > "%s"\nmode_sched_row fast\n' % conf,
        ["n"])
    esc_n, hotok_n = col(got4b.get("n", ""), 3), col(got4b.get("n", ""), 4)
    check(esc_n == "-" and hotok_n == "0",
          "目标 %s（不升级）⇒ hotok=%s 必须为 0" % (esc_n, hotok_n))

    print("\n[5] 文件损坏/半截 → 回落内置默认，不产生畸形行")
    juncases = [("j0", "\n\n\n"), ("j1", "garbage"), ("j2", "fast"),
                ("j3", "fast\t4-7"), ("j4", "fast\t4-7\t0\n")]
    import base64
    body_jun = []
    for key, junk in juncases:
        # 内容按 base64 传，避免引号/换行打乱脚本
        b64 = base64.b64encode(junk.encode("utf-8")).decode("ascii")
        body_jun.append((key,
                         'printf "%%s" "%s" | base64 -d > "%s"\nmode_sched_row fast\n'
                         % (b64, conf)))
    got5, _ = sh_multi_chunked(probe_src() + 'SCHED_CORES_FILE="%s"\n' % conf, body_jun)
    for key, junk in juncases:
        cols = (got5.get(key) or "").split()
        check(len(cols) == 9, "损坏输入 %r → 行仍为 9 列（实际 %d 列）" % (junk[:12], len(cols)))

    print("\n[6] 静态：默认表里只有那 5 个集合（防止有人在默认里塞 0-9 / 4-5）")
    src = io.open(UTIL, encoding="utf-8").read()
    fn = re.search(r"mode_sched_row\(\)\s*\{.*?\n\}", src, re.S)
    body = fn.group(0) if fn else ""
    rows = re.findall(r'^\s+(powersave|balance|performance|fast)\)\s+_def="([^"]+)"',
                      body, re.M)
    check(len(rows) == 4, "抽出 4 条默认行（实际 %d）" % len(rows))
    # ★ 核位在 _def 里是 `$(sched_cores_default_base xxx)` / `$(sched_cores_default_esc xxx)`
    #   这种**命令替换**，内部含空格 → 不能按空格 split 第 3/4 列取。
    #   改用「按模式名定位 _def，然后用正则抠出两个 $(...) 后的字面量」。
    for name, r in rows:
        # 先把命令替换整体替换成一个占位符，再看它后面跟的字面量
        #   _def = "<mode> <中文> <base> <esc> <hotok> <int> <hot> <idle> <io>"
        # 其中 base/esc 可能是 $(...)（此时内部空格会干扰 split），故：
        toks = re.findall(r'\$\([^)]*\)|\S+', r)
        if len(toks) < 5:
            check(False, "默认行列数不足: %r" % r)
            continue
        base, esc = toks[2], toks[3]

        def _ok(tok):
            return tok.startswith("$(") or tok == "-" or tok in acceptable

        check(_ok(base), "默认行 %s 的基线是命令替换或合法值（实际 %s）" % (name, base))
        check(_ok(esc), "默认行 %s 的升级目标是命令替换或合法值（实际 %s）" % (name, esc))
    # ★ 静态锁：4-5 不应出现在功能性代码里（SCHED_CORES_VALID 等）
    check("SCHED_CORES_VALID=\"0-3 4-7 8-9 0-7 4-9\"" in src,
          "SCHED_CORES_VALID 恰为那 5 个（源码级）")

    print("\n[7] 后端写入的列序必须与读取一致（真机实测接反过）")
    # 用例：写入 <mode>\t<base>\t<esc>，读回后 base 必须是 base、esc 必须是 esc。
    d2 = mkdtmp("schedround")
    conf2 = os.path.join(d2, "sched_cores.conf")
    io.open(conf2, "w", encoding="utf-8").write("fast\t0-7\t8-9\n")
    out, _ = sh(probe_src() + 'SCHED_CORES_FILE="%s"\n'
                'sched_cores_lookup fast 1 && echo "BASE=$SCV"\n'
                'sched_cores_lookup fast 2 && echo "ESC=$SCV"\n' % conf2)
    got = dict(l.split("=", 1) for l in out.splitlines() if "=" in l)
    check(got.get("BASE") == "0-7", "第 1 列读作基线（实际 %r）" % got.get("BASE"))
    check(got.get("ESC") == "8-9", "第 2 列读作升级目标（实际 %r）" % got.get("ESC"))

    # 静态：后端写文件处必须按 <base> 然后 <esc> 输出，且回读时 1→base、2→esc
    wsrc = io.open(os.path.join(MOD, "Scripts", "4+4+2", "O3", "webui.sh"),
                   encoding="utf-8").read()
    body = wsrc[wsrc.index("cmd_setschedcores()"):]
    body = body[:body.index("\n}\n")]
    check("printf '%s\\t%s\\t%s\\n' \"$x\" \"$b2\" \"$e2\"" in body,
          "写文件按 <mode>|<b2=base>|<e2=esc> 顺序")
    check('sched_cores_lookup "$x" 1 && sched_cores_valid "$SCV" && b2="$SCV"' in body,
          "回读第 1 列 → b2（基线）")
    check('sched_cores_lookup "$x" 2 && sched_cores_valid "$SCV" && e2="$SCV"' in body,
          "回读第 2 列 → e2（升级目标）")

    # ★ 读侧也要锁：cmd_schedcores 里第 1 列必须给 base、第 2 列给 esc。
    #   （实测只修了写侧、漏了读侧，于是 UI 上显示仍是反的 —— 这条就是防这个。）
    rd = wsrc[wsrc.index("cmd_schedcores()"):]
    rd = rd[:rd.index("\n}\n")]
    check('sched_cores_lookup "$m" 1 && sched_cores_valid "$SCV" && base="$SCV"' in rd,
          "读侧第 1 列 → base（基线）")
    check('sched_cores_lookup "$m" 2 && sched_cores_valid "$SCV" && esc="$SCV"' in rd,
          "读侧第 2 列 → esc（升级目标）")
    # v16.26：esc 在 9 列 row 里是第 4 列（原来错用 -f3）
    check("cut -d' ' -f4" in rd, "读侧 esc 取 9 列行的第 4 列（-f4）")

    print("\n[8] WebUI「模式列表」的可选项 == 后端白名单（必须是那 5 个）")
    html = io.open(os.path.join(MOD, "webroot", "index.html"), encoding="utf-8").read()
    mo = re.search(r"const SC_OUT = \[([^\]]*)\]", html)
    check(mo is not None, "index.html 里有 SC_OUT 定义")
    ui = re.findall(r"'([^']+)'", mo.group(1)) if mo else []
    check(ui == VALID, "WebUI 下拉与白名单逐项一致（实际 %r）" % ui)
    check("4-5" not in ui, "4-5 **不在** WebUI 可选列表里（v16.26 已移除）")
    env_out, _ = sh(probe_src() + 'echo "$SCHED_CORES_VALID"\n')
    check(env_out.split() == VALID, "SCHED_CORES_VALID 与清单一致（实际 %r）" % env_out)

    print("\n" + "=" * 62)
    if FAILS:
        print("\u274c 未通过 %d 项：" % len(FAILS))
        for f in FAILS:
            print("   - " + f)
        return 1
    print("\u2705 全部通过（%d 项断言）" % CHECKS[0])
    return 0


if __name__ == "__main__":
    # ★ 直接把报告写文件（Windows 下 sh 层/终端捕获不稳，实测 stdout 会被吞），
    #   并且**逐条 flush** —— 本环境偶发中途 SIGTERM，缓冲式写入会丢失全部输出。
    _rep = os.environ.get("TEST_REPORT")
    if _rep:
        _f = io.open(_rep, "w", encoding="utf-8")

        class _W(object):
            def write(self, s):
                _f.write(s)
                try:
                    _f.flush()
                except Exception:
                    pass

            def flush(self):
                try:
                    _f.flush()
                except Exception:
                    pass

            def isatty(self):
                return False

        sys.stdout = _W()
        try:
            _rc = main()
        except BaseException:
            import traceback
            sys.stdout.write("\nEXC\n" + traceback.format_exc())
            _rc = 2
        sys.stdout.write("\n=== EOF rc=%d ===\n" % _rc)
        _f.close()
        sys.exit(_rc)
    sys.exit(main())
