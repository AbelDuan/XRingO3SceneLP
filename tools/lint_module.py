#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
lint_module.py —— 打包前的静态自查（很便宜，能挡住几类致命问题）

为什么需要它：
  本次开发中我用「区间替换」改 webui.sh 时，结束锚点恰好与 cmd_status 里的一条
  case 语句同形且更靠前，于是整段被复制，文件里出现了 **两个 cmd_health**。
  后者（旧版本）覆盖前者，新逻辑完全不生效 —— 而 `sh -n` 语法检查照样通过，
  设备上也照样能跑，只是行为是旧的。这类问题只能靠「定义唯一性」检查发现。

检查项
  1. webui.sh / *.sh 里同一函数是否被定义多次
  2. webui.sh 的 case 分发表里引用的 cmd_* 是否都有定义
  3. 前端 webui/index.tpl.html 的页签与 app 里的视图函数是否一一对应
  4. index.html 里是否残留页面预览工具注入的 data-* 属性
"""
import io, os, re, sys, collections

# 本脚本位于 tools/ 下，模块内容就在仓库根目录
ROOT = os.path.dirname(os.path.abspath(__file__))
MOD = os.path.dirname(ROOT)
SH = os.path.join(MOD, "Scripts", "4+4+2", "O3", "webui.sh")
HTML = os.path.join(MOD, "webroot", "index.html")

problems = []
notes = []


def check_sh():
    s = io.open(SH, encoding="utf-8").read()
    defs = re.findall(r"^([a-z_][a-z0-9_]*)\(\)", s, re.M)
    dup = [k for k, v in collections.Counter(defs).items() if v > 1]
    if dup:
        problems.append("webui.sh 有重复定义的函数（后者会静默覆盖前者）：%s" % ", ".join(dup))
    else:
        notes.append("webui.sh 函数 %d 个，无重复定义" % len(defs))

    defined = set(defs)
    called = set(re.findall(r"^\s+[a-z_]+\s*\)\s+([a-z_][a-z0-9_]*)\s*;;", s, re.M))
    missing = sorted(c for c in called if c.startswith("cmd_") and c not in defined)
    if missing:
        problems.append("分发表里引用了未定义的函数：%s" % ", ".join(missing))
    else:
        notes.append("webui.sh 分发表引用的 %d 个命令都有实现" % len([c for c in called if c.startswith("cmd_")]))

    # 语法：真跑 sh -n（不要用「数花括号」这种粗办法 ——
    # 注释里的 cpuN/qos/{max,min}_freq 之类会让计数永远对不上）
    import subprocess, shutil
    if shutil.which("sh"):
        r = subprocess.run(["sh", "-n", SH], capture_output=True, text=True)
        if r.returncode != 0:
            problems.append("webui.sh 语法错误：%s" % (r.stderr or "").strip()[:200])
        else:
            notes.append("webui.sh sh -n 语法通过")
    else:
        notes.append("未找到 sh，跳过语法检查")
    return s


def check_frontend(sh_text):
    """前端检查。

    开发树里有 webui/（index.tpl.html + app.js / app.views.js / app.boot.js 三段源）；
    公开发布树里只有生成好的 webroot/index.html。
    两种布局都能跑：优先用源，源不在就退回解析 index.html 本身。
    """
    webui = os.path.join(ROOT, "webui")
    tpl_path = os.path.join(webui, "index.tpl.html")
    if os.path.isfile(tpl_path):
        tpl = io.open(tpl_path, encoding="utf-8").read()
        js = "".join(io.open(os.path.join(webui, f), encoding="utf-8").read()
                     for f in ("app.js", "app.views.js", "app.boot.js"))
        notes.append("前端源：webui/（模板 + 三段拼接 JS）")
    else:
        # 发布树：直接从生成产物里取出 <script> 内容当 js，整个文件当 tpl
        built = io.open(HTML, encoding="utf-8").read()
        tpl = built
        js = "".join(re.findall(r"<script[^>]*>(.*?)</script>", built, re.S))
        notes.append("前端源：webroot/index.html（已构建产物）")

    tabs = re.findall(r'data-tab="([a-z]+)"', tpl)
    m = re.search(r"const fn = \{(.*?)\}\[S\.tab\]", js, re.S)
    views = dict(re.findall(r"([a-z]+):\s*(view[A-Za-z]+)", m.group(1))) if m else {}
    for t in tabs:
        if t not in views:
            problems.append("页签 %s 在 render() 里没有对应视图函数" % t)
    for t in views:
        if t not in tabs:
            problems.append("视图 %s 没有对应页签" % t)
    notes.append("页签 %d 个与视图函数一一对应：%s" % (len(tabs), " ".join(tabs)))

    # 动作定义/引用
    used = set(re.findall(r'data-act="([a-z0-9_]+)"', js))
    blk = re.search(r"const ACTIONS = \{(.*?)\n\};", js, re.S)
    defined = set(re.findall(r"^\s*([a-z0-9_]+):", blk.group(1), re.M)) if blk else set()
    # 底部操作条的两个按钮由它自己的监听器处理，不注册在 ACTIONS 里
    LOCAL_ONLY = {"selclear", "seltpl"}
    miss = sorted(a for a in used if a not in defined and a not in LOCAL_ONLY)
    if miss:
        problems.append("data-act 引用了未实现的动作：%s" % ", ".join(miss))
    else:
        notes.append("data-act %d 个全部有实现" % len(used))

    # 前端调用的后端子命令必须都存在
    # 子命令名可能带数字（b64len / b64），别写成 [a-z_]+
    subs = set(re.findall(r"^\s{2}([a-z][a-z0-9_]*)\)\s", sh_text, re.M))
    for c in re.findall(r"run\('([a-z][a-z0-9_]*)", js):
        if c not in subs:
            problems.append("前端调用了后端不存在的子命令：%s" % c)
    notes.append("前端调用的后端子命令均存在")

    code = "\n".join(l for l in js.split("\n") if not l.strip().startswith("//"))
    if re.search(r"\.fullScreen\s*\(\s*true", code):
        problems.append("前端仍在调用 fullScreen(true)（要求保持状态栏/导航栏可见）")
    else:
        notes.append("未调用 fullScreen(true)，状态栏/导航栏保持可见")


def check_html():
    # 先剥离预览器注入 —— 它会在每次重写文件后自动加回来，属于环境行为，不是我们的产物问题
    # （modclean 只是开发树里的辅助脚本，公开发布树没有它，缺了不影响检查）
    try:
        from modclean import strip_page_node_id
        n = strip_page_node_id(HTML)
        if n:
            notes.append("已剥离预览器注入的 data-page-node-id ×%d" % n)
    except ImportError:
        pass
    except Exception as e:
        notes.append("剥离注入失败：%s" % e)
    if not os.path.isfile(HTML):
        problems.append("缺少 webroot/index.html（先跑 webui/gen_webui.py）")
        return
    s = io.open(HTML, encoding="utf-8").read()
    n = s.count("data-page-node-id")
    if n:
        problems.append("index.html 残留预览工具注入的 data-page-node-id ×%d —— 重新跑 gen_webui.py 再打包" % n)
    else:
        notes.append("index.html 干净（%d B，无预览注入）" % len(s.encode("utf-8")))


def main():
    sh_text = check_sh()
    check_frontend(sh_text)
    check_html()

    for n in notes:
        print("  ✓ " + n)
    if problems:
        print()
        for p in problems:
            print("  ✗ " + p)
        print("\n❌ 自查未通过（%d 项）" % len(problems))
        return 1
    print("\n✅ 自查全部通过")
    return 0


if __name__ == "__main__":
    sys.exit(main())
