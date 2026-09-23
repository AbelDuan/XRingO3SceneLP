#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""enforce_threads.sh §3.45「离表即释放」回归测试。

被锁住的需求（2026-09-22 真机 bug）：
  应用离开目标表（用户改回「跟随系统」/ 删掉那一行）后，**没有任何代码**回收
  它已经落核的窄掩码 —— 删掉 com.tencent.mm 那一行后该进程 331 个线程仍是 0-3，
  只能手动 `taskset -a -p 3ff <pid>`。旧代码唯一的释放路径是 unbind_fast.sh
  （只管极速档这一个特例）。

断言（对应交付要求的 a~d，外加两条安全边界）：
  a) 上一轮想要、这一轮不要的 pid → 生成并执行 taskset（回到**所属组**的预算）
  b) 仍在目标表里的 pid → 一条命令都不发（含「只是被 §3.5 缓存跳过」的情况）
  c) prev 里已退出的 pid → 跳过（不对尸体发 taskset）
  d) 目标表为空 / 缺失（瞬时空表）→ 一条都不放，否则会把全部受管应用解绑
  e) 在自有 nobig 组里的 pid → 除放掩码外还要按 oom_score_adj 迁出（>=200 background）
  f) 组预算读不到 / 目标表…目标组不存在 → 不猜：宁可不释放，也不越权放宽

离线手法（与 tools/test_migrate_nobig.py 同一套路）：全部走脚本自己的覆写
  TMPD / STATE_DIR / CG_ROOT / PROC_ROOT，外加 PATH 前置两个假命令：
    · ps      → 吐沙盒里的 ps.txt（真 ps 会列出真机进程，测试必须完全可控）
    · taskset → 只记录调用（**绝不允许**真 taskset 碰到真进程）
  ⚠ 子进程 env **不能**继承 os.environ：本机 DSH_* 那一套会让沙盒里的写入失效；
    这里只传固定白名单 + 覆写（顺带让测试与宿主环境无关）。

跑法: python3 tools/test_release_unbind.py
"""
import os
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT = os.path.join(ROOT, "Scripts", "4+4+2", "O3", "enforce_threads.sh")

SEQ = [0]
FAILS = []

# 假 pid 取很大且注定不存在的值：万一执行路径漏到真 taskset，也不会碰到真进程
P_KEEP, PKG_KEEP = 3999001, "com.test.keep"
P_GONE, PKG_GONE = 3999002, "com.test.gone"
P_A, PKG_A = 3999031, "com.test.a"
P_B, PKG_B = 3999032, "com.test.b"
P_C, PKG_C = 3999041, "com.test.c"
P_D, PKG_D = 3999042, "com.test.d"

NAMES = {}          # (沙盒, pid) → 假 ps 里的进程名 = 目标表里的包名


def w(path, text, mode=None):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)
    if mode is not None:
        os.chmod(path, mode)


def sandbox(tag):
    # ⚠ 目录名必须**每次都不一样**：宿主 safe-delete 钩子有时会拦住批量删除，
    #   复用同名目录就会把上一轮的 t.prev 带进「首轮」，测试变成假阳性/假阴性。
    d = None
    for _ in range(200):
        SEQ[0] += 1
        cand = os.path.join(ROOT, f"_t_rel_{tag}_{os.getpid()}_{SEQ[0]}")
        try:
            shutil.rmtree(cand)                 # 残留目录一律不复用
        except FileNotFoundError:
            pass
        except OSError:
            continue
        if not os.path.exists(cand):
            d = cand
            break
    if d is None:
        raise RuntimeError("建不出干净沙盒目录")
    for sub in ("tmp", "st/webui", "cg/background", "cg/top-app",
                "cg/SceneO3Tuner/nobig", "proc", "bin"):
        os.makedirs(os.path.join(d, sub), exist_ok=True)
    # 假 cgroup 树：组的 cpus = 该组允许的核（释放目标就是它）
    w(os.path.join(d, "cg/cpuset.cpus"), "0-9\n")
    w(os.path.join(d, "cg/background/cpus"), "0-3\n")
    w(os.path.join(d, "cg/background/cgroup.procs"), "")
    w(os.path.join(d, "cg/top-app/cpus"), "0-9\n")
    w(os.path.join(d, "cg/top-app/cgroup.procs"), "")
    w(os.path.join(d, "cg/SceneO3Tuner/nobig/cpus"), "0-7\n")
    # 假 ps：原样吐 ps.txt
    w(os.path.join(d, "bin/ps"), f'#!/bin/sh\ncat "{d}/ps.txt"\n', 0o755)
    # 假 taskset：只记录（真 taskset 会去改真进程的亲和性，绝不能让它被调起）
    w(os.path.join(d, "bin/taskset"),
      f'#!/bin/sh\necho "$@" >> "{d}/bin/taskset.log"\n', 0o755)
    # taskset 模式的一次性「清遗留组树」标记：避免脚本去动沙盒的假 cgroup 树
    w(os.path.join(d, "st/cg_unbound"), "")
    return d


def add_proc(d, pid, pkg, cgroup="/background", adj=0):
    """假 /proc/<pid>：cppset 路径决定「所属组」，组 cpus 就是释放目标。"""
    NAMES[(d, pid)] = pkg
    w(os.path.join(d, f"proc/{pid}/stat"), f"{pid} ({pkg}) S 1 {pid} {pid} 0 -1 0\n")
    w(os.path.join(d, f"proc/{pid}/cpuset"), cgroup + "\n")
    w(os.path.join(d, f"proc/{pid}/oom_score_adj"), f"{adj}\n")


def tgt_row(pkg):
    """t.targets 列序 PKG|other|main|heavy|ht|hr|commPairs|uni|tier（§3 的 awk 读 $1..$9）。"""
    return "|".join([pkg, "0-3", "0-3", "", "", "", "", "1", "balance"])


def run_round(d, entries, live):
    """跑一轮 enforce_threads.sh。

    entries = [(pkg, pid)] → t.targets（None = 目标表缺失）
    live    = [pid]        → 假 ps 里「在跑」的进程（名字 = 它当初的包名）
    """
    if entries is None:
        try:
            os.remove(os.path.join(d, "tmp/t.targets"))
        except OSError:
            pass
    else:
        w(os.path.join(d, "tmp/t.targets"),
          "".join(tgt_row(pkg) + "\n" for pkg, _ in entries))
    # 非空即可：输入文件在沙盒里都不存在 → §3 不会重算目标表，直接用我们写的这份
    w(os.path.join(d, "tmp/t.sig"), "1")
    w(os.path.join(d, "ps.txt"),
      "  PID ARGS\n" + "".join(f"{p} {NAMES[(d, p)]}\n" for p in live))
    env = {                                   # 白名单，见文件头 ⚠
        "PATH": os.path.join(d, "bin") + ":/usr/bin:/bin",
        "HOME": "/root",
        "MODDIR": ROOT,                       # 让脚本 source 到仓库里的 lib/util.sh
        "CG_ROOT": os.path.join(d, "cg"),
        "PROC_ROOT": os.path.join(d, "proc"),
        "TMPD": os.path.join(d, "tmp"),
        "STATE_DIR": os.path.join(d, "st"),
    }
    r = subprocess.run(["sh", SCRIPT], env=env, cwd=ROOT,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return r.returncode


def slurp(path):
    try:
        with open(path) as f:
            return f.read()
    except OSError:
        return ""


def rel_of(d):                      # 本轮生成的释放命令
    return slurp(os.path.join(d, "tmp/t.rel"))


def tslog(d):                       # 假 taskset 收到的调用（= 真被执行过的命令）
    return slurp(os.path.join(d, "bin/taskset.log"))


def prev_of(d):                     # 上一轮的 want 列表
    return slurp(os.path.join(d, "tmp/t.prev")).split()


def run_of(d):                      # §3.5 缓存过滤**之后**的 run 表
    return slurp(os.path.join(d, "tmp/t.run")).split()


def log_of(d):
    return slurp(os.path.join(d, "st/sceneo3.log"))


def check(name, cond, detail=""):
    if cond:
        print(f"  ✅ {name}")
    else:
        print(f"  ❌ {name} {detail}")
        FAILS.append(name)


def main():
    print("enforce_threads §3.45 离表即释放")
    if not os.path.exists(SCRIPT):
        print(f"  ❌ 找不到 {SCRIPT}")
        return 1

    # ---------------- (a)(b) 离表 → 释放；仍在表里 → 一条都不发 ----------------
    # 忠实复现真机场景：第二轮里「被删掉那一行」的进程**仍在运行**，
    # 而保留下来的那个 pid 恰好被 §3.5 缓存命中（RUN 被裁空）——
    # 于是「t.want 必须拍在缓存之前」这条也被一起钉住（见下面的缓存命中断言）。
    d = sandbox("ab")
    add_proc(d, P_KEEP, PKG_KEEP)
    add_proc(d, P_GONE, PKG_GONE)
    add_proc(d, P_A, PKG_A, "/top-app")          # 顶层组：预算 0-9 → 掩码 3ff
    run_round(d, [(PKG_KEEP, P_KEEP), (PKG_GONE, P_GONE), (PKG_A, P_A)], [P_KEEP, P_GONE, P_A])
    check("首轮无差集 → 不生成、不执行任何命令",
          rel_of(d).strip() == "" and tslog(d) == "", repr(rel_of(d)) + repr(tslog(d)))
    check("首轮把 want 落成 prev",
          sorted(prev_of(d)) == sorted([str(P_KEEP), str(P_GONE), str(P_A)]), repr(prev_of(d)))

    run_round(d, [(PKG_KEEP, P_KEEP)], [P_KEEP, P_GONE, P_A])   # 删掉 gone / a 那两行
    rel, tsl = rel_of(d), tslog(d)
    check("(a) 离表 pid 拿到 taskset 释放命令（回到所属组预算 0-3 → f）",
          f"taskset -a -p f {P_GONE}" in rel, repr(rel))
    check("(a) 顶层组 pid 释放成 3ff（= 用户手动 `taskset -a -p 3ff <pid>` 那条）",
          f"taskset -a -p 3ff {P_A}" in rel, repr(rel))
    check("(a) 释放命令真的被执行了",
          f"-a -p f {P_GONE}" in tsl and f"-a -p 3ff {P_A}" in tsl, repr(tsl))
    check("(b) 仍在目标表的 pid 不被释放",
          str(P_KEEP) not in rel and str(P_KEEP) not in tsl, repr(rel) + repr(tsl))
    check("(b) 该轮确实走了 §3.5 缓存命中（RUN 被裁空）→ 证明快照拍在缓存之前",
          run_of(d) == [] and prev_of(d) == [str(P_KEEP)],
          f"run={run_of(d)!r} prev={prev_of(d)!r}")
    check("(a) 释放后 t.prev 收敛成本轮 want", prev_of(d) == [str(P_KEEP)], repr(prev_of(d)))
    check("(a) 只在真的释放时写一行日志", log_of(d).count("离表释放") == 1, repr(log_of(d)))

    # 幂等：稳态（want == prev）再来一轮，不许重复发命令、不许再写日志
    tsl_before = tslog(d)
    run_round(d, [(PKG_KEEP, P_KEEP)], [P_KEEP, P_GONE])
    check("稳态幂等 → 不再发命令、不再写日志",
          tslog(d) == tsl_before and rel_of(d).strip() == "" and log_of(d).count("离表释放") == 1,
          repr(rel_of(d)) + repr(tslog(d)))

    # ---------------- (c) 已退出的 pid → 跳过 ----------------
    d = sandbox("dead")
    add_proc(d, P_KEEP, PKG_KEEP)
    add_proc(d, P_GONE, PKG_GONE)
    add_proc(d, P_A, PKG_A)          # 只把 stat 删掉：cpuset / 组预算**仍然可读**
    run_round(d, [(PKG_KEEP, P_KEEP), (PKG_GONE, PKG_GONE), (PKG_A, P_A)], [P_KEEP, P_GONE, P_A])
    shutil.rmtree(os.path.join(d, "proc", str(P_GONE)), ignore_errors=True)   # 整个 /proc 目录消失
    os.remove(os.path.join(d, "proc", str(P_A), "stat"))                      # 只是退出（目录还在）
    run_round(d, [(PKG_KEEP, P_KEEP)], [P_KEEP])
    rel = rel_of(d)
    check("(c) 整个 /proc/<pid> 消失的 pid 被跳过（不对尸体发 taskset）",
          str(P_GONE) not in rel and tslog(d) == "", repr(rel) + repr(tslog(d)))
    # ★ 这条专门钉住「存活检查」本身，而不是「组预算读不到」那条兜底：
    #   P_A 的 cpuset 与组预算都还在，只有 /proc/<pid>/stat 没了 —— 不查存活就会
    #   算出掩码 f 并真的下发 taskset（变异「去掉存活检查」正是靠这条变红的）。
    check("(c) 仅 stat 读不到（cpuset 仍可读）也被存活检查挡住", str(P_A) not in rel, repr(rel))
    check("(c) 死 pid 仍从 prev 收敛掉（不会永远卡住）",
          prev_of(d) == [str(P_KEEP)], repr(prev_of(d)))

    # ---------------- (d) 瞬时空表 / 表缺失 → 一条都不放 ----------------
    d = sandbox("empty")
    add_proc(d, P_KEEP, PKG_KEEP)
    run_round(d, [(PKG_KEEP, P_KEEP)], [P_KEEP])
    run_round(d, [], [])                                   # 目标表被清空
    check("(d) 空目标表 → 不释放任何 pid",
          tslog(d) == "" and rel_of(d).strip() == "", repr(rel_of(d)) + repr(tslog(d)))
    check("(d) 空表那一轮 t.prev 原样保留（没被清成空表）",
          prev_of(d) == [str(P_KEEP)], repr(prev_of(d)))
    run_round(d, [(PKG_KEEP, P_KEEP)], [P_KEEP])           # 表恢复
    check("(d) 表恢复后仍在表里 → 仍旧一条都不发", tslog(d) == "", repr(tslog(d)))
    run_round(d, None, [])                                 # 目标表文件缺失
    check("(d) 目标表缺失（$TGT 不存在）→ 不释放",
          tslog(d) == "" and rel_of(d).strip() == "", repr(rel_of(d)) + repr(tslog(d)))

    # ---------------- (e) 自有 nobig 组 → 放掩码之外还要迁出 ----------------
    d = sandbox("nobig")
    add_proc(d, P_KEEP, PKG_KEEP)
    add_proc(d, P_A, PKG_A, "/SceneO3Tuner/nobig", adj=250)   # 前台加权 → background
    add_proc(d, P_B, PKG_B, "/SceneO3Tuner/nobig", adj=0)     # 普通 → top-app
    run_round(d, [(PKG_KEEP, P_KEEP), (PKG_A, P_A), (PKG_B, P_B)], [P_KEEP, P_A, P_B])
    run_round(d, [(PKG_KEEP, P_KEEP)], [P_KEEP])
    rel = rel_of(d)
    check("(e) nobig 组：掩码回到组预算 0-7（ff）", f"taskset -a -p ff {P_A}" in rel, repr(rel))
    check("(e) nobig + oom_score_adj>=200 → 迁回 background",
          f"echo {P_A} > {d}/cg/background/cgroup.procs" in rel, repr(rel))
    check("(e) nobig + oom_score_adj<200 → 迁回 top-app",
          f"echo {P_B} > {d}/cg/top-app/cgroup.procs" in rel, repr(rel))

    # ---------------- (f) 预算/目标组读不到 → 不猜（宁漏勿宽） ----------------
    d = sandbox("nogroup")
    shutil.rmtree(os.path.join(d, "cg/background"), ignore_errors=True)
    shutil.rmtree(os.path.join(d, "cg/top-app"), ignore_errors=True)
    add_proc(d, P_KEEP, PKG_KEEP)                             # 保留
    add_proc(d, P_C, PKG_C, "/top-app")                       # 组预算文件被删 → 不释放
    add_proc(d, P_D, PKG_D, "/SceneO3Tuner/nobig", adj=250)   # 预算可读，但迁出目标组不存在
    run_round(d, [(PKG_KEEP, P_KEEP), (PKG_C, P_C), (PKG_D, P_D)], [P_KEEP, P_C, P_D])
    run_round(d, [(PKG_KEEP, P_KEEP)], [P_KEEP])
    rel = rel_of(d)
    check("(f) 组预算读不到 → 跳过，不猜（不越权放宽）", str(P_C) not in rel, repr(rel))
    check("(f) 迁出目标组不存在 → 只放掩码，不动 cgroup",
          f"taskset -a -p ff {P_D}" in rel and "cgroup.procs" not in rel, repr(rel))

    for x in [y for y in os.listdir(ROOT) if y.startswith("_t_rel_")]:
        try:
            shutil.rmtree(os.path.join(ROOT, x), ignore_errors=True)
        except BaseException:
            pass

    print()
    if FAILS:
        print(f"❌ 未通过 {len(FAILS)} 项：")
        for f in FAILS:
            print(f"   - {f}")
        return 1
    print("✅ 全部通过")
    return 0


if __name__ == "__main__":
    sys.exit(main())
