# -*- coding: utf-8 -*-
"""
O1 官方 HP 方案 → O3 移植转换器
蓝本: helloklf/scheduler-n1/1.0/hp/o1_asic（SCENE9 引擎，与 Scene N1 2026.09 Alpha7 同代）
目标: XRing O3 (xring_o3_asic) 10 核 3 簇 4+4+2 / governor xres / core_ctl cpu4锁4核 cpu8 0-2

映射规则（全部比例化，snap 到 O3 真实频率表）:
  O1 4 簇                 O3 3 簇
  c0 (cpu0,  ≤1795200) ┐
  c1 (cpu2,  ≤1891200) ┴→ policy0 小核 (≤3148800)
  c2 (cpu4,  ≤3398400)  → policy4 中核 (≤3686400)
  c3 (cpu8,  ≤3897600)  → policy8 大核 (≤4358400)

  freq 值:   f3 = snap(f1 / max1[簇] * max3[簇])
  max 上限:  小核取 c1（较大小簇，宽松侧）
  min 下限:  小核取 c0（较小簇，保守侧）
  target_loads: 每簇一行 → 小核行取 c1 行、断点按比例转换
  @cpuset:   4 级域 → 3 级递进域 ["0-3","0-7","0-9"]
  O3 缺失节点: perfmgr/metis/game_opt/migt.parameters → 删除相关行
"""
import json, os, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "Config")          # 生成物直接落到模块 Config/
REF = os.path.join(ROOT, "docs", "o1_reference")  # O1 官方原版参考
os.makedirs(OUT, exist_ok=True)

# ---- O3 真实频率表（2026-09-28 实机读取 scaling_available_frequencies）----
O3_L = [417792,557056,672000,787200,912000,1065600,1209600,1353600,1497600,1641600,
        1785600,1939200,2092800,2246400,2390400,2544000,2745600,2899200,3024000,3148800]
O3_M = [556800,691200,835200,988800,1142400,1296000,1468800,1651200,1804800,1968000,
        2131200,2294400,2419200,2544000,2668800,2803200,2947200,3148800,3283200,3427200,
        3532800,3686400]
O3_B = [1113600,1497600,2044800,2198400,2371200,2553600,2707200,2860800,3024000,3148800,
        3273600,3398400,3523200,3648000,3772800,3878400,3955200,4051200,4195200,4358400]
O3 = {"L": O3_L, "M": O3_M, "B": O3_B}

# ---- O1 簇（出自官方 'xring o1' 频率表文件）----
O1_MAX = {"c0": 1795200, "c1": 1891200, "c2": 3398400, "c3": 3897600}
O1_MIN = {"c0": 334230, "c1": 417790, "c2": 691200, "c3": 1891200}
# O1→O3 簇对应
MAP = {"c0": "L", "c1": "L", "c2": "M", "c3": "B"}

def snap(f, cl):
    """f 映射到 O3 簇 cl 的最近可用档"""
    tbl = O3[cl]
    return min(tbl, key=lambda x: abs(x - f))

def conv(f, oc):
    """O1 簇 oc 的频率 f → O3 对应簇频率（比例映射 + snap）"""
    cl = MAP[oc]
    return snap(round(f / O1_MAX[oc] * max(O3[cl])), cl)

def pfx(v):
    """保留 #/^ 前缀，转换数字部分"""
    m = ""
    s = str(v)
    while s and s[0] in "#^":
        m += s[0]; s = s[1:]
    return m

def conv_v(v, oc):
    """带前缀的频率值转换"""
    return pfx(v) + str(conv(int(str(v).lstrip("#^")), oc))

def reduce_freqs(arr, mode):
    """O1 4 值 [c0,c1,c2,c3] → O3 3 值 [L,M,B]
    mode='max': 小核取 c1（宽松）; mode='min': 小核取 c0（保守）"""
    a, b, c, d = arr
    small = conv_v(b, "c1") if mode == "max" else conv_v(a, "c0")
    return [small, conv_v(c, "c2"), conv_v(d, "c3")]

import re
def conv_tl_line(line, oc):
    """target_loads 行：断点频率按比例转换，负载百分比原样保留"""
    cl = MAP[oc]
    def rep(m):
        return str(conv(int(m.group(0)), oc))
    return re.sub(r"\b\d{6,7}\b", rep, line)

def reduce_tl(lines4):
    """O1 4 行 [c0,c1,c2,c3] → O3 3 行；小核行取 c1 行"""
    return [conv_tl_line(lines4[1], "c1"),
            conv_tl_line(lines4[2], "c2"),
            conv_tl_line(lines4[3], "c3")]

CPUSET_APP = ["0-3", "0-7", "0-9"]      # 递进域：小核 / +中核 / 全核
CPUSET_WL  = ["0-7", "0-9", "0-9"]      # 白名单宽松域

def load(name):
    with open(os.path.join(REF, name), encoding="utf-8") as fp:
        return json.load(fp)

# ============================================================
#  profile.json
# ============================================================
p = load("profile.json")

p["alias"] = {
    # O3 GPU: gpufreq_core/gpufreq_top（无 kgsl；O1 原为 /sys/class/kgsl/kgsl-3d0/...）
    "gpu_max_khz": "/sys/class/devfreq/gpufreq_top/max_freq",
    # 名字里的 6/8 沿用 O1 命名：6→policy4 中核、8→policy8 大核
    "cpu_min_6": "/sys/devices/system/cpu/cpufreq/policy4/scaling_min_freq",
    "cpu_max_6": "/sys/devices/system/cpu/cpufreq/policy4/scaling_max_freq",
    "cpu_min_8": "/sys/devices/system/cpu/cpufreq/policy8/scaling_min_freq",
    "cpu_max_8": "/sys/devices/system/cpu/cpufreq/policy8/scaling_max_freq",
    # perfmgr_enable / glk_disable 删除：O3 无 /sys/module/perfmgr、migt 无 parameters
    "core_ctl": "/sys/devices/system/cpu/cpu8/core_ctl/enable",
}

# gesture_boost：$cpu_max_N 按逻辑 CPU 号解析（cpu2/cpu6 在 O3 归属 policy0/policy4 域），
# 统一改写为 cpu_max_0/cpu_max_4/cpu_max_8 三条，避免歧义
gb = p["features"]["gesture_boost"]
gb["enter"] = [
    ["$cpu_max_0", "#" + str(conv(1795200, "c0"))],   # 小核满频
    ["$cpu_max_4", "^" + str(conv(3120000, "c2"))],   # 中核 ~92%
    ["$cpu_max_8", "^" + str(conv(2976000, "c3"))],   # 大核 ~76%
]

# reset：xres 自适应关断只列 O3 实有簇 cpu0/cpu4/cpu8；ddr min_freq 行删除
# （O3 ddr_devfreq 表未确认含 836000000，交给系统自治）
p["reset"] = [
    ["@xring_reset"],
    ["@governor", "xres"],
]
for c in (0, 4, 8):
    p["reset"] += [
        [f"/sys/devices/system/cpu/cpu{c}/cpufreq/xres/adaptive_high_freq", "#0"],
        [f"/sys/devices/system/cpu/cpu{c}/cpufreq/xres/adaptive_low_freq", "#0"],
    ]

pr = p["presets"]

# target_loads 路径组：3 簇
pr["target_loads"] = [
    ["/sys/devices/system/cpu/cpu0/cpufreq/xres/target_loads"],
    ["/sys/devices/system/cpu/cpu4/cpufreq/xres/target_loads"],
    ["/sys/devices/system/cpu/cpu8/cpufreq/xres/target_loads"],
]

# xres_c0/c1/c2 = cpu0/cpu4/cpu8 的 [hispeed, rtg_boost, irq_boost] 路径组
pr["xres_c0"] = [["/sys/devices/system/cpu/cpu0/cpufreq/xres/" + n]
                 for n in ("hispeed_freq", "rtg_boost_freq", "irq_boost_freq")]
pr["xres_c1"] = [["/sys/devices/system/cpu/cpu4/cpufreq/xres/" + n]
                 for n in ("hispeed_freq", "rtg_boost_freq", "irq_boost_freq")]
pr["xres_c2"] = [["/sys/devices/system/cpu/cpu8/cpufreq/xres/" + n]
                 for n in ("hispeed_freq", "rtg_boost_freq", "irq_boost_freq")]
for k in ("xres_c3",):
    pr.pop(k, None)

# limiter_off：O1 四行全引用 O3 缺失节点（game_opt/migt/perfmgr）→ 置空
pr["limiter_off"] = []

# common_active / common_inactive 的 xres 数值（O1: c0/c2/c3 → O3: c0/c1/c2）
def xres3(c0v, c2v, c3v):
    return [
        ["@values", "xres_c0"] + [pfx(x) + str(conv(int(str(x).lstrip('#^')), "c0")) for x in c0v],
        ["@values", "xres_c1"] + [pfx(x) + str(conv(int(str(x).lstrip('#^')), "c2")) for x in c2v],
        ["@values", "xres_c2"] + [pfx(x) + str(conv(int(str(x).lstrip('#^')), "c3")) for x in c3v],
    ]

pr["common_active"] = xres3(
    ["#1036800", "#1228800", "#1228800"],   # O1 c0
    ["#1017600", "#1017600", "#844800"],    # O1 c2
    ["#1017600", "#816000", "#816000"])     # O1 c3
pr["common_inactive"] = (
    [["@cpu_freqs_min",
      pfx("417792") + "417792",             # 小核回最低档（O1 两小簇同为各自最低档）
      pfx("556800") + "556800",
      pfx("1113600") + "1113600"]]
    + xres3(["#835200", "#1036800", "#1036800"],
            ["#844800", "#844800", "#844800"],
            ["#816000", "#816000", "#816000"])
)

pr["common_app"] = [
    ["@cpuset"] + CPUSET_APP,
    ["/dev/cpuset/sf/cpus", "#0-7"],        # O1: 2-7（含第二小簇）→ O3 0-7（实测桌面 0-7 才流畅）
    ["$core_ctl", "#1"],
]
pr["common_gaming"] = [
    ["@preset", "common_active"],
    ["@limiter", "NONE"],
    ["@cpuset"] + CPUSET_APP,
    ["/dev/cpuset/sf/cpus", "#0-6"],        # O1: 2-6（游戏态少留一个中核顶核）
    ["$core_ctl", "#0"],
]

# 四组模式 preset
def mode_preset(name, maxs, mins, tls):
    e = []
    if maxs: e.append(["@cpu_freqs_max"] + reduce_freqs(maxs, "max"))
    if mins: e.append(["@cpu_freqs_min"] + reduce_freqs(mins, "min"))
    if tls:  e.append(["@target_loads"] + reduce_tl(tls))
    pr[name] = e

mode_preset("powersave_active",
    ["1603200", "#1891200", "#2544000", "#2198400"],
    ["#643200", "#691200", "#691200", "#1891200"],
    ["80 1603200:90", "80 1017600:85 1536000:90",
     "80 1017600:85 1555200:90", "80 1891200:85 1891200:90"])
mode_preset("powersave_inactive",
    ["1603200", "#1891200", "#1900800", "#1891200"], None,
    ["85 1036800:90", "85 844800:90 1536000:95",
     "85 940800:90 1555200:95", "95"])
mode_preset("balance_active",
    ["1795200", "#1891200", "#2812800", "#2793600"],
    ["835200", "691200", "691200", "1891200"],
    ["80 1603200:90", "80 1555200:85 1718400:90",
     "80 1555200:85 1900800:90", "85 2044800:90"])
mode_preset("balance_inactive",
    ["1603200", "#1891200", "#2544000", "#2198400"], None,
    ["85 1036800:90", "85 844800:90 1536000:95",
     "85 940800:90 1555200:95", "95"])
mode_preset("performance_active",
    ["#1795200", "#1891200", "#3043200", "#3148800"],
    ["835200", "691200", "691200", "1891200"],
    ["80 1603200:90", "80 1718400:85 1891200:90",
     "80 1728000:85 2083200:90", "85 2044800:90"])
mode_preset("performance_inactive",
    ["1603200", "#1891200", "#2812800", "#2400000"], None,
    ["85 1036800:90", "85 1017600:90 1536000:95",
     "85 940800:90 1555200:95", "90"])
mode_preset("fast_active",
    ["#1795200", "#1891200", "#3398400", "#3542400"],
    ["835200", "844800", "816000", "1891200"],
    ["80 1603200:85", "80 1891200:85", "80 2083200:85", "80 2044800:85"])
mode_preset("fast_inactive",
    ["#1795200", "#1891200", "#3043200", "#2793600"], None,
    ["85 1603200:90", "83 1718400:87 1891200:95",
     "83 1728000:87 2083200:95", "87 2044800:95"])

# schemes / apps / games 原样保留（O1 官方结构）
with open(os.path.join(OUT, "profile.json"), "w", encoding="utf-8", newline="\n") as fp:
    json.dump(p, fp, ensure_ascii=False, indent=2)
    fp.write("\n")

# ============================================================
#  _apps.json —— @core_ctl 4 参数 → 3 参数
# ============================================================
a = load("_apps.json")
for m in a["modes"]:
    for st in ("active", "inactive"):
        for row in m["state"].get(st, []):
            if row and row[0] == "@core_ctl" and len(row) == 5:
                row[:] = row[:4]   # 去掉第 4 簇参数（O1 c1 归并）
with open(os.path.join(OUT, "_apps.json"), "w", encoding="utf-8", newline="\n") as fp:
    json.dump(a, fp, ensure_ascii=False, indent=2); fp.write("\n")

# ============================================================
#  _games.json —— 4 值数组 → 3 值 + fas.freq snap
# ============================================================
g = load("_games.json")
for m in g["modes"]:
    for row in m.get("call", []):
        if not row: continue
        if row[0] == "@cpu_freqs_max":
            row[:] = ["@cpu_freqs_max"] + reduce_freqs(row[1:], "max")
        elif row[0] == "@cpu_freqs_min":
            row[:] = ["@cpu_freqs_min"] + reduce_freqs(row[1:], "min")
        elif row[0] == "@target_loads":
            row[:] = ["@target_loads"] + reduce_tl(row[1:])
    fas = m.get("fas", {})
    if "freq" in fas:
        f1, f2 = fas["freq"]
        # O1 fas 双频 = [中核目标, 大核目标]（按各自簇比例转换）
        fas["freq"] = [str(conv(int(f1), "c2")), str(conv(int(f2), "c3"))]
with open(os.path.join(OUT, "_games.json"), "w", encoding="utf-8", newline="\n") as fp:
    json.dump(g, fp, ensure_ascii=False, indent=2); fp.write("\n")

# ============================================================
#  _camera.json —— policy0/2/4/8 → policy0/4/8，MHz 值按比例转换
# ============================================================
cam = load("_camera.json")
CAM_MAP = {"policy0": ("c0", "policy0"), "policy2": ("c1", None),
           "policy4": ("c2", "policy4"), "policy8": ("c3", "policy8")}
def cam_freq(v, oc):
    if v in ("min", "max"): return v
    mhz = int(str(v).replace("MHz", ""))
    return str(conv(mhz * 1000, oc) // 1000) + "MHz"
def fix_cam(rows):
    out = []
    for r in rows:
        if not r: continue
        tag = r[0]
        if tag == "@cpu_freq":
            oc, np_ = CAM_MAP.get(r[1], (None, None))
            if np_ is None: continue          # policy2 行删除
            out.append(["@cpu_freq", np_] + [cam_freq(x, oc) for x in r[2:]])
        else:
            out.append(r)
    return out
for st in ("active", "inactive"):
    cam["state"][st] = fix_cam(cam["state"].get(st, []))
with open(os.path.join(OUT, "_camera.json"), "w", encoding="utf-8", newline="\n") as fp:
    json.dump(cam, fp, ensure_ascii=False, indent=2); fp.write("\n")

# ============================================================
#  _whitelist.json
# ============================================================
w = load("_whitelist.json")
for row in w.get("call", []):
    if not row: continue
    if row[0] == "@cpu_freqs_max":
        row[:] = ["@cpu_freqs_max"] + reduce_freqs(row[1:], "max")
    elif row[0] == "@cpuset":
        row[:] = ["@cpuset"] + CPUSET_WL
with open(os.path.join(OUT, "_whitelist.json"), "w", encoding="utf-8", newline="\n") as fp:
    json.dump(w, fp, ensure_ascii=False, indent=2); fp.write("\n")

# ============================================================
#  manifest.json
# ============================================================
man = load("manifest.json")
man["version"] = "HP"
man["versionCode"] = 20260928
with open(os.path.join(OUT, "manifest.json"), "w", encoding="utf-8", newline="\n") as fp:
    json.dump(man, fp, ensure_ascii=False, indent=2); fp.write("\n")

print("OK ->", OUT)
for f in ("profile.json", "_apps.json", "_games.json", "_camera.json", "_whitelist.json", "manifest.json"):  # powercfg.sh/description.txt 为手写文件，转换器不碰
    fp_ = os.path.join(OUT, f)
    json.load(open(fp_, encoding="utf-8"))   # 校验 JSON 合法
    print("  %-16s %6d B  valid" % (f, os.path.getsize(fp_)))
