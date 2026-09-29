#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
gen_powercfg.py —— 从 profile.json（sweet_eco）生成「按 mode 分发」的外部配置脚本。

为什么需要：
  当前 Scene（N1 2026.09 Alpha7）已不再接受 SOURCE_SCENE_ONLINE（实测：写进去会被 App
  主动清除），本机唯一可用的本地方案通道是官方文档的「外部配置」——
      /data/powercfg.sh   +   /data/powercfg.json
  Scene 会以  sh /data/powercfg.sh <mode>  的形式调用（mode ∈ powersave/balance/
  performance/fast；另有一次 init）。所以频率方案必须以脚本形式提供。

生成内容：
  · 头部与工具函数（set_value / lock_value / hide_value / 频率 snap 写入）
  · do_init()：一次性初始化（温控解绑 / core_ctl / walt / joyose），来自 sweet_eco 的
    powercfg.sh 正文；用 boot_id 标记保证每开机只跑一次（否则每次切档都 force-stop joyose）
  · 各 mode 分支：从 profile.json 的 presets.<mode>_active 抽取频率相关写入
      - 裸路径 ["/sys/...","值"]      → set_value
      - ["@cpu_freq","cpuN","min","max"] → 按可用频率表 snap 后写 scaling_min/max_freq
      - @limiter / @preset / @cpuset 等 Scene 内部函数 → 跳过（外部通道下由本脚本负责）
"""
import json
import os
import re

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROFILE = os.path.join(ROOT, "Config", "profile.json")
SRC_INIT = os.path.join(ROOT, "Config", "powercfg-init.src.sh")   # sweet_eco 的初始化脚本（源码，勿被生成物覆盖）
OUT = os.path.join(ROOT, "Config", "powercfg.sh")

MODES = ["powersave", "balance", "performance", "fast"]
MODE_CN = {"powersave": "省电", "balance": "流畅", "performance": "性能", "fast": "极速"}

CLUSTER = {"cpu0": 0, "cpu4": 4, "cpu8": 8, "policy0": 0, "policy4": 4, "policy8": 8}


def extract_init_body(path):
    """取 sweet_eco 初始化脚本里「第 1 节」之后的正文到 exit 0 之前。"""
    lines = open(path, encoding="utf-8").read().splitlines()
    start = 0
    for i, l in enumerate(lines):
        if re.match(r"^# ─+ 1\.", l):
            start = i
            break
    body = []
    for l in lines[start:]:
        if l.strip() == "exit 0":
            break
        body.append(l)
    return "\n".join(body).rstrip() + "\n"


def freq_writes(entry):
    """@cpu_freq → 若干行 shell；返回 None 表示不是频率条目。"""
    if not isinstance(entry, list) or not entry:
        return None
    t = entry[0]
    if t == "@cpu_freq" and len(entry) >= 4:
        cluster = CLUSTER.get(str(entry[1]))
        if cluster is None:
            return None
        out = []
        for kind, val in (("min", entry[2]), ("max", entry[3])):
            out.append(f'  snap_write {kind} {cluster} "{val}"')
        return out
    return None


def plain_write(entry):
    if not isinstance(entry, list) or len(entry) != 2:
        return None
    path, value = entry
    if not isinstance(path, str) or not path.startswith("/"):
        return None
    return f'set_value "{value}" "{path}"'


def main():
    prof = json.load(open(PROFILE, encoding="utf-8"))
    presets = prof.get("presets", {})
    init_body = extract_init_body(SRC_INIT)

    mode_blocks = {}
    skipped = {}
    for m in MODES:
        lines = []
        for e in presets.get(f"{m}_active", []):
            w = freq_writes(e)
            if w:
                lines.extend(w)
                continue
            w = plain_write(e)
            if w:
                lines.append("  " + w)
                continue
            key = (e[0] if isinstance(e, list) and e else "?")
            skipped[key] = skipped.get(key, 0) + 1
        mode_blocks[m] = lines

    header = '''#!/system/bin/sh
# ============================================================================
#  SceneO3LP · 外部配置脚本（官方「外部配置（第三方调度）对接」通道）
#  由 Scene 以 `sh /data/powercfg.sh <mode>` 调用：
#     init | powersave | balance | performance | fast
#  频率数值来自本模块 Config/profile.json（早期完整方案集 sweet_eco 档）。
#  ⚠ 只做频率与调度参数；**不含任何线程绑定/落核逻辑**。
#  ⚠ 生成物，勿手改：改 profile.json 后跑 tools/gen_powercfg.py 重新生成。
# ============================================================================
LOG=/data/local/tmp/scene_o3_lp.log
BOOTMARK=/data/local/tmp/.scene_o3lp_init_$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo boot)

log() { echo "[$(date '+%H:%M:%S')] [$MODE] $*" >> $LOG; }

set_value() {
  value="$1"; path="$2"
  [ -f "$path" ] || return 0
  cur="$(cat "$path" 2>/dev/null)"
  [ "$cur" = "$value" ] && return 0
  chmod 0664 "$path" 2>/dev/null
  echo "$value" > "$path" 2>/dev/null
}

lock_value() {
  value="$1"; path="$2"
  [ -f "$path" ] || return 0
  chmod 0644 "$path" 2>/dev/null
  echo "$value" > "$path" 2>/dev/null
  chmod 0444 "$path" 2>/dev/null
}

# 频率写入：把请求值 snap 到该簇真实可用档位（低取），避免写入不存在的频率被内核丢弃
snap_write() {
  kind="$1"; cluster="$2"; want="$3"
  base="/sys/devices/system/cpu/cpufreq/policy$cluster"
  [ -d "$base" ] || return 0
  f="$base/scaling_${kind}_freq"
  [ -f "$f" ] || return 0
  case "$want" in
    min|max) v=$(cat "$base/cpuinfo_${kind}_freq" 2>/dev/null); [ -n "$v" ] && { set_value "$v" "$f"; return 0; } ;;
  esac
  avail=$(cat "$base/scaling_available_frequencies" 2>/dev/null)
  if [ -n "$avail" ] && [ -n "$want" ] && [ "$want" -gt 0 ] 2>/dev/null; then
    best=""
    for a in $avail; do
      if [ "$kind" = "max" ]; then
        [ "$a" -le "$want" ] && best="$a"
      else
        [ -z "$best" ] && best="$a"
        [ "$a" -ge "$want" ] && { best="$a"; break; }
      fi
    done
    [ -n "$best" ] && want="$best"
  fi
  set_value "$want" "$f"
}

lock_min() {
  # 把三簇下限锁成 0444：禁止系统/Scene 动态抬升 min（上限仍由 Scene 正常下发）
  local c f
  for c in 0 4 8; do
    f="/sys/devices/system/cpu/cpufreq/policy$c/scaling_min_freq"
    [ -f "$f" ] && chmod 0444 "$f" 2>/dev/null
  done
}

hide_value() {
  # 外部通道下不做 bind-mount 隐藏（简化且可逆），只做直接写入
  [ -n "$2" ] && set_value "$2" "$1"
  return 0
}

do_init() {
  [ -f "$BOOTMARK" ] && { log "init 已跑过（本开机）"; return 0; }
'''

    footer_tpl = '''
  touch "$BOOTMARK" 2>/dev/null
  log "===== init done ====="
}

MODE="${1:-init}"

case "$MODE" in
%s
  *)
    do_init
    ;;
esac

log "===== done ====="
exit 0
'''

    blocks = []
    for m in MODES:
        lines = mode_blocks[m]
        blocks.append(f'  {m})')
        blocks.append(f'    # {MODE_CN[m]}（来自 profile.json presets.{m}_active）')
        blocks.append('    do_init')
        blocks.extend(lines if lines else ['    : # 该档无频率写入'])
        blocks.append('    lock_min')
        blocks.append('    ;;')
    case_body = "\n".join(blocks)

    out = header + init_body + footer_tpl % case_body
    open(OUT, "w", encoding="utf-8").write(out)
    os.chmod(OUT, 0o755)

    print(f"生成 {OUT}（{len(out)} B）")
    for m in MODES:
        print(f"  {m}: {len(mode_blocks[m])} 行写入")
    print(f"  跳过（Scene 内部函数，外部通道不适用）: {skipped}")


if __name__ == "__main__":
    main()
