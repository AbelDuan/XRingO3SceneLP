#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
test_templates_v15.py —— 流畅/性能 核位重排（v15 迁移）的离线自检

需求（用户 2026-09-18）：
  · 流畅（均衡）= 轻线程 0-3 + 主/渲染线程 **4-5**
  · 性能        = 轻线程 **0-3** + 主/渲染线程 4-7
  · 自定义机制（WebUI 5 选项 + sched_cores.conf）保持原样

实测依据：4-7 是同一频率域（policy4 related_cpus=4-7）、cpu4/core_ctl min=max=4
（四核强制在线）→ 限制到 4-5 省「少 2 核漏电」，代价是重载线程 ≥3 时排队拉高频。

覆盖：
  1. seed 出的模板与期望逐字一致
  2. v15 迁移：新表不动、旧表被改对、用户自建行不受影响
  3. 幂等：迁移后表不再变化（靠 tpl_v15 标记）
  4. 单一来源：mode_sched_row 的核位与 sched_cores_default_* 一致
  5. 4-5 是内置默认但不在 WebUI 白名单（自定义仍用原来的 5 个选项）

跑法: python tools/test_templates_v15.py
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


def sh(script):
    r = subprocess.run(["sh", "-c", script], capture_output=True, text=True)
    return (r.stdout or ""), (r.stderr or "")


APP_NEW = ("balance\t流畅\t{e_core}\t\t4-5\tRenderThread\t4-5\t"
           "{e_core}=Worker,Job,Async,Pool\n"
           "performance\t性能\t{e_core}\t\t{p1_core}\tRenderThread\t{p1_core}\t\n")
GAME_NEW = ("balance\t流畅\t{e_core}\t\t4-5\tUnityGfx\t4-5\t"
            "{e_core}=Audio,FMOD,Http;4-5=RenderThread,GLThread,Vulkan\n"
            "performance\t性能\t{e_core}\t\t{p1_core}\tUnityGfx\t{p1_core}\t"
            "{e_core}=Audio,FMOD,Http\n")
# v14 时代的旧值（迁移前）
APP_OLD = ("balance\t流畅\t{e_core}\t\t{p1_core}\tRenderThread\t{p1_core}\t"
           "{e_core}=Worker,Job,Async,Pool\n"
           "performance\t性能\t{p1_core}\t\t{p1_core}\tRenderThread\t{p1_core}\t\n")


def make_env(app_rows, marker=False):
    """造一个沙盒：拷 util.sh，写模板与标记，返回 (sh, 沙盒路径)。"""
    d = tempfile.mkdtemp(prefix="v15_")
    st = os.path.join(d, "st")
    # ⚠ 模板必须落在 $STATE_DIR/webui/ —— util.sh 里
    #   WEBUI_DIR="${STATE_DIR}/webui"、APP_TPL_FILE="${WEBUI_DIR}/app_templates.tsv"。
    #   夹具写到别处会让 EXISTS=N，迁移静默无事（本测试踩过两次）。
    tpl = os.path.join(st, "webui")
    os.makedirs(tpl, exist_ok=True)
    os.makedirs(os.path.join(d, "tmp"), exist_ok=True)
    app = os.path.join(tpl, "app_templates.tsv")
    game = os.path.join(tpl, "game_templates.tsv")
    io.open(app, "w", encoding="utf-8").write(
        "# id\tfriendly\tother\theaviest_thread\theaviest_cores\theavy_thread\theavy_cores\tcomm\n"
        + app_rows)
    io.open(game, "w", encoding="utf-8").write(
        "# id\tfriendly\tother\theaviest_thread\theaviest_cores\theavy_thread\theavy_cores\tcomm\n"
        + app_rows)
    if marker:
        io.open(os.path.join(st, "tpl_v15"), "w").close()
    # 预置 v14 标记，避免 v14 迁移在本测试里插一脚
    io.open(os.path.join(st, "tpl_v14"), "w").close()
    return d, st, tpl, app, game


def run_migration(d, st, tpl, app, game):
    # ⚠ 必须在 source util.sh **之前**导出：util.sh 里是
    #   `STATE_DIR="/data/adb/..."`（硬赋值，非 :-）和
    #   `WEBUI_DIR="${STATE_DIR}/webui"`（依赖 STATE_DIR）——
    #   传参是 source 之后才生效的，等于没生效（本测试第一版就踩了这个）。
    tmp = os.path.join(d, "tmp")
    os.makedirs(tmp, exist_ok=True)
    script = (
        'STATE_DIR="%s"\n'
        'TMPD="%s"\n'
        '. "%s" >/dev/null 2>&1\n'
        'migrate_templates_v15\n'
        'echo "DBG APP=$APP_TPL_FILE TMPD=$TMPD EXISTS=$([ -f "$APP_TPL_FILE" ] && echo Y || echo N) TMPW=$([ -w "$TMPD" ] && echo Y || echo N)" >&2\n'
    ) % (st, tmp, UTIL)
    out, err = sh(script)
    if os.environ.get("V15_DEBUG"):
        print("    [dbg]", err.strip())
    return out, err


def rows_of(path, ids):
    out = []
    for line in io.open(path, encoding="utf-8"):
        f = line.rstrip("\n").split("\t")
        if f and f[0] in ids:
            out.append(line.rstrip("\n"))
    return "\n".join(out) + "\n"


def main():
    print("[1] 内置默认值（单一来源）")
    out, _ = sh('. "%s" >/dev/null 2>&1\n'
                'echo "B=$(sched_cores_default_base balance)"\n'
                'echo "E=$(sched_cores_default_esc balance)"\n'
                'echo "PB=$(sched_cores_default_base performance)"\n'
                'echo "PE=$(sched_cores_default_esc performance)"\n'
                'echo "VALID=$SCHED_CORES_VALID"\n' % UTIL)
    vals = dict(l.split("=", 1) for l in out.strip().splitlines() if "=" in l)
    check(vals.get("B") == "0-3", "流畅 基线 = 0-3（实际 %s）" % vals.get("B"))
    check(vals.get("E") == "4-5", "流畅 升级目标 = 4-5（实际 %s）" % vals.get("E"))
    check(vals.get("PB") == "0-3", "性能 基线 = 0-3（实际 %s）" % vals.get("PB"))
    check(vals.get("PE") == "4-7", "性能 升级目标 = 4-7（实际 %s）" % vals.get("PE"))
    check("4-5" not in (vals.get("VALID") or ""),
          "4-5 **不在** WebUI 白名单（自定义仍用原来的 5 个选项）")

    print("\n[2] mode_sched_row 与单一来源一致")
    out, _ = sh('. "%s" >/dev/null 2>&1\n'
                'for m in powersave balance performance fast; do echo "$(mode_sched_row $m)"; done\n' % UTIL)
    rows = [l for l in out.strip().splitlines() if l]
    m = {r.split()[0]: r.split() for r in rows}
    check(m.get("balance", [None, None, None])[2] == "4-5", "流畅 row 核位=4-5")
    check(m.get("performance", [None, None, None])[2] == "4-7", "性能 row 核位=4-7")
    check(m.get("fast", [None, None, None])[2] == "4-9", "极速 row 核位=4-9（未动）")
    check(m.get("powersave", [None, None, None])[2] == "-", "省电 row 核位=-（未动）")

    print("\n[3] v15 迁移：旧表 → 新值（含用户自建行不受影响）")
    old_with_custom = APP_OLD + "myapp\t我的档\t0-3\t\t4-7\t\t\t\n"
    d, st, tpl, app, game = make_env(old_with_custom)
    run_migration(d, st, tpl, app, game)
    got = rows_of(app, {"balance", "performance"})
    check(got == APP_NEW, "应用表两档已改为新值（实际：%r）" % got[:60])
    custom = rows_of(app, {"myapp"})
    check(custom.strip().endswith("4-7"), "用户自建行未被改动")
    check(os.path.exists(os.path.join(st, "tpl_v15")), "已落 tpl_v15 标记")
    bdir = os.path.join(st, "backup")
    baks = sorted(os.listdir(bdir)) if os.path.isdir(bdir) else []
    check(any(n.startswith("app_templates.tsv.pre-v15") for n in baks),
          "旧表已备份到 $STATE_DIR/backup/*.pre-v15（实际：%s）" % (baks or "空"))

    print("\n[4] 幂等：已迁移过（有标记）再跑不动表")
    d2, st2, tpl2, app2, game2 = make_env(APP_NEW, marker=True)
    before = io.open(app2, encoding="utf-8").read()
    run_migration(d2, st2, tpl2, app2, game2)
    after = io.open(app2, encoding="utf-8").read()
    check(before == after, "有标记时表内容不变")

    print("\n[5] 新表再跑一次迁移也幂等（表已是新值 → 无 diff）")
    d3, st3, tpl3, app3, game3 = make_env(APP_NEW)
    before = io.open(app3, encoding="utf-8").read()
    run_migration(d3, st3, tpl3, app3, game3)
    after = io.open(app3, encoding="utf-8").read()
    check(before == after, "表已是新值时迁移不产生改动")

    print("\n[6] seed_*_templates 里的 printf 与新值逐字一致（防两处漂移）")
    src = io.open(UTIL, encoding="utf-8").read()
    for line, label in ((APP_NEW.splitlines()[0], "应用-流畅"),
                        (APP_NEW.splitlines()[1], "应用-性能"),
                        (GAME_NEW.splitlines()[0], "游戏-流畅"),
                        (GAME_NEW.splitlines()[1], "游戏-性能")):
        # seed 里写的是 `printf '<真实 tab 分隔的行>\n'`（\t 在单引号里就是两个字符，
        # 但实际文件里必须是真 tab）——所以直接找「printf '」+ 该行 + 「\n'」
        pat = "printf '" + line.replace("\t", "\\t") + "\\n'"
        check(pat in src, "%s 的 seed printf 与期望逐字一致" % label)

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
