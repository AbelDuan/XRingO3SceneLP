#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
test_build_stamp.py —— 模块包里的日期必须跟着**构建日**走

背景（用户 2026-09-18 反馈）：刷进手机后模块页显示的版本仍是「16.22 (2026-09-18)」，
看着像日期被写死了。真实情况：

  · `dist/SceneO3Tuner-v<ver>-<date>.zip` 的**文件名**一直是 `time.strftime` 现算的
    （没问题）；
  · 但 `module.prop` 的 `version=` / `versionCode=` 是**仓库源码里手写的**，
    KernelSU 模块页读的是这两行 —— 所以显示日期永远停在写代码那天。

修法与 index.html 的版本注入同款：**只在写 zip 时替换**，仓库源文件保持不动
（module.prop 仍是模块元数据的单一来源，只是日期由构建日决定）。

跑法: python tools/test_build_stamp.py
"""
import importlib.util, io, os, sys, tempfile

ROOT = os.path.dirname(os.path.abspath(__file__))
MOD = os.path.dirname(ROOT)
PROP = os.path.join(MOD, "module.prop")

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


def field(text, key):
    for line in text.splitlines():
        if line.startswith(key + "="):
            return line.split("=", 1)[1]
    return None


def main():
    src = io.open(PROP, encoding="utf-8").read()
    # 版本号与修订号都从源文件取，测试不绑死具体版本（改版本不该改测试）
    src_ver = field(src, "version").split()[0]
    rev = field(src, "versionCode")[8:]

    print("[1] 构建日决定 version 与 versionCode")
    out = bm.stamp_module_prop(src, "20261231")
    check(field(out, "version") == "%s (2026-12-31)" % src_ver,
          "version 换成构建日（实际 %r）" % field(out, "version"))
    check(field(out, "versionCode") == "20261231" + rev,
          "versionCode 前 8 位换成构建日、保留修订号 %s（实际 %r）" % (rev, field(out, "versionCode")))
    check("2026-09-18" not in out, "旧日期 2026-09-18 不再残留")
    check(field(src, "versionCode")[:8] not in out, "旧 versionCode 日期段不再残留")

    print("\n[2] 其它字段一字不动")
    for k in ("id", "name", "author", "description", "action"):
        check(field(out, k) == field(src, k), "%s 未被改动" % k)

    print("\n[3] 幂等：再盖一次同一个日期不出变化")
    again = bm.stamp_module_prop(out, "20261231")
    check(again == out, "重复注入结果相同")

    print("\n[4] version 没有括号日期时也能补上")
    check(bm.stamp_module_prop("version=1.2\nversionCode=1970010101\n", "20260101")
          == "version=1.2 (2026-01-01)\nversionCode=2026010101\n",
          "无括号形式补成「(构建日)」")

    print("\n[5] 只改打包内容，绝不回写仓库源文件")
    d = tempfile.mkdtemp(prefix="stamp_")
    tmp = os.path.join(d, "module.prop")
    io.open(tmp, "w", encoding="utf-8").write(src)
    got = bm.inject_module_prop(tmp, "module.prop", "16.22", "20261231")
    check(got is not None and b"2026-12-31" in got, "inject_module_prop 返回替换后的内容")
    check(io.open(tmp, encoding="utf-8").read() == src, "临时文件本身没被写回")
    check(io.open(PROP, encoding="utf-8").read() == src, "仓库 module.prop 未被写回")
    check(bm.inject_module_prop(tmp, "webroot/index.html", "16.22", "20261231") is None,
          "非 module.prop 路径返回 None（不影响其它文件的注入）")

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
