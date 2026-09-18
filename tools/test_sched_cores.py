#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
test_sched_cores.py —— 四档核心集合「可自定义」的离线自检

需求（用户 2026-09-18）：WebUI 里能自定义所有线程模式、选择核心集合
（0-3 / 4-5 / 4-7 / 8-9 / 0-7 / 4-9）。
v16.23：4-5 从「仅内置默认」提升为**用户可选**（用户要求「同步到模式列表」），
于是 sched_cores_valid 与 WebUI 下拉、SCHED_CORES_VALID 三者必须是同一份清单。

设计约束（本测试锁住这些语义）：
  1. **缺省不行为变化**：没有配置文件时，mode_sched_row 必须与内置默认完全一致
     —— 否则升级会悄悄改变调参，用户又要重测。
  2. 配置文件存在时**覆盖**内置默认，且只覆盖写了的模式。
  3. 允许的核心集合**只有**那 6 个（防手滑写进 0-9 这种会打到超大核的非法值）。
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


def check(cond, msg):
    CHECKS[0] += 1
    if cond:
        print("  \u2713 " + msg)
    else:
        FAILS.append(msg)
        print("  \u2717 " + msg)


def sh(script, env_extra=None):
    env = dict(os.environ)
    if env_extra:
        env.update(env_extra)
    r = subprocess.run(["sh", "-c", script], capture_output=True, text=True, env=env)
    return (r.stdout or "").strip(), (r.stderr or "").strip()


def row_of(mode, conf_path=None):
    """取某档的 mode_sched_row（可指定自定义配置文件路径）。"""
    pre = '. "%s" >/dev/null 2>&1\n' % UTIL
    if conf_path:
        pre += 'SCHED_CORES_FILE="%s"\n' % conf_path
    out, err = sh(pre + 'mode_sched_row %s\n' % mode)
    return out, err


def main():
    print("[1] 缺省：无配置文件时与内置默认一致（不许悄悄改变调参）")
    defaults = {
        "powersave":   "powersave 省电 - 0 15 10 4 0",
        # v16.22：流畅升级目标 4-7 → 4-5；性能基线 4-7 → 0-3（按本机 4-7 共频实测）
        "balance":     "balance 流畅 4-5 0 12 10 4 0",
        "performance": "performance 性能 4-7 0 10 9 4 0",
        "fast":        "fast 极速 4-9 1 8 8 4 1",
    }
    for m, want in defaults.items():
        got, err = row_of(m, "/nonexistent/sched_cores.conf")
        check(got == want, "%s → %r（期望 %r）%s" % (m, got, want, (" err=" + err) if err else ""))

    print("\n[2] 配置文件覆盖内置默认（只覆盖写了的档）")
    d = tempfile.mkdtemp(prefix="schedcores_")
    conf = os.path.join(d, "sched_cores.conf")
    # 只写 fast 一行：升级目标改成 8-9（纯超大核）
    io.open(conf, "w", encoding="utf-8").write(
        "# mode\tesc_target\thotok\tinterval\thot\tidle\tidleoff\n"
        "fast\t8-9\t1\t6\t8\t4\t1\n")
    got, err = row_of("fast", conf)
    check(got.startswith("fast 极速 8-9 1 6 8 4 1"),
          "fast 升级目标被覆盖为 8-9、间隔 6（实际 %r）" % got)
    got2, _ = row_of("balance", conf)
    check(got2 == defaults["balance"],
          "未写进配置的 balance 仍是内置默认（实际 %r）" % got2)

    print("\n[3] 只接受那 6 个核心集合（v16.23：4-5 进入可选白名单）")
    valid = ["0-3", "4-5", "4-7", "8-9", "0-7", "4-9"]
    # 4-5 转正后不再有「内置默认合法、用户不可选」的第二口径，两边同一份清单
    acceptable = valid + ["-"]
    for v in valid:
        io.open(conf, "w", encoding="utf-8").write("fast\t%s\t1\t8\t8\t4\t1\n" % v)
        got, _ = row_of("fast", conf)
        check(got.split()[2] == v, "合法集合 %s 被接受（实际 %r）" % (v, got.split()[2] if got else ""))
    # 非法值必须回落内置默认，不能原样写进去
    for bad in ["0-9", "1-5", "abc", "", "0-3,4-7", "99"]:
        io.open(conf, "w", encoding="utf-8").write("fast\t%s\t1\t8\t8\t4\t1\n" % bad)
        got, _ = row_of("fast", conf)
        esc = got.split()[2] if got else None
        check(esc in acceptable,
              "非法集合 %r 被拒绝并回落（实际 %r）" % (bad, esc))

    print("\n[4] 自洽性：目标含 8/9 ⇒ hotok 必须为 1")
    io.open(conf, "w", encoding="utf-8").write("fast\t4-9\t0\t8\t8\t4\t1\n")
    got, _ = row_of("fast", conf)
    cols = got.split()
    esc, hotok = cols[2], cols[3]
    ok = ("8" not in esc and "9" not in esc) or hotok == "1"
    check(ok, "目标 %s 与 hotok=%s 自洽" % (esc, hotok))

    print("\n[5] 文件损坏/半截 → 回落内置默认，不产生畸形行")
    for junk in ["\n\n\n", "garbage", "fast", "fast\t4-7", "fast\t4-7\t0\n" ]:
        io.open(conf, "w", encoding="utf-8").write(junk)
        got, _ = row_of("fast", conf)
        cols = got.split()
        check(len(cols) == 8, "损坏输入 %r → 行仍为 8 列（实际 %d 列）" % (junk[:12], len(cols)))

    print("\n[6] 静态：默认表里只有那 5 个集合（防止有人在默认里塞 0-9）")
    src = io.open(UTIL, encoding="utf-8").read()
    # 默认现在是 `powersave) _def="powersave 省电 - 0 15 10 4 0" ;;` 形式
    fn = re.search(r"mode_sched_row\(\)\s*\{.*?\n\}", src, re.S)
    body = fn.group(0) if fn else ""
    rows = re.findall(r'^\s+(powersave|balance|performance|fast)\)\s+_def="([^"]+)"',
                      body, re.M)
    check(len(rows) == 4, "抽出 4 条默认行（实际 %d）" % len(rows))
    for _name, r in rows:
        cols = r.split()
        if len(cols) < 3:
            check(False, "默认行列数不足: %r" % r)
            continue
        esc = cols[2]
        # v16.22 起默认核位由 sched_cores_default_* 注入（单一来源），
        # 静态看到的是 `$(sched_cores_default_esc xxx)` —— 真值由本测试第 1 节
        # 的运行时断言保证，这里只确认「要么是命令替换、要么是合法字面量」。
        ok = esc.startswith("$(") or esc == "-" or esc in acceptable
        check(ok, "默认行 %s 的升级目标是命令替换或合法值（实际 %s）" % (cols[0], esc))

    print("\n[7] 后端写入的列序必须与读取一致（真机实测接反过）")
    # 用例：写入 <mode>\t<base>\t<esc>，读回后 base 必须是 base、esc 必须是 esc。
    # 上面 [2] 那节是 Python 直接写文件，绕过了后端代码，所以抓不到这条 —— 补上。
    d2 = tempfile.mkdtemp(prefix="schedround_")
    conf2 = os.path.join(d2, "sched_cores.conf")
    io.open(conf2, "w", encoding="utf-8").write("fast\t0-7\t8-9\n")
    out, _ = sh('. "%s" >/dev/null 2>&1\nSCHED_CORES_FILE="%s"\n'
                'sched_cores_lookup fast 1 && echo "BASE=$SCV"\n'
                'sched_cores_lookup fast 2 && echo "ESC=$SCV"\n' % (UTIL, conf2))
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

    print("\n[8] WebUI「模式列表」的可选项 == 后端白名单（4-5 必须能选到）")
    html = io.open(os.path.join(MOD, "webroot", "index.html"), encoding="utf-8").read()
    mo = re.search(r"const SC_OUT = \[([^\]]*)\]", html)
    check(mo is not None, "index.html 里有 SC_OUT 定义")
    ui = re.findall(r"'([^']+)'", mo.group(1)) if mo else []
    check(ui == valid, "WebUI 下拉与白名单逐项一致（实际 %r）" % ui)
    check("4-5" in ui, "4-5 出现在 WebUI 可选列表里")
    env_out, _ = sh('. "%s" >/dev/null 2>&1\necho "$SCHED_CORES_VALID"\n' % UTIL)
    check(env_out.split() == valid, "SCHED_CORES_VALID 与清单一致（实际 %r）" % env_out)

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
