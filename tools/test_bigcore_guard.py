#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
test_bigcore_guard.py —— bigcore_guard.sh 的离线自检

不碰真机：造假 cpuset 树 + 假 mount/umount shim（脚本支持 MOUNT_BIN /
UMOUNT_BIN / MOUNTS_FILE / CG_ROOT / STATE_DIR 覆写），跑**真脚本**验证：

  1. 收窄：含 8/9 的组被裁到 0-7；纯 8-9 的段落到 4-7；不含 8/9 的不动
  2. 先子后父（cpuset 要求 child ⊆ parent），父组冻结前子组已收窄
  3. 冻结：mount --bind，原值存 bigcore.saved（存的是**出厂值**，不是意图值）
  4. ★ 冻结值重申：外部把 bind 的后备文件改成 0-9 后，下一轮要写回意图值
     （v16.16 修复；之前只读不写，"锁在 0-7" 是空话 —— 真机 eff 会回到 0-9）
  5. ★ 按模式生效：极速档解冻并停用 8-9 封锁；其余档继续锁
  6. restore：解冻 + 原值写回 + 清清单，不用重启
  7. 幂等：值一致时不重复挂载

跑法: python tools/test_bigcore_guard.py
"""
import io, os, re, subprocess, sys, tempfile

ROOT = os.path.dirname(os.path.abspath(__file__))
MOD = os.path.dirname(ROOT)
GUARD = os.path.join(MOD, "Scripts", "4+4+2", "O3", "bigcore_guard.sh")

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
        self.dir = tempfile.mkdtemp(prefix="bigcore_test_")
        self.cg = os.path.join(self.dir, "cg")
        self.st = os.path.join(self.dir, "st")
        self.bin = os.path.join(self.dir, "bin")
        self.mounts = os.path.join(self.dir, "mounts")
        for d in (self.cg, self.st, self.bin):
            os.makedirs(d, exist_ok=True)
        io.open(self.mounts, "w").close()
        # 假 mount：只记挂载表；假 umount：从表里删
        mb = os.path.join(self.bin, "mount")
        io.open(mb, "w").write('#!/bin/sh\n[ "$1" = "--bind" ] || exit 1\n'
                               'printf "%s %s none bind 0 0\\n" "$2" "$3" >> "$MOUNTS_FILE"\n')
        ub = os.path.join(self.bin, "umount")
        io.open(ub, "w").write('#!/bin/sh\ngrep -v " $1 " "$MOUNTS_FILE" > "$MOUNTS_FILE.t" 2>/dev/null; '
                               'mv "$MOUNTS_FILE.t" "$MOUNTS_FILE"\n')
        os.chmod(mb, 0o755)
        os.chmod(ub, 0o755)
        self.mk("cpuset", "0-9")
        self.mk("top-app", "0-9")
        self.mk("top-app/main", "0-9")
        self.mk("top-app/render", "0-9")
        self.mk("foreground", "0-9")
        self.mk("foreground/boost", "4-9")
        self.mk("background", "0-3")
        self.set_scheme("sweet_hq")

    def mk(self, rel, val):
        d = os.path.join(self.cg, rel)
        os.makedirs(d, exist_ok=True)
        io.open(os.path.join(d, "cpus"), "w").write(val + "\n")
        io.open(os.path.join(d, "effective_cpus"), "w").write(val + "\n")

    def cpus(self, rel):
        return io.open(os.path.join(self.cg, rel, "cpus")).read().strip()

    def set_scheme(self, s):
        io.open(os.path.join(self.st, "active_scheme"), "w").write(s + "\n")

    def run(self, *args):
        env = dict(os.environ)
        env.update({
            "STATE_DIR": self.st, "CG_ROOT": self.cg,
            "MOUNTS_FILE": self.mounts,
            "MOUNT_BIN": os.path.join(self.bin, "mount"),
            "UMOUNT_BIN": os.path.join(self.bin, "umount"),
            "SCENE_DIR": os.path.join(self.dir, "scene"),
        })
        r = subprocess.run(["sh", GUARD] + list(args), env=env,
                           capture_output=True, text=True)
        return (r.stdout or "") + (r.stderr or ""), r.returncode

    def mount_count(self):
        return len([l for l in io.open(self.mounts) if l.strip()])

    def frozen(self):
        p = os.path.join(self.st, "bigcore.frozen")
        return [l.split("\t")[0] for l in io.open(p) if l.strip()] if os.path.exists(p) else []

    def saved(self):
        p = os.path.join(self.st, "bigcore.saved")
        if not os.path.exists(p):
            return {}
        return dict(l.rstrip("\n").split("\t", 1) for l in io.open(p) if "\t" in l)

    def backup_of(self, rel):
        """从 bigcore.frozen 清单里取该组真实的后备文件路径（第二列）。

        不自己拼文件名 —— 规则由脚本决定（`/`→`_`、路径含 /cpus 后缀），
        自拼容易失配，就测不到真实文件。
        """
        want = (self.cg + "/" + rel).rstrip("/")
        if not want.endswith("cpus"):
            want += "/cpus"
        p = os.path.join(self.st, "bigcore.frozen")
        if os.path.exists(p):
            for l in io.open(p, encoding="utf-8"):
                if "\t" in l:
                    a, b = l.rstrip("\n").split("\t", 1)
                    if a == want:
                        return b
        return None


def main():
    print("[1] 收窄与冻结（性能档）")
    s = Sandbox()
    s.run("quiet")
    check(s.cpus("top-app") == "0-7", "top-app 0-9 → 0-7（实际 %s）" % s.cpus("top-app"))
    check(s.cpus("foreground/boost") == "4-7", "boost 4-9 → 4-7（实际 %s）" % s.cpus("foreground/boost"))
    check(s.cpus("background") == "0-3", "不含 8/9 的组不动（background=0-3）")
    check(os.path.basename(s.cg) + "/top-app/cpus" in "".join(s.frozen()) or
          any("top-app/cpus" in f for f in s.frozen()),
          "top-app 已冻结（frozen 清单 %d 条）" % len(s.frozen()))
    check(s.mount_count() >= 2, "mount --bind 已建立（%d 条）" % s.mount_count())

    print("\n[2] 原值存档必须是出厂值")
    sv = s.saved()
    top = [v for k, v in sv.items() if k.endswith("top-app/cpus")]
    check(top and top[0] == "0-9", "bigcore.saved 里 top-app 记的是出厂 0-9（实际 %s）"
          % (top[0] if top else "无"))

    print("\n[3] 幂等：再跑一轮不重复挂载")
    n1 = s.mount_count()
    s.run("quiet")
    check(s.mount_count() == n1, "挂载数不变（%d → %d）" % (n1, s.mount_count()))

    print("\n[4] ★ 冻结值重申（外部改写后备文件后要写回意图值）")
    bp = s.backup_of("top-app")
    check(os.path.exists(bp), "后备文件存在：%s" % os.path.basename(bp))
    io.open(bp, "w").write("0-9\n")          # 模拟 scene-daemon 经 bind 写入
    io.open(os.path.join(s.cg, "top-app", "cpus"), "w").write("0-9\n")
    check(io.open(bp).read().strip() == "0-9", "已污染后备文件为 0-9")
    s.run("quiet")
    check(io.open(bp).read().strip() == "0-7",
          "下一轮已重申回意图值 0-7（实际 %s）" % io.open(bp).read().strip())

    print("\n[5] ★ 按模式生效：极速档解冻停用、其余档继续锁")
    s.set_scheme("sweet_perf")
    s.run("quiet")
    check(not os.path.exists(os.path.join(s.st, "bigcore.mode.fast")) is False,
          "极速档已打 mode.fast 标记")
    check(s.mount_count() == 0, "极速档已解冻（挂载数 %d）" % s.mount_count())
    check(s.cpus("top-app") == "0-9", "top-app 还原为 0-9（实际 %s）" % s.cpus("top-app"))
    check(s.cpus("foreground/boost") == "4-9", "boost 还原为 4-9（实际 %s）" % s.cpus("foreground/boost"))
    s.set_scheme("sweet_hq")
    s.run("quiet")
    check(not os.path.exists(os.path.join(s.st, "bigcore.mode.fast")), "切回性能档已清标记")
    check(s.cpus("top-app") == "0-7", "性能档重新封锁（top-app=%s）" % s.cpus("top-app"))

    print("\n[6] restore：解冻 + 原值写回 + 清清单")
    out, _ = s.run("restore")
    check(s.mount_count() == 0, "挂载已全部解除（%d）" % s.mount_count())
    check(s.cpus("top-app") == "0-9", "top-app 还原 0-9（实际 %s）" % s.cpus("top-app"))
    check(s.cpus("foreground/boost") == "4-9", "boost 还原 4-9（实际 %s）" % s.cpus("foreground/boost"))
    check(not s.frozen(), "frozen 清单已清")
    check(not os.path.exists(os.path.join(s.st, "bigcore.saved")), "saved 存档已清")

    print("\n[7] 关闭开关 allow_bigcore")
    s2 = Sandbox()
    io.open(os.path.join(s2.st, "allow_bigcore"), "w").close()
    s2.run("quiet")
    check(s2.cpus("top-app") == "0-9", "存在 allow_bigcore 时不动任何组")
    check(s2.mount_count() == 0, "不建立挂载")

    print("\n[8] 静态检查：极速档判断用的是 Scene state 或方案名兜底")
    text = io.open(GUARD, encoding="utf-8").read()
    check("scene_current_mode" in text or "state" in text and "sweet_perf" in text,
          "有模式判断（state / active_scheme 兜底）")
    check("bigcore.mode.fast" in text, "有「已解冻」标记，避免每轮反复 umount")

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
