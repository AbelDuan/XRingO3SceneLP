#!/usr/bin/env python3
"""migrate_nobig.sh 迁移判定回归测试。

守护的 bug（v17.4 真机事故）：判定「本应用要不要大核 8-9」时用**子串**匹配
`index(expr,"8")`，而 fast 档的升级目标是字符串 "4-9" —— 里面没有字符 '8'，
判定恒为假 → 极速档被自有 nobig(0-7) 夹死，8-9 永远拿不到。
本测试把「区间表达式的 8/9 成员判定」钉死，含 4-9 / 0-9 / 8-9 / 单核 8 四种写法。
"""
import os
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT = os.path.join(ROOT, "Scripts", "4+4+2", "O3", "migrate_nobig.sh")
SEQ = [0]
FAILS = []


def sandbox():
    SEQ[0] += 1
    d = os.path.join(ROOT, f"_t_mig_{os.getpid()}_{SEQ[0]}")
    shutil.rmtree(d, ignore_errors=True)
    for sub in ("cg/SceneO3Tuner/nobig", "cg/top-app", "proc/4242"):
        os.makedirs(os.path.join(d, sub), exist_ok=True)
    open(os.path.join(d, "cg/cpuset.mems"), "w").write("0\n")
    open(os.path.join(d, "cg/cpuset.cpus"), "w").write("0-9\n")
    return d


def run(d, pid, row, cgroup, esc=("", "4-7", "4-7", "4-9")):
    """跑一轮 migrate_nobig，返回迁移命令文件内容。"""
    open(os.path.join(d, f"proc/{pid}/cpuset"), "w").write(cgroup + "\n")
    runf = os.path.join(d, "run")
    open(runf, "w").write(row + "\n")
    env = dict(os.environ, CG_ROOT=os.path.join(d, "cg"),
               PROC_ROOT=os.path.join(d, "proc"), TMPD=os.path.join(d, "tmp"),
               STATE_DIR=os.path.join(d, "st"))
    subprocess.run(["sh", SCRIPT, runf, *esc], env=env,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    mig = os.path.join(d, "tmp", "t.mig")
    return open(mig).read() if os.path.exists(mig) else ""


def check(name, cond, detail=""):
    if cond:
        print(f"  ✅ {name}")
    else:
        print(f"  ❌ {name} {detail}")
        FAILS.append(name)


def main():
    print("migrate_nobig 迁移判定")
    if not os.path.exists(SCRIPT):
        print(f"  ❌ 找不到 {SCRIPT}")
        return 1

    # 1) fast 档（升级目标 4-9，字面不含 '8'）→ 必须迁出 nobig，8-9 才可达
    d = sandbox()
    out = run(d, 4242, "4242|0-7|0-7|||||0|com.foo|fast", "/SceneO3Tuner/nobig")
    check("fast(esc=4-9) 从 nobig 迁往 top-app",
          "top-app/cgroup.procs" in out and "SceneO3Tuner/nobig" not in out, repr(out))

    # 2) 省电档（升级目标 '-'）→ 收进 nobig
    d = sandbox()
    out = run(d, 4242, "4242|0-3|0-3|||||0|com.foo|powersave", "/top-app")
    check("powersave(esc=-) 迁回 nobig",
          "SceneO3Tuner/nobig/cgroup.procs" in out, repr(out))

    # 3) 静态目标就含 8-9（字面）→ 同样不进 nobig
    d = sandbox()
    out = run(d, 4242, "4242|0-3|8-9|||||0|com.foo|balance", "/SceneO3Tuner/nobig")
    check("静态目标 8-9 迁出 nobig", "top-app/cgroup.procs" in out, repr(out))

    # 4) 0-9（区间跨到 9）→ 迁出
    d = sandbox()
    out = run(d, 4242, "4242|0-9|0-9|||||0|com.foo|balance", "/SceneO3Tuner/nobig")
    check("目标 0-9 迁出 nobig", "top-app/cgroup.procs" in out, repr(out))

    # 5) 0-7（不含 8/9）→ 保持进 nobig（不许误判成大核）
    d = sandbox()
    out = run(d, 4242, "4242|0-7|0-7|||||0|com.foo|balance", "/top-app")
    check("目标 0-7 迁进 nobig", "SceneO3Tuner/nobig/cgroup.procs" in out, repr(out))

    # 6) 已在正确组 → 幂等，不产生命令
    d = sandbox()
    out = run(d, 4242, "4242|0-7|0-7|||||0|com.foo|fast", "/top-app")
    check("已在 top-app 的 fast 不再发命令", out.strip() == "", repr(out))

    for d in [x for x in os.listdir(ROOT) if x.startswith("_t_mig_")]:
        shutil.rmtree(os.path.join(ROOT, d), ignore_errors=True)

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
