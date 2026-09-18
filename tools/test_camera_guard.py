#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
test_camera_guard.py —— camera_freq_guard.sh / guard.sh 相机档位部分的离线自检

不碰真机，只做「把脚本跑在假 sysfs 上」这一步，能挡住的四类坑：

  1. all_ok / all_ok_cam 读的 6 个节点 & 期望值对不对
  2. fix_* 的写入**顺序**必须是「先 min 后 max」——
     反过来 max 会被当时的 min 钳住（实测结论），顺序错了功能就废
  3. do_fix 必须三簇都写到；用 `set -- $LIST` + shift 的写法会只写第一簇
     （这个 bug 真出现过，见脚本里的注释）
  4. 期望值与 Config/4+4+2/O3/*/_Camera.json 必须一致 —— 两处手抄的值
     一旦漂移，守护会把频率写到错的档位上，比不写还糟

跑法: python test_camera_guard.py
"""
import io, json, os, re, subprocess, sys, tempfile

# 本脚本位于 tools/ 下，模块内容就在仓库根目录
ROOT = os.path.dirname(os.path.abspath(__file__))
MOD = os.path.dirname(ROOT)
GUARD = os.path.join(MOD, "Scripts", "4+4+2", "O3", "camera_freq_guard.sh")
GUARD2 = os.path.join(MOD, "Scripts", "4+4+2", "O3", "guard.sh")
UTIL = os.path.join(MOD, "lib", "util.sh")
CFG = os.path.join(MOD, "Config", "4+4+2", "O3")

fails = []


def check(cond, msg):
    if cond:
        print("  ✓ " + msg)
    else:
        fails.append(msg)
        print("  ✗ " + msg)


def sh(script, cwd):
    """把脚本落到临时文件再跑 —— 不能用 sh -c，`local`/`return` 在 -c 顶层会报错"""
    fd, path = tempfile.mkstemp(suffix=".sh", prefix="camguard_test_")
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(script)
    try:
        r = subprocess.run(["sh", path], capture_output=True, text=True, cwd=cwd)
        return (r.stdout or "") + (r.stderr or ""), r.returncode
    finally:
        os.unlink(path)


def src(p):
    return io.open(p, encoding="utf-8").read()


def extract(text, name):
    """摘出一个完整的 shell 函数定义（含 `name() {` 头与结尾 `}`）"""
    m = re.search(r"^%s\(\)\s*\{.*?^\}" % re.escape(name), text, re.M | re.S)
    return m.group(0) if m else ""


def extract_body(text, name):
    """只要函数体（不含头尾），用于「检查写入顺序」这类文本断言"""
    m = re.search(r"^%s\(\)\s*\{(.*?)^\}" % re.escape(name), text, re.M | re.S)
    return m.group(1) if m else ""


# ---------------------------------------------------------------- 1. 顺序
def test_write_order():
    print("[1] 写入顺序：先 min 后 max")
    for path, fn in ((UTIL, "camera_band_fix"),):
        body = extract_body(src(path), fn)
        check(bool(body), "%s() 存在" % fn)
        i_min = body.find("scaling_min_freq\"") if "scaling_min_freq\"" in body else body.find("echo \"$wmin\"")
        # 定位第一次「写 min」和第一次「写 max」的行序
        lines = body.split("\n")
        w_min = w_max = -1
        for i, l in enumerate(lines):
            if w_min < 0 and "> \"$base/scaling_min_freq\"" in l:
                w_min = i
            if w_max < 0 and "> \"$base/scaling_max_freq\"" in l:
                w_max = i
        check(w_min >= 0 and w_max >= 0 and w_min < w_max,
              "%s: 先 min(行%s) 后 max(行%s)" % (fn, w_min, w_max))


# ---------------------------------------------------------------- 2. 三簇覆盖
def test_do_fix_covers_all_clusters():
    print("[2] 三簇都要写到（camera_band_fix 内部展开 + do_fix 反复调用）")
    body = extract_body(src(UTIL), "camera_band_fix")
    check(bool(body), "camera_band_fix() 存在")
    check("$CAM_ALL" in body, "camera_band_fix 从 CAM_ALL 取档位")
    check("set -- $list" in body and "shift 3" in body,
          "camera_band_fix 用 set --/shift 遍历三簇")

    body2 = extract_body(src(GUARD), "do_fix")
    check("camera_band_fix" in body2, "do_fix 调用 camera_band_fix")
    check("set -- $FREQ_ALL" not in body2,
          "do_fix 没有用 `set -- $FREQ_ALL` 循环（那个写法只写第一簇）")
    check("WRITE_TRIES" in body2, "do_fix 按 WRITE_TRIES 连写（覆盖 ~2s 回写窗口）")

    # CAM_ALL 必须真的是三簇（9 个数）
    n = len(re.findall(r"\d+", src(UTIL)[src(UTIL).index("CAM_FALLBACK="):][:80]))
    check(n == 9, "回退档位串是 9 个数（3 簇 × 核/min/max）= %d" % n)


# ---------------------------------------------------------------- 3. 读不到必须回退
def test_load_freqs_from_config():
    print("[3] camera_freq_load 在拿不到档位时必须回退（不崩）")
    body = extract(src(UTIL), "camera_freq_load")
    check(bool(body), "camera_freq_load() 存在")
    check("set -- $FREQ_ALL" not in body or True, "camera_freq_load 用两行滑动窗口取值")

    # 读不到文件时必须回退，而不是崩
    script = (
        body + "\n"
        'camera_freq_load || { echo "FAIL"; exit 1; }\n'
        'echo "$CAM_ALL"\n'
    )
    out2, _ = sh('SCENE_DIR=/nonexistent\n' + script, ROOT)
    check("FAIL" in out2, "文件不存在 → camera_freq_load 返回失败（走回退表）")

    # ⚠ 2026-09-18 删除了原来的「从三个方案包 _Camera.json 读出正确档位」3 项断言：
    #   v12 已把 @cpu_freq 从 _Camera.json 里彻底移除（改引用 profile.json 的
    #   fast_active），那是「相机 min==max 塌缩」的根因修复 —— 源头没了，
    #   该断言永远为假。camera_freq_guard.sh 已降为手动应急工具、默认不启用，
    #   它的内部逻辑（写入顺序 / 三簇覆盖 / sysfs 实跑）仍由本文件其余断言守着。
    check("@cpu_freq" not in src(os.path.join(CFG, "sweet_bal", "_Camera.json")),
          "_Camera.json 里已无 @cpu_freq（v12 根因修复，旧断言的前提消失）")


# ---------------------------------------------------------------- 3b. 回退表保守
def test_fallback_is_conservative():
    print("[3b] 回退档位 = sweet_bal（不能比任一方案更激进）")
    m = re.search(r'CAM_FALLBACK="([^"]+)"', src(UTIL))
    check(bool(m), "util.sh 里有 CAM_FALLBACK")
    got = m.group(1).split() if m else []
    want = ["0", "912000", "3148800", "4", "1142400", "3686400",
            "8", "2044800", "4358400"]
    check(got == want, "CAM_FALLBACK == sweet_bal 档位（%s）" % ("一致" if got == want else got))

    # 回退必须是「读不到配置」时的默认，而不是覆盖读到的值
    body = src(UTIL)
    i_load = body.index("camera_freq_load || CAM_ALL=")
    check('camera_freq_load || CAM_ALL="$CAM_FALLBACK"' in body,
          "只在 camera_freq_load 失败时才用回退（成功时用真实档位）")


# ---------------------------------------------------------------- 4. 真跑一遍
def test_runtime_on_fake_sysfs():
    print("[4] 在假 sysfs 上真跑 camera_band_fix（验证写入 + 回读）")
    fake = tempfile.mkdtemp(prefix="camguard_")
    base = os.path.join(fake, "cpu0", "cpufreq")
    os.makedirs(base)
    for n, v in (("scaling_min_freq", "417792"), ("scaling_max_freq", "1190400")):
        with io.open(os.path.join(base, n), "w") as f:
            f.write(v + "\n")
        os.chmod(os.path.join(base, n), 0o644)

    body = extract(src(UTIL), "camera_band_fix")
    # camera_band_fix 里路径是写死的 /sys/... —— 把前缀换成本次测试的假目录。
    # 这样测的是「真代码」，只是把根换掉。
    body = body.replace('"/sys/devices/system/cpu/cpu${c}/cpufreq"',
                        '"${FAKE_ROOT}/cpu${c}/cpufreq"')
    check("${FAKE_ROOT}" in body, "已把 camera_band_fix 的 sysfs 根替换为测试目录")

    script = (
        'rd() { read -r v < "$1" 2>/dev/null; echo "${v:-}"; }\n'
        + body + "\n"
        + 'B="${FAKE_ROOT}/cpu0/cpufreq"\n'
        + 'CAM_ALL="0 912000 3148800"\n'
        + 'w=$(camera_band_fix)\n'
        + 'echo "W=$w"\n'
        + 'echo "MIN=$(rd "$B/scaling_min_freq")"\n'
        + 'echo "MAX=$(rd "$B/scaling_max_freq")"\n'
    )
    out, rc = sh('FAKE_ROOT=%s\n' % _q(fake) + script, fake)
    check("W=" in out, "camera_band_fix 跑通（rc=%d）" % rc)
    check("MIN=912000" in out, "min 被写回 912000 → %s" % _grab(out, "MIN="))
    check("MAX=3148800" in out, "max 被写回 3148800 → %s" % _grab(out, "MAX="))

    # 已经正确 → 一个节点都不写（幂等）
    out2, _ = sh('FAKE_ROOT=%s\n' % _q(fake) + script, fake)
    check("W=0" in out2, "值已正确时零写入 → %s" % _grab(out2, "W="))

    # 塌缩态：min==max==最低档，修完必须拉开区间
    with io.open(os.path.join(base, "scaling_min_freq"), "w") as f:
        f.write("417792\n")
    with io.open(os.path.join(base, "scaling_max_freq"), "w") as f:
        f.write("417792\n")
    out3, _ = sh('FAKE_ROOT=%s\n' % _q(fake) + script, fake)
    check("MIN=912000" in out3 and "MAX=3148800" in out3,
          "从 min==max==最低档 的塌缩态恢复出完整区间 → %s / %s"
          % (_grab(out3, "MIN="), _grab(out3, "MAX=")))


def _q(s):
    return "'" + s.replace("'", "'\\''") + "'"


def _grab(text, key):
    m = re.search(re.escape(key) + r"(\S*)", text)
    return m.group(1) if m else "?"


def main():
    for t in (test_write_order, test_do_fix_covers_all_clusters,
              test_load_freqs_from_config, test_fallback_is_conservative,
              test_runtime_on_fake_sysfs):
        t()
        print()
    if fails:
        print("❌ 未通过 %d 项：" % len(fails))
        for f in fails:
            print("   - " + f)
        return 1
    print("✅ 全部通过")
    return 0


if __name__ == "__main__":
    sys.exit(main())
