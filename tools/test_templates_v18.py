#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
test_templates_v18.py —— 省电档「窄出口」（powersave heavy 行）的种子与迁移

真机事故（lhasa · 微信）：powersave 档把整应用 **333/333** 个线程（含
RenderThread 与主线程）硬锁在 0-3，而该档升级目标是 "-"、模板又没有
heavy 分流 —— 没有任何出口：进聊天 / 内容加载时 4 个小核扛不住，
表现为滑动卡顿、内容重载。

修复（本测试覆盖的两半）：
  (a) 种子两处逐字一致地带上窄出口，且**只动 powersave 一行**：
      1. Config/webui_model.seed.json → modes.powersave.cpuset 加
         heavy_thread=RenderThread / heavy_cores={p1_core}，main/other 仍 0-3；
         balance / performance / fast 三档 cpuset 逐字不变；
      2. lib/util.sh seed_app_templates() 的 powersave 行加
         RenderThread<TAB>{p1_core}，其余三行逐字不变；
      3. {p1_core} 展开 = 4-7（cpu_semantic 单一来源）。
  (e) migrate_templates_v18 把新 powersave 行装进**已有安装**的
      app_templates.tsv（状态目录里的活数据，安装从不覆盖它）：
      只改内置 powersave 行；其余三行 / 用户自建行 / 游戏表一律不动；
      改前备份 *.pre-v18；$STATE_DIR/tpl_v18 标记幂等；service.sh 已接线。

  为什么是新标记 tpl_v18 而不是扩展 v17：真机上 **tpl_v17 标记已存在**
  （v17.x 已刷入），扩展 v17 函数会被 `[ -f 标记 ]` 直接挡掉、永远不再执行
  —— 已有安装就拿不到新行。

跑法: python tools/test_templates_v18.py
"""
import io, json, os, subprocess, sys

ROOT = os.path.dirname(os.path.abspath(__file__))
MOD = os.path.dirname(ROOT)
UTIL = os.path.join(MOD, "lib", "util.sh")
SEED = os.path.join(MOD, "Config", "webui_model.seed.json")
SVC = os.path.join(MOD, "service.sh")

FAILS = []
CHECKS = [0]
# ⚠ 不在退出时清理沙盒：宿主 safe-delete 钩子会把全绿测试的退出码染成 1
#   （与 test_templates_v17.py 同一惯例）。残留 _t_* 由 .gitignore 忽略。


def check(cond, msg):
    CHECKS[0] += 1
    if cond:
        print("  ✓ " + msg)
    else:
        FAILS.append(msg)
        print("  ✗ " + msg)


def sh(script):
    r = subprocess.run(["sh", "-c", script], capture_output=True, text=True)
    return (r.stdout or ""), (r.stderr or "")


HDR = "# id\tfriendly\tother\theaviest_thread\theaviest_cores\theavy_thread\theavy_cores\tcomm\n"

# ---- 四行的黄金值（powersave = 本次新值；其余三行 = 现值，必须逐字不动）----
APP_PS_NEW = "powersave\t省电\t{e_core}\t\t{e_core}\tRenderThread\t{p1_core}\t\n"
APP_PS_OLD = "powersave\t省电\t{e_core}\t\t{e_core}\t\t\t\n"   # 已有安装里的旧行
APP_BAL = ("balance\t流畅\t{e_core}\t\t{p1_core}\tRenderThread\t{p1_core}\t"
           "{e_core}=Worker,Job,Async,Pool\n")
APP_PERF = ("performance\t性能\t{e_core},{p1_core}\t\t{p1_core}\t"
            "RenderThread,2.raster,rt-launcher\t{p1_core}\t\n")
APP_FAST = "fast\t极速\t{e_core},{p1_core}\t\t{e_core},{p1_core}\t\t\t\n"
CUSTOM = "myapp\t我的档\t4-7\t\t4-7\tHeavy\t4-7\tHeavy@4-7\n"
# 游戏表本次**不动**（事故是普通应用 WeChat；改动范围 = APP_TPL_FILE）
GAME_PS = "powersave\t省电\t{e_core}\t\t{e_core}\t\t\t\n"

# WebUI 种子里三档不变的 cpuset（逐字断言 = 顺带挡住「顺手给别的档也加 heavy」）
MODE_GOLDEN = {
    "balance":     {"main_thread": "0-7", "other": "0-5"},
    "performance": {"main_thread": "0-7", "other": "0-7"},
    "fast":        {"main_thread": "0-9", "other": "0-9"},
}

_SEQ = [0]


def make_env(seed_rows=None, marker=False, game=True, app_exists=True):
    """造一个「已有安装」沙盒：st/webui 下放旧表 + v10..v17 标记。

    app_exists=False：不创建 app_templates.tsv —— 专给 seed_app_templates
    用（它对已存在的表会 `[ -f ] && return 0` 直接跳过）。
    """
    _SEQ[0] += 1
    d = os.path.join(MOD, "_t_v18_%d_%d" % (os.getpid(), _SEQ[0]))
    os.makedirs(os.path.join(d, "st", "webui"), exist_ok=True)
    os.makedirs(os.path.join(d, "tmp"), exist_ok=True)
    st = os.path.join(d, "st")
    app = os.path.join(st, "webui", "app_templates.tsv")
    gme = os.path.join(st, "webui", "game_templates.tsv")
    if app_exists:
        rows = seed_rows if seed_rows is not None else (
            HDR + APP_PS_OLD + APP_BAL + APP_PERF + APP_FAST + CUSTOM)
        io.open(app, "w", encoding="utf-8").write(rows)
    if game:
        io.open(gme, "w", encoding="utf-8").write(HDR + GAME_PS)
    # 设备已有的历史标记（真机 tpl_v10/tpl_v11/…/tpl_v17 全在）
    for m in ("tpl_v10", "tpl_v11", "tpl_v12", "tpl_v13",
              "tpl_v14", "tpl_v15", "tpl_v16", "tpl_v17"):
        io.open(os.path.join(st, m), "w").close()
    if marker:
        io.open(os.path.join(st, "tpl_v18"), "w").close()
    return d, st, app, gme


def sandbox_prefix(d):
    return 'STATE_DIR="%s"\nTMPD="%s"\n. "%s" >/dev/null 2>&1\n' \
           % (os.path.join(d, "st"), os.path.join(d, "tmp"), UTIL)


def run_migration(d):
    return sh(sandbox_prefix(d) + "migrate_templates_v18\n")


def run_seed(d):
    return sh(sandbox_prefix(d) + "seed_app_templates\ncat \"$APP_TPL_FILE\"\n")


def line_of(path, tid):
    for l in io.open(path, encoding="utf-8"):
        if l.startswith(tid + "\t") or l.startswith(tid + "\n"):
            return l.rstrip("\n")
    return None


def main():
    # ============================================================
    print("[1] (a) WebUI 种子：powersave.cpuset 带窄出口，main/other 不动")
    model = json.load(io.open(SEED, encoding="utf-8"))
    ps = model["modes"]["powersave"]["cpuset"]
    check(ps.get("heavy_thread") == "RenderThread",
          "powersave.cpuset.heavy_thread == RenderThread（实际 %r）"
          % ps.get("heavy_thread"))
    check(ps.get("heavy_cores") == "{p1_core}",
          "powersave.cpuset.heavy_cores == {p1_core}（实际 %r）"
          % ps.get("heavy_cores"))
    check(ps.get("main_thread") == "0-3" and ps.get("other") == "0-3",
          "powersave main/other 仍 0-3（实际 %r）" % ps)

    print("\n[2] (a) {p1_core} 展开 = 4-7（cpu_semantic 单一来源）")
    out, _ = sh('. "%s" >/dev/null 2>&1\nexpand_semantic "{p1_core}"\n' % UTIL)
    check(out.strip() == "4-7",
          "expand_semantic({p1_core}) == 4-7（实际 %r）" % out.strip())

    print("\n[3] (a) 其余三档 cpuset 逐字不变（不许顺手加 heavy）")
    for m, golden in MODE_GOLDEN.items():
        got = model["modes"][m]["cpuset"]
        check(got == golden, "%s.cpuset 未被改动（实际 %r）" % (m, got))

    print("\n[4] (a) seed_app_templates：powersave 行带窄出口，其余三行不变")
    d, st, app, _ = make_env(app_exists=False)   # 无表 → 走全新种子
    out, err = run_seed(d)
    check(line_of(app, "powersave") == APP_PS_NEW.rstrip("\n"),
          "新装种子 powersave 行 == 黄金值（实际 %r）" % line_of(app, "powersave"))
    ps_cols = (line_of(app, "powersave") or "").split("\t")
    check(len(ps_cols) == 8 and ps_cols[2] == "{e_core}" and ps_cols[4] == "{e_core}"
          and ps_cols[7] == "",
          "powersave other/main 仍 {e_core}（0-3）、comm 仍为空（实际 %r）" % ps_cols)
    check(line_of(app, "balance") == APP_BAL.rstrip("\n"), "种子 balance 行逐字不变")
    check(line_of(app, "performance") == APP_PERF.rstrip("\n"),
          "种子 performance 行逐字不变")
    check(line_of(app, "fast") == APP_FAST.rstrip("\n"), "种子 fast 行逐字不变")

    # ============================================================
    print("\n[5] (e) 迁移：已有安装的旧 powersave 行 → 新行（tpl_v18）")
    d2, st2, app2, gme2 = make_env()             # 旧表：powersave 无 heavy
    game_before = io.open(gme2, encoding="utf-8").read()
    out, err = run_migration(d2)
    check(line_of(app2, "powersave") == APP_PS_NEW.rstrip("\n"),
          "已有安装的 powersave 行已升级（实际 %r）" % line_of(app2, "powersave"))
    check(line_of(app2, "balance") == APP_BAL.rstrip("\n"),
          "balance 行不动（实际 %r）" % line_of(app2, "balance"))
    check(line_of(app2, "performance") == APP_PERF.rstrip("\n"), "performance 行不动")
    check(line_of(app2, "fast") == APP_FAST.rstrip("\n"), "fast 行不动")
    check(line_of(app2, "myapp") == CUSTOM.rstrip("\n"),
          "用户自建行逐字不动（实际 %r）" % line_of(app2, "myapp"))
    check(io.open(gme2, encoding="utf-8").read() == game_before,
          "游戏表整表不动（本次范围只有 APP_TPL_FILE）")

    print("\n[6] (e) 备份 + 幂等标记 + service.sh 接线")
    bk = os.path.join(st2, "backup")
    names = os.listdir(bk) if os.path.isdir(bk) else []
    check(any("app_templates.tsv.pre-v18" in n for n in names),
          "改前备份 backup/*.pre-v18 存在（实际 %r）" % names[:4])
    # ★ 2026-09-23 真机排查：在 **webui/**（表所在的目录）下找 *.pre-v18 一个都
    #   没找到 → 备份约定与 v10..v17 完全一致，落在 **$STATE_DIR/backup/**
    #   （与表不同目录；见 lib/util.sh migrate_templates_v10 起的同一写法）。
    #   把「落点」和「内容」一起钉死：文件必须在 backup/、webui/ 下必须没有，
    #   且内容 = 迁移前的整份旧表（powersave 仍是旧行，没有 RenderThread 窄出口）。
    bkp = os.path.join(bk, "app_templates.tsv.pre-v18")
    check(os.path.isfile(bkp)
          and not os.path.exists(os.path.join(st2, "webui",
                                              "app_templates.tsv.pre-v18")),
          "备份落点 = $STATE_DIR/backup/app_templates.tsv.pre-v18，"
          "webui/ 下没有（真机排查找错的就是这个目录）")
    seeded = HDR + APP_PS_OLD + APP_BAL + APP_PERF + APP_FAST + CUSTOM
    bk_txt = (io.open(bkp, encoding="utf-8").read()
              if os.path.isfile(bkp) else None)   # 备份缺失时优雅判红，不抛栈
    check(bk_txt == seeded,
          "备份内容 = 迁移前整份旧表（powersave 仍旧行，无 RenderThread 出口）")
    check(os.path.isfile(os.path.join(st2, "tpl_v18")),
          "tpl_v18 标记已落盘")
    # 幂等：有标记后再跑一次，把表改回旧值也不许被再改
    io.open(app2, "w", encoding="utf-8").write(
        HDR + APP_PS_OLD + APP_BAL + APP_PERF + APP_FAST)
    run_migration(d2)
    check(line_of(app2, "powersave") == APP_PS_OLD.rstrip("\n"),
          "已有 tpl_v18 标记 → 第二次运行不动表（幂等，实际 %r）"
          % line_of(app2, "powersave"))
    svc = io.open(SVC, encoding="utf-8").read()
    check("migrate_templates_v18" in svc, "service.sh 调用了 migrate_templates_v18")
    util_src = io.open(UTIL, encoding="utf-8").read()
    check("migrate_templates_v18()" in util_src and 'tpl_v18' in util_src,
          "lib/util.sh 定义了 migrate_templates_v18 + tpl_v18 标记")

    print("\n" + "=" * 62)
    if FAILS:
        print("❌ 未通过 %d 项：" % len(FAILS))
        for f in FAILS:
            print("   - " + f)
        return 1
    print("✅ 全部通过（%d 项断言）" % CHECKS[0])
    return 0


if __name__ == "__main__":
    sys.exit(main())
