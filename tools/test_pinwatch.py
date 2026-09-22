#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
test_pinwatch.py —— pinwatch.sh 的 pkg_of() 必须扛得住「目标进程已死」

背景（2026-09-21 真机排查，设备 lhasa）：

  `pkg_of()` 要读 `/proc/<pid>/cmdline` 取包名。eBPF 报上来的 pid 是
  **fork 事件里的短命进程**，等用户态去读时它常常已经没了，此时
  `read()` 返回 `-ESRCH`（No such process）。而本机 `/system/bin/tr`
  是 **toybox 0.8.13**，它**不把负数返回当作输入结束** —— 原地空转：

      rchar 冻结不变 / wchar=0 / syscr ≈ 500 万次每秒 / state=R

  真机实测（两个卡住的实例）：单个 tr 吃掉 **~94% 单核**，且永不退出；
  因为它在 `$( ... )` 里，`consume()` 永不返回 → pinwatch 事件循环连同
  调用它的 guard.sh 一起僵死。对照实测：`cat` 会报 "No such process" 后
  正常退出，`head` 正常退出，**只有 tr 死循环**。

  根因是**结构性的**：toybox tr 的 stdin 直接接了 /proc 文件，出错时没有
  任何东西能给它 EOF。安全的写法只能是把 tr 的 stdin 变成普通管道 ——
  由另一个会正常退出的读者（cat）去开 /proc 文件，它一出错退出，管道写端
  关闭，tr 立刻读到 EOF。

本测试守三件事：
  [1] pkg_of 在「tr 的 stdin 不是管道就永不返回」的 shim 下必须**及时返回**
      （shim 复刻 toybox 的失败方式；旧写法在这里会挂死 → 红）
  [2] 目标 pid 不存在时同样及时返回，输出为空
  [3] 静态断言：pkg_of 里禁止把 /proc 路径直接重定向进 tr 的 stdin
      （防止有人把它「简化」回去）

跑法: python tools/test_pinwatch.py
"""
import io, os, shutil, signal, subprocess, sys, tempfile

ROOT = os.path.dirname(os.path.abspath(__file__))
MOD = os.path.dirname(ROOT)
PINWATCH = os.path.join(MOD, "Scripts", "4+4+2", "O3", "pinwatch.sh")

TIMEOUT = 5          # shim 挂死时的等待上限（秒）

FAILS = []
CHECKS = [0]


def check(cond, msg):
    CHECKS[0] += 1
    if cond:
        print("  \u2713 " + msg)
    else:
        FAILS.append(msg)
        print("  \u2717 " + msg)


def extract_pkg_of(text):
    """抽出 pkg_of() { ... } 整块（从行首 'pkg_of() {' 到行首 '}'）。"""
    lines = text.splitlines()
    start = end = None
    for i, l in enumerate(lines):
        if l.startswith("pkg_of() {"):
            start = i
        elif start is not None and l == "}":
            end = i
            break
    if start is None or end is None:
        raise SystemExit("无法从 pinwatch.sh 抽出 pkg_of() 块")
    return "\n".join(lines[start:end + 1])


def make_toybox_tr_shim(shimdir):
    """造一个复刻 toybox tr 失败方式的 tr：
       stdin 不是管道（= 直接接了 /proc 文件）就永不返回；
       是管道则转交真 tr，语义与真机一致。"""
    real_tr = shutil.which("tr") or "/usr/bin/tr"
    p = os.path.join(shimdir, "tr")
    io.open(p, "w", encoding="utf-8").write(
        "#!/bin/sh\n"
        "# 复刻 toybox 0.8.13 tr：读到 -ESRCH 不当作 EOF，原地空转。\n"
        "# 判据用「stdin 是不是管道」——旧写法把 /proc 文件直接接给 tr，\n"
        "# 出错时没有任何东西能给它 EOF，正是真机上挂死的那个结构。\n"
        "if [ ! -p /dev/stdin ]; then exec sleep 600; fi\n"
        "exec %s \"$@\"\n" % real_tr
    )
    os.chmod(p, 0o755)
    return p


def run_pkg_of(block, shimdir, target, timeout=TIMEOUT):
    """在沙盒里跑 pkg_of <target>，返回 (ok, stdout, note)。ok=False 表示挂死。"""
    script = 'PATH="%s:$PATH"\n%s\npkg_of %s\necho "|end"\n' % (shimdir, block, target)
    p = subprocess.Popen(["sh", "-c", script], stdout=subprocess.PIPE,
                         stderr=subprocess.PIPE, text=True, start_new_session=True)
    try:
        out, err = p.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(os.getpgid(p.pid), signal.SIGKILL)
        except OSError:
            pass
        p.communicate()
        return False, "", "超时 %ds 未返回（= toybox tr 式死循环）" % timeout
    return True, (out or "").strip(), (err or "").strip()


def main():
    text = io.open(PINWATCH, encoding="utf-8").read()
    block = extract_pkg_of(text)
    print("[1] 抽出的 pkg_of()")
    print("    " + block.replace("\n", "\n    "))

    shimdir = tempfile.mkdtemp(prefix="pinwatch_trshim_")
    make_toybox_tr_shim(shimdir)

    print("\n[2] 目标 pid 活着 —— 必须及时返回且取到包名")
    ok, out, note = run_pkg_of(block, shimdir, "$$")
    check(ok, "在 toybox-tr shim 下及时返回（%s）" % (note or "未超时"))
    check(out == "sh|end", "取到 cmdline 第一段 = sh（实际 %r）" % out)

    print("\n[3] 目标 pid 已不存在 —— 必须及时返回且输出为空，不能挂死")
    ok, out, note = run_pkg_of(block, shimdir, "999999")
    check(ok, "pid 不存在时及时返回（%s）" % (note or "未超时"))
    check(out == "|end", "输出为空、程序继续往下走（实际 %r）" % out)

    print("\n[4] 静态断言：禁止把 /proc 路径直接重定向进 tr 的 stdin")
    check('< "/proc' not in block,
          "pkg_of 里没有把 /proc 路径重定向给 tr（这正是挂死的写法）")
    check('cat "/proc/$1/cmdline"' in block,
          "由 cat 去开 /proc 文件，tr 只吃管道（出错时管道关闭 → tr 收到 EOF）")

    print("\n" + "=" * 62)
    if FAILS:
        print("\u274c 未通过 %d 项：" % len(FAILS))
        for f in FAILS:
            print("   - " + f)
        print("\n提示：真机现象是 pinwatch.sh 里出现永不退出的 tr（~94% 单核），")
        print("      同时 guard.sh 与事件循环一起僵死；修法见 pkg_of() 上方注释。")
        return 1
    print("\u2705 全部通过（%d 项断言）" % CHECKS[0])
    return 0


if __name__ == "__main__":
    sys.exit(main())
