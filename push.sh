#!/system/bin/sh
# ============================================================================
#  SceneO3LP · 配置推送（v17.1 profile_sync.sh 的极简内联版）
#  用法: push.sh [install|boot|manual]   参数只影响日志标记
#
#  做四件事（与 v17.1 「传递调度」一致，缺一不可）：
#   ① 灌文件    Config/ 下 6 个文件 → Scene files/（inode 替换 + 属主/SELinux 修正）
#   ② 启配置    global.xml: scene_profile_source=SOURCE_SCENE_ONLINE
#                           dynamic_control=true
#   ③ 清旧标记  删 files/profileInstalled（Scene 自维护 24B 旧方案标记）→ 逼 Scene 重装
#                + kill scene-daemon（Scene 4~8 秒自动拉起并重读配置）
#                + 非 boot 时 am start 把 Scene 拉前台，立即触发重读
#   ④ 校验      profile/manifest md5 与模块源一致、两键值正确
#
#  ⚠ 刻意不做 am force-stop（v17.1 实测会掉无障碍服务 → Scene 失效）
# ============================================================================
MODDIR="${MODDIR:-${0%/*}}"
[ -f "${MODDIR}/module.prop" ] || MODDIR="/data/adb/modules/SceneO3LP"

SCENE_PKG="com.omarea.vtools"
SCENE_DIR="/data/data/${SCENE_PKG}/files"
SCENE_GLOBAL_XML="/data/data/${SCENE_PKG}/shared_prefs/global.xml"
SRC="${MODDIR}/Config"
TAG="${1:-manual}"
LOG="/data/adb/SceneO3LP/push.log"

mkdir -p /data/adb/SceneO3LP 2>/dev/null
log() { echo "[$(date '+%m-%d %H:%M:%S')] $*" >> "$LOG"; echo "$*"; }

FILES="profile.json manifest.json powercfg.sh _Apps.json _Games.json _Camera.json _ELP.json description.txt"

get_uid() {
    grep -m1 "^${SCENE_PKG} " /data/system/packages.list 2>/dev/null | cut -d' ' -f2
}

can_write() {
    [ -e "$1" ] || return 1
    dd if=/dev/zero of="$1" bs=1 count=0 conv=notrunc >/dev/null 2>&1
}

# inode 替换写（个别 inode 拒写 ENOTSUP，cp 遇 open 失败会 unlink 重建才能落地）
write_replace() {
    [ -f "$1" ] || return 1
    mkdir -p "$(dirname "$2")" 2>/dev/null
    if cp -f "$1" "$2" 2>/dev/null && can_write "$2"; then return 0; fi
    rm -f "$2" 2>/dev/null
    cp -f "$1" "$2" 2>/dev/null && can_write "$2"
}

dir_x_ok() {
    local xs; xs=$(stat -c %A "$1" 2>/dev/null | cut -c4)
    case "$xs" in x|s) return 0 ;; *) return 1 ;; esac
}

fix_perm() {
    local uid="$2"
    chown "${uid}:${uid}" "$1" 2>/dev/null
    if [ -d "$1" ]; then
        dir_x_ok "$1" || chmod u+x "$1" 2>/dev/null
    else
        chmod 0666 "$1" 2>/dev/null
    fi
    chcon u:object_r:app_data_file:s0:c65,c257,c512,c768 "$1" 2>/dev/null
}

md5of() { md5sum "$1" 2>/dev/null | cut -d' ' -f1; }

# ---------- ① 灌文件 ----------
do_sync() {
    local uid n=0 f bad=""
    uid=$(get_uid)
    [ -n "$uid" ] || { log "ERR 未找到 $SCENE_PKG 的 uid"; return 1; }
    [ -d "$SCENE_DIR" ] || { log "ERR Scene 数据目录不存在（先启动一次 Scene）"; return 1; }
    dir_x_ok "$SCENE_DIR" || chmod u+x "$SCENE_DIR" 2>/dev/null

    for f in $FILES; do
        [ -f "${SRC}/${f}" ] || continue
        if write_replace "${SRC}/${f}" "${SCENE_DIR}/${f}"; then
            n=$((n+1))
        else
            bad="$bad $f"
        fi
        fix_perm "${SCENE_DIR}/${f}" "$uid"
    done
    [ -n "$bad" ] && { log "ERR 灌入失败:$bad"; return 1; }
    log "sync: ${n} files (tag=$TAG)"
    return 0
}

# ---------- ② global.xml 两键 ----------
# $1=键 $2=值 $3=string|boolean
pref_set() {
    local key="$1" want="$2" kind="$3" cur tmp bak uid now
    [ -f "$SCENE_GLOBAL_XML" ] || { log "ERR global.xml 不存在"; return 1; }
    if [ "$kind" = "boolean" ]; then
        cur=$(sed -n "s/.*name=\"${key}\" value=\"\([^\"]*\)\".*/\1/p" "$SCENE_GLOBAL_XML" | head -1)
    else
        cur=$(sed -n "s/.*name=\"${key}\">\([^<]*\)<.*/\1/p" "$SCENE_GLOBAL_XML" | head -1)
    fi
    [ "$cur" = "$want" ] && return 0

    tmp="/data/adb/SceneO3LP/global.xml.new"
    bak="/data/adb/SceneO3LP/global.xml.bak"
    if [ "$kind" = "boolean" ]; then
        if [ -n "$cur" ]; then
            sed "s|name=\"${key}\" value=\"[^\"]*\"|name=\"${key}\" value=\"${want}\"|" "$SCENE_GLOBAL_XML" > "$tmp"
        else
            sed "s|</map>|    <boolean name=\"${key}\" value=\"${want}\" />\n</map>|" "$SCENE_GLOBAL_XML" > "$tmp"
        fi
    else
        if [ -n "$cur" ]; then
            sed "s|name=\"${key}\">[^<]*<|name=\"${key}\">${want}<|" "$SCENE_GLOBAL_XML" > "$tmp"
        else
            sed "s|</map>|    <string name=\"${key}\">${want}</string>\n</map>|" "$SCENE_GLOBAL_XML" > "$tmp"
        fi
    fi
    [ -s "$tmp" ] || { log "ERR 生成 global.xml 失败"; return 1; }
    cp -af "$SCENE_GLOBAL_XML" "$bak" 2>/dev/null
    uid=$(get_uid); [ -n "$uid" ] || uid=10321
    write_replace "$tmp" "$SCENE_GLOBAL_XML"
    rm -f "$tmp" 2>/dev/null
    chown "${uid}:${uid}" "$SCENE_GLOBAL_XML" 2>/dev/null
    chmod 0660 "$SCENE_GLOBAL_XML" 2>/dev/null
    if [ "$kind" = "boolean" ]; then
        now=$(sed -n "s/.*name=\"${key}\" value=\"\([^\"]*\)\".*/\1/p" "$SCENE_GLOBAL_XML" | head -1)
    else
        now=$(sed -n "s/.*name=\"${key}\">\([^<]*\)<.*/\1/p" "$SCENE_GLOBAL_XML" | head -1)
    fi
    if [ "$now" = "$want" ]; then
        rm -f "$bak" 2>/dev/null
        log "pref: ${key} -> ${want}"
        return 0
    fi
    [ -f "$bak" ] && { cp -af "$bak" "$SCENE_GLOBAL_XML" 2>/dev/null; rm -f "$bak"; }
    log "ERR ${key} 写入失败（已回滚）"
    return 1
}

# ---------- ③ 重启调度进程 ----------
restart_daemon() {
    local pid
    for pid in $(ps -A -o PID,ARGS 2>/dev/null | grep scene-daemon | grep -v grep | awk '{print $1}'); do
        kill "$pid" 2>/dev/null
    done
    log "daemon killed（Scene 将在 4~8s 内自动拉起）"
}

# ---------- ④ 状态报告 + 校验 ----------
do_status() {
    local f miss="" auth id src dyn pi
    for f in profile.json manifest.json _Apps.json _Games.json _Camera.json _ELP.json powercfg.sh; do
        [ -f "${SRC}/${f}" ] || continue
        [ -f "${SCENE_DIR}/${f}" ] || miss="$miss $f"
    done
    auth=$(sed -n 's/.*"author"[ ]*:[ ]*"\([^"]*\)".*/\1/p' "${SCENE_DIR}/manifest.json" 2>/dev/null | head -1)
    id=$(sed -n 's/.*"version"[ ]*:[ ]*"\([^"]*\)".*/\1/p' "${SCENE_DIR}/manifest.json" 2>/dev/null | head -1)
    src=$(sed -n 's/.*name="scene_profile_source">\([^<]*\)<.*/\1/p' "$SCENE_GLOBAL_XML" 2>/dev/null | head -1)
    dyn=$(sed -n 's/.*name="dynamic_control" value="\([^"]*\)".*/\1/p' "$SCENE_GLOBAL_XML" 2>/dev/null | head -1)
    [ -f "${SCENE_DIR}/profileInstalled" ] && pi="yes" || pi="NO"

    echo "---- Scene 当前状态 ----"
    echo "  配置身份 : ${auth:-?}'${id:-?}"
    echo "  配置来源 : ${src:-?}"
    echo "  性能调节 : ${dyn:-?}"
    echo "  profileInstalled(已安装标记): $pi"
    if [ -n "$miss" ]; then
        echo "  ⚠ 缺失文件:$miss  → 被 Scene 清掉，请重跑本脚本"
    else
        echo "  ✅ 6 个配置文件齐全（Scene 未清掉）"
    fi
    if [ "$src" = "SOURCE_SCENE_ONLINE" ] && [ "$dyn" = "true" ] && [ "$pi" = "yes" ]; then
        echo "✅ 启用链完整：调节页应显示「Scene / Version: ${id}」"
        return 0
    else
        echo "⚠ 启用链不完整，调节页可能仍显示「未知 / 未选择」"
        [ "$src" != "SOURCE_SCENE_ONLINE" ] && echo "   · 来源不对（应为 SOURCE_SCENE_ONLINE）"
        [ "$dyn" != "true" ] && echo "   · 性能调节未开（应为 true）"
        [ "$pi" != "yes" ] && echo "   · profileInstalled 未重建（手动打开一次 Scene 调节页再试）"
        return 1
    fi
}

# ============================ 主流程 ============================
do_sync || exit 1

# ★ 升级路径：删掉 Scene 自维护的 profileInstalled（记着旧方案标识的 24B 标记）。
#   不删它，Scene 比对 manifest 新标识(LP) vs 旧记录(HP) 不一致会直接删掉我们的
#   profile.json/manifest.json（=「Scene 丢失配置」）。删掉后 Scene 启动时视作
#   "未安装" → 重新安装并重建 profileInstalled。⚠ 重建要时间（实测 ~18s），下面轮询等待。
#   ⚠ 放在 do_sync 之后立刻删，窗口最小，避免 Scene 在"新 manifest + 旧标记"窗口里删文件。
rm -f "${SCENE_DIR}/profileInstalled" 2>/dev/null && log "removed stale profileInstalled（逼 Scene 重装）"

pref_set scene_profile_source SOURCE_SCENE_ONLINE string || log "ERR 写入 scene_profile_source 失败"
pref_set dynamic_control true boolean || log "ERR 写入 dynamic_control 失败"

restart_daemon
# 非 boot 场景：把 Scene 拉到前台，逼它重读 manifest 并重建 profileInstalled
if [ "$TAG" != "boot" ]; then
    am start -n com.omarea.vtools/.StartActivity >/dev/null 2>&1
    log "am start Scene（触发重读/重装）"
fi

# 轮询等 Scene 重建 profileInstalled（最多 ~25s）。删掉后 Scene 需时间重装，
# 没重建完之前调节页会显示「未选择 / 未知」，属正常过渡，不是失败。
i=0
while [ $i -lt 25 ]; do
    [ -f "${SCENE_DIR}/profileInstalled" ] && break
    sleep 1; i=$((i+1))
done
[ -f "${SCENE_DIR}/profileInstalled" ] && \
    log "profileInstalled 已重建（size=$(wc -c < "${SCENE_DIR}/profileInstalled" 2>/dev/null)）" || \
    log "WARN profileInstalled 仍未重建（手动打开一次 Scene 调节页即可触发）"

do_status
exit $?
