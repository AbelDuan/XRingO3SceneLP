#!/system/bin/sh
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
# ─────────────────────── 1. xres 自适应升降频锁定 ───────────────────────
# 对应蓝本：锁 walt/adaptive_high_freq、adaptive_low_freq = 0
# 目的：关掉小米“自适应抬频”，让频率只由 target_loads/hispeed 决定 → 更可预测、更省电
for p in policy0 policy4 policy8; do
  lock_value 0 /sys/devices/system/cpu/cpufreq/$p/xres/adaptive_high_freq
  lock_value 0 /sys/devices/system/cpu/cpufreq/$p/xres/adaptive_low_freq
done

# ─────────────────────── 2. uclamp 上限放开 ───────────────────────
echo 1024 > /proc/sys/kernel/sched_util_clamp_max 2>/dev/null && log "uclamp_max=1024"

# ─────────────────────── 3. 温控 / 限频解绑（O3 版，替代 msm_performance）──
T=/sys/class/thermal/thermal_message
hide_value $T/temp_state 0
hide_value $T/market_download_limit 0
# 注：原有一行 hide_value $T/devfreq_gpu_limit 0（解除温控对 GPU 的限频），
#     v10 起删除 —— GPU 完全交回系统（含温控）管理，模块不做任何 GPU 调整。
# 说明：$T/cpu_nolimit_temp 在 O3 默认 0（= 用系统策略）。蓝本设 49500，
#       但 O3 语义未验证，贸然写入可能反而“打开”一个限频阈值 → 保持默认。
set_value 0 $T/special_cpu_limit
set_value 0 $T/boost_cpu_hotplug

# ─────────────────────── 4. core_ctl：抬高“拉起大核”阈值（LP 倾向）───────
# 蓝本对 cpu6 写 up=80/down=55/delay=24。
# O3 原值：cpu4 up=70*4 down=40*4 delay=32 ｜ cpu8 up=75*2 down=45*2 delay=16
# 这里只抬高 up 阈值（更难把大核/超大核拉上线），down 与 delay 保持 O3 默认，
# 避免过度改动导致卡顿；如需更激进可自行调低 down。
for i in 0 1 2 3; do printf '80 '; done > /sys/devices/system/cpu/cpu4/core_ctl/busy_up_thres 2>/dev/null
log "core_ctl cpu4 busy_up_thres=80*4"
printf '85 85 ' > /sys/devices/system/cpu/cpu8/core_ctl/busy_up_thres 2>/dev/null
log "core_ctl cpu8 busy_up_thres=85*2"

# ─────────────────────── 5. cpuset 家务 ───────────────────────
[ -d /dev/cpuset/background/untrustedapp ] && rmdir /dev/cpuset/background/untrustedapp 2>/dev/null \
  && log "rmdir background/untrustedapp"
# 注意：蓝本删除 /dev/cpuset/foreground/boost；O3 上该目录被 framework 使用，
#       删除可能影响启动/动画 → 这里保留不动。
KC=$(pgrep -f kcompactd0 2>/dev/null)
[ -n "$KC" ] && { echo $KC > /dev/cpuset/foreground/tasks 2>/dev/null; log "kcompactd0 -> foreground"; }

# kswapd 绑到**中核**（O3: 4-7，对应蓝本的 6-7）
#   ⚠ v16.11 从 8-9 改到 4-7：模块现在禁止系统 cpuset 组使用超大核
#     （bigcore_guard.sh），而 cpuset 要求 child ⊆ parent ——
#     若 kswapd 仍占 8-9，父组 top-app 就收不到 0-7（内核 EINVAL）。
mkdir -p /dev/cpuset/top-app/kswapd 2>/dev/null
echo 0 > /dev/cpuset/top-app/kswapd/mems 2>/dev/null
echo 4-7 > /dev/cpuset/top-app/kswapd/cpus 2>/dev/null
KS=$(pgrep kswapd0 2>/dev/null)
[ -n "$KS" ] && echo $KS > /dev/cpuset/top-app/kswapd/tasks 2>/dev/null && log "kswapd0 -> top-app/kswapd cpus=4-7"

# ─────────────────────── 6. walt 调度器（XRing 版）───────────────────────
# 蓝本的 walt 微调多数键在 O3 不存在，只保留 O3 实有的等价项
set_value 99 /proc/sys/walt/walt_rtg_cfs_boost_prio
set_value 0  /proc/sys/walt/sched_boost
set_value 60 /proc/sys/walt/sched_min_task_util_for_uclamp
set_value 60 /proc/sys/walt/sched_min_task_util_for_boost
# 关闭输入/按键 boost（LP：不靠瞬时抬频换手感）
set_value 0 /proc/sys/walt/input_boost/sched_boost_on_input
set_value 0 /proc/sys/walt/input_boost/sched_boost_on_powerkey
set_value 0 /proc/sys/walt/input_boost/sched_boost_on_volkey

# ─────────────────────── 7. GPU ───────────────────────
# v10 起模块**完全不碰 GPU**：不写 boost_enable / linked_freq_disable，
# 不解除温控 GPU 限频，profile.json 里也没有 gpu_* preset / alias。
# 原因：O3 的 GPU 由 devfreq + 厂商 power HAL 自治（实证：手写 core_ctl 会被
# vendor.xring.ha 在数秒内回写），模块插手既抢不过也有反效果。
# Scene 侧同步改为 features/env.conf 的 gpu_lock=0（= 不禁止系统 GPU Boost）。

# ─────────────────────── 8. 小米侧：停掉游戏加速服务 ───────────────────────
# 蓝本强停 joyose（替代其 migt/metis 参数锁）
am force-stop com.xiaomi.joyose 2>/dev/null && log "force-stop joyose"

log "===== done ====="

  touch "$BOOTMARK" 2>/dev/null
  log "===== init done ====="
}

MODE="${1:-init}"

case "$MODE" in
  powersave)
    # 省电（来自 profile.json presets.powersave_active）
    do_init
  set_value "xres" "/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor"
  snap_write min 0 "417792"
  snap_write max 0 "1209600"
  set_value "xres" "/sys/devices/system/cpu/cpu4/cpufreq/scaling_governor"
  snap_write min 4 "556800"
  snap_write max 4 "1651200"
  set_value "xres" "/sys/devices/system/cpu/cpu8/cpufreq/scaling_governor"
  snap_write min 8 "1113600"
  snap_write max 8 "2553600"
  set_value "95" "/sys/devices/system/cpu/cpu0/cpufreq/xres/hispeed_load"
  set_value "1209600" "/sys/devices/system/cpu/cpu0/cpufreq/xres/hispeed_freq"
  set_value "1497600" "/sys/devices/system/cpu/cpu0/cpufreq/xres/irq_boost_freq"
  set_value "1497600" "/sys/devices/system/cpu/cpu0/cpufreq/xres/rtg_boost_freq"
  set_value "1497600" "/sys/devices/system/cpu/cpu0/cpufreq/xres/ed_boost_freq"
  set_value "1497600" "/sys/devices/system/cpu/cpu0/cpufreq/xres/iowait_upper_limit"
  set_value "200000" "/sys/devices/system/cpu/cpu0/cpufreq/xres/iowait_boost_step"
  set_value "1" "/sys/devices/system/cpu/cpu0/cpufreq/xres/pl"
  set_value "200000" "/sys/devices/system/cpu/cpu0/cpufreq/xres/pl_step_limit"
  set_value "2000" "/sys/devices/system/cpu/cpu0/cpufreq/xres/above_hispeed_delay"
  set_value "4000" "/sys/devices/system/cpu/cpu0/cpufreq/xres/min_sample_time"
  set_value "4000" "/sys/devices/system/cpu/cpu0/cpufreq/xres/timer_slack"
  set_value "2000" "/sys/devices/system/cpu/cpu0/cpufreq/xres/rate_limit_us"
  set_value "250" "/sys/devices/system/cpu/cpu0/cpufreq/xres/overload_duration"
  set_value "0" "/sys/devices/system/cpu/cpu0/cpufreq/xres/nl"
  set_value "0" "/sys/devices/system/cpu/cpu0/cpufreq/xres/fl"
  set_value "0" "/sys/devices/system/cpu/cpu0/cpufreq/xres/adaptive_high_freq"
  set_value "0" "/sys/devices/system/cpu/cpu0/cpufreq/xres/adaptive_low_freq"
  set_value "95" "/sys/devices/system/cpu/cpu4/cpufreq/xres/hispeed_load"
  set_value "1651200" "/sys/devices/system/cpu/cpu4/cpufreq/xres/hispeed_freq"
  set_value "1651200" "/sys/devices/system/cpu/cpu4/cpufreq/xres/irq_boost_freq"
  set_value "1651200" "/sys/devices/system/cpu/cpu4/cpufreq/xres/rtg_boost_freq"
  set_value "1651200" "/sys/devices/system/cpu/cpu4/cpufreq/xres/ed_boost_freq"
  set_value "1651200" "/sys/devices/system/cpu/cpu4/cpufreq/xres/iowait_upper_limit"
  set_value "200000" "/sys/devices/system/cpu/cpu4/cpufreq/xres/iowait_boost_step"
  set_value "1" "/sys/devices/system/cpu/cpu4/cpufreq/xres/pl"
  set_value "200000" "/sys/devices/system/cpu/cpu4/cpufreq/xres/pl_step_limit"
  set_value "2000" "/sys/devices/system/cpu/cpu4/cpufreq/xres/above_hispeed_delay"
  set_value "4000" "/sys/devices/system/cpu/cpu4/cpufreq/xres/min_sample_time"
  set_value "4000" "/sys/devices/system/cpu/cpu4/cpufreq/xres/timer_slack"
  set_value "2000" "/sys/devices/system/cpu/cpu4/cpufreq/xres/rate_limit_us"
  set_value "250" "/sys/devices/system/cpu/cpu4/cpufreq/xres/overload_duration"
  set_value "0" "/sys/devices/system/cpu/cpu4/cpufreq/xres/nl"
  set_value "0" "/sys/devices/system/cpu/cpu4/cpufreq/xres/fl"
  set_value "0" "/sys/devices/system/cpu/cpu4/cpufreq/xres/adaptive_high_freq"
  set_value "0" "/sys/devices/system/cpu/cpu4/cpufreq/xres/adaptive_low_freq"
  set_value "95" "/sys/devices/system/cpu/cpu8/cpufreq/xres/hispeed_load"
  set_value "2044800" "/sys/devices/system/cpu/cpu8/cpufreq/xres/hispeed_freq"
  set_value "2044800" "/sys/devices/system/cpu/cpu8/cpufreq/xres/irq_boost_freq"
  set_value "2044800" "/sys/devices/system/cpu/cpu8/cpufreq/xres/rtg_boost_freq"
  set_value "2044800" "/sys/devices/system/cpu/cpu8/cpufreq/xres/ed_boost_freq"
  set_value "2044800" "/sys/devices/system/cpu/cpu8/cpufreq/xres/iowait_upper_limit"
  set_value "200000" "/sys/devices/system/cpu/cpu8/cpufreq/xres/iowait_boost_step"
  set_value "1" "/sys/devices/system/cpu/cpu8/cpufreq/xres/pl"
  set_value "200000" "/sys/devices/system/cpu/cpu8/cpufreq/xres/pl_step_limit"
  set_value "2000" "/sys/devices/system/cpu/cpu8/cpufreq/xres/above_hispeed_delay"
  set_value "4000" "/sys/devices/system/cpu/cpu8/cpufreq/xres/min_sample_time"
  set_value "4000" "/sys/devices/system/cpu/cpu8/cpufreq/xres/timer_slack"
  set_value "2000" "/sys/devices/system/cpu/cpu8/cpufreq/xres/rate_limit_us"
  set_value "250" "/sys/devices/system/cpu/cpu8/cpufreq/xres/overload_duration"
  set_value "0" "/sys/devices/system/cpu/cpu8/cpufreq/xres/nl"
  set_value "0" "/sys/devices/system/cpu/cpu8/cpufreq/xres/fl"
  set_value "0" "/sys/devices/system/cpu/cpu8/cpufreq/xres/adaptive_high_freq"
  set_value "0" "/sys/devices/system/cpu/cpu8/cpufreq/xres/adaptive_low_freq"
  set_value "50 557056:60 1065600:85 1785600:90" "/sys/devices/system/cpu/cpu0/cpufreq/xres/target_loads"
  set_value "50 691200:60 988800:85 1468800:90" "/sys/devices/system/cpu/cpu4/cpufreq/xres/target_loads"
  set_value "50 1113600:60 2044800:85 2553600:90" "/sys/devices/system/cpu/cpu8/cpufreq/xres/target_loads"
  set_value "912000" "/sys/devices/system/cpu/cpu0/cpufreq/xres/pl_max_freq"
  set_value "1142400" "/sys/devices/system/cpu/cpu4/cpufreq/xres/pl_max_freq"
  set_value "2198400" "/sys/devices/system/cpu/cpu8/cpufreq/xres/pl_max_freq"
    lock_min
    ;;
  balance)
    # 流畅（来自 profile.json presets.balance_active）
    do_init
  set_value "xres" "/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor"
  snap_write min 0 "417792"
  snap_write max 0 "1939200"
  set_value "xres" "/sys/devices/system/cpu/cpu4/cpufreq/scaling_governor"
  snap_write min 4 "556800"
  snap_write max 4 "2419200"
  set_value "xres" "/sys/devices/system/cpu/cpu8/cpufreq/scaling_governor"
  snap_write min 8 "1113600"
  snap_write max 8 "2371200"
  set_value "92" "/sys/devices/system/cpu/cpu0/cpufreq/xres/hispeed_load"
  set_value "1353600" "/sys/devices/system/cpu/cpu0/cpufreq/xres/hispeed_freq"
  set_value "1497600" "/sys/devices/system/cpu/cpu0/cpufreq/xres/irq_boost_freq"
  set_value "1497600" "/sys/devices/system/cpu/cpu0/cpufreq/xres/rtg_boost_freq"
  set_value "1497600" "/sys/devices/system/cpu/cpu0/cpufreq/xres/ed_boost_freq"
  set_value "1497600" "/sys/devices/system/cpu/cpu0/cpufreq/xres/iowait_upper_limit"
  set_value "200000" "/sys/devices/system/cpu/cpu0/cpufreq/xres/iowait_boost_step"
  set_value "1" "/sys/devices/system/cpu/cpu0/cpufreq/xres/pl"
  set_value "200000" "/sys/devices/system/cpu/cpu0/cpufreq/xres/pl_step_limit"
  set_value "2000" "/sys/devices/system/cpu/cpu0/cpufreq/xres/above_hispeed_delay"
  set_value "4000" "/sys/devices/system/cpu/cpu0/cpufreq/xres/min_sample_time"
  set_value "4000" "/sys/devices/system/cpu/cpu0/cpufreq/xres/timer_slack"
  set_value "1500" "/sys/devices/system/cpu/cpu0/cpufreq/xres/rate_limit_us"
  set_value "250" "/sys/devices/system/cpu/cpu0/cpufreq/xres/overload_duration"
  set_value "0" "/sys/devices/system/cpu/cpu0/cpufreq/xres/nl"
  set_value "0" "/sys/devices/system/cpu/cpu0/cpufreq/xres/fl"
  set_value "0" "/sys/devices/system/cpu/cpu0/cpufreq/xres/adaptive_high_freq"
  set_value "0" "/sys/devices/system/cpu/cpu0/cpufreq/xres/adaptive_low_freq"
  set_value "92" "/sys/devices/system/cpu/cpu4/cpufreq/xres/hispeed_load"
  set_value "1804800" "/sys/devices/system/cpu/cpu4/cpufreq/xres/hispeed_freq"
  set_value "1651200" "/sys/devices/system/cpu/cpu4/cpufreq/xres/irq_boost_freq"
  set_value "1651200" "/sys/devices/system/cpu/cpu4/cpufreq/xres/rtg_boost_freq"
  set_value "1651200" "/sys/devices/system/cpu/cpu4/cpufreq/xres/ed_boost_freq"
  set_value "1651200" "/sys/devices/system/cpu/cpu4/cpufreq/xres/iowait_upper_limit"
  set_value "200000" "/sys/devices/system/cpu/cpu4/cpufreq/xres/iowait_boost_step"
  set_value "1" "/sys/devices/system/cpu/cpu4/cpufreq/xres/pl"
  set_value "200000" "/sys/devices/system/cpu/cpu4/cpufreq/xres/pl_step_limit"
  set_value "2000" "/sys/devices/system/cpu/cpu4/cpufreq/xres/above_hispeed_delay"
  set_value "4000" "/sys/devices/system/cpu/cpu4/cpufreq/xres/min_sample_time"
  set_value "4000" "/sys/devices/system/cpu/cpu4/cpufreq/xres/timer_slack"
  set_value "1500" "/sys/devices/system/cpu/cpu4/cpufreq/xres/rate_limit_us"
  set_value "250" "/sys/devices/system/cpu/cpu4/cpufreq/xres/overload_duration"
  set_value "0" "/sys/devices/system/cpu/cpu4/cpufreq/xres/nl"
  set_value "0" "/sys/devices/system/cpu/cpu4/cpufreq/xres/fl"
  set_value "0" "/sys/devices/system/cpu/cpu4/cpufreq/xres/adaptive_high_freq"
  set_value "0" "/sys/devices/system/cpu/cpu4/cpufreq/xres/adaptive_low_freq"
  set_value "92" "/sys/devices/system/cpu/cpu8/cpufreq/xres/hispeed_load"
  set_value "2198400" "/sys/devices/system/cpu/cpu8/cpufreq/xres/hispeed_freq"
  set_value "2044800" "/sys/devices/system/cpu/cpu8/cpufreq/xres/irq_boost_freq"
  set_value "2044800" "/sys/devices/system/cpu/cpu8/cpufreq/xres/rtg_boost_freq"
  set_value "2044800" "/sys/devices/system/cpu/cpu8/cpufreq/xres/ed_boost_freq"
  set_value "2044800" "/sys/devices/system/cpu/cpu8/cpufreq/xres/iowait_upper_limit"
  set_value "200000" "/sys/devices/system/cpu/cpu8/cpufreq/xres/iowait_boost_step"
  set_value "1" "/sys/devices/system/cpu/cpu8/cpufreq/xres/pl"
  set_value "200000" "/sys/devices/system/cpu/cpu8/cpufreq/xres/pl_step_limit"
  set_value "2000" "/sys/devices/system/cpu/cpu8/cpufreq/xres/above_hispeed_delay"
  set_value "4000" "/sys/devices/system/cpu/cpu8/cpufreq/xres/min_sample_time"
  set_value "4000" "/sys/devices/system/cpu/cpu8/cpufreq/xres/timer_slack"
  set_value "1500" "/sys/devices/system/cpu/cpu8/cpufreq/xres/rate_limit_us"
  set_value "250" "/sys/devices/system/cpu/cpu8/cpufreq/xres/overload_duration"
  set_value "0" "/sys/devices/system/cpu/cpu8/cpufreq/xres/nl"
  set_value "0" "/sys/devices/system/cpu/cpu8/cpufreq/xres/fl"
  set_value "0" "/sys/devices/system/cpu/cpu8/cpufreq/xres/adaptive_high_freq"
  set_value "0" "/sys/devices/system/cpu/cpu8/cpufreq/xres/adaptive_low_freq"
  set_value "45 912000:55 1209600:75 1497600:85" "/sys/devices/system/cpu/cpu0/cpufreq/xres/target_loads"
  set_value "45 988800:55 1142400:75 1651200:85" "/sys/devices/system/cpu/cpu4/cpufreq/xres/target_loads"
  set_value "55 1113600:65 1497600:75 2044800:85" "/sys/devices/system/cpu/cpu8/cpufreq/xres/target_loads"
  set_value "1785600" "/sys/devices/system/cpu/cpu0/cpufreq/xres/pl_max_freq"
  set_value "2419200" "/sys/devices/system/cpu/cpu4/cpufreq/xres/pl_max_freq"
  set_value "3148800" "/sys/devices/system/cpu/cpu8/cpufreq/xres/pl_max_freq"
    lock_min
    ;;
  performance)
    # 性能（来自 profile.json presets.performance_active）
    do_init
  set_value "xres" "/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor"
  snap_write min 0 "417792"
  snap_write max 0 "2745600"
  set_value "xres" "/sys/devices/system/cpu/cpu4/cpufreq/scaling_governor"
  snap_write min 4 "556800"
  snap_write max 4 "3148800"
  set_value "xres" "/sys/devices/system/cpu/cpu8/cpufreq/scaling_governor"
  snap_write min 8 "1113600"
  snap_write max 8 "3955200"
  set_value "88" "/sys/devices/system/cpu/cpu0/cpufreq/xres/hispeed_load"
  set_value "1497600" "/sys/devices/system/cpu/cpu0/cpufreq/xres/hispeed_freq"
  set_value "1497600" "/sys/devices/system/cpu/cpu0/cpufreq/xres/irq_boost_freq"
  set_value "1497600" "/sys/devices/system/cpu/cpu0/cpufreq/xres/rtg_boost_freq"
  set_value "1497600" "/sys/devices/system/cpu/cpu0/cpufreq/xres/ed_boost_freq"
  set_value "1497600" "/sys/devices/system/cpu/cpu0/cpufreq/xres/iowait_upper_limit"
  set_value "200000" "/sys/devices/system/cpu/cpu0/cpufreq/xres/iowait_boost_step"
  set_value "1" "/sys/devices/system/cpu/cpu0/cpufreq/xres/pl"
  set_value "200000" "/sys/devices/system/cpu/cpu0/cpufreq/xres/pl_step_limit"
  set_value "2000" "/sys/devices/system/cpu/cpu0/cpufreq/xres/above_hispeed_delay"
  set_value "4000" "/sys/devices/system/cpu/cpu0/cpufreq/xres/min_sample_time"
  set_value "4000" "/sys/devices/system/cpu/cpu0/cpufreq/xres/timer_slack"
  set_value "1000" "/sys/devices/system/cpu/cpu0/cpufreq/xres/rate_limit_us"
  set_value "250" "/sys/devices/system/cpu/cpu0/cpufreq/xres/overload_duration"
  set_value "0" "/sys/devices/system/cpu/cpu0/cpufreq/xres/nl"
  set_value "0" "/sys/devices/system/cpu/cpu0/cpufreq/xres/fl"
  set_value "0" "/sys/devices/system/cpu/cpu0/cpufreq/xres/adaptive_high_freq"
  set_value "0" "/sys/devices/system/cpu/cpu0/cpufreq/xres/adaptive_low_freq"
  set_value "88" "/sys/devices/system/cpu/cpu4/cpufreq/xres/hispeed_load"
  set_value "1968000" "/sys/devices/system/cpu/cpu4/cpufreq/xres/hispeed_freq"
  set_value "1651200" "/sys/devices/system/cpu/cpu4/cpufreq/xres/irq_boost_freq"
  set_value "1651200" "/sys/devices/system/cpu/cpu4/cpufreq/xres/rtg_boost_freq"
  set_value "1651200" "/sys/devices/system/cpu/cpu4/cpufreq/xres/ed_boost_freq"
  set_value "1651200" "/sys/devices/system/cpu/cpu4/cpufreq/xres/iowait_upper_limit"
  set_value "200000" "/sys/devices/system/cpu/cpu4/cpufreq/xres/iowait_boost_step"
  set_value "1" "/sys/devices/system/cpu/cpu4/cpufreq/xres/pl"
  set_value "200000" "/sys/devices/system/cpu/cpu4/cpufreq/xres/pl_step_limit"
  set_value "2000" "/sys/devices/system/cpu/cpu4/cpufreq/xres/above_hispeed_delay"
  set_value "4000" "/sys/devices/system/cpu/cpu4/cpufreq/xres/min_sample_time"
  set_value "4000" "/sys/devices/system/cpu/cpu4/cpufreq/xres/timer_slack"
  set_value "1000" "/sys/devices/system/cpu/cpu4/cpufreq/xres/rate_limit_us"
  set_value "250" "/sys/devices/system/cpu/cpu4/cpufreq/xres/overload_duration"
  set_value "0" "/sys/devices/system/cpu/cpu4/cpufreq/xres/nl"
  set_value "0" "/sys/devices/system/cpu/cpu4/cpufreq/xres/fl"
  set_value "0" "/sys/devices/system/cpu/cpu4/cpufreq/xres/adaptive_high_freq"
  set_value "0" "/sys/devices/system/cpu/cpu4/cpufreq/xres/adaptive_low_freq"
  set_value "88" "/sys/devices/system/cpu/cpu8/cpufreq/xres/hispeed_load"
  set_value "2371200" "/sys/devices/system/cpu/cpu8/cpufreq/xres/hispeed_freq"
  set_value "2044800" "/sys/devices/system/cpu/cpu8/cpufreq/xres/irq_boost_freq"
  set_value "2044800" "/sys/devices/system/cpu/cpu8/cpufreq/xres/rtg_boost_freq"
  set_value "2044800" "/sys/devices/system/cpu/cpu8/cpufreq/xres/ed_boost_freq"
  set_value "2044800" "/sys/devices/system/cpu/cpu8/cpufreq/xres/iowait_upper_limit"
  set_value "200000" "/sys/devices/system/cpu/cpu8/cpufreq/xres/iowait_boost_step"
  set_value "1" "/sys/devices/system/cpu/cpu8/cpufreq/xres/pl"
  set_value "200000" "/sys/devices/system/cpu/cpu8/cpufreq/xres/pl_step_limit"
  set_value "2000" "/sys/devices/system/cpu/cpu8/cpufreq/xres/above_hispeed_delay"
  set_value "4000" "/sys/devices/system/cpu/cpu8/cpufreq/xres/min_sample_time"
  set_value "4000" "/sys/devices/system/cpu/cpu8/cpufreq/xres/timer_slack"
  set_value "1000" "/sys/devices/system/cpu/cpu8/cpufreq/xres/rate_limit_us"
  set_value "250" "/sys/devices/system/cpu/cpu8/cpufreq/xres/overload_duration"
  set_value "0" "/sys/devices/system/cpu/cpu8/cpufreq/xres/nl"
  set_value "0" "/sys/devices/system/cpu/cpu8/cpufreq/xres/fl"
  set_value "0" "/sys/devices/system/cpu/cpu8/cpufreq/xres/adaptive_high_freq"
  set_value "0" "/sys/devices/system/cpu/cpu8/cpufreq/xres/adaptive_low_freq"
  set_value "40 1209600:50 1497600:70 1641600:85" "/sys/devices/system/cpu/cpu0/cpufreq/xres/target_loads"
  set_value "40 1142400:50 1651200:70 1968000:85" "/sys/devices/system/cpu/cpu4/cpufreq/xres/target_loads"
  set_value "50 1497600:60 2044800:70 2553600:85" "/sys/devices/system/cpu/cpu8/cpufreq/xres/target_loads"
  set_value "2745600" "/sys/devices/system/cpu/cpu0/cpufreq/xres/pl_max_freq"
  set_value "3148800" "/sys/devices/system/cpu/cpu4/cpufreq/xres/pl_max_freq"
  set_value "3955200" "/sys/devices/system/cpu/cpu8/cpufreq/xres/pl_max_freq"
    lock_min
    ;;
  fast)
    # 极速（来自 profile.json presets.fast_active）
    do_init
  set_value "xres" "/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor"
  snap_write min 0 "417792"
  snap_write max 0 "3148800"
  set_value "xres" "/sys/devices/system/cpu/cpu4/cpufreq/scaling_governor"
  snap_write min 4 "556800"
  snap_write max 4 "3686400"
  set_value "xres" "/sys/devices/system/cpu/cpu8/cpufreq/scaling_governor"
  snap_write min 8 "1113600"
  snap_write max 8 "4358400"
  set_value "85" "/sys/devices/system/cpu/cpu0/cpufreq/xres/hispeed_load"
  set_value "1641600" "/sys/devices/system/cpu/cpu0/cpufreq/xres/hispeed_freq"
  set_value "1497600" "/sys/devices/system/cpu/cpu0/cpufreq/xres/irq_boost_freq"
  set_value "1497600" "/sys/devices/system/cpu/cpu0/cpufreq/xres/rtg_boost_freq"
  set_value "1497600" "/sys/devices/system/cpu/cpu0/cpufreq/xres/ed_boost_freq"
  set_value "1497600" "/sys/devices/system/cpu/cpu0/cpufreq/xres/iowait_upper_limit"
  set_value "200000" "/sys/devices/system/cpu/cpu0/cpufreq/xres/iowait_boost_step"
  set_value "1" "/sys/devices/system/cpu/cpu0/cpufreq/xres/pl"
  set_value "200000" "/sys/devices/system/cpu/cpu0/cpufreq/xres/pl_step_limit"
  set_value "2000" "/sys/devices/system/cpu/cpu0/cpufreq/xres/above_hispeed_delay"
  set_value "4000" "/sys/devices/system/cpu/cpu0/cpufreq/xres/min_sample_time"
  set_value "4000" "/sys/devices/system/cpu/cpu0/cpufreq/xres/timer_slack"
  set_value "500" "/sys/devices/system/cpu/cpu0/cpufreq/xres/rate_limit_us"
  set_value "250" "/sys/devices/system/cpu/cpu0/cpufreq/xres/overload_duration"
  set_value "0" "/sys/devices/system/cpu/cpu0/cpufreq/xres/nl"
  set_value "0" "/sys/devices/system/cpu/cpu0/cpufreq/xres/fl"
  set_value "0" "/sys/devices/system/cpu/cpu0/cpufreq/xres/adaptive_high_freq"
  set_value "0" "/sys/devices/system/cpu/cpu0/cpufreq/xres/adaptive_low_freq"
  set_value "85" "/sys/devices/system/cpu/cpu4/cpufreq/xres/hispeed_load"
  set_value "2131200" "/sys/devices/system/cpu/cpu4/cpufreq/xres/hispeed_freq"
  set_value "1651200" "/sys/devices/system/cpu/cpu4/cpufreq/xres/irq_boost_freq"
  set_value "1651200" "/sys/devices/system/cpu/cpu4/cpufreq/xres/rtg_boost_freq"
  set_value "1651200" "/sys/devices/system/cpu/cpu4/cpufreq/xres/ed_boost_freq"
  set_value "1651200" "/sys/devices/system/cpu/cpu4/cpufreq/xres/iowait_upper_limit"
  set_value "200000" "/sys/devices/system/cpu/cpu4/cpufreq/xres/iowait_boost_step"
  set_value "1" "/sys/devices/system/cpu/cpu4/cpufreq/xres/pl"
  set_value "200000" "/sys/devices/system/cpu/cpu4/cpufreq/xres/pl_step_limit"
  set_value "2000" "/sys/devices/system/cpu/cpu4/cpufreq/xres/above_hispeed_delay"
  set_value "4000" "/sys/devices/system/cpu/cpu4/cpufreq/xres/min_sample_time"
  set_value "4000" "/sys/devices/system/cpu/cpu4/cpufreq/xres/timer_slack"
  set_value "500" "/sys/devices/system/cpu/cpu4/cpufreq/xres/rate_limit_us"
  set_value "250" "/sys/devices/system/cpu/cpu4/cpufreq/xres/overload_duration"
  set_value "0" "/sys/devices/system/cpu/cpu4/cpufreq/xres/nl"
  set_value "0" "/sys/devices/system/cpu/cpu4/cpufreq/xres/fl"
  set_value "0" "/sys/devices/system/cpu/cpu4/cpufreq/xres/adaptive_high_freq"
  set_value "0" "/sys/devices/system/cpu/cpu4/cpufreq/xres/adaptive_low_freq"
  set_value "85" "/sys/devices/system/cpu/cpu8/cpufreq/xres/hispeed_load"
  set_value "2553600" "/sys/devices/system/cpu/cpu8/cpufreq/xres/hispeed_freq"
  set_value "2044800" "/sys/devices/system/cpu/cpu8/cpufreq/xres/irq_boost_freq"
  set_value "2044800" "/sys/devices/system/cpu/cpu8/cpufreq/xres/rtg_boost_freq"
  set_value "2044800" "/sys/devices/system/cpu/cpu8/cpufreq/xres/ed_boost_freq"
  set_value "2044800" "/sys/devices/system/cpu/cpu8/cpufreq/xres/iowait_upper_limit"
  set_value "200000" "/sys/devices/system/cpu/cpu8/cpufreq/xres/iowait_boost_step"
  set_value "1" "/sys/devices/system/cpu/cpu8/cpufreq/xres/pl"
  set_value "200000" "/sys/devices/system/cpu/cpu8/cpufreq/xres/pl_step_limit"
  set_value "2000" "/sys/devices/system/cpu/cpu8/cpufreq/xres/above_hispeed_delay"
  set_value "4000" "/sys/devices/system/cpu/cpu8/cpufreq/xres/min_sample_time"
  set_value "4000" "/sys/devices/system/cpu/cpu8/cpufreq/xres/timer_slack"
  set_value "500" "/sys/devices/system/cpu/cpu8/cpufreq/xres/rate_limit_us"
  set_value "250" "/sys/devices/system/cpu/cpu8/cpufreq/xres/overload_duration"
  set_value "0" "/sys/devices/system/cpu/cpu8/cpufreq/xres/nl"
  set_value "0" "/sys/devices/system/cpu/cpu8/cpufreq/xres/fl"
  set_value "0" "/sys/devices/system/cpu/cpu8/cpufreq/xres/adaptive_high_freq"
  set_value "0" "/sys/devices/system/cpu/cpu8/cpufreq/xres/adaptive_low_freq"
  set_value "40 1353600:50 1785600:70 2092800:85" "/sys/devices/system/cpu/cpu0/cpufreq/xres/target_loads"
  set_value "40 1468800:50 1804800:70 2294400:85" "/sys/devices/system/cpu/cpu4/cpufreq/xres/target_loads"
  set_value "50 2371200:60 2553600:70 3024000:85" "/sys/devices/system/cpu/cpu8/cpufreq/xres/target_loads"
  set_value "2745600" "/sys/devices/system/cpu/cpu0/cpufreq/xres/pl_max_freq"
  set_value "3148800" "/sys/devices/system/cpu/cpu4/cpufreq/xres/pl_max_freq"
  set_value "3955200" "/sys/devices/system/cpu/cpu8/cpufreq/xres/pl_max_freq"
    lock_min
    ;;
  *)
    do_init
    ;;
esac

log "===== done ====="
exit 0
