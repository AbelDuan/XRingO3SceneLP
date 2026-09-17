#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
build_module.py —— 把当前仓库打成一个可刷入的 KernelSU 模块包

产出: dist/SceneO3Tuner-v<version>-<date>.zip
      （模块包根目录必须直接是 module.prop，所以这里不套多一层目录）

跑法: python tools/build_module.py
"""
import io
import os
import re
import sys
import time
import zipfile

TOOLS = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.dirname(TOOLS)                      # 仓库根 = 模块根
DIST = os.path.join(SRC, "dist")

# 这些不该进包
SKIP_DIRS = {".git", "dist", "tools", "__pycache__", ".github"}
SKIP_FILES = {".gitignore", ".gitattributes", "LICENSE", ".DS_Store", "Thumbs.db"}


def skip(name):
    return name in SKIP_FILES or ".bak-" in name


def module_version():
    """从 module.prop 里抠出 version，用于文件名。"""
    try:
        s = io.open(os.path.join(SRC, "module.prop"), encoding="utf-8").read()
    except OSError:
        return "0.0"
    m = re.search(r"^version=(.+)$", s, re.M)
    if not m:
        return "0.0"
    return m.group(1).split()[0].strip()


# 二进制后缀：不做 CRLF 检查
BIN_EXT = {".png", ".jpg", ".jpeg", ".zip", ".tgz", ".apk", ".db",
           ".so", ".bin", ".keystore", ".jar"}


def crlf_check(paths):
    """★ 打包前拦一遍 CRLF —— 这是本模块**反复复发**的一类事故。

    为什么必须拦：Android 的 mksh 对 CRLF 零容忍。`#!/system/bin/sh\\r` 会
    `bad interpreter`；即便脚本是用 `sh file` 调起的，CRLF 也会让
    `case "$x" in` / 变量比较**静默不匹配**（值里带了 \\r），症状是
    「脚本跑了但什么都没干」，极难定位。

    历史：v7.0 首发包里 23 个文件带 CRLF，修过一轮还剩 9 个漏网
    （含一个 162 行的 shell 脚本），一直到 v16.0 才发现 → 所以做成硬闸门。
    """
    bad = []
    for abs_p, rel in paths:
        if os.path.splitext(rel)[1].lower() in BIN_EXT:
            continue
        try:
            with open(abs_p, "rb") as fh:
                d = fh.read()
        except OSError:
            continue
        if b"\r\n" in d:
            bad.append((rel, d.count(b"\r\n")))
    return bad


def collect():
    """先只收集 (绝对路径, 相对路径)，不写包 —— 便于先跑闸门。"""
    out = []
    for root, dirs, files in os.walk(SRC):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
        for f in files:
            if skip(f):
                continue
            p = os.path.join(root, f)
            rel = os.path.relpath(p, SRC).replace(os.sep, "/")
            out.append((p, rel))
    out.sort(key=lambda t: t[1])
    return out


def main():
    os.makedirs(DIST, exist_ok=True)
    ver = module_version()
    stamp = time.strftime("%Y%m%d")
    out = os.path.join(DIST, "SceneO3Tuner-v%s-%s.zip" % (ver, stamp))

    items = collect()

    # ★ CRLF 闸门：硬失败，不给放行
    bad_crlf = crlf_check(items)
    if bad_crlf:
        print("!! 以下文件含 CRLF，禁止打包（Android shell 对 CRLF 零容忍）:")
        for rel, n in bad_crlf:
            print("     %-70s %d 行" % (rel, n))
        print("   修法：按字节把 \\r\\n 换成 \\n，例如")
        print("     python -c \"p='<file>';d=open(p,'rb').read();"
              "open(p,'wb').write(d.replace(b'\\r\\n',b'\\n'))\"")
        return 1

    entries = []
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        for p, rel in items:
            z.write(p, rel)
            entries.append(rel)

    # 模块包的自检：根必须有 module.prop，且不能混进测试/备份
    assert "module.prop" in entries, "包根缺少 module.prop —— 刷入会失败"
    bad = [e for e in entries if ".bak-" in e or e.startswith("tools/")]
    assert not bad, "包里混进了不该有的文件: %s" % bad

    entries.sort()
    print("WROTE %s  (%d bytes, %d entries)" % (out, os.path.getsize(out), len(entries)))
    print()
    print("关键文件:")
    for k in ("module.prop", "service.sh", "customize.sh",
              "lib/util.sh", "Scripts/4+4+2/O3/guard.sh",
              "Scripts/4+4+2/O3/camera_freq_guard.sh",
              "webroot/index.html"):
        print(("  OK  " if k in entries else "  !!  ") + k)
    return 0


if __name__ == "__main__":
    sys.exit(main())
