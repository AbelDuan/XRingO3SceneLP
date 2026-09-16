#!/system/bin/sh
# ============================================================================
#  Abel · 玄戒 O3 适配版 powercfg.sh
#  蓝本：Xiaomi 17 Ultra (canoe / SM8850) Scene lp 分支 powercfg.sh
#  目标：XRing O3 (xring_o3_asic) 10 核 3 簇 / governor xres / scheduler walt(xring)
#
#  适配要点（与蓝本的差异，逐条）：
#   · walt/policy0+6  → xres/policy0+4+8                 （2 簇 → 3 簇）
#   · msm_performance/parameters/cpu_*_freq   → O3 无此节点，删除
#   · perfmgr/parameters/load_scaling_y       → O3 无此节点，删除
#   · migt/metis/mi_game 参数                 → O3 无这些节点，改为 joyose 强停
#   · /proc/sys/walt/{sched_pipeline_util_thres, walt_low_latency_task_threshold,
#       sched_disable_mvp_thres, sched_lib_name, sched_lib_task,
#       cluster*/smart_freq/ipc_freq_levels}  → O3 的 walt 是 XRing 定制版，
#       无这些键；改用 O3 实有的 sched_min_task_util_for_{uclamp,boost}
#   · thermal_message/cpu_limits              → O3 无此节点，删除
#   · thermal_message/cpu_nolimit_temp（49500）→ O3 默认 0，保持不动（避免反而触发限频）
#   · core_ctl cpu6 → O3 的 cpu4 + cpu8；只抬高“拉起大核”的阈值（LP 倾向）
#   · kswapd cpuset 6-7 → 8-9
#   · foreground/boost 不删除（O3 framework 依赖），仅做 kcompactd 迁移
#
#  USE_HIDE=1 时用 bind-mount 隐藏易被系统改回的节点；设为 0 可完全不用挂载。
# ============================================================================
USE_HIDE=1
LOG=/data/local/tmp/scene_lp_o3.log

log() { echo "[$(date +%H:%M:%S)] $*" >> $LOG; }
echo "===== Abel/O3 powercfg.sh @ $(date) =====" >> $LOG

set_value() {
  value=$1; path=$2
  if [ -f "$path" ]; then
    cur="$(cat $path 2>/dev/null)"
    if [ "$cur" != "$value" ]; then
      chmod 0664 "$path" 2>/dev/null
      echo "$value" > "$path" 2>/dev/null && log "set  $path = $value" || log "FAIL $path"
    fi
  else
    log "skip $path (missing)"
  fi
}

lock_value() {
  if [ -f "$2" ]; then
    chmod 644 "$2" 2>/dev/null
    echo "$1" > "$2" 2>/dev/null
    chmod 444 "$2" 2>/dev/null
    log "lock $2 = $1"
  fi
}

dev_mount=/dev/$(cat /dev/urandom | tr -dc 'a-z_' | head -c 8; echo)
hide_value() {
  [ "$USE_HIDE" = "1" ] || { set_value "$2" "$1"; return; }
  if [ -e "$1" ]; then
    umount "$1" 2>/dev/null
    c_path="$dev_mount${1}"
    [ -f "$c_path" ] || { mkdir -p "$c_path"; rm -r "$c_path"; }
    cp -f "$1" "$c_path" 2>/dev/null || { set_value "$2" "$1"; return; }
    [ -n "$2" ] && set_value "$2" "$1"
    mount --bind "$c_path" "$1" 2>/dev/null && log "hide $1 (= $2)" || log "hideFAIL $1"
  else
    log "skip $1 (missing)"
  fi
}

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
hide_value $T/devfreq_gpu_limit 0
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

# kswapd 绑到超大核（O3: 8-9，对应蓝本的 6-7）
mkdir -p /dev/cpuset/top-app/kswapd 2>/dev/null
echo 0 > /dev/cpuset/top-app/kswapd/mems 2>/dev/null
echo 8-9 > /dev/cpuset/top-app/kswapd/cpus 2>/dev/null
KS=$(pgrep kswapd0 2>/dev/null)
[ -n "$KS" ] && echo $KS > /dev/cpuset/top-app/kswapd/tasks 2>/dev/null && log "kswapd0 -> top-app/kswapd cpus=8-9"

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

# ─────────────────────── 7. GPU devfreq（O3 专有）───────────────────────
# Scene 的 @gpu_freq 在 O3 报 "Unsupported processor!"（daemon 无该 SoC 表）
# → 这里统一关掉 GPU 联动抬频，具体上限交给 profile.json 的 gpu_* preset
set_value 0 /sys/class/devfreq/gpufreq_core/boost_enable
set_value 0 /sys/class/devfreq/gpufreq_core/linked_freq_disable

# ─────────────────────── 8. 小米侧：停掉游戏加速服务 ───────────────────────
# 蓝本强停 joyose（替代其 migt/metis 参数锁）
am force-stop com.xiaomi.joyose 2>/dev/null && log "force-stop joyose"

log "===== done ====="
exit 0
