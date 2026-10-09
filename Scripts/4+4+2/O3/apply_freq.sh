#!/system/bin/sh
# ============================================================
#  频率接管器 apply_freq.sh   （v18 · 模块自有 QoS）
# ------------------------------------------------------------
#  【v18 变更：频率完全由本模块定义，不再交回 Scene】
#    v3 把频率交回 Scene；v18 收回 —— Scene 在玄戒 O3 上本就不适配
#    （硬编码 SoC 白名单没有 xring，配置源显示「未知」、开关无法启用），
#    所以频率必须由模块自己下发。
#
#    本脚本把「当前全局模式」的频率写进每簇的 PM QoS 上下限：
#      · 上限 = 该模式 active 档的 max（硬上限，O3 上唯一被强制执行的旋钮）
#      · 下限 = 该模式 active 档的 min
#    切换全局模式 / 落地方案 / 守护每轮都会调用本脚本。
#
#  用法:
#    apply_freq.sh              → 按当前全局模式下发频率（幂等）
#    apply_freq.sh --mode <m>   → 指定模式(powersave|balance|performance|fast)
#    apply_freq.sh --restore    → 恢复 stock（放开上限、下限回最低）
# ============================================================
MODDIR="${MODDIR:-/data/adb/modules/SceneO3Tuner}"
. "$MODDIR/lib/util.sh"

MODE=""
while [ $# -gt 0 ]; do
    case "$1" in
      --mode) MODE="$2"; shift 2 ;;
      --restore) MODE="__restore__"; shift ;;
      *) shift ;;
    esac
done

if [ "$MODE" = "__restore__" ]; then
    restore_stock_freq
    log "freq: 已恢复 stock 频率策略（QoS 放开）"
    echo "OK 已恢复 stock 频率"
    exit 0
fi

# 没指定模式 → 用当前全局模式
if [ -z "$MODE" ]; then
    current_mode_read 2>/dev/null
    MODE="${CUR_MODE:-balance}"
fi
case "$MODE" in
  powersave|balance|performance|fast) ;;
  *) echo "ERR 未知模式: $MODE"; exit 1 ;;
esac

apply_mode_freq "$MODE"
