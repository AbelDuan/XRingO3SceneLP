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

# ---------- 文件 ID → 真实路径（白名单，v18 只含模块自有配置）----------
path_of() {
    case "$1" in
      model)    echo "${WEB_DIR}/model.json" ;;
      activemode) echo "${STATE_DIR}/active_mode" ;;
      settings) echo "${WEB_DIR}/settings.conf" ;;
      app_assign)  echo "${WEB_DIR}/app_assign.tsv" ;;
      game_assign) echo "${WEB_DIR}/game_assign.tsv" ;;
      *) echo "" ;;
    esac
}
modpath_of() {
    case "$1" in
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
    write_replace "$raw" "$dst" || { echo "ERR 覆盖失败: $dst"; return 1; }
    chmod 0666 "$dst"; chown 0:0 "$dst" 2>/dev/null
    echo "OK $(wc -c < "$raw" | tr -d ' ')"
}

cmd_read() { local p; p=$(path_of "$1"); [ -z "$p" ] && { echo ""; return 1; }; [ -f "$p" ] && cat "$p" || echo ""; }
B64BIN="base64"; { [ -x /system/bin/base64 ] && B64BIN=/system/bin/base64; } 2>/dev/null
if ! command -v "$B64BIN" >/dev/null 2>&1; then [ -x "$BB" ] && B64BIN="$BB base64"; fi
cmd_b64len() { local p; p=$(path_of "$1"); [ -f "$p" ] || { echo 0; return; }; $B64BIN "$p" 2>/dev/null | tr -d '\n' | wc -c | tr -d ' '; }
cmd_b64() { local p; p=$(path_of "$1"); [ -f "$p" ] || return 0; local s="${2:-1}" n="${3:-40000}"; $B64BIN "$p" 2>/dev/null | tr -d '\n' | cut -c "${s}-$(( s + n - 1 ))"; }
cmd_conf() { echo "ERR v18 起不再读取 Scene features 配置"; return 1; }

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
    pgrep -f "O3/guard\.sh" >/dev/null 2>&1 && echo "DAEMON=1" || echo "DAEMON=0"
    # 调度守护
    pgrep -f scene-daemon >/dev/null 2>&1 && echo "SCENE_DAEMON=1" || echo "SCENE_DAEMON=0"
    # 三簇频率（v18：QoS 由本模块下发，scaling_max 不受我们控制）
    local c l
    for pair in "L 0" "M 4" "P 8"; do
        set -- $pair; l=$1; c=$2
        echo "QMAX_${l}=$(qmax $c)"; echo "QMIN_${l}=$(qmin $c)"; echo "SCMAX_${l}=$(scmax $c)"; echo "SCUR_${l}=$(scur $c)"; echo "HWMAX_${l}=$(hwmax $c)"
    done
    local pinned=0
    for c in 0 4 8; do local a b; a=$(qmax $c); b=$(qmin $c); [ -n "$a" ] && [ -n "$b" ] && [ "$a" = "$b" ] && pinned=$((pinned+1)); done
    echo "FREQ_PINNED=${pinned}"
    echo "TEMP_CPU0=$(tempof 9)"; echo "TEMP_CPU8=$(tempof 1)"
    # 当前模式
    local cm; cm=$(active_mode); echo "MODE=${cm}"; echo "MODE_CN=$(mode_name_cn "$cm")"; echo "MODE_LIST=${MODE_LIST}"
    local m cn af inf
    for m in $MODE_LIST; do
        cn=$(mode_name_cn "$m"); af=$(mode_freq "$m" active); inf=$(mode_freq "$m" inactive)
        echo "MODE_${m}=${cn}|${af}|${inf}"
    done
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
    # v18：不再与 Scene 无障碍服务交互。改为「立即应用模块配置」：
    #   · 按当前全局模式下发 PM QoS 频率；
    #   · 重建线程分配并让艇长引擎重载。
    log "webui: 应用模块配置（频率 + 线程）"
    local m; m=$(active_mode)
    sh "$MODDIR/Scripts/4+4+2/O3/apply_freq.sh" --mode "$m" >/dev/null 2>&1
    gen_threads >/dev/null 2>&1
    [ -f "$STATE_DIR/aether.on" ] && [ -x "$AETHER_CTL" ] && sh "$AETHER_CTL" restart >/dev/null 2>&1
    echo "OK 已应用模块配置（频率[${m}] + 线程已重建）"
}

cmd_mode() {
    local cm; cm=$(active_mode); echo "MODE=${cm}"; echo "MODE_CN=$(mode_name_cn "$cm")"; echo "MODE_LIST=${MODE_LIST}"
    local m cn af inf
    for m in $MODE_LIST; do
        cn=$(mode_name_cn "$m"); af=$(mode_freq "$m" active); inf=$(mode_freq "$m" inactive)
        echo "MODE_${m}=${cn}|${af}|${inf}"
    done
    # v18：频率由模块 QoS 接管，无 Scene profile.json 预设校验；频率表恒为模块自带
    echo "PRESET_OK=1"
}
cmd_modeset() {
    local m; m=$(mode_from_cn "$1")
    mode_valid "$m" || { echo "ERR 未知模式: $1（可用: $MODE_LIST / 省电|流畅|性能|极速）"; return 1; }
    mkdir -p "$STATE_DIR"; echo "$m" > "${STATE_DIR}/active_mode"
    log "webui: 全局模式 → $m（$(mode_name_cn "$m")）"
    echo "OK $(mode_name_cn "$m")"
}

# ---------- 频率档位：查看（含可用档位 + 当前 QoS）----------
cmd_freqview() {
    local m f
    for m in $MODE_LIST; do
        f=$(mode_freq "$m" active)
        echo "TIER_${m}=${f}"
    done
    echo "HWMAX_L=$(hwmax 0)"; echo "HWMAX_M=$(hwmax 4)"; echo "HWMAX_P=$(hwmax 8)"
    echo "STOCKMIN_L=$(stock_min_of 0)"; echo "STOCKMIN_M=$(stock_min_of 4)"; echo "STOCKMIN_P=$(stock_min_of 8)"
    echo "STEPS_L=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_frequencies 2>/dev/null)"
    echo "STEPS_M=$(cat /sys/devices/system/cpu/cpu4/cpufreq/scaling_available_frequencies 2>/dev/null)"
    echo "STEPS_P=$(cat /sys/devices/system/cpu/cpu8/cpufreq/scaling_available_frequencies 2>/dev/null)"
    echo "QMAX_L=$(qmax 0)"; echo "QMAX_M=$(qmax 4)"; echo "QMAX_P=$(qmax 8)"
    echo "QMIN_L=$(qmin 0)"; echo "QMIN_M=$(qmin 4)"; echo "QMIN_P=$(qmin 8)"
}

# ---------- 频率档位：写入 tiers 文件（仅落地，不应用）----------
#   入参两种：① 标准输入：每行 mode<TAB>Lmin Lmax Mmin Mmax Pmin Pmax
#            ② 单个位置参数：base64(同上)，适配 KSU 桥（无 stdin）
#   仅校验 + 落地到 FREQ_TIERS_FILE，回显忽略条数；不碰 QoS（应用交给 cmd_freqapply）。
freq_write_tiers() {
    local src="$1" tmp="${TMPD}/freq_tiers.tsv" bad=0
    if [ -n "$src" ]; then
        has base64 || { echo "ERR 缺少 base64"; return 1; }
        base64 -d <<EOF 2>/dev/null | cat - > "$tmp"
$src
EOF
    else
        : > "$tmp"
        while IFS= read -r line || [ -n "$line" ]; do
            [ -z "$line" ] && continue
            printf '%s\n' "$line" >> "$tmp"
        done
    fi
    [ -s "$tmp" ] || { rm -f "$tmp"; echo "ERR 没有有效的档位输入"; return 1; }
    local out="${TMPD}/freq_tiers.valid" m vals n
    : > "$out"
    while IFS= read -r line || [ -n "$line" ]; do
        [ -z "$line" ] && continue
        m=$(printf '%s' "$line" | cut -f1); vals=$(printf '%s' "$line" | cut -f2-)
        mode_valid "$m" || { bad=$((bad+1)); continue; }
        n=$(echo "$vals" | wc -w | tr -d ' ')
        [ "$n" -eq 6 ] || { bad=$((bad+1)); continue; }
        printf '%s\t%s\n' "$m" "$vals" >> "$out"
    done < "$tmp"
    rm -f "$tmp"
    [ -s "$out" ] || { rm -f "$out"; echo "ERR 没有有效的档位输入"; return 1; }
    mkdir -p "$WEBUI_DIR"
    cp -f "$out" "$FREQ_TIERS_FILE" 2>/dev/null; chmod 0666 "$FREQ_TIERS_FILE" 2>/dev/null; rm -f "$out"
    echo "$bad"
}

# ---------- 频率档位：仅保存（不应用）----------
cmd_freqsave() {
    local bad; bad=$(freq_write_tiers "$1")
    [ $? -eq 0 ] || { echo "ERR 保存失败"; return 1; }
    echo "OK 频率档位已保存（未下发；${bad} 条非法已忽略）"
}

# ---------- 频率档位：保存 + 应用 ----------
cmd_freqedit() {
    local bad; bad=$(freq_write_tiers "$1")
    [ $? -eq 0 ] || { echo "ERR 保存失败"; return 1; }
    local cm; cm=$(active_mode)
    apply_mode_freq_bg "$cm"   # 后台异步下发，WebUI 不阻塞
    echo "OK 频率档位已保存并应用（忽略 ${bad} 条非法）；当前模式 ${cm}"
}

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
    echo "DEFAULT=$(active_mode)"
    local pm="${TMPD}/pkgmode.txt"; scene_pkg_modes > "$pm"
    local md n
    for md in $MODE_LIST; do n=$(awk -F'\t' -v m="$md" '$2==m' "$pm" 2>/dev/null | wc -l | tr -d ' '); echo "COUNT_${md}=${n:-0}"; done
    echo "TOTAL=$(wc -l < "$pm" 2>/dev/null | tr -d ' ')"
    awk -F'\t' 'NF==2 && $2!="" { print "A_"$1"="$2 }' "$pm"
}
cmd_setappmode() {
    # v18：写入模块自有的 app_assign.tsv（pkg<TAB>mode），Scene 不再参与
    local pkg="$1" mode="$2"
    [ -z "$pkg" ] || [ -z "$mode" ] && { echo "ERR 用法: setappmode <包名> <powersave|balance|performance|fast>"; return 1; }
    mode_valid "$mode" || { echo "ERR 非法模式: $mode"; return 1; }
    case "$pkg" in *'/'*|*'"'*|*'<'*|*'>'*) echo "ERR 包名含非法字符"; return 1 ;; esac
    local f="${WEBUI_DIR}/app_assign.tsv"; mkdir -p "$WEBUI_DIR" 2>/dev/null
    local tmp="${TMPD}/app_assign.new"
    # 若该行已存在则替换，否则追加
    if [ -f "$f" ] && grep -q "^${pkg}	" "$f" 2>/dev/null; then
        awk -F'\t' -v P="$pkg" -v M="$mode" 'BEGIN{OFS="\t"} $1==P{$2=M} {print}' "$f" > "$tmp" 2>/dev/null
    else
        [ -f "$f" ] && cp -f "$f" "$tmp" 2>/dev/null
        printf '%s\t%s\n' "$pkg" "$mode" >> "$tmp" 2>/dev/null
    fi
    [ -s "$tmp" ] || { rm -f "$tmp"; echo "ERR 生成 app_assign.tsv 失败"; return 1; }
    cp -f "$tmp" "$f" 2>/dev/null; chmod 0666 "$f" 2>/dev/null; rm -f "$tmp"
    gen_threads >/dev/null 2>&1
    echo "OK 已把 ${pkg} 设为模块模式「${mode}」"
}

cmd_fasxres() {
    echo "ERR v18 起调速器不再写入 Scene features/fas.conf；O3 的 FAS 由内核 schedutil/xres 直接管理，无需模块干预"
    return 1
}

cmd_log(){ tail -n "${1:-40}" "$LOG_FILE" 2>/dev/null; }
cmd_daemonlog(){ local n="${1:-30}"; echo "--- guard.log（模块守护）---"; tail -n "$n" "$LOG_FILE" 2>/dev/null; }

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
    local m; m=$(active_mode)
    # 后台异步下发，WebUI 调用不阻塞（真正的写入在后台跑，守护每轮兜底）
    apply_mode_freq_bg "$m"
    echo "OK 频率配置下发中（模式 ${m}）"
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
cmd_aethersetbatch() {
    # 入参两种：① 标准输入 pkg<TAB>cluster（多行）；② 单个位置参数 base64(同上)
    # cluster=auto 表示移除该包自定义
    if [ -n "$1" ]; then
        has base64 || { echo "ERR 缺少 base64"; return 1; }
        local d="${TMPD}/aetherbatch.b64"
        printf '%s' "$1" > "$d"
        if base64 -d "$d" 2>/dev/null | sh "$AETHER_CTL" setbatch 2>&1; then :; fi
    else
        sh "$AETHER_CTL" setbatch 2>&1
    fi
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
  profilebackup) cmd_profilebackup ;;
  profilerestore) cmd_profilerestore "$@" ;;
  profilelist)   cmd_profilelist ;;
  mode)          cmd_mode ;;
  modeset)       cmd_modeset "$2" ;;
  freqs)         cmd_freqs ;;
  freqview)      cmd_freqview ;;
  freqsave)      cmd_freqsave "$2" ;;
  freqedit)      cmd_freqedit "$2" ;;
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
  aethersetbatch) cmd_aethersetbatch "$2" ;;
  *) echo "err: unknown command '$1'"; exit 1 ;;
esac
