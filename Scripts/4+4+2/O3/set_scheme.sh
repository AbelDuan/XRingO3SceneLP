#!/system/bin/sh
# ============================================================
#  切换 / 落地方案   (v2 · 实测校正版)
#  用法: set_scheme.sh <sweet_eco|sweet_bal|sweet_perf> [quiet]
#  可选: set_scheme.sh lock | unlock | restore
# ============================================================
MODDIR="${MODDIR:-/data/adb/modules/SceneO3Tuner}"
. "$MODDIR/lib/util.sh"

ACTION="$1"
QUIET="$2"

# ---------- 前置：Scene 数据目录必须可进入 ----------
# 目录缺 owner 执行位会导致 Scene 无法访问自己的配置，直接卡在启动 splash。
# 任何动作（含 lock/unlock）前都先自愈一次。
ensure_scene_dir_perm

# ---------- 锁定 / 解锁：已废除（2026-09-15）----------
# ⚠ chattr +i 会让 **Scene 自己存不下配置** —— 用户在 Scene 里点小齿轮改特性、
#   切全局/单应用模式时，写 features/*.conf 与 profile.json 会 ENOTSUP 失败，
#   现象就是「改了没反应」。本机型云端并无对应配置，没有防替换的必要，
#   所以彻底不再加锁。
#   保留 lock / unlock 这两个词是为了兼容旧入口（音量键菜单、switch.sh），
#   它们现在都等价于「修复可写性」。
if [ "$ACTION" = "lock" ] || [ "$ACTION" = "unlock" ]; then
    r=$(repair_scene_writable)
    unlock_scene_all >/dev/null 2>&1
    log "✅ 锁定机制已废除 → 已改为「确保配置可写」($r)；Scene 内可自由调整"
    [ -z "$QUIET" ] && echo "✅ 配置已解锁且可写（Scene 内可自由调整）"
    exit 0
fi
if [ "$ACTION" = "repair" ]; then
    r=$(repair_scene_writable)
    unlock_scene_all >/dev/null 2>&1
    out=$(gen_threads_from_scene 2>&1)
    log "🔧 修复：可写性 $r；$out"
    [ -z "$QUIET" ] && echo "✅ $r · $out"
    exit 0
fi
if [ "$ACTION" = "restore" ]; then
    unlock_scene_all
    rm -f "$ACTIVE_FILE"
    restore_stock_freq
    log "↩️ 已恢复 stock 频率策略"
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

# 1) 落地 Scene 配置
cnt=$(sync_scheme "$SRC")
log "  · 已写入 ${cnt} 个配置文件"

# 2) 记录当前方案
echo "$SCHEME" > "$ACTIVE_FILE"

# 3) CPU 调频：**已彻底交回 Scene 接管**（2026-09-16）。
#    模块不再写任何频率节点；频率一律由 Scene 自己的模式 preset
#    （profile.json 里 <mode>_active/inactive 的 @cpu_freq）下发。
#    这里只做一次幂等清理：把 v2 时代写过的 cpuN/qos/{min,max}_freq 残留值
#    清成「不限频」，让 Scene 从干净的白纸接管（值已正确就零写入）。

# 4) 不再加锁（锁定机制已废除）。
#    落地方案本身仍会覆盖 Scene 侧配置 —— 这是一个**显式修复动作**，
#    只在用户主动点「重新落地配置」时才会执行（见 WebUI 的相应按钮）。
#    日常运行中守护不会回滚、开机也不会覆盖，所以 Scene 侧才是真源。

# 4.5) 清理 v2 遗留的 QoS 上下限 —— 让 Scene 从「不限频」状态接管
sh "$MODDIR/Scripts/4+4+2/O3/apply_freq.sh" >/dev/null 2>&1

# 5) 让 Scene daemon 重读配置
if pgrep -f scene-daemon >/dev/null 2>&1; then
    pkill -f scene-daemon 2>/dev/null
    log "  · scene-daemon 已重启（将重读新配置）"
fi

# 6) 按 Scene 的「应用→模式」表重建线程分配，让改动立刻可见
out=$(gen_threads_from_scene 2>&1)
echo "$(md5of "$SCENE_POWERCFG")/$(md5of "$SCENE_GAMES_XML")" > "${STATE_DIR}/scene.hash"
log "  · $out"

log "✅ 方案 ${SCHEME} 已生效"
[ -z "$QUIET" ] && echo "✅ 已切换到【$(scheme_name_cn "$SCHEME")】"
