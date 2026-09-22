#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
test_pack_hygiene.py —— 打出来的模块包不得混入「自检沙盒」残留

背景（2026-09-22，交接换机后复现）：

  `tools/test_*.py` 与 `tools/test_sync_skip.sh` 会在**仓库根目录**建临时沙盒
  （`.test_sync_skip/`、`_t_*/` 等）。`.gitignore` 明确忽略它们，而且作者在注释里
  写清了为什么**故意**不在测试退出时 rmtree：

      宿主 safe-delete 钩子会因「批量删除 >50 文件」抛 SystemExit(1)，
      把全绿测试的退出码染成 1。残留目录交给 .gitignore 忽略。

  问题在于 `build_module.py` 的 `collect()` **不读 .gitignore**，而 `--check` 恰恰是
  「先跑自检、再打包」——于是**用 --check 打出来的包必然把沙盒一起装进去**。

  实测（本机）：交接包 84 条目，本机 --check 打出 139 条目，多出的 55 个全是沙盒文件
  （`.test_sync_skip/scene/**` 15 个 + `_t_lw_*/ _t_v16_*/ _t_schedcores_*/ ...` 40 个）。
  刷进设备后它们会落在 `/data/adb/modules/<id>/` 下，属于污染，必须挡住。

跑法: python tools/test_pack_hygiene.py
"""
import importlib.util, os, re, sys

ROOT = os.path.dirname(os.path.abspath(__file__))
MOD = os.path.dirname(ROOT)

_spec = importlib.util.spec_from_file_location("build_module",
                                              os.path.join(ROOT, "build_module.py"))
bm = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(bm)

FAILS = []
CHECKS = [0]


def check(cond, msg):
    CHECKS[0] += 1
    if cond:
        print("  \u2713 " + msg)
    else:
        FAILS.append(msg)
        print("  \u2717 " + msg)


# 自检沙盒的命名 —— 与 .gitignore 里那几条规则保持一致
SANDBOX = re.compile(r"(^|/)(\.test_[^/]*|_t_[^/]*|_rep_[^/]*|__pycache__|scratch)(/|$)")


def main():
    items = bm.collect()
    rels = [rel for _, rel in items]

    print("[1] collect() 不得收进自检沙盒")
    bad = [r for r in rels if SANDBOX.search(r)]
    check(not bad,
          "无沙盒残留（实际 %d 个%s）" % (len(bad), (": " + ", ".join(bad[:4])) if bad else ""))

    print("\n[2] 沙盒过滤不得误伤真正的模块文件")
    for must in ("module.prop", "service.sh", "customize.sh", "lib/util.sh",
                 "Scripts/4+4+2/O3/guard.sh", "webroot/index.html"):
        check(must in rels, "包内含 %s" % must)
    check(any(r.startswith("Config/4+4+2/O3/sweet_hq/") for r in rels),
          "包内含方案配置（Config/4+4+2/O3/sweet_hq/…）")

    print("\n[3] 与 .gitignore 的口径一致（新增沙盒前缀时两边都要改）")
    gi = io_open_ignore()
    for pat in (".test_sync_skip/", "_t_*/", "_t_*"):
        check(pat in gi, ".gitignore 仍忽略 %s" % pat)

    print("\n" + "=" * 62)
    if FAILS:
        print("\u274c 未通过 %d 项：" % len(FAILS))
        for f in FAILS:
            print("   - " + f)
        return 1
    print("\u2705 全部通过（%d 项断言）" % CHECKS[0])
    return 0


def io_open_ignore():
    import io
    p = os.path.join(MOD, ".gitignore")
    try:
        return io.open(p, encoding="utf-8").read()
    except OSError:
        return ""


if __name__ == "__main__":
    sys.exit(main())
