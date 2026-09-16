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
SKIP_FILES = {".gitignore", "LICENSE", ".DS_Store", "Thumbs.db"}


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


def main():
    os.makedirs(DIST, exist_ok=True)
    ver = module_version()
    stamp = time.strftime("%Y%m%d")
    out = os.path.join(DIST, "SceneO3Tuner-v%s-%s.zip" % (ver, stamp))

    entries = []
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        for root, dirs, files in os.walk(SRC):
            dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
            for f in files:
                if skip(f):
                    continue
                p = os.path.join(root, f)
                rel = os.path.relpath(p, SRC).replace(os.sep, "/")
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
