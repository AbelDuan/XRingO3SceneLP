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
# ⚠ 自检沙盒：tools/test_*.py 与 test_sync_skip.sh 会在**仓库根**建临时目录，
#   .gitignore 明确忽略了它们（测试故意不 rmtree，见 .gitignore 里的说明），
#   但**本文件不读 .gitignore** —— 而 `--check` 正是「先跑自检、再打包」，
#   于是 --check 打出来的包必然把沙盒一起装进去（实测 v17.1：84 → 139 条目）。
#   ⚠ 改这里时同步改 .gitignore；两边口径由 tools/test_pack_hygiene.py 锁住。
SKIP_PREFIXES = (".test_", "_t_", "_rep_", "scratch")


def skip_dir(name):
    return name in SKIP_DIRS or name.startswith(SKIP_PREFIXES)


def skip(name):
    return (name in SKIP_FILES or ".bak-" in name
            or name.startswith(SKIP_PREFIXES) or name.endswith(".pyc"))


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
        dirs[:] = [d for d in dirs if not skip_dir(d)]
        for f in files:
            if skip(f):
                continue
            p = os.path.join(root, f)
            rel = os.path.relpath(p, SRC).replace(os.sep, "/")
            out.append((p, rel))
    out.sort(key=lambda t: t[1])
    return out


def run_offline_suite():
    """跑离线自检套件（--check）。

    默认构建**不**跑测试：构建是高频动作，测试失败会拖慢它；但发版前应当
    显式跑一次 —— 用 `python tools/build_module.py --check`。
    涵盖 lint + tools/test_*.py（test_pin_mode.py 会递归跑其余测试，已自排除；
    跳过需要真实方案目录布局的 test_sync_skip.sh）。任一失败即中止打包。
    """
    import subprocess
    suite = [
        ("lint_module.py", "模块结构自检"),
        ("test_build_stamp.py", "产物日期跟随构建日"),
        ("test_load_aware.py", "负载感知四档语义"),
        ("test_bigcore_guard.py", "8-9 封锁"),
        ("test_pin_mode.py", "落核模式默认值"),
        ("test_sched_cores.py", "四档核心集合可自定义"),
        ("test_webui_render.py", "WebUI 渲染（无头）"),
        ("test_templates_v15.py", "流畅/性能核位重排迁移"),
        ("test_camera_guard.py", "相机档位（手动应急工具的写入逻辑）"),
        ("test_pack_hygiene.py", "打包卫生（不得混入自检沙盒）"),
        ("test_templates_v17.py", "4-5 字面量迁移（已有安装）"),
    ]
    rc = 0
    for f, desc in suite:
        p = os.path.join(TOOLS, f)
        if not os.path.exists(p):
            print("  ─  跳过 %s（不存在）" % f)
            continue
        print("  ▶  %s —— %s" % (f, desc))
        r = subprocess.run([sys.executable, p], capture_output=True, text=True)
        tail = (r.stdout or "").strip().splitlines()
        last = tail[-1] if tail else ""
        ok = r.returncode == 0
        print("      %s %s" % ("PASS" if ok else "FAIL", last[:70]))
        if not ok:
            rc = 1
    return rc


def needs_exec(rel):
    """.sh 与无扩展名的可执行（如 pinwatch ELF）在包里必须是 0755。"""
    if rel.endswith(".sh"):
        return True
    base = rel.rsplit("/", 1)[-1]
    return "." not in base and base not in ("module.prop", "LICENSE")


def inject_version(path, rel, ver, stamp):
    """把前端里硬编码的版本号换成当前版本（只影响**打包内容**，不写源文件）。

    背景：`webroot/index.html` 的标题栏有 `<span class="h-ver" id="ver">16.12 (…)`，
    是手写的。构建脚本原来只从 module.prop 取版本做**文件名**，从不注入前端 ——
    于是模块升到 16.20、WebUI 里仍显示 16.12（用户在界面上看到的就是这个）。
    这里在写 zip 时替换，仓库源文件保持不动（版本号单一来源 = module.prop）。
    """
    if rel not in ("webroot/index.html", "webroot/index.htm"):
        return None
    try:
        s = io.open(path, encoding="utf-8").read()
    except OSError:
        return None
    text = "%s (%s-%s-%s)" % (ver, stamp[0:4], stamp[4:6], stamp[6:8])
    new = re.sub(r'(id="ver"[^>]*>)[^<]*(</span>)',
                 lambda m: m.group(1) + text + m.group(2), s, count=1)
    if new == s:
        return None          # 没有可替换的标记 → 按原文件打包
    return new.encode("utf-8")


def stamp_module_prop(text, stamp):
    """把 module.prop 文本里的日期改成构建日 stamp（YYYYMMDD）。

    · `version=16.22 (2026-09-18)` → 括号里的日期换成构建日；
      没写括号日期的 `version=1.2` 会补上 `(构建日)`。
    · `versionCode=2026091822` → 只换**前 8 位日期段**，保留末尾修订号（22）。
    """
    pretty = "%s-%s-%s" % (stamp[0:4], stamp[4:6], stamp[6:8])
    new = re.sub(r"(?m)^(version=[^\s(]+)\s*(?:\([^)]*\))?\s*$",
                 lambda m: "%s (%s)" % (m.group(1), pretty), text)
    new = re.sub(r"(?m)^versionCode=\d{8}", "versionCode=" + stamp, new)
    return new


def inject_module_prop(path, rel, ver, stamp):
    """module.prop 的 version / versionCode 里日期换成**构建日**（只影响打包内容）。

    背景：`dist/*.zip` 的文件名一直是 time.strftime 现算的，但 module.prop 的
    `version=16.22 (2026-09-18)` 与 `versionCode=2026091822` 是源码里手写的 ——
    KernelSU 模块页读的正是这两行，所以显示日期永远停在写代码那天。
    这里在写 zip 时替换；仓库源文件保持不动（与 index.html 的版本注入同款）。
    """
    if rel != "module.prop":
        return None
    try:
        s = io.open(path, encoding="utf-8").read()
    except OSError:
        return None
    new = stamp_module_prop(s, stamp)
    return new.encode("utf-8") if new != s else None


def main():
    args = sys.argv[1:]
    if "--check" in args:
        print("== 离线自检套件 ==")
        if run_offline_suite() != 0:
            print("!! 自检未通过，已中止打包")
            return 1
        print("== 自检通过，继续打包 ==")
        print()

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
    injected = []
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        for p, rel in items:
            data = inject_version(p, rel, ver, stamp)
            if data is None:
                data = inject_module_prop(p, rel, ver, stamp)
            if data is None:
                data = io.open(p, "rb").read()
            else:
                injected.append(rel)
            # 显式写权限位：zip 的 external_attr 决定解包后的模式。
            # ⚠ 实测：直接用 z.write() 会带上构建账户的 umask（普通文件 0600），
            #   只靠安装脚本的 set_perm_recursive 兜底。这里统一写成
            #   0755（.sh 与 ELF）/ 0644（其余），包里就是自洽的。
            zi = zipfile.ZipInfo(rel)
            zi.external_attr = (0o100755 if needs_exec(rel) else 0o100644) << 16
            zi.compress_type = zipfile.ZIP_DEFLATED
            z.writestr(zi, data)
            entries.append(rel)

    # 模块包的自检：根必须有 module.prop，且不能混进测试/备份
    assert "module.prop" in entries, "包根缺少 module.prop —— 刷入会失败"
    bad = [e for e in entries if ".bak-" in e or e.startswith("tools/")]
    assert not bad, "包里混进了不该有的文件: %s" % bad

    entries.sort()
    print("WROTE %s  (%d bytes, %d entries)" % (out, os.path.getsize(out), len(entries)))
    if injected:
        print("已注入版本号（%s）：%s" % (ver, ", ".join(injected)))
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
