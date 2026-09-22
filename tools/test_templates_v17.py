#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
test_templates_v17.py —— 「已存在的字面量 4-5」必须被迁移回 {p1_core}（4-7）

真机发现（lhasa / 2026-09-22，上机调试 v17.1）：

  v16.26 把 `4-5` 从**可选核位白名单**、**内置默认 esc**、**新装种子**、以及
  v15/v16 迁移里删掉了 —— 但漏了一件事：

      `app_templates.tsv` / `game_templates.tsv` 是**模块状态目录里的活数据**，
      安装从不覆盖它（lib/util.sh:523）。**已有安装**里那两行是 v16.22 时代写下的
      **字面量** `4-5`（不是 {p1_core}），而**没有任何迁移**去改它。

  真机证据（v17.1 已刷入）：

      app_templates.tsv  balance 流畅 … RenderThread 4-5 …
      game_templates.tsv balance 流畅 … UnityGfx 4-5 … 4-5=RenderThread,GLThread,Vulkan
      /data/local/tmp/_wui/t.targets  →  232 个目标里 **158 个** heavy_cores=4-5

  也就是说：交接认为"纯负收益、已彻底删除"的那套绑核，在 158 个应用上**仍在生效**
  （只改了白名单/默认，没改已落地的事实数据）。

  本测试覆盖：
    1. 应用表：heavy_cores 的 4-5 → {p1_core}
    2. 游戏表：heavy_cores 与 comm 列里的 4-5 → {p1_core}（两处都要改）
    3. 用户自建行不受影响
    4. 幂等：已有 tpl_v17 标记时不动表
    5. 备份落盘到 backup/*.pre-v17
    6. 表里不再残留 4-5

  跑法: python tools/test_templates_v17.py
"""
import io, os, subprocess, sys

ROOT = os.path.dirname(os.path.abspath(__file__))
MOD = os.path.dirname(ROOT)
UTIL = os.path.join(MOD, "lib", "util.sh")

FAILS = []
CHECKS = [0]
# ⚠ 不在退出时清理沙盒：宿主 safe-delete 钩子会因「批量删除 >50 文件」抛 SystemExit(1)，
#   把全绿测试的退出码染成 1。残留 _t_* 由 .gitignore 忽略。


def check(cond, msg):
    CHECKS[0] += 1
    if cond:
        print("  \u2713 " + msg)
    else:
        FAILS.append(msg)
        print("  \u2717 " + msg)


def sh(script):
    env = dict(os.environ)
    r = subprocess.run(["sh", "-c", script], capture_output=True, text=True, env=env)
    return (r.stdout or ""), (r.stderr or "")


HDR = "# id\tfriendly\tother\theaviest_thread\theaviest_cores\theavy_thread\theavy_cores\tcomm\n"

# 真机上那两行（字面量 4-5，v16.22 时代写下的）
APP_BAL_OLD = "balance\t流畅\t0-3\t\t0-3\tRenderThread\t4-5\t{e_core}=Worker,Job,Async,Pool\n"
GAME_BAL_OLD = ("balance\t流畅\t0-3\t\t0-3\tUnityGfx\t4-5\t"
                "{e_core}=Audio,FMOD,Http;4-5=RenderThread,GLThread,Vulkan\n")
# 期望：所有 4-5 变成 {p1_core}
APP_BAL_NEW = "balance\t流畅\t0-3\t\t0-3\tRenderThread\t{p1_core}\t{e_core}=Worker,Job,Async,Pool\n"
GAME_BAL_NEW = ("balance\t流畅\t0-3\t\t0-3\tUnityGfx\t{p1_core}\t"
                "{e_core}=Audio,FMOD,Http;{p1_core}=RenderThread,GLThread,Vulkan\n")
CUSTOM = "myapp\t我的档\t4-5\t\t4-5\tRenderThread\t4-5\t4-5=X\n"


_SEQ = [0]


def make_env(marker=False, custom=False):
    # ⚠ 每次调用必须**独立目录**：同一 pid 下复用会让上一次跑出的 tpl_v17 标记
    #   把下一次的迁移直接挡掉（第一版就栽在这，表现为"内置行没改"的假失败）。
    _SEQ[0] += 1
    d = os.path.join(MOD, "_t_v17_%d_%d" % (os.getpid(), _SEQ[0]))
    os.makedirs(os.path.join(d, "st", "webui"), exist_ok=True)
    os.makedirs(os.path.join(d, "tmp"), exist_ok=True)

    st = os.path.join(d, "st")
    app = os.path.join(st, "webui", "app_templates.tsv")
    game = os.path.join(st, "webui", "game_templates.tsv")
    io.open(app, "w", encoding="utf-8").write(HDR + APP_BAL_OLD + (CUSTOM if custom else ""))
    io.open(game, "w", encoding="utf-8").write(HDR + GAME_BAL_OLD)
    for m in ("tpl_v10", "tpl_v11", "tpl_v12", "tpl_v13", "tpl_v14", "tpl_v15", "tpl_v16"):
        io.open(os.path.join(st, m), "w").close()
    if marker:
        io.open(os.path.join(st, "tpl_v17"), "w").close()
    return d, st, app, game


def run_migration(d, st):
    return sh('STATE_DIR="%s"\nTMPD="%s"\n. "%s" >/dev/null 2>&1\nmigrate_templates_v17\n'
              % (st, os.path.join(d, "tmp"), UTIL))


def line_of(path, tid):
    for l in io.open(path, encoding="utf-8"):
        if l.startswith(tid + "\t") or l.startswith(tid + "\n"):
            return l.rstrip("\n")
    return None


def main():
    print("[1] 已有安装的字面量 4-5 → {p1_core}")
    d, st, app, game = make_env()
    out, err = run_migration(d, st)
    check(line_of(app, "balance") == APP_BAL_NEW.rstrip("\n"),
          "应用表 balance 已改（实际 %r）" % line_of(app, "balance"))
    check(line_of(game, "balance") == GAME_BAL_NEW.rstrip("\n"),
          "游戏表 balance 已改（heavy_cores 与 comm 两处，实际 %r）" % line_of(game, "balance"))
    check("4-5" not in io.open(app, encoding="utf-8").read()
          and "4-5" not in io.open(game, encoding="utf-8").read(),
          "两张表里都不再残留 4-5")

    print("\n[2] 用户自建行不受影响")
    d2, st2, app2, game2 = make_env(custom=True)
    run_migration(d2, st2)
    check(line_of(app2, "balance") == APP_BAL_NEW.rstrip("\n"), "内置 balance 行已改")
    check(line_of(app2, "myapp") == CUSTOM.rstrip("\n"),
          "自建行逐字不变（实际 %r）" % line_of(app2, "myapp"))

    print("\n[3] 幂等：已有 tpl_v17 标记时不动表")
    d3, st3, app3, game3 = make_env(marker=True)
    run_migration(d3, st3)
    check(line_of(app3, "balance") == APP_BAL_OLD.rstrip("\n"),
          "有标记 → 表原样不动（实际 %r）" % line_of(app3, "balance"))

    print("\n[4] 备份落盘")
    bk = os.path.join(st, "backup")
    names = os.listdir(bk) if os.path.isdir(bk) else []
    check(any("app_templates.tsv.pre-v17" in n for n in names),
          "应用表备份存在（实际 %r）" % names[:4])
    check(any("game_templates.tsv.pre-v17" in n for n in names),
          "游戏表备份存在")

    print("\n[5] 静态：迁移已在 service.sh 里被调用")
    svc = io.open(os.path.join(MOD, "service.sh"), encoding="utf-8").read()
    check("migrate_templates_v17" in svc, "service.sh 调用了 migrate_templates_v17")

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
