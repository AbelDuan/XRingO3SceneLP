#!/system/bin/sh
# ============================================================
#  切换 / 落地方案   (v18 · 模块自有)
#  用法: set_scheme.sh <sweet_eco|sweet_bal|sweet_hq|sweet_perf> [quiet]
#  可选: set_scheme.sh repair | restore
#  v18：方案切换 = 选默认全局模式 + 频率下发 + 线程重建，
#       不再与 Scene 做任何交互。
# ============================================================
MODDIR="${MODDIR:-/data/adb/modules/SceneO3Tuner}"
. "$MODDIR/lib/util.sh"

ACTION="$1"
QUIET="$2"

# ---------- 修复：重建线程分配 + 重新下发频率 ----------
if [ "$ACTION" = "repair" ]; then
    out=$(gen_threads 2>&1)
    log "🔧 修复：线程重建 $out"
    current_mode_read 2>/dev/null
    sh "$MODDIR/Scripts/4+4+2/O3/apply_freq.sh" --mode "${CUR_MODE:-balance}" >/dev/null 2>&1
    [ -z "$QUIET" ] && echo "✅ 线程已重建 · 频率已按[${CUR_MODE:-balance}]下发"
    exit 0
fi

# ---------- 恢复 stock（频率放开；线程仍按模块规则）----------
if [ "$ACTION" = "restore" ]; then
    rm -f "$ACTIVE_FILE" "$ACTIVE_MODE_FILE"
    restore_stock_freq
    log "↩️ 已恢复 stock 频率策略（模块频率接管关闭）"
    [ -z "$QUIET" ] && echo "✅ 已恢复 stock 频率策略"
    exit 0
fi

SCHEME="$ACTION"
[ -z "$SCHEME" ] && SCHEME=$(active_scheme)
[ -z "$SCHEME" ] && SCHEME="sweet_bal"

SRC="${MODDIR}/Config/4+4+2/O3/${SCHEME}"
if [ ! -d "$SRC" ]; then
    log "❌ 方案不存在: $SCHEME"
    exit 1
fi

log "▶ 应用方案: $SCHEME（$(scheme_name_cn "$SCHEME")）"

# 1) 记录当前方案
echo "$SCHEME" > "$ACTIVE_FILE"

# 2) 方案 → 默认全局模式（也写 active_mode，让频率跟随方案）
case "$SCHEME" in
  sweet_eco)  set_global_mode powersave   ;;
  sweet_bal)  set_global_mode balance     ;;
  sweet_hq)   set_global_mode performance ;;
  sweet_perf) set_global_mode fast        ;;
  *)          set_global_mode balance     ;;
esac

# 3) 平台调优脚本（sysfs 节点，与方案包内 powercfg.sh 同源）
PC="${SRC}/powercfg.sh"
if [ -f "$PC" ]; then
    sh "$PC" >> "$LOG_FILE" 2>&1
    log "  · powercfg.sh 已执行（方案 $SCHEME）"
fi

# 4) 按模块模板/分配重建线程（写到 Aether 配置）
out=$(gen_threads 2>&1)
log "  · $out"

log "✅ 方案 ${SCHEME} 已生效"
[ -z "$QUIET" ] && echo "✅ 已切换到【$(scheme_name_cn "$SCHEME")】· 频率[$(current_mode_read 2>/dev/null; echo ${CUR_MODE:-balance})]"
