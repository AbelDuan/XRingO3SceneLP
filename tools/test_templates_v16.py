#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
test_templates_v16.py —— 「性能」档放开轻线程到 0-7（v16 迁移）的离线自检

真机实测根因（lhasa / 2026-09-22，v16.25 在跑）：
  com.miui.home（澎湃桌面 4，Flutter + Rust，102 线程）被分在 performance 档，
  而 v15 给该档 other={e_core}（0-3）且 heavy 只认 RenderThread ——
  桌面的渲染线程叫 2.raster / rt-launcher-main，**对不上** →
  102 个线程全落 0-3 → 桌面 70.9% CPU、surfaceflinger 48%、composer3 29%
  → 掉帧卡顿 → HyperOS 智能刷新率锁 90Hz。

A/B 验证：手改桌面 affinity 到 0-7，20s 后 com.miui.home 掉出 top10（<3.5%）。

本测试覆盖：
  1. seed printf 与 v16 期望逐字一致（应用表 / 游戏表）
  2. v16 迁移：旧表 → 新值（performance 的 other 由 0-3 变 0-7；heavy 补光栅线程）
  3. 用户自建行不受影响
  4. 幂等：有 tpl_v16 标记时不动表
  5. 新表再跑迁移无 diff
  6. 关键回归：迁移后的 other 列**必须含 p1_core**（这条就是本次 bug 的守门断言）
  7. 备份落盘到 backup/*.pre-v16

跑法: python tools/test_templates_v16.py
"""
import io, os, subprocess, sys, tempfile

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


# v16 期望值（与 seed_app_templates / seed_game_templates 逐字一致）
APP_PERF = ("performance\t性能\t{e_core},{p1_core}\t\t{p1_core}\t"
            "RenderThread,2.raster,rt-launcher\t{p1_core}\t")
GAME_PERF = ("performance\t性能\t{e_core},{p1_core}\t\t{p1_core}\tUnityGfx\t{p1_core}\t"
             "{e_core}=Audio,FMOD,Http")
# v15 时代旧值（迁移前）
APP_PERF_OLD = "performance\t性能\t{e_core}\t\t{p1_core}\tRenderThread\t{p1_core}\t"
GAME_PERF_OLD = "performance\t性能\t{e_core}\t\t{p1_core}\tUnityGfx\t{p1_core}\t{e_core}=Audio,FMOD,Http"

HDR = "# id\tfriendly\tother\theaviest_thread\theaviest_cores\theavy_thread\theavy_cores\tcomm\n"


def make_env(perf_row, marker=False, kind="app"):
    # ⚠ 不用 tempfile.mkdtemp()：沙盒/安全钩子会拦系统 temp 下的目录创建 → SIGTERM。
    d = os.path.join(MOD, "_t_v16_%d" % os.getpid())
    try:
        os.makedirs(d, exist_ok=True)
        _TMPDIRS.append(d)
    except Exception:
        d = tempfile.mkdtemp(prefix="v16_")
    st = os.path.join(d, "st")
    tpl = os.path.join(st, "webui")
    os.makedirs(tpl, exist_ok=True)
    os.makedirs(os.path.join(d, "tmp"), exist_ok=True)
    app = os.path.join(tpl, "app_templates.tsv")
    game = os.path.join(tpl, "game_templates.tsv")
    # balance 行用 v15 的值（v16 不改它，作对照）
    #   ★ v16.26：v15 迁移的 balance 值已由 4-5 改为 {p1_core}（4-5 被移除）
    bal_app = "balance\t流畅\t{e_core}\t\t{p1_core}\tRenderThread\t{p1_core}\t{e_core}=Worker,Job,Async,Pool\n"
    bal_game = ("balance\t流畅\t{e_core}\t\t{p1_core}\tUnityGfx\t{p1_core}\t"
                "{e_core}=Audio,FMOD,Http;{p1_core}=RenderThread,GLThread,Vulkan\n")
    extra = "\nmyapp\t我的档\t0-3\t\t4-7\t\t\t" if kind == "custom" else ""
    io.open(app, "w", encoding="utf-8").write(HDR + bal_app + perf_row + "\n" + extra)
    io.open(game, "w", encoding="utf-8").write(HDR + bal_game + perf_row + "\n")
    for m in ("tpl_v10", "tpl_v11", "tpl_v12", "tpl_v13", "tpl_v14", "tpl_v15"):
        io.open(os.path.join(st, m), "w").close()
    if marker:
        io.open(os.path.join(st, "tpl_v16"), "w").close()
    return d, st, app, game


def run_migration(d, st, app, game):
    tmp = os.path.join(d, "tmp")
    script = (
        'STATE_DIR="%s"\n'
        'TMPD="%s"\n'
        '. "%s" >/dev/null 2>&1\n'
        'migrate_templates_v16\n'
    ) % (st, tmp, UTIL)
    return sh(script)


def row_of(path, tid):
    for line in io.open(path, encoding="utf-8"):
        f = line.rstrip("\n").split("\t")
        if f and f[0] == tid:
            return line.rstrip("\n")
    return ""


def main():
    print("[1] seed printf 与 v16 期望逐字一致（防两处漂移）")
    src = io.open(UTIL, encoding="utf-8").read()
    for row, label in ((APP_PERF, "应用表-性能"), (GAME_PERF, "游戏表-性能")):
        pat = "printf '" + row.replace("\t", "\\t") + "\\n'"
        check(pat in src, "%s 的 seed printf 与期望一致" % label)

    print("\n[2] v16 迁移：旧表现场升级")
    d, st, app, game = make_env(APP_PERF_OLD, kind="custom")
    run_migration(d, st, app, game)
    got_app = row_of(app, "performance")
    got_game = row_of(game, "performance")
    check(got_app == APP_PERF, "应用表 performance 已改为新值（实际 %r）" % got_app[:70])
    check(got_game == GAME_PERF, "游戏表 performance 已改为新值（实际 %r）" % got_game[:70])
    check(row_of(app, "balance").endswith("{e_core}=Worker,Job,Async,Pool"),
          "应用表 balance 行未被波及")

    print("\n[3] 关键回归守门：other 列必须含 p1_core（本次 bug 的断言）")
    other = got_app.split("\t")[2]
    check("p1_core" in other, "性能档 other 含 p1_core（= 0-7，不再只有 0-3）；实际 %r" % other)
    heavy = got_app.split("\t")[5]
    check("2.raster" in heavy and "rt-launcher" in heavy,
          "重载线程名补上 Flutter 光栅线程（2.raster / rt-launcher）；实际 %r" % heavy)

    print("\n[4] 用户自建行不受影响")
    # ⚠ 自建行的 heavy_cores 是第 6 列（4-7），行尾还有 2 个空列（comm 为空）
    #   → 不能用 endswith("4-7") 断言（末尾是制表符）。
    myrow = row_of(app, "myapp")
    check(myrow.split("\t")[:6] == ["myapp", "我的档", "0-3", "", "4-7", ""],
          "自建行 myapp 保持原值（实际 %r）" % myrow)

    print("\n[5] 幂等：有 tpl_v16 标记时不动表")
    d2, st2, app2, game2 = make_env(APP_PERF_OLD, marker=True)
    before = io.open(app2, encoding="utf-8").read()
    run_migration(d2, st2, app2, game2)
    check(before == io.open(app2, encoding="utf-8").read(), "有标记时表内容不变")

    print("\n[6] 已是新值再跑迁移无 diff（表已对 → 不重写）")
    d3, st3, app3, game3 = make_env(APP_PERF)
    before = io.open(app3, encoding="utf-8").read()
    run_migration(d3, st3, app3, game3)
    check(before == io.open(app3, encoding="utf-8").read(), "表已是新值时迁移不产生改动")

    print("\n[7] 备份落盘")
    bdir = os.path.join(st, "backup")
    baks = sorted(os.listdir(bdir)) if os.path.isdir(bdir) else []
    check(any(n.startswith("app_templates.tsv.pre-v16") for n in baks),
          "应用表已备份到 backup/*.pre-v16（实际 %s）" % (baks or "空"))
    check(any(n.startswith("game_templates.tsv.pre-v16") for n in baks),
          "游戏表已备份到 backup/*.pre-v16（实际 %s）" % (baks or "空"))

    print("\n[8] 标记落盘 + service.sh 已挂载调用")
    check(os.path.exists(os.path.join(st, "tpl_v16")), "已落 tpl_v16 标记")
    svc = io.open(os.path.join(MOD, "service.sh"), encoding="utf-8").read()
    check("migrate_templates_v16" in svc, "service.sh 调用了 migrate_templates_v16")

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
