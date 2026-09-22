#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
test_templates_v15.py —— 流畅/性能 核位重排（v15 迁移）的离线自检

需求（用户 2026-09-18）：
  · 流畅（均衡）= 轻线程 0-3 + 主/渲染线程 落中核
  · 性能        = 轻线程 **0-3** + 主/渲染线程 落中核
  · 自定义机制（WebUI 选项 + sched_cores.conf）保持原样

★ v16.26 更正：本测试原先断言「流畅 = 4-5」。该值已被**彻底移除**，理由：
  · 旧依据「4-7 同域共频、收窄到 2 核更省电」被实测推翻
    （cpu4=988800 / cpu5=835200 / cpu6=988800 / cpu7=1142400，各自独立 PLL）；
  · cpu4/core_ctl min_cpus=max_cpus=4 → 4 颗中核常在线，收窄省不到漏电；
  · 净效果只有「并行度 4→2」，重载线程 ≥3 排队。
  于是 v15 迁移的 balance 目标也改为 **{p1_core}（4-7）**，`4-5` 从白名单移除。
  （migrate_templates_v15 仍保留，只是产出的值变了 —— 历史设备升级路径不变。）

覆盖：
  1. 内置默认值与 sched_cores_default_* 一致
  2. mode_sched_row 与单一来源一致
  3. v15 迁移：新表不动、旧表被改对、用户自建行不受影响
  4. 幂等：迁移后表不再变化（靠 tpl_v15 标记）
  5. 4-5 **不在** 白名单里（v16.26 已移除）

跑法: python tools/test_templates_v15.py
"""
import io, os, re, subprocess, sys, tempfile

ROOT = os.path.dirname(os.path.abspath(__file__))
MOD = os.path.dirname(ROOT)
UTIL = os.path.join(MOD, "lib", "util.sh")

FAILS = []
CHECKS = [0]
_TMPDIRS = []
# ⚠ 不在退出时清理沙盒目录：宿主 safe-delete 钩子会因「批量删除 >50 文件」
#   抛 SystemExit(1)，把测试退出码染成 1。残留 _t_* 由 .gitignore 忽略。


def check(cond, msg):
    CHECKS[0] += 1
    if cond:
        print("  \u2713 " + msg)
    else:
        FAILS.append(msg)
        print("  \u2717 " + msg)


def sh(script):
    env = dict(os.environ)
    extra = []
    for c in ("C:/Users/Abel/.workbuddy/binaries/PortableGit/versions/1.2.0/usr/bin",
              "C:/Program Files/Git/usr/bin"):
        if os.path.isdir(c):
            extra.append(c)
    if extra:
        env["PATH"] = os.pathsep.join(extra) + os.pathsep + env.get("PATH", "")
    r = subprocess.run(["sh", "-c", script], capture_output=True, text=True, env=env)
    return (r.stdout or ""), (r.stderr or "")


# v15 迁移的产出（migrate_templates_v15 负责）
#   ★ v16.26：balance 的核位由 4-5 改为 {p1_core}（4-7）
APP_V15 = ("balance\t流畅\t{e_core}\t\t{p1_core}\tRenderThread\t{p1_core}\t"
           "{e_core}=Worker,Job,Async,Pool\n"
           "performance\t性能\t{e_core}\t\t{p1_core}\tRenderThread\t{p1_core}\t\n")
# v16 之后 seed_*_templates 的新默认（seed 只维护一份，必须是**最新**值）
#   ⚠ 这条只用于 [6] 的「seed 与迁移脚本不漂移」断言：
#     migrate_templates_v15 产出 v15 值 → 随后 migrate_templates_v16 再升到 v16 值，
#     两段各司其职。seed 直接给最终值，所以两者不同名不同值是**预期**的。
APP_NEW = ("balance\t流畅\t{e_core}\t\t{p1_core}\tRenderThread\t{p1_core}\t"
           "{e_core}=Worker,Job,Async,Pool\n"
           "performance\t性能\t{e_core},{p1_core}\t\t{p1_core}\t"
           "RenderThread,2.raster,rt-launcher\t{p1_core}\t\n")
GAME_NEW = ("balance\t流畅\t{e_core}\t\t{p1_core}\tUnityGfx\t{p1_core}\t"
            "{e_core}=Audio,FMOD,Http;{p1_core}=RenderThread,GLThread,Vulkan\n"
            "performance\t性能\t{e_core},{p1_core}\t\t{p1_core}\tUnityGfx\t{p1_core}\t"
            "{e_core}=Audio,FMOD,Http\n")
# v14 时代的旧值（迁移前）
APP_OLD = ("balance\t流畅\t{e_core}\t\t{p1_core}\tRenderThread\t{p1_core}\t"
           "{e_core}=Worker,Job,Async,Pool\n"
           "performance\t性能\t{p1_core}\t\t{p1_core}\tRenderThread\t{p1_core}\t\n")


def make_env(app_rows, marker=False):
    """造一个沙盒：拷 util.sh，写模板与标记，返回 (sh, 沙盒路径)。"""
    # ⚠ 不用 tempfile.mkdtemp()：沙盒/安全钩子会拦系统 temp 下的目录创建，
    #   实测会 SIGTERM 掉测试进程。放模块目录内最稳；退出时清理，别污染仓库。
    d = os.path.join(MOD, "_t_v15_%d" % os.getpid())
    try:
        os.makedirs(d, exist_ok=True)
        _TMPDIRS.append(d)
    except Exception:
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
    check(vals.get("E") == "4-7", "流畅 升级目标 = 4-7（实际 %s）" % vals.get("E"))
    check(vals.get("PB") == "0-3", "性能 基线 = 0-3（实际 %s）" % vals.get("PB"))
    check(vals.get("PE") == "4-7", "性能 升级目标 = 4-7（实际 %s）" % vals.get("PE"))
    check("4-5" not in (vals.get("VALID") or ""),
          "4-5 **不在** 白名单里（v16.26 已移除，实际 VALID=%s）" % vals.get("VALID"))
    check((vals.get("VALID") or "").split() ==
          ["0-3", "4-7", "8-9", "0-7", "4-9"],
          "白名单恰为那 5 个（实际 %r）" % (vals.get("VALID") or "").split())

    print("\n[2] mode_sched_row 与单一来源一致")
    # ★ v16.26：行变 9 列，核位在第 3(base)/4(esc) 列
    out, _ = sh('. "%s" >/dev/null 2>&1\n'
                'for m in powersave balance performance fast; do echo "$(mode_sched_row $m)"; done\n' % UTIL)
    rows = [l for l in out.strip().splitlines() if l]
    m = {r.split()[0]: r.split() for r in rows}
    check(len(m.get("balance", [])) == 9, "balance 行为 9 列（实际 %d）" % len(m.get("balance", [])))
    check(m.get("balance", [None, None, None])[3] == "4-7", "流畅 升级目标=4-7")
    check(m.get("performance", [None, None, None])[3] == "4-7", "性能 升级目标=4-7")
    check(m.get("fast", [None, None, None])[3] == "4-9", "极速 升级目标=4-9（未动）")
    check(m.get("powersave", [None, None, None])[3] == "-", "省电 升级目标=-（未动）")

    print("\n[3] v15 迁移：旧表 → 新值（含用户自建行不受影响）")
    old_with_custom = APP_OLD + "myapp\t我的档\t0-3\t\t4-7\t\t\t\n"
    d, st, tpl, app, game = make_env(old_with_custom)
    run_migration(d, st, tpl, app, game)
    got = rows_of(app, {"balance", "performance"})
    check(got == APP_V15, "应用表两档已改为 v15 值（实际：%r）" % got[:60])
    custom = rows_of(app, {"myapp"})
    check(custom.strip().endswith("4-7"), "用户自建行未被改动")
    check(os.path.exists(os.path.join(st, "tpl_v15")), "已落 tpl_v15 标记")
    bdir = os.path.join(st, "backup")
    baks = sorted(os.listdir(bdir)) if os.path.isdir(bdir) else []
    check(any(n.startswith("app_templates.tsv.pre-v15") for n in baks),
          "旧表已备份到 $STATE_DIR/backup/*.pre-v15（实际：%s）" % (baks or "空"))

    print("\n[4] 幂等：已迁移过（有标记）再跑不动表")
    d2, st2, tpl2, app2, game2 = make_env(APP_V15, marker=True)
    before = io.open(app2, encoding="utf-8").read()
    run_migration(d2, st2, tpl2, app2, game2)
    after = io.open(app2, encoding="utf-8").read()
    check(before == after, "有标记时表内容不变")

    print("\n[5] 新表再跑一次迁移也幂等（表已是 v15 值 → 无 diff）")
    d3, st3, tpl3, app3, game3 = make_env(APP_V15)
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
