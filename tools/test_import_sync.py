#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
test_import_sync.py —— 「从 Scene 导入档位」的回归测试（v17.4）

守护两个真机事故：

  1. **旧导入只是并集，不是同步**。Scene 里取消某应用的单应用设置后，
     app_assign.tsv 仍留着旧档位，模块继续按它硬绑核 —— 实测：Scene 里早已没有
     com.tencent.mm（全局 balance），表里却留着 com.tencent.mm<TAB>powersave，
     微信 333 条线程被钉死 0-3，界面持续掉帧。
     → 现在导入写第 3 列来源标记 `scene`：带标记且 Scene 已无 → 删（回跟随系统）；
       没标记（WebUI 手工设的）→ 永远保留。老表 2 列无标记 → 第一次导入不删。

  2. **powercfg.xml 里混着 Activity 类名**（Scene 也会给具体界面设模式），如
     com.tencent.mm.plugin.scanner.ui.BaseScanUI。它们永远匹配不到进程，进表只是
     僵尸行。→ 跳过「最后一段首字母大写」的键（Java 类名约定），
       但保留 com.tencent.mm:appbrand 这类 `:进程` 后缀条目。

另有两项容易复发的细节一并钉住：
  3. 第 3 列绝不能漏进档位值（读表必须按 tab 切列取 f[2]；shell 的
     `while IFS=<tab> read -r a b` 会把剩余整行塞进 b）。
  4. 注释行（# 开头）必须原样保留、顺序不变。

跑法: python tools/test_import_sync.py
"""
import os
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MOD = ROOT
SEQ = [0]
FAILS = []
CHECKS = [0]

# 一份「已存在」的分配表：手工行（2 列）+ 上次从 Scene 导的行（第 3 列 scene）
LEGACY = (
    "com.hand.set\tperformance\n"                       # 手工：永远保留
    "com.tencent.mm\tpowersave\tscene\n"                # 上次导的，本次 Scene 已无 → 删
    "com.keep.me\tbalance\tscene\n"                     # 上次导的，Scene 仍在 → 覆盖为 Scene 值
    "# pkg\ttemplate_id\n"                              # 注释行：必须原样保留
)

POWERCFG = """<?xml version='1.0' encoding='utf-8' standalone='yes' ?>
<map>
<string name="com.keep.me">performance</string>
<string name="com.tencent.mm:appbrand">balance</string>
<string name="com.tencent.mm.plugin.scanner.ui.BaseScanUI">fast</string>
<string name="com.tencent.mm.plugin.appbrand.ui.AppBrandLauncherUI">fast</string>
<string name="com.tencent.mm.plugin.recordvideo.activity.MMRecordUI">fast</string>
<string name="com.tencent.wework.login.controller.LoginScannerActivity">fast</string>
<string name="com.miHoYo.Yuanshen">performance</string>
<string name="com.qidian.QDReader">powersave</string>
<string name="*">balance</string>
</map>
"""

# 后缀白名单判据（util.sh import_scene_assign 里的那一条）：最后一个点分段以组件类
# 后缀结尾、或以 Proxy 开头 = 界面类名，必须滤掉。种子表 Config/app_assign.tsv 里
# 13 行界面类垃圾全靠它，而 com.miHoYo.Yuanshen / com.qidian.QDReader 两个真包
# **最后一段也是大写**，会被旧的「首字母大写」判据误杀 —— 这里一并钉死。
CLASSY = ("Activity", "UI", "Service", "Provider", "Receiver", "Fragment", "Dialog")


def is_junk(key):
    last = key.split(".")[-1]
    return last.startswith("Proxy") or last.endswith(CLASSY)


def sandbox(assign_text=LEGACY):
    """建一个 _t_ 前缀的沙盒：Scene 的 powercfg.xml + 模块自己的分配表。"""
    SEQ[0] += 1
    d = os.path.join(ROOT, "_t_import_%d_%d" % (os.getpid(), SEQ[0]))
    shutil.rmtree(d, ignore_errors=True)
    for sub in ("prefs", "st/webui", "tmp"):
        os.makedirs(os.path.join(d, sub), exist_ok=True)
    with open(os.path.join(d, "prefs/powercfg.xml"), "w") as f:
        f.write(POWERCFG)
    if assign_text is not None:
        with open(os.path.join(d, "st/webui/app_assign.tsv"), "w") as f:
            f.write(assign_text)
    return d


def run_shell(d, code):
    """在沙盒里 source lib/util.sh 后执行 code，返回 (stdout, stderr, rc)。"""
    env = dict(os.environ,
               MODDIR=MOD,
               STATE_DIR=os.path.join(d, "st"),
               TMPD=os.path.join(d, "tmp"),
               SCENE_PREFS_DIR=os.path.join(d, "prefs"))
    script = '. "%s/lib/util.sh" >/dev/null 2>&1 || exit 9\n%s\n' % (MOD, code)
    r = subprocess.run(["sh", "-c", script], capture_output=True, text=True, env=env)
    return r.stdout, r.stderr, r.returncode


def assign_rows(d):
    """读出 app_assign.tsv 的行（已按 tab 切好列），供断言。"""
    p = os.path.join(d, "st/webui/app_assign.tsv")
    if not os.path.exists(p):
        return None
    rows = []
    with open(p, encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\n")
            if line == "":
                continue
            rows.append(line.split("\t"))
    return rows


def find(rows, pkg):
    for r in rows or []:
        if r and r[0] == pkg:
            return r
    return None


def check(cond, msg, detail=""):
    CHECKS[0] += 1
    if cond:
        print("  \u2705 " + msg)
    else:
        FAILS.append(msg)
        print("  \u274c " + msg + ("  " + detail if detail else ""))


def main():
    print("import_scene_assign / import_scene_apply 同步语义")
    if not os.path.exists(os.path.join(MOD, "lib", "util.sh")):
        print("  \u274c 找不到 lib/util.sh")
        return 1

    # ---------- 1) 真同步：带标记的行 Scene 已无 → 删；手工行保留；Scene 仍有的 → 覆盖
    print("\n[1] 导入 = 真同步（scene 标记的行会被删，手工行永远保留）")
    d = sandbox()
    out, err, rc = run_shell(d, "import_scene_apply app")
    rows = assign_rows(d)
    check(rc == 0, "import_scene_apply 退出码 0（实际 %d%s）" % (rc, " stderr=" + err if err else ""))
    check(find(rows, "com.tencent.mm") is None,
          "(a) 带 scene 标记但 Scene 已无的行被移除",
          "实际行=%r" % (find(rows, "com.tencent.mm"),))
    check(find(rows, "com.hand.set") == ["com.hand.set", "performance"],
          "(b) 无标记的手工行原样保留（2 列不变）",
          "实际行=%r" % (find(rows, "com.hand.set"),))
    check(find(rows, "com.keep.me") == ["com.keep.me", "performance", "scene"],
          "Scene 仍在的行被覆盖成 Scene 的值并带 scene 标记",
          "实际行=%r" % (find(rows, "com.keep.me"),))
    check("（移除 1 条 Scene 已不再单独设置的 → 回到跟随系统）" in out,
          "输出里报告了移除条数", "实际输出=%r" % out.strip())
    check("已从 Scene 导入" in out, "保留原有的「OK 已从 Scene 导入 N 条档位」措辞",
          "实际输出=%r" % out.strip())
    check([r[0] for r in rows][:3] == ["com.hand.set", "com.keep.me", "# pkg"],
          "已有行与注释行的相对位置不变（注释行原样保留）",
          "实际顺序=%r" % ([r[0] for r in rows],))
    check(sorted(r[0] for r in rows[3:]) ==
          ["com.miHoYo.Yuanshen", "com.qidian.QDReader", "com.tencent.mm:appbrand"],
          "Scene 的新条目追加在表尾（顺序无关）",
          "实际顺序=%r" % ([r[0] for r in rows],))

    # ---------- 2) 老表（2 列）第一次导入不删任何行
    print("\n[2] 兼容老表：只有 2 列时第一次导入不删行（无标记 = 手工行）")
    d = sandbox("com.old.row\tpowersave\ncom.hand.set\tperformance\n")
    out, _, rc = run_shell(d, "import_scene_apply app")
    rows = assign_rows(d)
    check(find(rows, "com.old.row") == ["com.old.row", "powersave"],
          "老 2 列表里 Scene 没有的行不被删（第一次导入不剪枝）",
          "实际行=%r" % (find(rows, "com.old.row"),))
    check(find(rows, "com.keep.me") == ["com.keep.me", "performance", "scene"],
          "本次导入给 Scene 条目补上 scene 标记（下次才可能被删）",
          "实际行=%r" % (find(rows, "com.keep.me"),))
    # 再跑一次：这时 com.old.row 仍无标记（不保留标记，只保留行）→ 依旧不删
    run_shell(d, "import_scene_apply app")
    check(find(assign_rows(d), "com.old.row") is not None,
          "第二次导入仍不删无标记行（标记只加给 Scene 里的条目）")

    # ---------- 3) 组件类名不进表；真包名与 :进程 后缀照常保留
    print("\n[3] import_scene_assign 只吐包名/进程名（后缀白名单判据）")
    d = sandbox(assign_text=None)
    out, _, rc = run_shell(d, "import_scene_assign")
    pairs = [tuple(l.split("\t")) for l in out.splitlines() if l]
    keys = [p[0] for p in pairs]
    check(rc == 0 and keys, "import_scene_assign 有输出（实际 %r）" % out)
    check("com.tencent.mm.plugin.scanner.ui.BaseScanUI" not in keys,
          "(c) Activity/组件类名不被导入（BaseScanUI）")
    check("com.tencent.mm.plugin.appbrand.ui.AppBrandLauncherUI" not in keys
          and "com.tencent.mm.plugin.recordvideo.activity.MMRecordUI" not in keys,
          "(c) 其余界面类名同样被跳过（...LauncherUI / ...MMRecordUI）")
    check("com.tencent.wework.login.controller.LoginScannerActivity" not in keys,
          "(c) LoginScannerActivity 被后缀白名单滤掉",
          "实际=%r" % out)
    check(("com.miHoYo.Yuanshen", "performance") in pairs,
          "(c) 真包名 com.miHoYo.Yuanshen（原神，最后一段大写）必须保留", "实际=%r" % out)
    check(("com.qidian.QDReader", "powersave") in pairs,
          "(c) 真包名 com.qidian.QDReader（起点，最后一段大写）必须保留", "实际=%r" % out)
    check(("com.tencent.mm:appbrand", "balance") in pairs,
          "(d) 带 :进程 后缀的 com.tencent.mm:appbrand 仍然被导入", "实际=%r" % out)
    check(("com.keep.me", "performance") in pairs,
          "普通小写包名照常导入（没被误杀）")
    # 最强的一条：输出**恰好**是这 4 条 —— 组件类名一条都没漏进来
    check(sorted(keys) == ["com.keep.me", "com.miHoYo.Yuanshen",
                           "com.qidian.QDReader", "com.tencent.mm:appbrand"],
          "输出恰好是 4 条白名单条目（6 条界面类名一条都没漏进来）",
          "实际=%r" % (sorted(keys),))
    check(is_junk("com.qidian.QDReader") is False and is_junk("com.miHoYo.Yuanshen") is False
          and is_junk("com.tencent.wework.login.controller.LoginScannerActivity") is True
          and is_junk("com.tencent.mm:appbrand") is False,
          "判据自检：两个真包与 :进程 键不算组件类名、LoginScannerActivity 算")

    # ---------- 4) 第 3 列不漏进档位值
    print("\n[4] 第 3 列不得污染档位值（读表只能按 tab 切列取 f[2]）")
    d = sandbox()
    run_shell(d, "import_scene_apply app")
    rows = assign_rows(d)
    tiers = [r[1] for r in rows if len(r) >= 2 and not r[0].startswith("#")]
    check(all(t in ("powersave", "balance", "performance", "fast") for t in tiers),
          "所有档位值都是四个合法档位之一（无 \"powersave\\tscene\" 这种拼接值）",
          "实际=%r" % tiers)
    check(all(len(r) == 2 or (len(r) == 3 and r[2] == "scene") for r in rows if not r[0].startswith("#")),
          "行只有 2 列（手工）或 3 列且第 3 列恰为 scene")
    # gen_rules_json 是档位表的直接消费者：喂一张带标记的表，确认它取的是 f[2]
    tpl = "performance\t性能\t0-3\t\t\t\t\t\n"
    with open(os.path.join(d, "st/webui/app_templates.tsv"), "w") as f:
        f.write(tpl)
    with open(os.path.join(d, "st/webui/app_assign.tsv"), "w") as f:
        f.write("com.keep.me\tperformance\tscene\n")
    out, err, rc = run_shell(d, "gen_app_rules_json")
    check('"com.keep.me"' in out, "gen_app_rules_json 认得带标记的行", "实际=%r" % out)
    check('"other": "0-3"' in out,
          "gen_rules_json 取到的是干净档位（按 tab 切列，没把 scene 拼进值里）",
          "实际=%r" % out)

    # ---------- 5) 读不到 powercfg.xml 时一行都不许删
    print("\n[5] 读不到 Scene 的 powercfg.xml → 不剪枝（防误杀整表）")
    d = sandbox()
    os.unlink(os.path.join(d, "prefs/powercfg.xml"))
    out, _, rc = run_shell(d, "import_scene_apply app")
    check(find(assign_rows(d), "com.tencent.mm") is not None,
          "powercfg.xml 缺失时带标记的行也保留", "实际输出=%r" % out.strip())
    check(rc == 0 and "读不到" in out, "明确报告「读不到」，不静默", "实际输出=%r" % out.strip())

    for name in [x for x in os.listdir(ROOT) if x.startswith("_t_import_")]:
        shutil.rmtree(os.path.join(ROOT, name), ignore_errors=True)

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
