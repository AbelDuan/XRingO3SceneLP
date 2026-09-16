#!/system/bin/sh
# ============================================================
#  调度配置：传递 / 备份 / 恢复
# ------------------------------------------------------------
#  用法:
#    profile_sync.sh push   [scheme]   把模块内置方案配置灌进 Scene（含权限+校验）
#    profile_sync.sh backup            备份 Scene 的全部调度与线程配置
#    profile_sync.sh restore [名称]    恢复某个备份（默认最新）
#    profile_sync.sh list              列出可用备份
#
#  ⚠ 「传递调度」到底在做什么 —— 四件事缺一不可（2026-09-16 设备实测定论）：
#
#    ① 停 Scene   先 `am force-stop`。运行中的 Scene 会做两件把我们成果冲掉的事：
#                 · 把内存里的偏好整份写回 shared_prefs/global.xml（改的开关会丢）
#                 · 用自己的运行时格式重写 files/profile.json（43KB 配置被换成 8KB）
#
#    ② 灌文件     把 Config/4+4+2/O3/<scheme>/ 下的 profile.json / manifest.json /
#                 _Apps.json / _Games.json / _Camera.json / _ELP.json / powercfg.sh
#                 同步进 Scene 的 files/，并按 Scene 的 uid 修正属主权限。
#
#    ③ 启配置     shared_prefs/global.xml 里两个键：
#                 · scene_profile_source = **SOURCE_SCENE_ONLINE**（唯一可用值）
#                 · dynamic_control      = **true**（「性能调节」总开关，必须打开）
#                 ⚠ 三个取值都实测过（2026-09-16）：
#                   SOURCE_SCENE_ONLINE  → 显示「Scene / 🌍 Version: LP」+ 可启用 ✅
#                   SOURCE_SCENE_CUSTOM  → 能启用，但显示成「自定义」，看着不像我们的
#                   SOURCE_OUTSIDE       → 显示我们的身份，但被判无效、性能调节打不开 ❌
#                 ⚠ dynamic_control=false 时 Scene 完全不下发调度，就是用户看到的
#                   「配置无法启用」。所以这一步必须做。
#
#    ④ 校验       重新启动 Scene，再读回 manifest / profile 的 md5 与两个开关，
#                 确认 Scene 没有把它们改回去。
#
#    实测生效标志：
#                 manifest.json = 我们那份（SCENE9 / LP），md5 未被回写；
#                 profile.json  = 我们那份（原样），md5 未被回写；
#                 scene_profile_source = SOURCE_SCENE_ONLINE，dynamic_control = true；
#                 调节页那行显示「Scene」+「🌍 Version: LP 20260916」。
#
#  ⚠ 为什么默认不覆盖（继承优先）：
#    profile.json 里存着用户在 Scene 里调过的 8 组频率预设。每次装模块都覆盖
#    等于把用户的调校冲掉。所以只在「首次安装」或「配置确实缺失」时才灌。
#    主动点「传递调度」属于显式修复动作，会覆盖（并先自动备份当前状态）。
# ============================================================

MODDIR="${MODDIR:-/data/adb/modules/SceneO3Tuner}"
. "$MODDIR/lib/util.sh"

BACKUP_ROOT="${STATE_DIR}/backups"
CFG_ROOT="${MODDIR}/Config/4+4+2/O3"

# 备份保留份数：只留最近 3 个，新增一个就删掉最早的那个。
# 依据：每次「传递调度」都会自动备份一份，攒多了纯占 /data 空间
#       （一份含 profile.json 43KB + threads.json 25KB + powercfg.xml + 游戏名单，
#        二十几份就接近 2MB），而实际回滚只会用到最近一两个。
KEEP_BACKUPS="${KEEP_BACKUPS:-3}"

# Scene 的「调度 + 线程」配置文件清单（files/ 下）
SCENE_FILES="profile.json manifest.json _Apps.json _Camera.json _ELP.json _Games.json powercfg.sh description.txt threads.json threads_games.json"
# Scene 的调度相关偏好
SCENE_PREFS="powercfg.xml games.xml"
# 模块自己的线程模板与分配表
MOD_WEBUI="app_assign.tsv app_templates.tsv game_assign.tsv game_templates.tsv settings.conf"

ts() { date '+%Y%m%d_%H%M%S'; }

# ============================================================
#  传递调度
# ============================================================
do_push() {
    local scheme="$1"
    [ -z "$scheme" ] && scheme=$(active_scheme)
    [ -z "$scheme" ] && scheme="sweet_bal"

    local src="${CFG_ROOT}/${scheme}"
    if [ ! -d "$src" ]; then
        echo "ERR 方案目录不存在: $src"
        return 1
    fi
    if [ ! -d "$SCENE_DIR" ]; then
        echo "ERR Scene 数据目录不存在，请先安装并启动一次 Scene"
        return 1
    fi

    local uid; uid=$(get_package_uid "$SCENE_PKG")
    if [ -z "$uid" ]; then
        echo "ERR 未安装 Scene（$SCENE_PKG）"
        return 1
    fi

    # 灌之前先自动备份一份（备份只保留最近 KEEP_BACKUPS 个）
    do_backup >/dev/null 2>&1

    ensure_scene_dir_perm

    # ---- ⚠ 刻意**不** force-stop Scene（2026-09-16 调整）----
    #  早先版本会先 `am force-stop` 再写，理由是「运行中的 Scene 会把偏好写回、
    #  并重写 profile.json」。但那会**连带掉无障碍服务 → Scene 直接失效**，
    #  代价太大。实测：只要两个开关本来就已经是对的值（SOURCE_SCENE_ONLINE /
    #  dynamic_control=true —— 这是稳定态），直接写文件即可，Scene 会自己重读；
    #  写入后我们会读回 md5 复核，真被回写了会明确报出来。
    #  开关只有在「确实不对」时才写（首次启用那种一次性场景）。
    # ---- ① 灌文件 ----
    #  ⚠ manifest.json **必须**跟着灌，而且必须是**我们的**身份（SCENE9 / LP / versionCode）。
    #    它就是 Scene 眼里「当前启用的这套配置」的身份，先在调节页被显示出来。
    local n
    n=$(sync_scheme "$src" 2>/dev/null)
    case "$n" in
      ''|*[!0-9]*) echo "ERR 同步失败（sync_scheme 未返回文件数）"; return 1 ;;
    esac

    # ---- ② 启用配置：来源通道 + 「性能调节」总开关 ----
    local src_out dyn_out src_ok="" dyn_ok=""
    src_out=$(scene_source_set "$SCENE_SOURCE_WANT" 2>&1)
    dyn_out=$(scene_dyn_set true 2>&1)
    [ "$(scene_source_get)" = "$SCENE_SOURCE_WANT" ] && src_ok=1
    [ "$(scene_dyn_get)" = "true" ] && dyn_ok=1

    # ---- 严格校验：确认关键文件真的落盘且与源一致 ----
    #  ⚠ verify_synced 对「设备上不存在」的文件是 skip（continue），
    #    所以这里再逐个显式查一遍存在性 + md5，避免"同步失败却被判成功"。
    #  ⚠ manifest.json 这次**要**进校验列表：我们就是要覆盖 Scene 的旧身份。
    local miss="" diff="" f
    for f in profile.json manifest.json _Apps.json _Games.json _Camera.json _ELP.json powercfg.sh; do
        [ -f "${src}/${f}" ] || continue
        if [ ! -f "${SCENE_DIR}/${f}" ]; then
            miss="$miss $f"
        elif [ "$(md5of "${src}/${f}")" != "$(md5of "${SCENE_DIR}/${f}")" ]; then
            diff="$diff $f"
        fi
    done
    if [ -n "$miss" ] || [ -n "$diff" ]; then
        echo "ERR 传递未通过校验：缺失=[$miss] 内容不一致=[$diff]"
        return 1
    fi

    # 目录可进入性（缺 x 位会让 Scene 卡启动 splash）
    if ! dir_x_ok "$SCENE_DIR"; then
        ensure_scene_dir_perm
        dir_x_ok "$SCENE_DIR" || { echo "ERR Scene files 目录缺执行位"; return 1; }
    fi

    # ---- ③ 让 scene-daemon 重读配置（不碰 Scene 进程）----
    #  实测 scene-daemon 被 kill 后由 Scene 自身在 4~8 秒内自动拉起并重读配置；
    #  它只是个后台调度进程，杀掉不影响 Scene 界面与无障碍服务。
    restart_scene_daemon >/dev/null 2>&1 || pkill -f scene-daemon 2>/dev/null
    sleep 3

    # ---- ④ 端到端复核：身份 / 开关 / 文件有没有被 Scene 改回去 ----
    local idv ida src_now mf_ok="" pf_ok=""
    idv=$(sed -n 's/.*"version"[ ]*:[ ]*"\([^"]*\)".*/\1/p' "${SCENE_DIR}/manifest.json" 2>/dev/null | head -1)
    ida=$(sed -n 's/.*"author"[ ]*:[ ]*"\([^"]*\)".*/\1/p' "${SCENE_DIR}/manifest.json" 2>/dev/null | head -1)
    src_now=$(scene_source_get)
    [ "$(md5of "${src}/manifest.json")" = "$(md5of "${SCENE_DIR}/manifest.json")" ] && mf_ok=1
    [ "$(md5of "${src}/profile.json")" = "$(md5of "${SCENE_DIR}/profile.json")" ] && pf_ok=1

    echo "OK 已传递【${scheme}】共 ${n} 个文件到 Scene 并启用为当前配置"
    echo "   · 配置身份：${ida:-?}'${idv:-?}${mf_ok:+ ✓未被回写}"
    echo "   · 配置来源：${src_now:-?}${src_ok:+ ✓}"
    echo "   · 性能调节：$(scene_dyn_get)${dyn_ok:+ ✓}"
    [ -z "$mf_ok" ] && echo "   ⚠ manifest.json 被 Scene 改回去了 —— 调节页身份会不对"
    [ -z "$pf_ok" ] && echo "   ⚠ profile.json 被 Scene 覆盖了 —— 我们的参数未生效"
    [ -z "$src_ok" ] && echo "   ⚠ 来源未就绪：${src_out}"
    [ -z "$dyn_ok" ] && echo "   ⚠ 性能调节未打开：${dyn_out}"
    log_quiet "profile: push ${scheme} (${n} files) ok, identity=${ida}/${idv} source=${src_now} dyn=${dyn_ok:-0} kept(mf/pf)=${mf_ok:-0}/${pf_ok:-0}"
    return 0
}

# ============================================================
#  备份剪枝：只保留最近 KEEP_BACKUPS 个
# ------------------------------------------------------------
#  备份目录名就是时间戳（YYYYmmdd_HHMMSS），字典序 == 时间序，
#  所以 `ls | sort` 后取前面的就是最早的。
#  ⚠ 只删「时间戳命名的目录」，绝不碰 webui.sh 写在同目录下的
#    `<id>.<ts>.bak` 单文件备份（那是另一套机制）。
#  ⚠ 不用 `head -n -N`（toybox/busybox 的 head 对负值支持不一致），
#    改成先数总数再算要删几个。
# ============================================================
prune_backups() {
    local keep="${1:-$KEEP_BACKUPS}" all total drop i=0 d
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
    # 输出被删掉的清单，方便调用方回显（stdout 是命令输出，故走 stderr 之外的方式）
    printf '%s\n' "$all" | head -n "$drop" | tr '\n' ' '
    return 0
}

# ============================================================
#  备份
# ============================================================
do_backup() {
    local name; name=$(ts)
    local dir="${BACKUP_ROOT}/${name}"
    mkdir -p "${dir}/scene-files/features" "${dir}/scene-prefs" "${dir}/module-webui" 2>/dev/null

    local uid; uid=$(get_package_uid "$SCENE_PKG")
    local n=0 f

    # ---- Scene files/ 下的调度与线程配置 ----
    for f in $SCENE_FILES; do
        [ -f "${SCENE_DIR}/${f}" ] || continue
        cp -f "${SCENE_DIR}/${f}" "${dir}/scene-files/${f}" 2>/dev/null && n=$((n+1))
    done
    if [ -d "${SCENE_DIR}/features" ]; then
        for f in "${SCENE_DIR}"/features/*; do
            [ -f "$f" ] || continue
            cp -f "$f" "${dir}/scene-files/features/${f##*/}" 2>/dev/null && n=$((n+1))
        done
    fi
    # objects/ 是 Scene 按模式展开的运行产物，一并备份（可能是空的）
    if [ -d "${SCENE_DIR}/objects" ]; then
        mkdir -p "${dir}/scene-files/objects" 2>/dev/null
        for f in "${SCENE_DIR}"/objects/*; do
            [ -f "$f" ] || continue
            cp -f "$f" "${dir}/scene-files/objects/${f##*/}" 2>/dev/null && n=$((n+1))
        done
    fi

    # ---- Scene 的调度偏好（单应用模式表 / 游戏名单）----
    for f in $SCENE_PREFS; do
        [ -f "${SCENE_PREFS_DIR}/${f}" ] || continue
        cp -f "${SCENE_PREFS_DIR}/${f}" "${dir}/scene-prefs/${f}" 2>/dev/null && n=$((n+1))
    done

    # ---- 模块自己的线程模板与分配表 ----
    for f in $MOD_WEBUI; do
        [ -f "${WEBUI_DIR}/${f}" ] || continue
        cp -f "${WEBUI_DIR}/${f}" "${dir}/module-webui/${f}" 2>/dev/null && n=$((n+1))
    done

    # ---- 清单（人可读，恢复时也用它定位）----
    {
        echo "backup_name=${name}"
        echo "created=$(date '+%Y-%m-%d %H:%M:%S')"
        echo "module_version=$(sed -n 's/^version=//p' "${MODDIR}/module.prop" 2>/dev/null | head -1)"
        echo "files=${n}"
    } > "${dir}/MANIFEST.txt" 2>/dev/null

    if [ "$n" -eq 0 ]; then
        rm -rf "$dir" 2>/dev/null
        echo "ERR 没有可备份的配置文件"
        return 1
    fi

    # 剪枝：超过上限就把最早的删掉（保留最近 KEEP_BACKUPS 个）
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
        # 没指定就用最新一个（ls 排序后取最后一行）
        name=$(ls -1 "$BACKUP_ROOT" 2>/dev/null | grep -E '^[0-9]{8}_[0-9]{6}$' | tail -1)
        [ -z "$name" ] && { echo "ERR 没有可用备份"; return 1; }
    fi
    local dir="${BACKUP_ROOT}/${name}"
    [ -d "$dir" ] || { echo "ERR 备份不存在: $name"; return 1; }

    local uid; uid=$(get_package_uid "$SCENE_PKG")
    if [ -z "$uid" ]; then
        echo "ERR 未安装 Scene（$SCENE_PKG）"
        return 1
    fi

    ensure_scene_dir_perm
    mkdir -p "${SCENE_DIR}/features" 2>/dev/null

    local n=0 f d

    # ---- Scene files/ ----
    for f in "${dir}"/scene-files/*; do
        [ -f "$f" ] || continue
        d="${SCENE_DIR}/${f##*/}"
        if write_replace "$f" "$d"; then n=$((n+1)); fi
        fix_perm "$d" "$uid"
    done
    for f in "${dir}"/scene-files/features/*; do
        [ -f "$f" ] || continue
        d="${SCENE_DIR}/features/${f##*/}"
        if write_replace "$f" "$d"; then n=$((n+1)); fi
        fix_perm "$d" "$uid"
    done

    # ---- Scene 偏好 ----
    for f in "${dir}"/scene-prefs/*; do
        [ -f "$f" ] || continue
        d="${SCENE_PREFS_DIR}/${f##*/}"
        if write_replace "$f" "$d"; then n=$((n+1)); fi
        fix_perm "$d" "$uid"
    done

    # ---- 模块模板与分配表 ----
    for f in "${dir}"/module-webui/*; do
        [ -f "$f" ] || continue
        cp -f "$f" "${WEBUI_DIR}/${f##*/}" 2>/dev/null && n=$((n+1))
        chmod 0666 "${WEBUI_DIR}/${f##*/}" 2>/dev/null
    done

    chown -R "${uid}:${uid}" "$SCENE_DIR" 2>/dev/null
    ensure_scene_dir_perm
    # 目录执行位（缺 x 会让 Scene 卡启动）
    ensure_dir_x "${SCENE_DIR}" 2>/dev/null
    ensure_dir_x "${SCENE_DIR}/features" 2>/dev/null

    # 让 Scene 重新读取
    pkill -f scene-daemon 2>/dev/null
    touch "${STATE_DIR}/scene.mark" 2>/dev/null

    echo "OK 已从 ${name} 恢复 ${n} 个文件，权限已修正｜Scene 正在重新读取"
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
  push)    shift; do_push "$1" ;;
  backup)  do_backup ;;
  restore) shift; do_restore "$1" ;;
  list)    do_list ;;
  *)
    echo "用法: profile_sync.sh push|backup|restore|list"
    exit 1
    ;;
esac
