#!/system/bin/sh
# ============================================================
#  频率接管器 apply_freq.sh   （v3 · 2026-09-16 交回 Scene）
# ------------------------------------------------------------
#  【v3 变更：CPU 调频权限交回 Scene】
#    v2 由本模块按「前台应用的模式」写 cpuN/qos/{max,min}_freq 限频。
#    现按用户要求**全部交回 Scene 自己的模式 preset**
#    （profile.json 里 <mode>_active / <mode>_inactive 的 @cpu_freq）——
#    那是 Scene 的正规通道，天然支持「按应用 / 按前后台」区分。
#
#    本脚本从此**不再写任何频率节点**，只做一件事：
#    在交回瞬间把 v2 遗留的 QoS 上下限清成「不限频」，让 Scene 从干净的白纸接管。
#      上限 → cpuinfo_max_freq（硬件最高 = 无限制）
#      下限 → 该核 stock 地板（platform 默认）
#
#    只清「被我们改过的」值：本来就是不限频的核一个字节都不写（0 开销）。
#
#  【保留可执行的原因】guard.sh / WebUI 仍在调用它；将来若需要恢复模块限频，
#    把 v2 的那段写回去即可（见 README §5.1 的实测结论表）。
#
#  用法:
#    apply_freq.sh             → 确保「不限频」（幂等，值已正确就什么都不写）
#    apply_freq.sh --restore   → 同上（保留兼容旧调用）
#    apply_freq.sh -f <pkg>    → 忽略 <pkg>，同上（保留兼容旧调用）
# ============================================================
MODDIR="${MODDIR:-/data/adb/modules/SceneO3Tuner}"
. "$MODDIR/lib/util.sh"

while [ $# -gt 0 ]; do
    case "$1" in
      --restore) : ;;
      -f)        shift ;;
      *)         : ;;
    esac
    shift
done

CL_L="0 1 2 3"; CL_M="4 5 6 7"; CL_P="8 9"

rd()    { read -r v < "$1" 2>/dev/null; echo "${v:-0}"; }
hwmax() { rd "/sys/devices/system/cpu/cpu$1/cpufreq/cpuinfo_max_freq"; }
qmax()  { rd "/sys/devices/system/cpu/cpu$1/qos/max_freq"; }
qmin()  { rd "/sys/devices/system/cpu/cpu$1/qos/min_freq"; }

N=0
for v in $CL_L $CL_M $CL_P; do
    MX=$(hwmax "$v"); [ -n "$MX" ] || continue
    now=$(qmax "$v")
    if [ -n "$now" ] && [ "$now" != "$MX" ]; then
        echo "$MX" > "/sys/devices/system/cpu/cpu$v/qos/max_freq" 2>/dev/null && N=$((N+1))
    fi
    MN=$(stock_min_of "$v")
    now=$(qmin "$v")
    if [ -n "$MN" ] && [ -n "$now" ] && [ "$now" != "$MN" ]; then
        echo "$MN" > "/sys/devices/system/cpu/cpu$v/qos/min_freq" 2>/dev/null && N=$((N+1))
    fi
done

if [ "$N" = "0" ]; then
    log_quiet "freq: 已交回 Scene 接管（QoS 无遗留值，未写任何节点）"
else
    log_quiet "freq: 已交回 Scene 接管 · 清理 v2 遗留 QoS 值 $N 处 → 不限频"
fi
exit 0
