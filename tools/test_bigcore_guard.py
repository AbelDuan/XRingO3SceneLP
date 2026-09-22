#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
test_bigcore_guard.py —— v17 自有 cpuset 组方案的离线自检

不碰真机：造假 cpuset 树 + 假 mount/umount shim + 假 /proc（脚本支持
CG_ROOT / STATE_DIR / TMPD / MOUNTS_FILE / MOUNT_BIN / UMOUNT_BIN 覆写），
跑**真脚本**验证：

  bigcore_guard.sh（自有组模型）：
    1. 自建 /dev/cpuset/SceneO3Tuner/nobig（cpus=0-7），top-app/foreground 不动
    2. 不再 mount --bind 冻结系统组（无打架，无每轮后备文件写）
    3. 幂等：再跑一轮不重复创建
    4. allow_bigcore 关闭 → 不建组
    5. restore：解组 + 清理（无挂载残留）
    6. 向后兼容：残留 v16 冻结清单能被 restore 清理

  migrate_nobig.sh（受管进程迁入/迁出）：
    7. 受管且目标不含 8/9 → 迁入 nobig（写 cgroup.procs）
    8. 目标含 8/9（fast）→ 不迁入；当前在 nobig → 迁回 top-app
    9. 受管且已在 nobig → 幂等不重复写

  guard.sh 静态检查：
    10. bigcore 调用在 WORK 块之外（每轮都跑，但现已近乎免费）、只一处

跑法: python tools/test_bigcore_guard.py
"""
import io, os, re, subprocess, sys, tempfile

ROOT = os.path.dirname(os.path.abspath(__file__))
MOD = os.path.dirname(ROOT)
GUARD = os.path.join(MOD, "Scripts", "4+4+2", "O3", "bigcore_guard.sh")
MIGRATE = os.path.join(MOD, "Scripts", "4+4+2", "O3", "migrate_nobig.sh")

FAILS = []
CHECKS = [0]


def check(cond, msg):
    CHECKS[0] += 1
    if cond:
        print("  \u2713 " + msg)
    else:
        FAILS.append(msg)
        print("  \u2717 " + msg)


class Sandbox:
    def __init__(self):
        # 统一用正斜杠：Windows 下 Python 与 sh 都接受，且避免 awk 把反斜杠当转义吃掉
        self.dir = tempfile.mkdtemp(prefix="bigcore_v17_").replace("\\", "/")
        self.cg = self.dir + "/cg"
        self.st = self.dir + "/st"
        self.tmp = self.dir + "/tmp"
        self.bin = self.dir + "/bin"
        self.proc = self.dir + "/proc"
        self.mounts = self.dir + "/mounts"
        for d in (self.cg, self.st, self.tmp, self.bin, self.proc):
            os.makedirs(d, exist_ok=True)
        io.open(self.mounts, "w").close()
        # 假 mount / umount：只更新挂载表
        mb = os.path.join(self.bin, "mount")
        io.open(mb, "w").write('#!/bin/sh\n[ "$1" = "--bind" ] || exit 1\n'
                               'printf "%s %s none bind 0 0\\n" "$2" "$3" >> "$MOUNTS_FILE"\n')
        ub = os.path.join(self.bin, "umount")
        # umount 按「目标（字段2）」匹配删行（v16 冻结的 target 是真实 cpuset 路径）
        io.open(ub, "w").write(
            '#!/bin/sh\n'
            'while IFS=" " read -r _f1 _f2 _rest; do '
            '[ "$_f2" = "$1" ] || echo "$_f1 $_f2 $_rest"; '
            'done < "$MOUNTS_FILE" > "$MOUNTS_FILE.t" 2>/dev/null; '
            'mv "$MOUNTS_FILE.t" "$MOUNTS_FILE"\n')
        # 假 rmdir：模拟内核删 cpuset cgroup（无视内部 cpus/mems 文件）
        rb = os.path.join(self.bin, "rmdir")
        io.open(rb, "w").write('#!/bin/sh\nrm -rf "$1" 2>/dev/null\n')
        os.chmod(mb, 0o755)
        os.chmod(ub, 0o755)
        os.chmod(rb, 0o755)
        # 根组 mems（新子组必须 \u2264 父 mems）
        io.open(os.path.join(self.cg, "cpuset.mems"), "w").write("0\n")
        self.mk("cpuset", "0-9")
        self.mk("top-app", "0-9")
        self.mk("top-app/main", "0-9")
        self.mk("foreground", "0-9")
        self.mk("foreground/boost", "4-9")
        self.mk("background", "0-3")

    def mk(self, rel, val):
        d = os.path.join(self.cg, rel)
        os.makedirs(d, exist_ok=True)
        io.open(os.path.join(d, "cpus"), "w").write(val + "\n")
        io.open(os.path.join(d, "effective_cpus"), "w").write(val + "\n")
        io.open(os.path.join(d, "mems"), "w").write("0\n")

    def cpus(self, rel):
        return io.open(os.path.join(self.cg, rel, "cpus")).read().strip()

    def exists(self, rel):
        return os.path.exists(os.path.join(self.cg, rel))

    def procs(self, rel):
        p = os.path.join(self.cg, rel, "cgroup.procs")
        return io.open(p).read().strip() if os.path.exists(p) else ""

    def set_scheme(self, s):
        io.open(os.path.join(self.st, "active_scheme"), "w").write(s + "\n")

    def fake_proc(self, pid, cpuset):
        d = os.path.join(self.proc, str(pid))
        os.makedirs(d, exist_ok=True)
        io.open(os.path.join(d, "cpuset"), "w").write(cpuset + "\n")

    def write_run(self, path, lines):
        with io.open(path, "w", encoding="utf-8") as f:
            for ln in lines:
                f.write(ln + "\n")

    def run_guard(self, *args, **kw):
        env = dict(os.environ)
        env.update({
            "STATE_DIR": self.st, "CG_ROOT": self.cg,
            "MOUNTS_FILE": self.mounts,
            "MOUNT_BIN": os.path.join(self.bin, "mount"),
            "UMOUNT_BIN": os.path.join(self.bin, "umount"),
            "RMDIR_BIN": os.path.join(self.bin, "rmdir"),
            "SCENE_DIR": os.path.join(self.dir, "scene"),
        })
        env.update(kw.get("env") or {})
        r = subprocess.run(["sh", GUARD] + list(args), env=env,
                           capture_output=True, text=True)
        return (r.stdout or "") + (r.stderr or ""), r.returncode

    def run_migrate(self, runfile, **kw):
        env = dict(os.environ)
        env.update({
            "STATE_DIR": self.st, "CG_ROOT": self.cg,
            "TMPD": self.tmp, "PROC_ROOT": self.proc,
            "SCENE_DIR": os.path.join(self.dir, "scene"),
        })
        env.update(kw.get("env") or {})
        r = subprocess.run(["sh", MIGRATE, runfile], env=env,
                           capture_output=True, text=True)
        return (r.stdout or "") + (r.stderr or ""), r.returncode

    def mount_count(self):
        return len([l for l in io.open(self.mounts) if l.strip()])


def main():
    print("[1] 自有组创建：nobig=0-7，系统组不动，无挂载")
    s = Sandbox()
    s.run_guard("quiet")
    check(s.exists("SceneO3Tuner/nobig"),
          "SceneO3Tuner/nobig 组已建立")
    check(s.cpus("SceneO3Tuner/nobig") == "0-7",
          "nobig cpus = 0-7（实际 %s）" % (s.cpus("SceneO3Tuner/nobig") if s.exists("SceneO3Tuner/nobig") else "无"))
    check(s.cpus("top-app") == "0-9",
          "top-app 未动（仍 0-9，不再打架；实际 %s）" % s.cpus("top-app"))
    check(s.cpus("foreground") == "0-9",
          "foreground 未动（仍 0-9；实际 %s）" % s.cpus("foreground"))
    check(s.mount_count() == 0,
          "未建立任何 mount --bind（无冻结；挂载数 %d）" % s.mount_count())

    print("\n[2] 幂等：再跑一轮不重复创建 / 不改变")
    s.run_guard("quiet")
    check(s.cpus("SceneO3Tuner/nobig") == "0-7", "nobig 仍为 0-7")
    check(s.mount_count() == 0, "仍无挂载")

    print("\n[3] 关闭开关 allow_bigcore → 不建组")
    s2 = Sandbox()
    io.open(os.path.join(s2.st, "allow_bigcore"), "w").close()
    s2.run_guard("quiet")
    check(not s2.exists("SceneO3Tuner/nobig"), "存在 allow_bigcore 时不建立 nobig 组")

    print("\n[4] restore：解组 + 清理，无挂载残留")
    s.run_guard("restore")
    check(not s.exists("SceneO3Tuner/nobig"), "nobig 组已删除")
    check(not s.exists("SceneO3Tuner"), "父组已删除（空）")
    check(s.mount_count() == 0, "无挂载残留")

    print("\n[5] 向后兼容：残留 v16 冻结清单能被 restore 清理")
    s3 = Sandbox()
    # 模拟 v16 留下的冻结：挂载表（bind: 假后备 -> 真实 cpuset target）+ frozen 清单
    realtarget = os.path.join(s3.cg, "top-app", "cpus")          # v16 冻结的真实目标
    fake = os.path.join(s3.dir, "SceneO3Tuner_fake", "top-app", "cpus")  # v16 写的后备空文件
    os.makedirs(os.path.dirname(fake), exist_ok=True)
    io.open(fake, "w").write("x\n")
    io.open(s3.mounts, "w").write("%s %s none bind 0 0\n" % (fake, realtarget))
    with io.open(os.path.join(s3.st, "bigcore.frozen"), "w") as f:
        f.write("%s\t%s\n" % (realtarget, fake))
    s3.run_guard("restore")
    check(s3.mount_count() == 0, "v16 遗留挂载已解除（%d）" % s3.mount_count())
    check(not os.path.exists(os.path.join(s3.st, "bigcore.frozen")), "frozen 清单已清")

    print("\n[6] migrate：受管且目标不含 8/9 → 迁入 nobig")
    s4 = Sandbox()
    s4.run_guard("quiet")  # 先建 nobig
    s4.fake_proc(100, "/top-app")   # 受管 app，当前在 top-app，目标 4-7
    runf = os.path.join(s4.tmp, "run")
    # 格式 pid|o|m|h|ht|hr|cm|uni|tids|pkg
    s4.write_run(runf, ["100|0-3|4-7|4-7|||||123 124|com.a.restricted"])
    s4.run_migrate(runf)
    check("100" in s4.procs("SceneO3Tuner/nobig"),
          "受管(目标4-7)进程 100 已迁入 nobig（cgroup.procs=%r）" % s4.procs("SceneO3Tuner/nobig"))

    print("\n[7] migrate：目标含 8/9（fast）→ 不迁入；已在 nobig → 迁回 top-app")
    s5 = Sandbox()
    s5.run_guard("quiet")
    s5.fake_proc(200, "/top-app")   # fast app，目标 4-9，当前 top-app
    s5.fake_proc(201, "/SceneO3Tuner/nobig")  # fast app，当前错误地卡在 nobig
    runf = os.path.join(s5.tmp, "run")
    s5.write_run(runf, [
        "200|0-3|4-9|4-9|||||223|com.b.fast",
        "201|0-3|4-9|4-9|||||224|com.c.fast",
    ])
    s5.run_migrate(runf)
    check("200" not in s5.procs("SceneO3Tuner/nobig"),
          "fast(目标4-9)进程 200 不迁入 nobig")
    check("201" in s5.procs("top-app"),
          "fast 进程 201 从 nobig 迁回 top-app（top-app cgroup.procs=%r）" % s5.procs("top-app"))
    check("201" not in s5.procs("SceneO3Tuner/nobig"),
          "fast 进程 201 已离 nobig")

    print("\n[8] migrate：幂等 —— 已在 nobig 的受管进程不再写")
    s6 = Sandbox()
    s6.run_guard("quiet")
    s6.fake_proc(300, "/SceneO3Tuner/nobig")  # 受管，当前 cpuset 指向 nobig
    # 先模拟上一轮已把它迁入 nobig（写一次 cgroup.procs）
    io.open(os.path.join(s6.cg, "SceneO3Tuner", "nobig", "cgroup.procs"), "w").write("300\n")
    runf = os.path.join(s6.tmp, "run")
    s6.write_run(runf, ["300|0-3|4-7|4-7|||||323|com.d.restricted"])
    s6.run_migrate(runf)
    check("300" in s6.procs("SceneO3Tuner/nobig"),
          "受管进程 300 仍在 nobig（幂等未改写；cgroup.procs=%r）" % s6.procs("SceneO3Tuner/nobig"))

    print("\n[9] 静态检查：脚本不含系统组冻结残留")
    gtext = io.open(GUARD, encoding="utf-8").read()
    check("mount --bind" not in gtext, "bigcore_guard.sh 不再 mount --bind 冻结系统组")
    check("SceneO3Tuner/nobig" in gtext, "bigcore_guard.sh 维护 nobig 自有组")
    check("restore" in gtext and "do_restore" in gtext, "保留 restore（不用重启）")
    mtext = io.open(MIGRATE, encoding="utf-8").read()
    check("wantbig" in mtext, "migrate_nobig.sh 按目标核位判定是否放行大核")
    check(os.path.exists(MIGRATE), "migrate_nobig.sh 存在")

    print("\n[10] guard.sh：bigcore 调用在 WORK 块之外、且只一处（每轮跑，现已近乎免费）")
    gtext = io.open(os.path.join(MOD, "Scripts", "4+4+2", "O3", "guard.sh"), encoding="utf-8").read()
    INVOKE = 'sh "$MODDIR/Scripts/4+4+2/O3/bigcore_guard.sh"'
    check(gtext.count(INVOKE) == 1, "guard.sh 里只有一处调用（实际 %d）" % gtext.count(INVOKE))
    wo = gtext.index('if [ "$WORK" = "1" ]; then')
    # 粗略配平：数到配对的 fi
    depth = 0
    body_end = wo
    for line in gtext[wo:].splitlines(True):
        for tok in line.split("#")[0].replace(";", " ").split():
            if tok in ("if", "case"):
                depth += 1
            elif tok in ("fi", "esac"):
                depth -= 1
                if depth == 0:
                    body_end = wo + gtext[wo:].index(line) + len(line)
                    break
        if depth == 0:
            break
    body = gtext[wo:body_end]
    check(INVOKE not in body, "bigcore 调用在 WORK 块之外（每轮都跑，不再每 120s 才纠正）")

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
