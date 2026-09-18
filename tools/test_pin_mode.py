#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
test_pin_mode.py —— 落核模式默认值（PIN_MODE）的离线自检

背景：`enforce_threads.sh` 有两条落核路线
  · group   = cgroup 分组（整进程进子组，**新线程靠继承**）
  · taskset = 逐线程 sched_setaffinity（艇长 Aether_OptExt 的原始手段）

2026-09-18 真机 A/B（同 TMPD、各 4 轮稳态）：
    cgroup 分组  459 / 488 / 528 ms
    逐线程 taskset 268 / 321 / 396 ms
用户据此刻意选定 **taskset 为默认**，换取每轮约 150~250ms 的 CPU 时间。
代价：新线程不再自动继承，最多等一轮才被绑上（TTL 180s 兜底自愈）。

本测试把源文件里的「模式解析」片段原样抽出来跑，锁住三件事：
  1. 默认（无标记文件）= taskset
  2. 存在 $STATE_DIR/pin_cgroup 时 = group（保留 cgroup 作为**可选**回退）
  3. 环境变量 PIN_MODE 仍能强制覆盖（调试/单测用）

跑法: python tools/test_pin_mode.py
"""
import io, os, subprocess, sys, tempfile

ROOT = os.path.dirname(os.path.abspath(__file__))
MOD = os.path.dirname(ROOT)
ENFORCE = os.path.join(MOD, "Scripts", "4+4+2", "O3", "enforce_threads.sh")

FAILS = []
CHECKS = [0]


def check(cond, msg):
    CHECKS[0] += 1
    if cond:
        print("  \u2713 " + msg)
    else:
        FAILS.append(msg)
        print("  \u2717 " + msg)


def extract_mode_block(text):
    """抽出模式解析片段：从 PIN_MODE= 起，到 CG_PIN= 止（含两者之间的行）。"""
    lines = text.splitlines()
    start = end = None
    for i, l in enumerate(lines):
        if l.startswith('PIN_MODE='):
            start = i
        if start is not None and l.startswith('CG_PIN='):
            end = i
            break
    if start is None or end is None:
        raise SystemExit("无法从 enforce_threads.sh 抽出 PIN_MODE 解析片段")
    return "\n".join(lines[start:end])


def resolve(block, state_dir, env_pin=None):
    """在沙盒里跑该片段，输出最终 PIN_MODE。"""
    d = tempfile.mkdtemp(prefix="pinmode_test_")
    script = (
        'STATE_DIR="%s"\n'
        'MODDIR="%s"\n'
        '%s\n'
        'echo "$PIN_MODE"\n'
    ) % (state_dir, MOD, block)
    env = dict(os.environ)
    env.pop("PIN_MODE", None)
    if env_pin is not None:
        env["PIN_MODE"] = env_pin
    r = subprocess.run(["sh", "-c", script], capture_output=True, text=True, env=env)
    return (r.stdout or "").strip(), (r.stderr or "").strip()


def main():
    text = io.open(ENFORCE, encoding="utf-8").read()
    block = extract_mode_block(text)
    print("[1] 抽出的模式解析片段")
    print("    " + block.replace("\n", "\n    "))

    d = tempfile.mkdtemp(prefix="pinmode_dir_")

    print("\n[2] 默认值（无任何标记文件）")
    got, err = resolve(block, d)
    check(got == "taskset",
          "默认 PIN_MODE = taskset（实际 %r%s）" % (got, " stderr=" + err if err else ""))

    print("\n[3] 可选回退：pin_cgroup 标记 → group")
    io.open(os.path.join(d, "pin_cgroup"), "w").close()
    got, _ = resolve(block, d)
    check(got == "group", "存在 $STATE_DIR/pin_cgroup 时 = group（实际 %r）" % got)
    os.unlink(os.path.join(d, "pin_cgroup"))

    print("\n[4] 环境变量仍可强制覆盖")
    got, _ = resolve(block, d, env_pin="group")
    check(got == "group", "PIN_MODE=group 覆盖默认（实际 %r）" % got)
    got, _ = resolve(block, d, env_pin="taskset")
    check(got == "taskset", "PIN_MODE=taskset 覆盖默认（实际 %r）" % got)

    print("\n[5] 已废弃的旧标记 pin_taskset 不应再影响结果")
    io.open(os.path.join(d, "pin_taskset"), "w").close()
    got, _ = resolve(block, d)
    check(got == "taskset", "残留 pin_taskset 被忽略（默认已是 taskset，实际 %r）" % got)
    os.unlink(os.path.join(d, "pin_taskset"))

    print("\n[6] taskset 模式必须清掉遗留 cgroup 组树（否则线程仍被组 cpus 锁住）")
    check("cg_unbound" in text and "--unbind-all" in text,
          "有一次性清理逻辑（--unbind-all + cg_unbound 幂等标记）")
    check('PIN_MODE" = "taskset"' in text,
          "清理只在 taskset 模式下触发")

    print("\n[7] 离线套件必须干净通过（不留已知失败）")
    import glob
    me = os.path.basename(os.path.abspath(__file__))
    suite = [t for t in sorted(glob.glob(os.path.join(ROOT, "test_*.py")))
             if os.path.basename(t) != me]          # 排除自己，避免自递归
    bad = []
    for t in suite:
        r = subprocess.run([sys.executable, t], capture_output=True, text=True)
        if r.returncode != 0:
            bad.append(os.path.basename(t))
    check(not bad, "其它 tools/test_*.py 退出码全为 0（失败: %s）"
          % (", ".join(bad) if bad else "无"))

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
