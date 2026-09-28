#!/system/bin/sh
# ============================================================================
#  Abel · 玄戒 O3 powercfg.sh（O1 官方方案移植版）
#  蓝本：helloklf/scheduler-n1 1.0（O1 官方 SCENE9 蓝本，本方案为 LP 低耗移植）
#  目标：XRing O3 (xring_o3_asic) 10 核 3 簇 / governor xres / core_ctl cpu4 锁4核 cpu8 0-2
#
#  与 O1 蓝本的差异（逐条）：
#   · migt/metis/perfmgr 参数段整体删除 —— O3 无 /sys/module/migt/parameters、
#     无 metis/perfmgr 模块（实测 2026-09-28），写了也是空转
#   · thermal_message/cpu_limits 段保留 if 判断（O3 无该文件，自然跳过）
#   · cpu_nolimit_temp 不写 —— O1 官方设 49500，O3 当前默认 0 且语义未验证，
#     贸然写入可能激活一个未启用的限流阈值（v17 时代实测结论，保守保留）
#   · core_ctl not_preferred 不写 —— O1 官方该行参数错位（lock_value 5 参数，
#     $2 吃到的是"1"而不是路径）实际从未生效，O3 保持系统默认
#   · hide_value 挂载点用固定路径 /dev/.scene_o3_hide —— O1 蓝本用随机名，
#     每跑一次在 /dev 堆一个目录且无人清理（v16 时代实测一天 67 个）
# ============================================================================
LOG=/data/local/tmp/scene_o3_lp.log
echo "===== O3 powercfg.sh @ $(date) =====" >> $LOG

set_value() {
  value=$1; path=$2
  if [ -f "$path" ]; then
    cur="$(cat "$path" 2>/dev/null)"
    if [ "$cur" != "$value" ]; then
      chmod 0664 "$path" 2>/dev/null
      echo "$value" > "$path" 2>/dev/null && echo "[$(date +%H:%M:%S)] set $path=$value" >> $LOG
    fi
  fi
}

lock_value() {
  if [ -f "$2" ]; then
    chmod 644 "$2" 2>/dev/null
    echo "$1" > "$2" 2>/dev/null
    chmod 444 "$2" 2>/dev/null
    echo "[$(date +%H:%M:%S)] lock $2=$1" >> $LOG
  fi
}

dev_mount=/dev/.scene_o3_hide
hide_value() {
  if [ -e "$1" ]; then
    umount "$1" 2>/dev/null
    c_path="$dev_mount$1"
    if [ ! -f "$c_path" ]; then
      mkdir -p "$c_path" 2>/dev/null
      rm -r "$c_path" 2>/dev/null
    fi
    cp -f "$1" "$c_path" 2>/dev/null || return
    [ -n "$2" ] && set_value "$2" "$1"
    mount --bind "$c_path" "$1" 2>/dev/null \
      && echo "[$(date +%H:%M:%S)] hide $1=$2" >> $LOG \
      || echo "[$(date +%H:%M:%S)] hideFAIL $1" >> $LOG
  fi
}

# ── 1. 温控解绑（O1 官方段；O3 无 cpu_limits 文件，if 自然跳过）──────────
t_message=/sys/class/thermal/thermal_message
hide_value $t_message/temp_state 0
hide_value $t_message/market_download_limit 0
set_value 0 $t_message/special_cpu_limit
set_value 0 $t_message/boost_cpu_hotplug
# cpu_nolimit_temp：见文件头注释，O3 不写

# ── 2. core_ctl（O1 官方值；O3 的 cpu4/cpu8 簇规模与 O1 相同）────────────
cpu4=/sys/devices/system/cpu/cpu4/core_ctl
lock_value 4  $cpu4/min_cpus
lock_value 4  $cpu4/max_cpus
lock_value 20 $cpu4/offline_delay_ms
lock_value "80 80 80 80" $cpu4/busy_up_thres
lock_value "50 50 50 50" $cpu4/busy_down_thres

cpu8=/sys/devices/system/cpu/cpu8/core_ctl
lock_value 0  $cpu8/min_cpus
lock_value 2  $cpu8/max_cpus
lock_value 20 $cpu8/offline_delay_ms
lock_value "80 80" $cpu8/busy_up_thres
lock_value "50 50" $cpu8/busy_down_thres

# ── 3. 小米游戏加速（O1 官方保留项；migt/metis 段 O3 无节点已删）──────────
am force-stop com.xiaomi.joyose 2>/dev/null

echo "[$(date +%H:%M:%S)] ===== done =====" >> $LOG
exit 0
