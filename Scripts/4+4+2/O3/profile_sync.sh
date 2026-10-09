#!/system/bin/sh
# ============================================================
#  调度配置：备份 / 恢复 / 列出   （v18 · 模块自有，不再触碰 Scene）
# ------------------------------------------------------------
#  v18 起：频率 / 调度器 / 线程全部由本模块定义，不再与 Scene 做任何交互。
#  本脚本只负责备份 / 恢复「模块自己的配置」：
#    · 模块 WebUI 配置：app_assign.tsv / app_templates.tsv /
#                       game_assign.tsv / game_templates.tsv / settings.conf
#    · 模块状态：active_mode（当前全局模式）、active_scheme（当前方案）
#    · 当前方案的平台调优脚本 powercfg.sh
#  用法:
#    profile_sync.sh backup            备份上述配置
#    profile_sync.sh restore [名称]    恢复某个备份（默认最新）
#    profile_sync.sh list              列出可用备份
# ============================================================

MODDIR="${MODDIR:-/data/adb/modules/SceneO3Tuner}"
. "$MODDIR/lib/util.sh"

BACKUP_ROOT="${STATE_DIR}/backups"
CFG_ROOT="${MODDIR}/Config/4+4+2/O3"

# 备份保留份数：只留最近 3 个
KEEP_BACKUPS="${KEEP_BACKUPS:-3}"

# 模块自己的可备份配置
MOD_WEBUI="app_assign.tsv app_templates.tsv game_assign.tsv game_templates.tsv settings.conf"
MOD_STATE="active_mode"

ts() { date '+%Y%m%d_%H%M%S'; }

# ============================================================
#  备份剪枝：只保留最近 KEEP_BACKUPS 个
# ============================================================
prune_backups() {
    local keep="${1:-$KEEP_BACKUPS}" all total drop d
    [ -d "$BACKUP_ROOT" ] || return 0
    [ "$keep" -gt 0 ] 2>/dev/null || return 0
    all=$(ls -1 "$BACKUP_ROOT" 2>/dev/null | grep -E '^[0-9]{8}_[0-9]{6}$' | sort)
    [ -n "$all" ] || return 0
    total=$(printf '%s\n' "$all" | grep -c .)
    [ "$total" -le "$keep" ] && return 0
    drop=$((total - keep))
    printf '%s\n' "$all" | head -n "$drop" | while IFS= read -r d; do
        [ -n "$d" ] || continue
        rm -rf "${BACKUP_ROOT:?}/${d}" 2>/dev/null && log_quiet "profile: pruned backup ${d}"
    done
    printf '%s\n' "$all" | head -n "$drop" | tr '\n' ' '
    return 0
}

# ============================================================
#  备份
# ============================================================
do_backup() {
    local name; name=$(ts)
    local dir="${BACKUP_ROOT}/${name}"
    mkdir -p "${dir}/module-webui" "${dir}/module-state" 2>/dev/null

    local n=0 f
    # ---- 模块 WebUI 模板与分配表 ----
    for f in $MOD_WEBUI; do
        [ -f "${WEBUI_DIR}/${f}" ] || continue
        cp -f "${WEBUI_DIR}/${f}" "${dir}/module-webui/${f}" 2>/dev/null && n=$((n+1))
    done
    # ---- 模块状态：当前全局模式 ----
    [ -f "$ACTIVE_MODE_FILE" ] && cp -f "$ACTIVE_MODE_FILE" "${dir}/module-state/active_mode" 2>/dev/null && n=$((n+1))
    # ---- 当前方案的 powercfg.sh ----
    local scheme; scheme=$(active_scheme); [ -z "$scheme" ] && scheme="sweet_bal"
    if [ -f "${CFG_ROOT}/${scheme}/powercfg.sh" ]; then
        mkdir -p "${dir}/scheme" 2>/dev/null
        cp -f "${CFG_ROOT}/${scheme}/powercfg.sh" "${dir}/scheme/powercfg.sh" 2>/dev/null && n=$((n+1))
    fi

    {
        echo "backup_name=${name}"
        echo "created=$(date '+%Y-%m-%d %H:%M:%S')"
        echo "module_version=$(sed -n 's/^version=//p' "${MODDIR}/module.prop" 2>/dev/null | head -1)"
        echo "scheme=${scheme}"
        echo "files=${n}"
    } > "${dir}/MANIFEST.txt" 2>/dev/null

    if [ "$n" -eq 0 ]; then
        rm -rf "$dir" 2>/dev/null
        echo "ERR 没有可备份的配置文件（WebUI 尚未生成？）"
        return 1
    fi

    local pruned; pruned=$(prune_backups)
    pruned="${pruned% }"

    echo "OK 已备份 ${n} 个文件 → ${name}"
    echo "BACKUP=${name}"
    if [ -n "$pruned" ]; then
        echo "PRUNED=${pruned}"
        echo "   （备份最多保留 ${KEEP_BACKUPS} 个，已删除最早的：${pruned}）"
    fi
    log_quiet "profile: backup ${name} (${n} files)${pruned:+ pruned=[${pruned}]}"
    return 0
}

# ============================================================
#  恢复
# ============================================================
do_restore() {
    local name="$1"
    if [ -z "$name" ]; then
        name=$(ls -1 "$BACKUP_ROOT" 2>/dev/null | grep -E '^[0-9]{8}_[0-9]{6}$' | tail -1)
        [ -z "$name" ] && { echo "ERR 没有可用备份"; return 1; }
    fi
    local dir="${BACKUP_ROOT}/${name}"
    [ -d "$dir" ] || { echo "ERR 备份不存在: $name"; return 1; }

    local n=0 f

    # ---- 模块模板与分配表 ----
    for f in "${dir}"/module-webui/*; do
        [ -f "$f" ] || continue
        cp -f "$f" "${WEBUI_DIR}/${f##*/}" 2>/dev/null && n=$((n+1))
        chmod 0666 "${WEBUI_DIR}/${f##*/}" 2>/dev/null
    done
    # ---- 模块状态 ----
    [ -f "${dir}/module-state/active_mode" ] && cp -f "${dir}/module-state/active_mode" "$ACTIVE_MODE_FILE" 2>/dev/null && n=$((n+1))

    # 恢复后立刻把频率按模式重新下发
    current_mode_read 2>/dev/null
    sh "$MODDIR/Scripts/4+4+2/O3/apply_freq.sh" --mode "${CUR_MODE:-balance}" >/dev/null 2>&1
    # 重建线程
    gen_threads >/dev/null 2>&1

    echo "OK 已从 ${name} 恢复 ${n} 个文件｜频率已按[${CUR_MODE:-balance}]重新下发、线程已重建"
    log_quiet "profile: restore ${name} (${n} files)"
    return 0
}

# ============================================================
#  列出备份
# ============================================================
do_list() {
    local d n
    for d in $(ls -1 "$BACKUP_ROOT" 2>/dev/null | grep -E '^[0-9]{8}_[0-9]{6}$'); do
        n=$(sed -n 's/^files=//p' "${BACKUP_ROOT}/${d}/MANIFEST.txt" 2>/dev/null | head -1)
        echo "BK=${d}|${n:-?}"
    done
    return 0
}

# ============================================================
case "$1" in
  push)    echo "ERR v18 起已不再与 Scene 交互（频率/线程由本模块自有）。请用 backup/restore 管理模块配置。" ; exit 1 ;;
  backup)  do_backup ;;
  restore) shift; do_restore "$1" ;;
  list)    do_list ;;
  *)
    echo "用法: profile_sync.sh backup|restore|list"
    exit 1
    ;;
esac
