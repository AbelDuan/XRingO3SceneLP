#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
test_action_import.py —— KSU 动作按钮 action.sh = WebUI「同步配置」的回归测试

module.prop 声明 action=action.sh：KernelSU 模块卡片上的按钮跑的就是它。
要求（与 webui.sh 的「同步配置」按钮同一条代码路径）：

  1. **走同一段代码**：lib/util.sh 的 `import_scene_apply app`
     （webui.sh cmd_importscene 的核心）—— Scene 显式设过模式的条目覆盖进
     app_assign.tsv 并打第 3 列 `scene` 标记；带标记而 Scene 已无 → 删（剪枝）；
     手工行永远保留。断言看的是**分配表落盘结果 + 输出里的条数/剪枝条数**，
     不是「调用了哪个函数」的形式检查。
  2. **无头跑完**：KSU 只是把 stdout 显示出来 —— 没有终端、没有人按音量键。
     旧版 action.sh 是「音量键选方案」交互菜单（25s 等按键超时），与按钮语义
     互斥：这里用超时把它判死，输出里也不许再出现「音量 / 切换方案」字样。
  3. **退出码 = 成败**：读不到 Scene 的 powercfg.xml → 明确报错 + 非零
     （注意 import_scene_apply 对「读不到」是刻意宽容的：返回 0 + 提示、
     一行不删，防误剪整表 —— 按钮这一层必须把这种「其实没同步」翻成失败）。
  4. `sh -n action.sh` 必须过（语法自检，KSU 直接拿 sh 跑它）。

沙盒手法与 tools/test_import_sync.py 同一套路：STATE_DIR / TMPD /
SCENE_PREFS_DIR 三个环境变量覆写（lib/util.sh 里全部是 ${VAR:-默认}）。

跑法: python3 tools/test_action_import.py
"""
import os
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MOD = ROOT
ACTION = os.path.join(MOD, "action.sh")
SEQ = [0]
FAILS = []
CHECKS = [0]

# 与 test_import_sync.py 同一份种子：手工行 + 带 scene 标记的行（一条该剪、一条该覆盖）
LEGACY = (
    "com.hand.set\tperformance\n"          # 手工：永远保留
    "com.tencent.mm\tpowersave\tscene\n"   # 上次导的，Scene 已无 → 必须删（剪枝）
    "com.keep.me\tbalance\tscene\n"        # 上次导的，Scene 仍在 → 覆盖为 Scene 值
    "# pkg\ttemplate_id\n"                 # 注释行：原样保留
)

POWERCFG = """<?xml version='1.0' encoding='utf-8' standalone='yes' ?>
<map>
<string name="com.keep.me">performance</string>
<string name="com.miHoYo.Yuanshen">performance</string>
<string name="com.tencent.mm.plugin.scanner.ui.BaseScanUI">fast</string>
<string name="*">balance</string>
</map>
"""


def sandbox(with_powercfg=True):
    """建一个 _t_ 前缀的沙盒：Scene 的 powercfg.xml + 模块自己的分配表。"""
    SEQ[0] += 1
    d = os.path.join(ROOT, "_t_action_%d_%d" % (os.getpid(), SEQ[0]))
    shutil.rmtree(d, ignore_errors=True)
    for sub in ("prefs", "st/webui", "tmp"):
        os.makedirs(os.path.join(d, sub), exist_ok=True)
    if with_powercfg:
        with open(os.path.join(d, "prefs/powercfg.xml"), "w") as f:
            f.write(POWERCFG)
    with open(os.path.join(d, "st/webui/app_assign.tsv"), "w") as f:
        f.write(LEGACY)
    return d


def run_action(d):
    """跑真正的 action.sh（sh action.sh），返回 (stdout, rc)。

    ⚠ 20s 上限：旧版交互菜单要等 25s 音量键超时 —— 超时即视为
      「没有无头跑完」，直接判失败（这是断言的一部分，不是测试基建）。"""
    env = dict(os.environ,
               STATE_DIR=os.path.join(d, "st"),
               TMPD=os.path.join(d, "tmp"),
               SCENE_PREFS_DIR=os.path.join(d, "prefs"))
    try:
        r = subprocess.run(["sh", ACTION], capture_output=True, text=True,
                           env=env, timeout=20)
    except subprocess.TimeoutExpired:
        return ("[TIMEOUT] action.sh 20s 内没跑完（疑似仍在等按键）", -1)
    return (r.stdout or ""), r.returncode


def assign_rows(d):
    p = os.path.join(d, "st/webui/app_assign.tsv")
    rows = []
    if not os.path.exists(p):
        return rows
    with open(p, encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\n")
            if line:
                rows.append(line.split("\t"))
    return rows


def find(rows, pkg):
    for r in rows:
        if r and r[0] == pkg:
            return r
    return None


def check(cond, msg, detail=""):
    CHECKS[0] += 1
    if cond:
        print("  ✅ " + msg)
    else:
        FAILS.append(msg)
        print("  ❌ " + msg + ("  " + detail if detail else ""))


def main():
    print("action.sh —— KSU 动作按钮 = WebUI「同步配置」")
    if not os.path.exists(ACTION):
        print("  ❌ 找不到 action.sh")
        return 1

    # ---------- 0) 语法自检 ----------
    print("\n[0] sh -n action.sh")
    r = subprocess.run(["sh", "-n", ACTION], capture_output=True, text=True)
    check(r.returncode == 0, "sh -n 通过（实际 rc=%d %s）"
          % (r.returncode, (r.stderr or "").strip()[:80]))

    # ---------- 1) powercfg.xml 在场 → 同步成功、退出 0、有条数与剪枝条数
    print("\n[1] 合成 powercfg.xml → 走 import_scene_apply 同步，退出码 0")
    d = sandbox(with_powercfg=True)
    out, rc = run_action(d)
    check(rc == 0, "退出码 0（实际 %d）输出=%r" % (rc, out.strip()[:120]))
    check("已从 Scene 导入" in out,
          "输出含成功行与导入条数（「已从 Scene 导入 N 条档位」）",
          "实际输出=%r" % out.strip())
    check("移除 1 条" in out,
          "输出含剪枝条数（「移除 1 条 Scene 已不再单独设置的」）",
          "实际输出=%r" % out.strip())
    rows = assign_rows(d)
    check(find(rows, "com.tencent.mm") is None,
          "(a) 同步真发生了：带 scene 标记、Scene 已无的行被剪掉",
          "实际行=%r" % (find(rows, "com.tencent.mm"),))
    check(find(rows, "com.hand.set") == ["com.hand.set", "performance"],
          "(b) 手工行原样保留（2 列不变）",
          "实际行=%r" % (find(rows, "com.hand.set"),))
    check(find(rows, "com.keep.me") == ["com.keep.me", "performance", "scene"],
          "(c) Scene 仍在的行被覆盖成 Scene 的值 + scene 标记",
          "实际行=%r" % (find(rows, "com.keep.me"),))
    for word in ("音量", "切换方案", "超时"):
        check(word not in out, "输出不含旧交互菜单字样「%s」" % word,
              "实际输出=%r" % out.strip())

    # ---------- 2) powercfg.xml 缺失 → 明确报错 + 非零
    print("\n[2] powercfg.xml 缺失 → 报错且非零退出（import_scene_apply 自身返回 0）")
    d2 = sandbox(with_powercfg=False)
    out2, rc2 = run_action(d2)
    check(rc2 != 0, "退出码非 0（实际 %d）输出=%r" % (rc2, out2.strip()[:120]))
    check("powercfg.xml" in out2,
          "错误信息点名读不到 powercfg.xml", "实际输出=%r" % out2.strip())
    rows2 = assign_rows(d2)
    check(find(rows2, "com.tencent.mm") == ["com.tencent.mm", "powersave", "scene"],
          "读不到 powercfg 时一行都不动（不许误剪整表）",
          "实际行=%r" % (find(rows2, "com.tencent.mm"),))

    # 沙盒不清理：与本套其它测试同惯例（宿主 safe-delete 钩子会染色退出码），
    # 残留 _t_* 已被 .gitignore / build_module 的 SKIP_PREFIXES 忽略。
    print("\n" + "=" * 62)
    if FAILS:
        print("❌ 未通过 %d 项：" % len(FAILS))
        for f in FAILS:
            print("   - " + f)
        return 1
    print("✅ 全部通过（%d 项断言）" % CHECKS[0])
    return 0


if __name__ == "__main__":
    sys.exit(main())
