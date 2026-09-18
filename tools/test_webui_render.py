#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
test_webui_render.py —— WebUI 渲染函数的「无头」运行时自检

背景（真实事故，2026-09-18）：给「模式」页加核心集合编辑器时，把局部变量
命名为 `esc`，**遮蔽了全局转义函数 esc()** —— 下一行 `esc(cn)` 变成"调用字符串"，
`viewModes()` 抛 TypeError，整个模式页打不开。

lint_module.py 只做静态检查（语法、接线、data-act 覆盖），**抓不到这种运行时错误**。
本测试把 index.html 的脚本抽出来，在 Node 里造最小 DOM 跑**真实渲染函数**，
断言每个视图都能返回 HTML 且不抛异常。

跑法: python tools/test_webui_render.py
"""
import io, os, re, subprocess, sys, tempfile, json

ROOT = os.path.dirname(os.path.abspath(__file__))
MOD = os.path.dirname(ROOT)
HTML = os.path.join(MOD, "webroot", "index.html")

FAILS = []
CHECKS = [0]


def check(cond, msg):
    CHECKS[0] += 1
    if cond:
        print("  \u2713 " + msg)
    else:
        FAILS.append(msg)
        print("  \u2717 " + msg)


def extract_script(html):
    blocks = re.findall(r"<script(?![^>]*\bsrc=)[^>]*>(.*?)</script>", html, re.S)
    return "\n".join(blocks)


def main():
    html = io.open(HTML, encoding="utf-8").read()
    script = extract_script(html)
    if not script.strip():
        print("  \u2717 index.html 里找不到内联脚本")
        return 1

    print("[1] 抽出脚本并准备最小 DOM")
    d = tempfile.mkdtemp(prefix="webui_render_")
    harness = os.path.join(d, "h.js")
    io.open(harness, "w", encoding="utf-8").write(
        # ---- 最小 DOM/环境桩：只够渲染函数用 ----
        """
        const __els = {};
        function mkEl(tag){
          return {
            tagName: tag, style: {}, dataset: {}, children: [], value: '', textContent: '',
            className: '', innerHTML: '',
            classList: { add(){}, remove(){}, toggle(){}, contains(){ return false; } },
            appendChild(c){ this.children.push(c); return c; },
            removeChild(){}, remove(){}, setAttribute(){}, getAttribute(){ return null; },
            addEventListener(){}, querySelector(){ return null; },
            querySelectorAll(){ return []; }, closest(){ return null; }, prepend(){},
            focus(){}, blur(){}, click(){}, scrollIntoView(){},
          };
        }
        global.document = {
          _els: __els,
          getElementById(id){ return __els[id] || (__els[id] = mkEl('div')); },
          createElement: mkEl,
          querySelector(sel){ return mkEl('div'); },
          querySelectorAll(){ return []; },
          addEventListener(){},
          body: mkEl('body'),
          documentElement: mkEl('html'),
        };
        global.window = global;
        global.location = { href: 'http://x/', search: '', hash: '' };
        global.navigator = { userAgent: 'node' };
        global.localStorage = { getItem(){ return null; }, setItem(){}, removeItem(){} };
        global.fetch = async () => ({ ok: true, status: 200, text: async () => '', json: async () => ({}) });
        global.setTimeout = (f) => 0; global.clearTimeout = () => {};
        global.setInterval = () => 0; global.clearInterval = () => {};
        global.requestAnimationFrame = () => 0;
        """)
    # 把站点脚本接在后面，并导出要测的渲染函数
    with io.open(harness, "a", encoding="utf-8") as f:
        f.write("\n" + script + "\n")
        f.write("""
        // 注入一份"有数据"的状态，覆盖到核心集合那一屏
        S.tab = 'modes';
        S.model = { modes: {} };
        // ⚠ cell() 要的是 t.active.L/M/P = [min,max]（对象），不是频率字符串 ——
        //   夹具写成字符串会让 cell() 读 t[st][c] 得到 undefined → 误报成"页面打不开"。
        for (const k of ['powersave','balance','performance','fast']) {
          S.model.modes[k] = {
            cn: k,
            active:   { L: [417792, 1939200], M: [556800, 2419200], P: [1113600, 2371200] },
            inactive: { L: [417792, 1785600], M: [556800, 2131200], P: [1113600, 2198400] },
          };
        }
        S.freqs = { FREQS_L: '417792 557056 912000', FREQS_M: '556800 835200 1142400',
                    FREQS_P: '1113600 1497600 2044800' };
        S.schedcores = {
          SC_powersave: '省电|0-3|-|0-3|-',
          SC_balance: '流畅|0-3|4-5|0-3|4-5',
          SC_performance: '性能|0-3|4-7|0-3|4-7',
          SC_fast: '极速|0-7|4-9|0-7|4-9',
          SC_VALID: '0-3 4-5 4-7 8-9 0-7 4-9',
          SC_HAS: '0',
        };
        S.status = { MODE_CN: '性能', MODE: 'performance' };
        S.sceneDefault = 'performance';
        S.apps = []; S.games = []; S.ownMode = {}; S.launchable = null;
        S.jobs = []; S.log = ''; S.bridgeMode = 'official';

        // ⚠ Node 的 CommonJS 里顶层函数**不是 globalThis 属性**，必须按名字直接调用
        //   （上一版用 global[v] 动态取，五个视图全报 NOT_A_FUNCTION —— 是测试的锅）
        const out = {};
        try { const h = viewOverview(); out.viewOverview = { len: (h||'').length, ok: typeof h==='string' && h.length>0 }; }
        catch (e) { out.viewOverview = { err: String(e && e.message || e) }; }
        try { const h = viewModes(); out.viewModes = { len: (h||'').length, ok: typeof h==='string' && h.length>0 }; }
        catch (e) { out.viewModes = { err: String(e && e.message || e) }; }
        try { const h = viewApps(); out.viewApps = { len: (h||'').length, ok: typeof h==='string' && h.length>0 }; }
        catch (e) { out.viewApps = { err: String(e && e.message || e) }; }
        try { const h = viewGames(); out.viewGames = { len: (h||'').length, ok: typeof h==='string' && h.length>0 }; }
        catch (e) { out.viewGames = { err: String(e && e.message || e) }; }
        try { const h = viewLog(); out.viewLog = { len: (h||'').length, ok: typeof h==='string' && h.length>0 }; }
        catch (e) { out.viewLog = { err: String(e && e.message || e) }; }
        let modesHtml = '';
        try { modesHtml = viewModes() || ''; } catch (e) {}
        out.__hasSC = modesHtml.indexOf('模式 → 核心集合') >= 0;
        // v16.23：模式页曾用原生 <select> —— Android WebView 点开会先弹一个
        //   系统大窗、再变成列表（用户报「闪出大半屏窗口」）。改为模块自己的
        //   底部选择器后，模式页必须**一个 <select> 都不剩**。
        out.__selCount = (modesHtml.match(/<select/g) || []).length;
        out.__pickmf = (modesHtml.match(/data-act="pickmf"/g) || []).length;
        out.__picksc = (modesHtml.match(/data-act="picksc"/g) || []).length;

        // 功能：选择器回调必须真的写回状态（不是只画了个能点的壳）
        const pick = (act, arg, val) => {
          ACTIONS[act](arg);
          const sheet = document.getElementById('picksheet');
          sheet.onclick({ target: { closest: () => ({ getAttribute: () => val }) } });
        };
        let mf = 'NONE', sc = 'NONE';
        try {
          pick('pickmf', 'balance:active:L:1', '1939200');
          mf = (S.model.modes.balance.active.L[1] === 1939200)
            ? 'OK' : ('BAD:' + S.model.modes.balance.active.L[1]);
        } catch (e) { mf = 'ERR:' + e; }
        try {
          pick('picksc', 'balance:esc', '4-5');
          sc = (S.scPicks && S.scPicks.balance && S.scPicks.balance.esc === '4-5')
            ? 'OK' : ('BAD:' + JSON.stringify(S.scPicks));
        } catch (e) { sc = 'ERR:' + e; }
        out.__mfPick = mf; out.__scPick = sc;
        console.log(JSON.stringify(out));
        """)
    r = subprocess.run(["node", harness], capture_output=True, text=True)
    if r.returncode != 0:
        print("  \u2717 node 执行失败：")
        print((r.stderr or "").strip()[:600])
        FAILS.append("node 执行失败")
        return 1
    try:
        res = json.loads((r.stdout or "").strip().splitlines()[-1])
    except Exception as e:
        print("  \u2717 无法解析结果：", e)
        print((r.stdout or "")[:300])
        return 1

    print("\n[2] 各视图渲染（不得抛异常、必须返回非空 HTML）")
    for v in ["viewOverview", "viewModes", "viewApps", "viewGames", "viewLog"]:
        got = res.get(v, {})
        if "err" in got:
            check(False, "%s 抛异常：%s" % (v, got["err"]))
        else:
            check(got.get("ok") and got.get("len", 0) > 0,
                  "%s 正常返回（%d 字符）" % (v, got.get("len", 0)))

    print("\n[3] 「模式」页的核心集合区块确实渲染出来了")
    check(res.get("__hasSC"), "包含「模式 → 核心集合」标题（选择器数量见 [5]）")

    print("\n[4] 源文件静态检查：不得有遮蔽转义函数的变量名 esc")
    # 只查赋值形式 `esc =` / `esc,`（出现在 const/let 声明里），排除函数定义与调用
    # 匹配「在同一层作用域里把 esc 当变量声明」：const/let/var 之后的声明列表里
    # 出现独立的 esc（后面跟 = 或 , 或 ;）。实测踩过的写法是
    #   const cn = ..., base = ..., esc = p2[2] || '-'
    bad = re.findall(r"(?:const|let|var)\s+[^;\n]*?\besc\s*[,=;]", script)
    check(not bad, "无 `esc` 局部变量遮蔽全局 esc()（发现 %d 处）" % len(bad))

    print("\n[5] 模式页不得再用原生 <select>（Android 原生下拉 = 先弹系统大窗再变列表）")
    check(res.get("__selCount", -1) == 0,
          "模式页 0 个原生 <select>（实际 %s）" % res.get("__selCount"))
    check(res.get("__pickmf", 0) >= 48,
          "频率格子全走模块自己的选择器（≥48，实际 %s）" % res.get("__pickmf"))
    check(res.get("__picksc", 0) >= 8,
          "核心集合格子全走模块自己的选择器（≥8，实际 %s）" % res.get("__picksc"))

    print("\n[6] 选择器回调真的写回状态（不是只画个能点的壳）")
    check(res.get("__mfPick") == "OK",
          "pickmf 选中后写入 S.model（实际 %s）" % res.get("__mfPick"))
    check(res.get("__scPick") == "OK",
          "picksc 选中后写入 S.scPicks（实际 %s）" % res.get("__scPick"))

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
