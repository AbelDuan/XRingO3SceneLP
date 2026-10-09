#!/system/bin/sh
# ============================================================
#  webui.sh —— WebUI 后端（两模块版：频率 / 线程）
# ------------------------------------------------------------
#  设计原则：前端只传简单参数，所有路径 / 权限 / 备份 / 自检都在本脚本里。
#  文件写入走 base64 分块（wbegin → wappend ×N → wcommit）。
#
#  子命令
#   —— 频率（交给 Scene）——
#    status           状态（K=V）
#    read <id>        读文件到 stdout（id: profile/model/...）
#    wbegin/wappend/wcommit <id>  分块写（profile 等）
#    b64len/b64 <id>  分片读（大文件）
#    conf <name>      读 features/<name>.conf
#    scheme <name> | restore   切换 / 恢复频率方案
#    schemes          列出可选频率方案
#    mode | modeset   读模式阶梯 / 切换全局模式
#    profilepush/backup/restore/list  调度配置 传递/备份/恢复/列出
#    freqs            三簇可用频率档位
#    appmodes/setappmode  应用→模式（Scene 频率档位）
#    fasxres          统一 FAS 调速器为 xres
#    ksufix/live/apply/log/daemonlog/launchables/apps  维护类
#   —— 线程（艇长 Aether）——
#    aether           艇长引擎状态 + 特性 + 规则
#    aetherswitch on|off   免重启开关
#    aetherfeat <k> [v]    读写特性（ebpf/auto-for-none/foreground/load_aware/render_guard/min_cpus）
#    aetherrules      艇长规则列表
#    aetherraw        读艇长配置（base64）
#    aetherrawset <b64>  写艇长配置（JSON 校验 + 重载）
# ============================================================
MODDIR="${MODDIR:-/data/adb/modules/SceneO3Tuner}"
. "$MODDIR/lib/util.sh"

STATE_DIR="/data/adb/SceneO3Tuner"
WEB_DIR="${STATE_DIR}/webui"
BKDIR="${STATE_DIR}/backups"
TMPD="/data/local/tmp/_wui"
SCHEME=$(active_scheme); [ -z "$SCHEME" ] && SCHEME="sweet_bal"
MODCFG="${MODDIR}/Config/4+4+2/O3/${SCHEME}"
AETHER_CTL="$MODDIR/Scripts/4+4+2/O3/aether/aether_ctl.sh"
AETHER_CFG="/sdcard/Android/Aether/threads.json"
PY="$(command -v python3 2>/dev/null || command -v python 2>/dev/null)"

mkdir -p "$WEB_DIR" "$BKDIR" "$TMPD" 2>/dev/null

# 访问即自愈：合并 KSU 待更新副本（免重启）
selfheal_pending_update

has(){ command -v "$1" >/dev/null 2>&1; }

# ---------- 文件 ID → 真实路径（白名单）----------
path_of() {
    case "$1" in
      profile)  echo "${SCENE_DIR}/profile.json" ;;
      model)    echo "${WEB_DIR}/model.json" ;;
      activemode) echo "${STATE_DIR}/active_mode" ;;
      settings) echo "${WEB_DIR}/settings.conf" ;;
      conf:cpuset) echo "${SCENE_DIR}/features/cpuset.conf" ;;
      *) echo "" ;;
    esac
}
modpath_of() {
    case "$1" in
      profile) echo "${MODCFG}/profile.json" ;;
      conf:*)  echo "${MODCFG}/features/${1#conf:}.conf" ;;
      *) echo "" ;;
    esac
}

# ---------- 分块写 ----------
cmd_wbegin() { : > "${TMPD}/$1.b64"; : > "${TMPD}/$1.raw"; }
cmd_wappend() { [ -f "${TMPD}/$1.b64" ] || return 1; printf '%s' "$2" >> "${TMPD}/$1.b64"; return 0; }
cmd_wcommit() {
    local id="$1" b64="${TMPD}/$1.b64" raw="${TMPD}/$1.raw" dst mod
    dst=$(path_of "$id"); [ -z "$dst" ] && { echo "ERR 未知文件 id: $id"; return 1; }
    if has base64; then base64 -d "$b64" > "$raw" 2>/dev/null
    elif [ -x "$BB" ]; then "$BB" base64 -d "$b64" > "$raw" 2>/dev/null
    else echo "ERR 缺少 base64 工具"; return 1; fi
    [ -s "$raw" ] || { echo "ERR base64 解码为空"; return 1; }
    case "$id" in
      model|activemode|settings) ;;
      *) unlock_tree "$SCENE_DIR" ;;
    esac
    write_replace "$raw" "$dst" || { echo "ERR 覆盖失败: $dst"; return 1; }
    case "$id" in
      model|activemode|settings) chmod 0666 "$dst"; chown 0:0 "$dst" 2>/dev/null ;;
      *) perm_file "$dst"; ensure_scene_dir_perm >/dev/null 2>&1 ;;
    esac
    mod=$(modpath_of "$id")
    if [ -n "$mod" ] && [ -d "$(dirname "$mod")" ]; then
        cp -f "$raw" "$mod" 2>/dev/null; chmod 0644 "$mod" 2>/dev/null; chown 0:0 "$mod" 2>/dev/null
        log_quiet "webui: ${id} → scene + module 已同步"
    fi
    echo "OK $(wc -c < "$raw" | tr -d ' ')"
}

cmd_read() { local p; p=$(path_of "$1"); [ -z "$p" ] && { echo ""; return 1; }; [ -f "$p" ] && cat "$p" || echo ""; }
B64BIN="base64"; { [ -x /system/bin/base64 ] && B64BIN=/system/bin/base64; } 2>/dev/null
if ! command -v "$B64BIN" >/dev/null 2>&1; then [ -x "$BB" ] && B64BIN="$BB base64"; fi
cmd_b64len() { local p; p=$(path_of "$1"); [ -f "$p" ] || { echo 0; return; }; $B64BIN "$p" 2>/dev/null | tr -d '\n' | wc -c | tr -d ' '; }
cmd_b64() { local p; p=$(path_of "$1"); [ -f "$p" ] || return 0; local s="${2:-1}" n="${3:-40000}"; $B64BIN "$p" 2>/dev/null | tr -d '\n' | cut -c "${s}-$(( s + n - 1 ))"; }
cmd_conf() { local p="${SCENE_DIR}/features/$1.conf"; [ -f "$p" ] && cat "$p" || echo ""; }

# ============================================================
#  状态
# ============================================================
qmax(){ cat "/sys/devices/system/cpu/cpu$1/qos/max_freq" 2>/dev/null; }
qmin(){ cat "/sys/devices/system/cpu/cpu$1/qos/min_freq" 2>/dev/null; }
scmax(){ cat "/sys/devices/system/cpu/cpu$1/cpufreq/scaling_max_freq" 2>/dev/null; }
scmin(){ cat "/sys/devices/system/cpu/cpu$1/cpufreq/scaling_min_freq" 2>/dev/null; }
scur(){ cat "/sys/devices/system/cpu/cpu$1/cpufreq/scaling_cur_freq" 2>/dev/null; }
hwmax(){ cat "/sys/devices/system/cpu/cpu$1/cpufreq/cpuinfo_max_freq" 2>/dev/null; }
tempof(){ cat "/sys/class/thermal/thermal_zone$1/temp" 2>/dev/null; }

cmd_status() {
    echo "VER=$(grep -m1 '^version=' "$MODDIR/module.prop" 2>/dev/null | cut -d= -f2-)"
    echo "MODNAME=$(grep -m1 '^name=' "$MODDIR/module.prop" 2>/dev/null | cut -d= -f2-)"
    echo "SCHEME=${SCHEME}"
    settings_load
    echo "DEBUG=${SET_DEBUG:-1}"
    pgrep -f scene-daemon >/dev/null 2>&1 && echo "DAEMON=1" || echo "DAEMON=0"
    local acc=0
    case "$(settings get secure enabled_accessibility_services 2>/dev/null)" in
      *omarea.vtools*) acc=1 ;;
    esac
    echo "ACC=${acc}"
    # Scene 配置完整性
    local miss="" f
    for f in profile.json manifest.json _Apps.json _Games.json _Camera.json _ELP.json powercfg.sh; do
        [ -f "${SCENE_DIR}/${f}" ] || miss="$miss $f"
    done
    if [ -n "$miss" ]; then echo "PROFILE_OK=0"; echo "PROFILE_MISS=${miss# }"; else echo "PROFILE_OK=1"; fi
    echo "SCENE_AUTHOR=$(sed -n 's/.*\"author\"[ ]*:[ ]*\"\([^\"]*\)\".*/\1/p' "${SCENE_DIR}/manifest.json" 2>/dev/null | head -1)"
    echo "SCENE_ID=$(sed -n 's/.*\"version\"[ ]*:[ ]*\"\([^\"]*\)\".*/\1/p' "${SCENE_DIR}/manifest.json" 2>/dev/null | head -1)"
    echo "SCENE_SOURCE=$(scene_source_get)"
    echo "SCENE_DYN=$(scene_dyn_get)"
    # 三簇频率
    local c l
    for pair in "L 0" "M 4" "P 8"; do
        set -- $pair; l=$1; c=$2
        echo "SCMAX_${l}=$(scmax $c)"; echo "SCUR_${l}=$(scur $c)"; echo "QMAX_${l}=$(qmax $c)"; echo "HWMAX_${l}=$(hwmax $c)"
    done
    local pinned=0
    for c in 0 4 8; do local a b; a=$(scmax $c); b=$(scmin $c); [ -n "$a" ] && [ "$a" = "$b" ] && pinned=$((pinned+1)); done
    echo "FREQ_PINNED=${pinned}"
    echo "TEMP_CPU0=$(tempof 9)"; echo "TEMP_CPU8=$(tempof 1)"
    # 当前模式
    local cm; cm=$(active_mode); echo "MODE=${cm}"; echo "MODE_CN=$(mode_name_cn "$cm")"; echo "MODE_LIST=${MODE_LIST}"
    local m cn af inf
    for m in $MODE_LIST; do
        cn=$(mode_name_cn "$m"); af=$(mode_freq "$m" active); inf=$(mode_freq "$m" inactive)
        echo "MODE_${m}=${cn}|${af}|${inf}"
    done
    local pc; pc=$(preset_check); [ -z "$pc" ] && echo "PRESET_OK=1" || { echo "PRESET_OK=0"; echo "PRESET_BAD=${pc}"; }
    echo "KSU_UPDATE_MARK=$([ -e "$MODDIR/update" ] && echo 1 || echo 0)"
    # —— 艇长线程引擎 ——
    echo "AETHER_ON=$(sh "$AETHER_CTL" ison 2>/dev/null)"
    if pgrep -f "aether-optext" >/dev/null 2>&1; then echo "AETHER_RUNNING=1"; echo "AETHER_PID=$(pgrep -f 'aether-optext' | tr '\n' ',' | sed 's/,$//')"; else echo "AETHER_RUNNING=0"; echo "AETHER_PID="; fi
    echo "AETHER_RULES=$(grep -c '\"friendly\"' "$AETHER_CFG" 2>/dev/null)"
    echo "AETHER_BIN=$([ -x "$MODDIR/Scripts/4+4+2/O3/aether/aether-optext" ] && echo 1 || echo 0)"
    echo "AETHER_CFG_BYTES=$(wc -c < "$AETHER_CFG" 2>/dev/null | tr -d ' ')"
}

# ============================================================
#  频率方案（预设）
# ============================================================
SCHEME_CN_MAP="sweet_eco=省电 sweet_bal=均衡 sweet_hq=高画质 sweet_perf=性能"
scheme_cn(){ local s="$1"; for kv in $SCHEME_CN_MAP; do [ "${kv%=*}" = "$s" ] && { echo "${kv#*=}"; return; }; done; echo "$s"; }

cmd_schemes() {
    local d="$MODDIR/Config/4+4+2/O3"
    for s in "$d"/*; do
        [ -d "$s" ] || continue
        sn=$(basename "$s")
        cur=""; [ "$sn" = "$SCHEME" ] && cur=" (当前)"
        echo "SCHEME=${sn}|$(scheme_cn "$sn")${cur}"
    done
}

# ============================================================
#  维护 / 动作
# ============================================================
cmd_scheme(){ sh "$MODDIR/Scripts/4+4+2/O3/set_scheme.sh" "$1"; }
cmd_restore(){ sh "$MODDIR/Scripts/4+4+2/O3/set_scheme.sh" restore; }
cmd_apply() {
    local ACC_BASE='net.dinglisch.android.taskerm/net.dinglisch.android.taskerm.MyAccessibilityService:com.wangc.bill/com.google.android.accessibility.selecttospeak.SelectToSpeakService'
    local SCENE_ACC='com.omarea.vtools/com.omarea.vtools.AccessibilitySceneMode'
    log "webui: 重绑 Scene 无障碍服务"
    am force-stop "$SCENE_PKG" 2>/dev/null
    for p in $(pidof scene-daemon 2>/dev/null); do kill -9 "$p" 2>/dev/null; done
    sleep 2
    settings put secure enabled_accessibility_services "$ACC_BASE"
    sleep 2
    am start -n "${SCENE_PKG}/.activities.ActivityMain" >/dev/null 2>&1
    sleep 8
    settings put secure enabled_accessibility_services "${ACC_BASE}:${SCENE_ACC}"
    settings put secure accessibility_enabled 1
    sleep 6
    local ok=0
    pgrep -f scene-daemon >/dev/null 2>&1 && ok=1
    case "$(settings get secure enabled_accessibility_services 2>/dev/null)" in
      *omarea.vtools*) ok=$((ok+1)) ;;
    esac
    if [ "$ok" -ge 2 ]; then echo "OK 已重绑无障碍并重启 daemon"; else echo "WARN 重绑完成但状态不完整，可再执行一次"; fi
}

cmd_mode() {
    local cm; cm=$(active_mode); echo "MODE=${cm}"; echo "MODE_CN=$(mode_name_cn "$cm")"; echo "MODE_LIST=${MODE_LIST}"
    local m cn af inf
    for m in $MODE_LIST; do
        cn=$(mode_name_cn "$m"); af=$(mode_freq "$m" active); inf=$(mode_freq "$m" inactive)
        echo "MODE_${m}=${cn}|${af}|${inf}"
    done
    local pc; pc=$(preset_check); [ -z "$pc" ] && echo "PRESET_OK=1" || { echo "PRESET_OK=0"; echo "PRESET_BAD=${pc}"; }
}
cmd_modeset() {
    local m; m=$(mode_from_cn "$1")
    mode_valid "$m" || { echo "ERR 未知模式: $1（可用: $MODE_LIST / 省电|流畅|性能|极速）"; return 1; }
    mkdir -p "$STATE_DIR"; echo "$m" > "${STATE_DIR}/active_mode"
    log "webui: 全局模式 → $m（$(mode_name_cn "$m")）"
    echo "OK $(mode_name_cn "$m")"
}

cmd_profilepush() { shift; sh "$MODDIR/Scripts/4+4+2/O3/profile_sync.sh" push "$1"; }
cmd_profilebackup() { sh "$MODDIR/Scripts/4+4+2/O3/profile_sync.sh" backup; }
cmd_profilerestore() { shift; sh "$MODDIR/Scripts/4+4+2/O3/profile_sync.sh" restore "$1"; }
cmd_profilelist() { sh "$MODDIR/Scripts/4+4+2/O3/profile_sync.sh" list; }

cmd_freqs() {
    echo "FREQS_L=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_frequencies 2>/dev/null)"
    echo "FREQS_M=$(cat /sys/devices/system/cpu/cpu4/cpufreq/scaling_available_frequencies 2>/dev/null)"
    echo "FREQS_P=$(cat /sys/devices/system/cpu/cpu8/cpufreq/scaling_available_frequencies 2>/dev/null)"
    echo "HWMAX_L=$(hwmax 0)"; echo "HWMAX_M=$(hwmax 4)"; echo "HWMAX_P=$(hwmax 8)"
}

cmd_appmodes() {
    echo "SCENE_DEFAULT=$(scene_default_mode)"
    local pm="${TMPD}/pkgmode.txt"; scene_pkg_modes > "$pm"
    local md n
    for md in $MODE_LIST; do n=$(awk -F'\t' -v m="$md" '$2==m' "$pm" 2>/dev/null | wc -l | tr -d ' '); echo "COUNT_${md}=${n:-0}"; done
    echo "TOTAL=$(wc -l < "$pm" 2>/dev/null | tr -d ' ')"
    awk -F'\t' 'NF==2 { print "A_"$1"="$2 }' "$pm"
    scene_mode_map 2>/dev/null | awk -F'\t' '$1!="*" && $1!="" { print "OWN_"$1"="$2 }'
}
cmd_setappmode() {
    local pkg="$1" mode="$2" uid tmp bak
    [ -z "$pkg" ] || [ -z "$mode" ] && { echo "ERR 用法: setappmode <包名> <powersave|balance|performance|fast>"; return 1; }
    mode_valid "$mode" || { echo "ERR 非法模式: $mode"; return 1; }
    case "$pkg" in *'/'*|*'"'*|*'<'*|*'>'*) echo "ERR 包名含非法字符"; return 1 ;; esac
    [ -f "$SCENE_POWERCFG" ] || { echo "ERR 找不到 powercfg.xml"; return 1; }
    tmp="${TMPD}/pc.xml.new"; bak="${TMPD}/pc.xml.bak"; mkdir -p "$TMPD" 2>/dev/null
    cp -af "$SCENE_POWERCFG" "$bak" 2>/dev/null
    if grep -q "<string name=\"${pkg}\">" "$SCENE_POWERCFG" 2>/dev/null; then
        sed "s|<string name=\"${pkg}\">[^<]*</string>|<string name=\"${pkg}\">${mode}</string>|" "$SCENE_POWERCFG" > "$tmp" 2>/dev/null
    else
        sed "s|</map>|    <string name=\"${pkg}\">${mode}</string>\n</map>|" "$SCENE_POWERCFG" > "$tmp" 2>/dev/null
    fi
    [ -s "$tmp" ] || { rm -f "$tmp"; echo "ERR 生成新 powercfg.xml 失败"; return 1; }
    uid=$(get_package_uid "$SCENE_PKG"); [ -n "$uid" ] || uid=10321
    write_replace "$tmp" "$SCENE_POWERCFG" || { rm -f "$tmp"; echo "ERR 写入 powercfg.xml 失败"; return 1; }
    rm -f "$tmp" 2>/dev/null; chown "${uid}:${uid}" "$SCENE_POWERCFG" 2>/dev/null; chmod 0660 "$SCENE_POWERCFG" 2>/dev/null
    if ! grep -q "<string name=\"${pkg}\">${mode}</string>" "$SCENE_POWERCFG" 2>/dev/null; then
        [ -f "$bak" ] && write_replace "$bak" "$SCENE_POWERCFG" >/dev/null 2>&1
        rm -f "$bak" 2>/dev/null; echo "ERR 写入后校验失败（已回滚）"; return 1
    fi
    rm -f "$bak" 2>/dev/null
    echo "OK 已把 ${pkg} 设为 Scene「${mode}」"
}

cmd_fasxres() {
    local f="${SCENE_DIR}/features/fas.conf"
    [ -f "$f" ] || { echo "ERR 找不到 features/fas.conf"; return 1; }
    local tmp="${TMPD}/fas.conf.new"
    awk -F= -v OFS='=' '
        /^governor_little=/ { $2="xres"; a=1 } /^governor_middle=/ { $2="xres"; b=1 } /^governor_prime=/ { $2="xres"; c=1 }
        { print }
        END { if(!a) print "governor_little=xres"; if(!b) print "governor_middle=xres"; if(!c) print "governor_prime=xres" }
    ' "$f" > "$tmp" 2>/dev/null || { echo "ERR 生成新 fas.conf 失败"; return 1; }
    local n_old n_new; n_old=$(grep -c . "$f" 2>/dev/null); n_new=$(grep -c . "$tmp" 2>/dev/null)
    if [ "${n_new:-0}" -lt "${n_old:-0}" ] || [ "$(grep -c '^governor_' "$tmp" 2>/dev/null)" -lt 3 ]; then
        rm -f "$tmp"; echo "ERR 新内容自检未过，已放弃写入"; return 1
    fi
    write_replace "$tmp" "$f" || { rm -f "$tmp"; echo "ERR 写回 fas.conf 失败"; return 1; }
    perm_file "$f"; rm -f "$tmp"; restart_scene_daemon >/dev/null 2>&1
    echo "OK FAS 调速器已设为 xres · scene-daemon 已重启"
}

cmd_log(){ tail -n "${1:-40}" "$LOG_FILE" 2>/dev/null; }
cmd_daemonlog(){ local n="${1:-30}"; echo "--- daemon.log ---"; tail -n "$n" "${SCENE_DIR}/daemon.log" 2>/dev/null; echo "--- daemon.stderr.log ---"; tail -n "$n" "${SCENE_DIR}/daemon.stderr.log" 2>/dev/null; }

cmd_launchables() {
    cmd package query-activities --brief -a android.intent.action.MAIN -c android.intent.category.LAUNCHER 2>/dev/null \
      | sed -n 's#^[[:space:]]*\([^/][^/]*\)/.*#\1#p' | sort -u
}
cmd_apps() {
    if has cmd; then cmd package list packages 2>/dev/null | sed 's/^package://' | while read -r p; do
        case "$p" in *overlay*|*.rro*|*.auto_generated*|android|*shared_library*) continue ;; esac; echo "$p"; done
    else pm list packages 2>/dev/null | sed 's/^package://'; fi
}

cmd_ksufix() {
    if selfheal_pending_update; then
        [ -e "$MODDIR/update" ] && rm -f "$MODDIR/update"
        if [ -d /data/adb/modules_update/SceneO3Tuner ]; then echo "OK 已合并待更新副本 + 清标记 + 重拉服务"; else echo "OK 已清孤儿 update 标记"; fi
    else echo "ERR 待更新副本校验不通过，已保留副本未删除"; fi
}

cmd_live() {
    local f; f=$(ensure_required_flags)
    local pid; pid=$(restart_scene_daemon) || return 1
    echo "OK 频率配置已下发（核心分配 PID ${pid}）"
}

# ============================================================
#  线程引擎（艇长 Aether）
# ============================================================
cmd_aether() {
    sh "$AETHER_CTL" status 2>&1
    sh "$AETHER_CTL" featlist 2>&1
    sh "$AETHER_CTL" rules 2>&1
}
cmd_aetherswitch() {
    case "$1" in
      on)  touch "$STATE_DIR/aether.on" 2>/dev/null; sh "$AETHER_CTL" start 2>&1; update_module_desc >/dev/null 2>&1 ;;
      off) rm -f "$STATE_DIR/aether.on" 2>/dev/null; sh "$AETHER_CTL" stop 2>&1; update_module_desc >/dev/null 2>&1 ;;
      *) echo "ERR 用法: aetherswitch on|off"; return 1 ;;
    esac
    echo "OK 艇长线程引擎已${1}（免重启生效）"
}
cmd_aetherfeat() {
    sh "$AETHER_CTL" feat "$2" "$3" 2>&1
    [ -n "$3" ] && sh "$AETHER_CTL" restart >/dev/null 2>&1
}
cmd_aetherrules() { sh "$AETHER_CTL" rules 2>&1; }
cmd_aetherraw() { [ -f "$AETHER_CFG" ] || { echo ""; return; }; $B64BIN "$AETHER_CFG" 2>/dev/null | tr -d '\n'; }
cmd_aetherrawset() {
    local raw="${TMPD}/aether.cfg.raw" b64="$1"
    [ -n "$b64" ] || { echo "ERR 空内容"; return 1; }
    if has base64; then base64 -d <<EOF > "$raw" 2>/dev/null
$b64
EOF
    else echo "ERR 缺少 base64"; return 1; fi
    [ -s "$raw" ] || { echo "ERR 解码为空"; return 1; }
    if [ -n "$PY" ]; then
        "$PY" -c "import json,sys; json.load(open('$raw'))" 2>/dev/null || { echo "ERR JSON 非法"; return 1; }
    else grep -q '{' "$raw" && grep -q '}' "$raw" || { echo "ERR 内容异常"; return 1; }; fi
    write_replace "$raw" "$AETHER_CFG" || { echo "ERR 写入失败"; return 1; }
    chmod 0666 "$AETHER_CFG" 2>/dev/null; chown 0:0 "$AETHER_CFG" 2>/dev/null
    sh "$AETHER_CTL" restart >/dev/null 2>&1
    echo "OK 已写入并重载 Aether 配置（$(wc -c < "$raw" | tr -d ' ') B）"
}

# ---------- 应用级线程分配（读取本机有界面应用 + 艇长已定义 / 自定义 / 未分配）----------
cmd_aetherapps() {
    sh "$AETHER_CTL" apps 2>&1
}
cmd_aetherset() {
    [ -n "$2" ] || { echo "ERR 用法: aetherset <包名> <核位>"; return 1; }
    sh "$AETHER_CTL" set "$2" "$3" 2>&1
}
cmd_aetherdel() {
    [ -n "$2" ] || { echo "ERR 用法: aetherdel <包名>"; return 1; }
    sh "$AETHER_CTL" del "$2" 2>&1
}

# ============================================================
case "$1" in
  status)        cmd_status ;;
  read)          cmd_read "$2" ;;
  b64len)        cmd_b64len "$2" ;;
  b64)           cmd_b64 "$2" "$3" "$4" ;;
  conf)          cmd_conf "$2" ;;
  wbegin)        cmd_wbegin "$2" && echo "OK" ;;
  wappend)       cmd_wappend "$2" "$3" && echo "OK" ;;
  wcommit)       cmd_wcommit "$2" ;;
  apply)         cmd_apply ;;
  schemes)       cmd_schemes ;;
  scheme)        cmd_scheme "$2" ;;
  restore)       cmd_restore ;;
  profilepush)   cmd_profilepush "$@" ;;
  profilebackup) cmd_profilebackup ;;
  profilerestore) cmd_profilerestore "$@" ;;
  profilelist)   cmd_profilelist ;;
  mode)          cmd_mode ;;
  modeset)       cmd_modeset "$2" ;;
  freqs)         cmd_freqs ;;
  appmodes)      cmd_appmodes ;;
  setappmode)    shift; cmd_setappmode "$1" "$2" ;;
  fasxres)       cmd_fasxres ;;
  log)           cmd_log "$2" ;;
  daemonlog)     cmd_daemonlog "$2" ;;
  launchables)   cmd_launchables ;;
  apps)          cmd_apps ;;
  ksufix)        cmd_ksufix ;;
  live)          cmd_live ;;
  aether)        cmd_aether ;;
  aetherswitch)  cmd_aetherswitch "$2" ;;
  aetherfeat)    cmd_aetherfeat "$2" "$3" "$4" ;;
  aetherrules)   cmd_aetherrules ;;
  aetherraw)     cmd_aetherraw ;;
  aetherrawset)  cmd_aetherrawset "$2" ;;
  aetherapps)    cmd_aetherapps ;;
  aetherset)     cmd_aetherset "$1" "$2" "$3" ;;
  aetherdel)     cmd_aetherdel "$1" "$2" ;;
  *) echo "err: unknown command '$1'"; exit 1 ;;
esac
