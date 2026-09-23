#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
test_assign_mark.py —— 分配表第 3 列（`scene` 来源标记）的「保存往返」回归测试

事故背景（真机）：
  app_assign.tsv / game_assign.tsv 的每行是 `pkg<TAB>档位[<TAB>来源标记]`。
  标记 `scene` = 这一行**来自与 Scene 的同步**，后端在「Scene 里已不再单独设置」时会删掉它；
  没有标记的行 = 用户在 WebUI 手动设的，永远保留。
  WebUI 保存时曾经把每行重建成 `pkg + '\t' + 档位` —— 第 3 列被静默丢掉。后果：
  「Scene 删掉该条 → 用户在 WebUI 随便保存一次 → 标记没了 → 该行永久复活」，
  于是 Scene 里早就没有的应用又被模块按旧档位硬绑核（微信钉死 0-3 掉帧那一类）。

本测试锁住的语义：
  1. 带标记的行**保存后标记仍在**（原样写回第 3 列）。
  2. **改了档位**的行 → 标记消失（只写 2 列），内存里的 mark 同步清空。
     手动选择 = 受保护的手工行，不能被后续同步删掉。
  3. 档位没变（重复点同一档）→ 标记保留。
  4. 「套用到所选」改档位 → 全部 2 列；「取消分配」→ 行与标记一起消失。
  5. 「分配表」文本框直编：同档保留标记，改档位去标记（写出去的就是 2 列）。
  6. 游戏页（game_assign.tsv）同一套规则。
  ★ 每一步都打印**真正交给 Api.writeText 的原文**（制表符/换行转义成字面量，便于数列）——
    这条测试最值钱的部分：断言看的是将要落盘的字节，而不是内存里自洽的对象。

无头环境（没有 DOM / 没有 fetch）是怎么跑的：
  · 内联脚本从 webroot/index.html 抽出（复用 test_webui_render.py 的 extract_script）。
  · 运行前先注入**同一份最小 DOM 桩**（从 test_webui_render.py 源码里按注释锚点取出，
    不另写一套；取不到就直接失败并提示维护方式）。
  · node 位置 / PATH 补丁复用它的 _node() / _binenv()。
  · 脚本加载后只打两处补丁：
      ① Api.writeText / Api.syncmode 换成记录器 —— 这样能拿到写入原文，且不必碰真桥；
      ② h() 与 Bridge.toast() 换成空实现 —— busy() 的进度框要真 DOM 元素，探针不需要。
    其它一律跑**真代码**（setAppTpl / applySelected / ACTIONS.appasssave / viewApps…），
    所以断的是真实数据流，不是复刻的逻辑。

跑法: python3 tools/test_assign_mark.py
"""
import io, json, os, re, shutil, subprocess, sys

ROOT = os.path.dirname(os.path.abspath(__file__))
MOD = os.path.dirname(ROOT)
HTML = os.path.join(MOD, "webroot", "index.html")
sys.path.insert(0, ROOT)
import test_webui_render as W      # 复用：extract_script / _node / _binenv / _p / check


def dom_stub():
    """取出 test_webui_render.py 里的最小 DOM 桩（不另写一套）。

    那个桩写在该文件 main() 内部的三引号字符串里，没暴露成模块常量，这里按注释锚点取。
    ⚠ 取不到就**大声失败**，绝不偷偷退回一份本地副本 —— 副本会和它漂移，
      而漂移的后果是「桩缺了某个全局 → 探针报莫名其妙的 ReferenceError」。
    """
    src = io.open(os.path.abspath(W.__file__), encoding="utf-8").read()
    m = re.search(r'# ---- 最小 DOM/环境桩[^\n]*\n\s*"""(.*?)\n\s*"""', src, re.S)
    if not m:
        raise SystemExit("✗ 取不到 test_webui_render.py 的 DOM 桩（源码结构变了？）。\n"
                         "  请把那段的字符串抽成模块常量（如 DOM_STUB）后同步本测试，"
                         "不要在本文件里复制一份。")
    return m.group(1)


# ---- 场景脚本：在最小 DOM 里跑真代码，把每一步的写入原文与状态导出成 JSON ----
PROBE = r"""
const R = { log: [] };
let W = null;                        // 最近一次 writeText 的原文（含 \t）
const snap = (label) => R.log.push([label, W ? W.id + '\t' + W.text : '(未写盘)']);
Api.writeText = async (id, text) => { W = { id: id, text: text }; return 'OK'; };
Api.syncmode  = async () => 'OK 0';
// 探针不测 DOM：busy() 的进度框与 toast 换空实现（h() 返回的对象只要能被 remove()）
h = () => ({ style: {}, classList: { add(){}, remove(){}, toggle(){} }, remove(){}, prepend(){},
             textContent: '', innerHTML: '' });
Bridge.toast = () => {};

S.tab = 'apps'; S.apps = []; S.sel = new Set(); S.query = ''; S.launchable = null; S.ownMode = {};
S.appTplLib = [{id:'powersave',friendly:'省电',other:'{e_core}',heaviest_cores:'',heavy_cores:'{e_core}',comm:''},
               {id:'balance',  friendly:'均衡',other:'{e_core}',heaviest_cores:'{p1_core}',heavy_cores:'',comm:''}];
S.templates = S.appTplLib;
const rows = (t) => t.split('\n').filter(Boolean);

(async () => {
  // ---- [2] 后端 ASSIGN= 带第 3 列 → 读入并保留 ----
  Api.apps_tpl = async () => [
    'APP=com.tencent.mm\tbalance',
    'ASSIGN=com.tencent.mm\tpowersave\tscene',   // 来自同步，可被剪枝
    'ASSIGN=com.hand.set\tperformance',          // 手工行，无标记
    'SEM_e_core=0-3', 'SEM_p1_core=4-7', 'CPU_ONLINE=0-9'
  ].join('\n');
  await loadAppsTpl();
  R.inMap  = JSON.stringify(S.appTplAssign);
  R.inMark = JSON.stringify(S.appAssignMark);
  R.textareaShowsMark = /com\.tencent\.mm\tpowersave\tscene/.test(viewApps());

  // ---- [3] 档位没变 → 标记仍在 ----
  await setAppTpl('com.tencent.mm', 'powersave');
  snap('档位没变：setAppTpl(mm, powersave)');
  R.sameWrite = JSON.stringify(rows(W.text));
  R.sameMark  = JSON.stringify(S.appAssignMark);

  // ---- [4] 手动改档位 → 标记消失（只写 2 列）----
  await setAppTpl('com.tencent.mm', 'balance');
  snap('改档位：setAppTpl(mm, balance)');
  R.changedWrite = JSON.stringify(rows(W.text));
  R.changedMark  = JSON.stringify(S.appAssignMark);

  // ---- [5] 套用到所选（改档位）----
  await loadAppsTpl();
  S.sel = new Set(['com.tencent.mm', 'com.hand.set']);
  await applySelected('app', 'balance');
  snap('套用到所选：两个包 → balance');
  R.applyWrite = JSON.stringify(rows(W.text));
  R.applyMark  = JSON.stringify(S.appAssignMark);

  // ---- [6] 分配表文本框直编：同档保留 / 改档去标记 ----
  await loadAppsTpl();
  document.getElementById('app-assign').value = 'com.tencent.mm\tpowersave\tscene\ncom.hand.set\tperformance';
  await ACTIONS.appasssave();
  snap('文本框直编：档位没变，保存');
  R.tsvKeepWrite = JSON.stringify(rows(W.text));
  R.tsvKeepMark  = JSON.stringify(S.appAssignMark);

  document.getElementById('app-assign').value = 'com.tencent.mm\tbalance\tscene\ncom.hand.set\tperformance';
  await ACTIONS.appasssave();
  snap('文本框直编：把 mm 改成 balance，保存');
  R.tsvDropWrite = JSON.stringify(rows(W.text));
  R.tsvDropMark  = JSON.stringify(S.appAssignMark);

  // ---- [7] 取消分配 → 行与标记一起消失 ----
  await loadAppsTpl();
  await setAppTpl('com.tencent.mm', '');
  snap('取消分配：setAppTpl(mm, 空)');
  R.cancelWrite = JSON.stringify(rows(W.text));
  R.cancelMark  = JSON.stringify(S.appAssignMark);

  // ---- [8] 游戏页同一套 ----
  S.tab = 'games';
  Api.games = async () => ['GAME=com.tencent.tmgp.sgame\tfast',
    'ASSIGN=com.tencent.tmgp.sgame\tbalance\tscene', 'ASSIGN=com.keep.me\tperformance'].join('\n');
  await loadSceneGames();
  R.gameInMark = JSON.stringify(S.gameAssignMark);
  await setGameTpl('com.tencent.tmgp.sgame', 'balance');
  snap('游戏页：档位没变');
  R.gameKeepWrite = JSON.stringify(rows(W.text));
  await setGameTpl('com.tencent.tmgp.sgame', 'powersave');
  snap('游戏页：改档位');
  R.gameDropWrite = JSON.stringify(rows(W.text));
  R.gameDropMark  = JSON.stringify(S.gameAssignMark);

  console.log('@@' + JSON.stringify(R));
})();
"""


def build_harness(path):
    html = io.open(HTML, encoding="utf-8").read()
    script = W.extract_script(html)
    if not script.strip():
        return 0
    io.open(path, "w", encoding="utf-8").write(dom_stub() + "\n" + script + "\n" + PROBE)
    return len(script)


def run_node(harness):
    try:
        return subprocess.run([W._node(), W._p(harness)], capture_output=True, text=True,
                              env=W._binenv())
    except FileNotFoundError:
        return None


def show_log(res):
    """打印真正落盘的字节（制表符/换行都转义成字面量）—— 本测试的核心证据。"""
    print("\n[3] 真正交给 Api.writeText 的原文（\\t / 换行都已转义，一行一次写入）")
    for label, text in res.get("log", []):
        print("  · " + label)
        print("      " + text.replace("\t", "\\t").replace("\n", "\\n"))


def main():
    print("[1] 抽 index.html 内联脚本 + 复用 test_webui_render.py 的 DOM 桩")
    try:
        stub = dom_stub()
    except SystemExit as e:
        print("  ✗ " + str(e))
        return 1
    W.check(bool(stub.strip()), "DOM 桩取自 test_webui_render.py（未另写一套，%d 字符）" % len(stub))

    # 沙盒目录：仓库约定 `_t_` 前缀，建在模块目录内（别用系统 temp，见 test_sched_cores.py 注释）
    sandbox = os.path.join(MOD, "_t_assign_mark_%d" % os.getpid())
    os.makedirs(sandbox, exist_ok=True)
    harness = os.path.join(sandbox, "h.js")

    try:
        n = build_harness(harness)
        if not n:
            print("  ✗ index.html 里找不到内联脚本")
            return 1
        W.check(True, "内联脚本已抽出（%d 字符）" % n)

        r = run_node(harness)
        if r is None:
            print("  ✗ 找不到 node（复用 test_webui_render.py 的 _node()/_binenv() 也没定位到）")
            return 1
        if r.returncode != 0:
            print("  ✗ node 执行失败（rc=%d）：" % r.returncode)
            print((r.stderr or "").strip()[:800])
            return 1
        out = [l for l in (r.stdout or "").splitlines() if l.startswith("@@")]
        if not out:
            print("  ✗ 探针没有输出：" + (r.stdout or "")[:300])
            return 1
        res = json.loads(out[-1][2:])
    finally:
        # 用完清理：`_t_*` 已在 .gitignore 里；宿主 safe-delete 钩子偶尔会拦批量删除，
        # 那种情况下 ignore_errors 保证不影响退出码，残留目录可手删。
        shutil.rmtree(sandbox, ignore_errors=True)

    print("\n[2] 第 3 列从后端 ASSIGN= 读入（带标记的行能被识别）")
    W.check(res["inMark"] == '{"com.tencent.mm":"scene"}', "第 3 列 scene 读入 mark（实际 %s）" % res["inMark"])
    W.check(res["inMap"] == '{"com.tencent.mm":"powersave","com.hand.set":"performance"}',
            "档位与第 3 列分开存（mark 没被拼进档位值）")
    W.check(res["textareaShowsMark"], "「分配表」文本框显示 3 列（否则直编保存必丢）")

    show_log(res)

    print("\n[4] 保存往返：带标记的行标记仍在，改了档位就丢标记")
    W.check(res["sameWrite"] == '["com.tencent.mm\\tpowersave\\tscene","com.hand.set\\tperformance"]',
            "档位没变 → 写出去仍带 scene（实际 %s）" % res["sameWrite"])
    W.check(res["sameMark"] == '{"com.tencent.mm":"scene"}', "档位没变 → 内存 mark 也在")
    W.check(res["changedWrite"] == '["com.tencent.mm\\tbalance","com.hand.set\\tperformance"]',
            "改了档位 → 写出去只剩 2 列（实际 %s）" % res["changedWrite"])
    W.check(res["changedMark"] == '{}', "改了档位 → 内存 mark 同步清空（实际 %s）" % res["changedMark"])

    print("\n[5] 其它保存入口走同一套规则")
    W.check(res["applyWrite"] == '["com.tencent.mm\\tbalance","com.hand.set\\tbalance"]',
            "「套用到所选」改档位 → 2 列（实际 %s）" % res["applyWrite"])
    W.check(res["applyMark"] == '{}', "「套用到所选」→ mark 清空")
    W.check(res["cancelWrite"] == '["com.hand.set\\tperformance"]', "取消分配 → 行被删")
    W.check(res["cancelMark"] == '{}', "取消分配 → 标记也删")

    print("\n[6] 「分配表」文本框直编")
    W.check(res["tsvKeepWrite"] == '["com.tencent.mm\\tpowersave\\tscene","com.hand.set\\tperformance"]',
            "同档 → 写出的文本仍带 scene（实际 %s）" % res["tsvKeepWrite"])
    W.check(res["tsvKeepMark"] == '{"com.tencent.mm":"scene"}', "同档 → mark 保留")
    W.check(res["tsvDropWrite"] == '["com.tencent.mm\\tbalance","com.hand.set\\tperformance"]',
            "改档位 → 写出的文本只剩 2 列（实际 %s）" % res["tsvDropWrite"])
    W.check(res["tsvDropMark"] == '{}', "改档位 → mark 清空（实际 %s）" % res["tsvDropMark"])

    print("\n[7] 游戏页（game_assign.tsv）同套")
    W.check(res["gameInMark"] == '{"com.tencent.tmgp.sgame":"scene"}',
            "ASSIGN= 第 3 列读入（实际 %s）" % res["gameInMark"])
    W.check(res["gameKeepWrite"] == '["com.tencent.tmgp.sgame\\tbalance\\tscene","com.keep.me\\tperformance"]',
            "档位没变 → 仍带 scene（实际 %s）" % res["gameKeepWrite"])
    W.check(res["gameDropWrite"] == '["com.tencent.tmgp.sgame\\tpowersave","com.keep.me\\tperformance"]',
            "改档位 → 2 列（实际 %s）" % res["gameDropWrite"])
    W.check(res["gameDropMark"] == '{}', "改档位 → mark 清空")

    print("\n" + "=" * 62)
    if W.FAILS:
        print("❌ 未通过 %d 项：" % len(W.FAILS))
        for f in W.FAILS:
            print("   - " + f)
        return 1
    print("✅ 全部通过（%d 项断言）" % W.CHECKS[0])
    return 0


if __name__ == "__main__":
    sys.exit(main())
