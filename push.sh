#!/system/bin/sh
# ============================================================================
#  SceneO3LP · 配置推送（Scene N1 外部配置通道 · 只做频率方案 + 配置传送）
#  用法: push.sh [install|boot|manual]   参数只影响日志标记
#
#  做四件事（顺序铁律，缺一不可）：
#   ⓪ 停 App     杀掉 Scene App 进程（防 SharedPreferences 内存态把两键整份写回；
#                 用 kill 不用 am force-stop —— 后者实测会掉无障碍服务）
#   ① 装外部配置  Config/powercfg.sh → /data/powercfg.sh
#                Config/powercfg.json → /data/powercfg.json（官方外部配置描述文件）
#                ★ 2026-09-29 实机结论：本机 Scene（N1 2026.09 Alpha7）**已不再接受
#                  SOURCE_SCENE_ONLINE**（写进去会被 App 主动清除；实测 BANANA /
#                  SCENE_CUSTOM / SCENE_LP / SCENE_HP / SCENE_IMPORT 等都保留，唯独
#                  ONLINE 被清）。本地方案唯一可用通道 = 官方文档的「外部配置对接」：
#                  /data/powercfg.sh 非空 → outsideConfigInstalled() = true →
#                  modeConfigCompleted() 直接为 true → 「性能调节」总开关才打得开。
#                  Scene 以 `sh /data/powercfg.sh <mode>` 调用（init/四档）
#   ② 灌文件     Config/ 下 8 个文件 → Scene files/，features/*.conf → files/features/
#                （内嵌方案身份用；inode 替换写 + 属主/权限修正 + 逐个 md5 自检）
#   ③ 写两键     global.xml: scene_profile_source=SOURCE_OUTSIDE
#                           dynamic_control=true（性能调节总开关）
#                写后复核，不到位重写一次
#   ④ 拉起复核   kill scene-daemon + am start Scene（.activities.ActivityMain）
#                → 等 App 起来后复核两键是否被回写 → do_status 打印通道状态
#
#  ⚠ 不推 threads.json / threads_games.json：按用户要求剥掉线程绑定，只留频率配置
#  ⚠ 不删 files/profileInstalled —— 实测那是 **AndroidX ProfileInstaller** 的基线
#    profile 标记（App 启动日志 `D/ProfileInstaller: Installing profile for ...`），
#    与 Scene 方案安装态无关；v1.4 把它当「Scene 旧方案标记」删掉是误判
#  ⚠ 不做 am force-stop（会掉无障碍）；杀进程必须复核 —— KSU 环境里
#    `ps -A -o PID,ARGS` 不认大写 PID/ARGS（bad -o argument）→ 空列表 → 空循环 →
#    日志却打「已杀」= 假成功（2026-09-29 实机踩坑）
# ============================================================================
MODDIR="${MODDIR:-${0%/*}}"
[ -f "${MODDIR}/module.prop" ] || MODDIR="/data/adb/modules/SceneO3LP"

SCENE_PKG="com.omarea.vtools"
SCENE_DIR="/data/data/${SCENE_PKG}/files"
SCENE_FEAT_DIR="${SCENE_DIR}/features"
SCENE_GLOBAL_XML="/data/data/${SCENE_PKG}/shared_prefs/global.xml"
SCENE_PREFS_DIR="/data/data/${SCENE_PKG}/shared_prefs"
SRC="${MODDIR}/Config"
TAG="${1:-manual}"
LOG="/data/adb/SceneO3LP/push.log"
OUTSIDE_SH="/data/powercfg.sh"
OUTSIDE_JSON="/data/powercfg.json"

mkdir -p /data/adb/SceneO3LP 2>/dev/null
log() { echo "[$(date '+%m-%d %H:%M:%S')] $*" >> "$LOG"; echo "$*"; }

FILES="profile.json manifest.json powercfg.sh _Apps.json _Games.json _Camera.json _ELP.json description.txt"
FEATURES="cpuset.conf env.conf fas.conf limiter.conf refresh_rate.conf"

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

# ---------- ⓪ 停 Scene App（防内存态回写两键）----------
# ★ 用单次 grep 扫 /proc 的 Uid（逐文件 awk 太慢：本机 proot 下 900+ 次 fork 要数秒，
#   而 FGS 会在杀后 1~3 秒内把 App 拉起来 —— 慢就等于让新实例先读到旧状态）
stop_app() {
    local uid s p n=0
    uid=$(get_uid)
    [ -n "$uid" ] || { log "WARN 未找到 $SCENE_PKG 的 uid，跳过停 App"; return 0; }
    for s in $(grep -l "^Uid:[[:space:]]*${uid}" /proc/[0-9]*/status 2>/dev/null); do
        p="${s#/proc/}"; p="${p%/status}"
        kill -9 "$p" 2>/dev/null && n=$((n+1))
    done
    if [ "$n" -gt 0 ]; then
        log "app killed x$n（防内存态回写 global.xml）"
    else
        log "app 未在运行（无需杀）"
    fi
    return 0
}

# ---------- ① 灌文件（基础文件 + features/）----------
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

    if [ -d "${SRC}/features" ]; then
        mkdir -p "$SCENE_FEAT_DIR" 2>/dev/null
        fix_perm "$SCENE_FEAT_DIR" "$uid"
        for f in $FEATURES; do
            [ -f "${SRC}/features/${f}" ] || continue
            if write_replace "${SRC}/features/${f}" "${SCENE_FEAT_DIR}/${f}"; then
                n=$((n+1))
            else
                bad="$bad features/${f}"
            fi
            fix_perm "${SCENE_FEAT_DIR}/${f}" "$uid"
        done
    fi

    [ -n "$bad" ] && { log "ERR 灌入失败:$bad"; return 1; }
    log "sync: ${n} files (tag=$TAG)"
    return 0
}

# ---------- ①b 外部配置通道：/data/powercfg.sh + /data/powercfg.json ----------
install_outside() {
    local n=0
    if [ -f "${SRC}/powercfg.sh" ]; then
        cp -f "${SRC}/powercfg.sh" "$OUTSIDE_SH" 2>/dev/null && chmod 0755 "$OUTSIDE_SH" 2>/dev/null && n=$((n+1))
    fi
    if [ -f "${SRC}/powercfg.json" ]; then
        cp -f "${SRC}/powercfg.json" "$OUTSIDE_JSON" 2>/dev/null && chmod 0644 "$OUTSIDE_JSON" 2>/dev/null && n=$((n+1))
    fi
    [ "$n" -ge 2 ] || { log "ERR 外部配置安装不完整（$n/2）"; return 1; }
    [ -s "$OUTSIDE_SH" ] || { log "ERR $OUTSIDE_SH 为空"; return 1; }
    log "outside: powercfg.sh($(wc -c < "$OUTSIDE_SH" 2>/dev/null)B) + powercfg.json 已就位"
    return 0
}

# ---------- ①c 立即生效：按 Scene 当前默认档应用一次 ----------
# ★ 2026-09-29 实机观察：门控通过、Scene 启动时也会调用我们的 `init`，但它的「按档下发」
#   （executeMode）始终不触发 —— daemon.log 恒为 `Scheduler [Stop]`，切换应用 / 重开 Scene
#   都不产生 mode 调用。为保证方案「装完即生效」，这里读 Scene 的按应用默认档
#   （shared_prefs/powercfg.xml 的 "*"）主动应用一次；Scene 之后若要下发会覆盖为它的档位。
apply_default_mode() {
    local mode
    mode=$(sed -n 's|.*<string name="\*">\([^<]*\)<.*|\1|p' "${SCENE_PREFS_DIR}/powercfg.xml" 2>/dev/null | head -1)
    case "$mode" in
        powersave|balance|performance|fast|igoned) ;;
        *) mode="balance" ;;
    esac
    if [ "$mode" = "igoned" ]; then
        log "Scene 默认档=igoned（保持状态），跳过主动应用"
        return 0
    fi
    if [ -f "$OUTSIDE_SH" ]; then
        sh "$OUTSIDE_SH" "$mode" >/dev/null 2>&1 && log "已按 Scene 默认档应用一次: $mode"
    fi
    return 0
}

# ---------- ③ global.xml 两键 ----------
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
    uid=$(get_uid)
    write_replace "$tmp" "$SCENE_GLOBAL_XML"
    rm -f "$tmp" 2>/dev/null
    [ -n "$uid" ] && chown "${uid}:${uid}" "$SCENE_GLOBAL_XML" 2>/dev/null
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

# ---------- ④ 重启调度进程（pidof + 杀后复核）----------
restart_daemon() {
    local pid pids
    pids=$(pidof scene-daemon 2>/dev/null)
    if [ -z "$pids" ]; then
        log "daemon 未在运行（无需重启）"
        return 0
    fi
    for pid in $pids; do kill "$pid" 2>/dev/null; done
    sleep 1
    pids=$(pidof scene-daemon 2>/dev/null)
    if [ -n "$pids" ]; then
        for pid in $pids; do kill -9 "$pid" 2>/dev/null; done
        sleep 1
    fi
    pids=$(pidof scene-daemon 2>/dev/null)
    if [ -n "$pids" ]; then
        log "ERR daemon 杀不掉（pid=$pids），旧内存态可能覆写配置"
        return 1
    fi
    log "daemon killed（Scene 将在 4~8s 内自动拉起并重读配置）"
}

# ---------- ⑤ 状态报告 + 校验 ----------
do_status() {
    local f miss="" diff="" auth id src dyn nfeat osz jsz
    for f in $FILES; do
        [ -f "${SRC}/${f}" ] || continue
        if [ ! -f "${SCENE_DIR}/${f}" ]; then
            miss="$miss $f"
        elif [ "$(md5of "${SRC}/${f}")" != "$(md5of "${SCENE_DIR}/${f}")" ]; then
            diff="$diff $f"
        fi
    done
    nfeat=0
    for f in $FEATURES; do
        [ -f "${SRC}/features/${f}" ] || continue
        nfeat=$((nfeat+1))
        if [ ! -f "${SCENE_FEAT_DIR}/${f}" ]; then
            miss="$miss features/${f}"
        elif [ "$(md5of "${SRC}/features/${f}")" != "$(md5of "${SCENE_FEAT_DIR}/${f}")" ]; then
            diff="$diff features/${f}"
        fi
    done

    auth=$(sed -n 's/.*"author"[ ]*:[ ]*"\([^"]*\)".*/\1/p' "${SCENE_DIR}/manifest.json" 2>/dev/null | head -1)
    id=$(sed -n 's/.*"version"[ ]*:[ ]*"\([^"]*\)".*/\1/p' "${SCENE_DIR}/manifest.json" 2>/dev/null | head -1)
    src=$(sed -n 's/.*name="scene_profile_source">\([^<]*\)<.*/\1/p' "$SCENE_GLOBAL_XML" 2>/dev/null | head -1)
    dyn=$(sed -n 's/.*name="dynamic_control" value="\([^"]*\)".*/\1/p' "$SCENE_GLOBAL_XML" 2>/dev/null | head -1)
    osz=$(wc -c < "$OUTSIDE_SH" 2>/dev/null); osz="${osz:-0}"
    jsz=$(wc -c < "$OUTSIDE_JSON" 2>/dev/null); jsz="${jsz:-0}"

    echo "---- Scene 当前状态 ----"
    echo "  配置身份 : ${auth:-?}'${id:-?}（内嵌方案，供 UI 显示）"
    echo "  外部配置 : ${OUTSIDE_SH}(${osz}B) + ${OUTSIDE_JSON}(${jsz}B)"
    echo "  配置来源 : ${src:-?}"
    echo "  性能调节 : ${dyn:-?}"
    if [ -n "$miss" ]; then
        echo "  ⚠ 缺失文件:$miss → 被 Scene 清掉，请重跑本脚本"
    elif [ -n "$diff" ]; then
        echo "  ⚠ 内容不一致:$diff → 被 Scene 回写，请重跑本脚本"
    else
        echo "  ✅ 8 个配置文件 + ${nfeat} 个 features 配置全部落盘且与源一致"
    fi
    if [ "$src" = "SOURCE_OUTSIDE" ] && [ "$dyn" = "true" ] && [ "$osz" -gt 0 ] && [ "$jsz" -gt 0 ]; then
        echo "✅ 通道就绪：Scene 调节页「性能调节」应可开启，频率由 $OUTSIDE_SH 按档下发"
        return 0
    else
        echo "⚠ 通道未就绪"
        [ "$src" != "SOURCE_OUTSIDE" ] && echo "   · 来源不对（应为 SOURCE_OUTSIDE，当前 ${src:-空}）"
        [ "$dyn" != "true" ] && echo "   · 性能调节未开（应为 true）"
        { [ "$osz" -eq 0 ] || [ "$jsz" -eq 0 ]; } && echo "   · 外部配置缺失（$OUTSIDE_SH / $OUTSIDE_JSON）"
        return 1
    fi
}

# ============================ 主流程 ============================
# ★ 顺序铁律（2026-09-29 实机定论）：先杀 App → 装外部配置 + **立刻** 写两键 → 灌文件
#   → 再杀一次 → 拉起。理由：Scene App **不主动回写** prefs（实测零进程静置 20s 两键
#   纹丝不动），它只在被「戳」（启动 / 页面恢复）时用**自己内存里的映射**整份覆盖
#   global.xml；而它的前台服务会在被杀后 1~3 秒把进程拉起 —— 写入必须紧贴杀进程。
stop_app
install_outside || exit 1
i=0
while [ $i -lt 3 ]; do
    pref_set scene_profile_source SOURCE_OUTSIDE string || log "ERR 写入 scene_profile_source 失败"
    pref_set dynamic_control true boolean || log "ERR 写入 dynamic_control 失败"
    s=$(sed -n 's/.*name="scene_profile_source">\([^<]*\)<.*/\1/p' "$SCENE_GLOBAL_XML" 2>/dev/null | head -1)
    d=$(sed -n 's/.*name="dynamic_control" value="\([^"]*\)".*/\1/p' "$SCENE_GLOBAL_XML" 2>/dev/null | head -1)
    [ "$s" = "SOURCE_OUTSIDE" ] && [ "$d" = "true" ] && break
    i=$((i+1))
done
log "两键写入（紧贴 kill）: source=${s:-?} dynamic=${d:-?}"

do_sync || exit 1

# ★ 再杀一次：确保之后拉起的新实例，是在两键写入之后才加载 prefs 的
stop_app

restart_daemon
# ★ 立即生效保障：按 Scene 当前默认档应用一次（见正文 ①c 的实机观察）
apply_default_mode
# 非 boot 场景：把 Scene 拉到前台（App 冷启动会读到我们的两键）
if [ "$TAG" != "boot" ]; then
    if am start -n com.omarea.vtools/.activities.ActivityMain >/dev/null 2>&1; then
        log "am start Scene（App 冷启动读新配置）"
    else
        log "WARN am start Scene 失败（手动打开一次 Scene 即可）"
    fi
fi

# 等 App 起来后复核两键（外部通道下不依赖 profileInstalled）
sleep 6
s=$(sed -n 's/.*name="scene_profile_source">\([^<]*\)<.*/\1/p' "$SCENE_GLOBAL_XML" 2>/dev/null | head -1)
d=$(sed -n 's/.*name="dynamic_control" value="\([^"]*\)".*/\1/p' "$SCENE_GLOBAL_XML" 2>/dev/null | head -1)
log "拉起后复核: source=${s:-?} dynamic=${d:-?}"

do_status
exit $?
