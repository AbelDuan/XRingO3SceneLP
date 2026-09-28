#!/system/bin/sh
# ============================================================================
#  SceneO3LP · 配置推送（v17.1 profile_sync.sh 的极简内联版）
#  用法: push.sh [install|boot|manual]   参数只影响日志标记
#
#  做四件事（与 v17.1 「传递调度」一致，缺一不可）：
#   ① 灌文件    Config/ 下 6 个文件 → Scene files/（inode 替换 + 属主/SELinux 修正）
#   ② 启配置    global.xml: scene_profile_source=SOURCE_SCENE_ONLINE
#                           dynamic_control=true
#   ③ 重启调度  kill scene-daemon（Scene 4~8 秒自动拉起并重读配置）
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

FILES="profile.json manifest.json powercfg.sh _apps.json _games.json _camera.json _whitelist.json description.txt"

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

# ---------- ④ 校验 ----------
do_verify() {
    local bad=""
    for f in profile.json manifest.json powercfg.sh; do
        [ -f "${SRC}/${f}" ] || continue
        [ "$(md5of "${SRC}/${f}")" = "$(md5of "${SCENE_DIR}/${f}")" ] || bad="$bad $f"
    done
    local src dyn
    src=$(sed -n 's/.*name="scene_profile_source">\([^<]*\)<.*/\1/p' "$SCENE_GLOBAL_XML" | head -1)
    dyn=$(sed -n 's/.*name="dynamic_control" value="\([^"]*\)".*/\1/p' "$SCENE_GLOBAL_XML" | head -1)
    [ "$src" = "SOURCE_SCENE_ONLINE" ] || bad="$bad source($src)"
    [ "$dyn" = "true" ] || bad="$bad dyn($dyn)"
    if [ -n "$bad" ]; then
        log "VERIFY FAIL:$bad"; echo "❌ 校验失败:$bad"; return 1
    fi
    log "verify OK"
    echo "✅ 校验通过：profile/manifest 与源一致，SOURCE_SCENE_ONLINE + dynamic_control=true"
    return 0
}

# ============================ 主流程 ============================
do_sync || exit 1
pref_set scene_profile_source SOURCE_SCENE_ONLINE string
pref_set dynamic_control true boolean
restart_daemon
sleep 3
do_verify
exit $?
