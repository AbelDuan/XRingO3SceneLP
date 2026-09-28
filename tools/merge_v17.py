# -*- coding: utf-8 -*-
"""v17.1 四方案（能效校准）→ 单一 SceneO3LP 配置合并器

Scene 四模式 ← v17.1 四方案（玄戒能效实测校准，非比例换算）：
  powersave(省电)   ← sweet_eco
  balance(流畅)     ← sweet_bal
  performance(性能) ← sweet_perf
  fast(极速)        ← sweet_hq

limiter（辅助调速器，动态按当前频率压新上限）：
  运行时级 p1/p2/p3/inactive/idle 跨模式共享一份 → 取 sweet_perf
  （p3 大核 3955200 不压制 performance 档；游戏时 @limiter NONE 关闭，不影响 fast 满频）

schema：完全沿用 v17.1（Scene N1 实战验证过的同族写法，含 4 参数 @cpuset）
"""
import json, os

W = r"C:\Users\Abel\WorkBuddy\2026-09-15-15-05-05"
V17 = os.path.join(W, "_work", "Config", "4+4+2", "O3")
OUT = os.path.join(W, "_repo", "SceneO3LP", "Config")

def load(base, name):
    p = os.path.join(V17, base, name)
    return json.load(open(p, encoding="utf-8"))

MODE_SRC = {"powersave": "sweet_eco", "balance": "sweet_bal",
            "performance": "sweet_perf", "fast": "sweet_hq"}

# ============ profile.json ============
base = load("sweet_bal", "profile.json")          # 结构底座（alias/reset/schemes/apps/games）
eco  = load("sweet_eco", "profile.json")
perf = load("sweet_perf", "profile.json")
hq   = load("sweet_hq", "profile.json")

# limiter：辅助调速器（Limited），取 sweet_perf（p3 大核 3955200 不压 performance）
base["features"]["limiter"] = perf["features"]["limiter"]

# presets：公共组用 sweet_bal；四档模式各取对应方案
pr = base["presets"]
for mode, src in MODE_SRC.items():
    sp = load(src, "profile.json")["presets"]
    pr[f"{mode}_active"]   = sp[f"{mode}_active"]
    pr[f"{mode}_inactive"] = sp[f"{mode}_inactive"]
# common_app/common_gaming/cpu_on/cpu_auto*/limiter_off/limiter_on/latency/target_loads
# 保持 sweet_bal 原样（已在 base 中）

with open(os.path.join(OUT, "profile.json"), "w", encoding="utf-8", newline="\n") as f:
    json.dump(base, f, ensure_ascii=False, indent=2); f.write("\n")

# ============ _Games.json（游戏档独立频率，四模式各取对应方案） ============
games_base = load("sweet_bal", "_Games.json")
gout = []
for m in games_base["modes"]:
    src = MODE_SRC[m["mode"][0]] if m["mode"][0] != "*" else "sweet_hq"
    gm = load(src, "_Games.json")
    match = next((x for x in gm["modes"] if x["mode"] == m["mode"]), None)
    if match is None:
        match = next((x for x in gm["modes"] if "*" in x["mode"]), m)
    gout.append(match)
games_base["modes"] = gout
with open(os.path.join(OUT, "_games.json"), "w", encoding="utf-8", newline="\n") as f:
    json.dump(games_base, f, ensure_ascii=False, indent=2); f.write("\n")

# ============ _Apps / _Camera / _ELP ← sweet_bal 原样 ============
for name in ("_Apps.json", "_Camera.json", "_ELP.json"):
    data = load("sweet_bal", name)
    with open(os.path.join(OUT, name.lower()), "w", encoding="utf-8", newline="\n") as f:
        json.dump(data, f, ensure_ascii=False, indent=2); f.write("\n")

# ============ manifest.json：version=LP + limiter 特性开启 ============
man = {
    "version": "LP",
    "versionCode": 20260928,
    "author": "SCENE9",
    "projectUrl": "http://vtools.omarea.com/",
    "features": {"strict": True, "pedestal": False, "reboot": False,
                 "fas": True, "limiter": True},
    "files": ["_Apps.json", "_Camera.json", "_ELP.json", "_Games.json",
              "powercfg.sh", "profile.json"],
}
with open(os.path.join(OUT, "manifest.json"), "w", encoding="utf-8", newline="\n") as f:
    json.dump(man, f, ensure_ascii=False, indent=2); f.write("\n")

# ============ 校验 & 摘要 ============
chk = json.load(open(os.path.join(OUT, "profile.json"), encoding="utf-8"))
print("== 合并完成，四档频率摘要（active max [L/M/P]）==")
for mode in MODE_SRC:
    rows = chk["presets"][f"{mode}_active"]
    vals = [r[3] for r in rows if r[0] == "@cpu_freq"]
    print(f"  {mode:12} ← {MODE_SRC[mode]:10} max: {vals}")
lim = chk["features"]["limiter"]["limiters"]
print("limiter p3 大核 max =", lim["p3"]["cpus"][2]["max"], "（perf 源，不压 performance）")
man_chk = json.load(open(os.path.join(OUT, "manifest.json"), encoding="utf-8"))
print("manifest:", man_chk["version"], man_chk["versionCode"], "| limiter:", man_chk["features"]["limiter"])
for f in ("profile.json", "_apps.json", "_games.json", "_camera.json", "_elp.json", "manifest.json"):
    json.load(open(os.path.join(OUT, f), encoding="utf-8"))
print("全部 JSON 合法 ✓")
