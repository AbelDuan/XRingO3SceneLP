#!/system/bin/sh
# ============================================================
#  webui.sh —— WebUI 后端（两模块版：频率 / 线程）
# ------------------------------------------------------------
#  设计原则：前端只传简单参数，所有路径 / 权限 / 备份 / 自检都在本脚本里。
#  文件写入走 base64 分块（wbegin → wappend ×N → wcommit）。
#
#  子命令
#   —— 频率（交给 调度App）——
#    status           状态（K=V）
#    read <id>        读文件到 stdout（id: profile/model/...）
#    wbegin/wappend/wcommit <id>  分块写（profile 等）
#    b64len/b64 <id>  分片读（大文件）
#    conf <name>      读 features/<name>.conf
#    scheme <name> | restore   切换 / 恢复频率方案
#    schemes          列出可选频率方案
#    mode | modeset   读模式阶梯 / 切换全局模式
#    modeset          切换全局模式
#    freqs            三簇可用频率档位
#    appmodes/setappmode  应用→模式（调度App 频率档位）
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
MODDIR="${MODDIR:-/data/adb/modules/O3CPUSet}"
. "$MODDIR/lib/util.sh"

STATE_DIR="/data/adb/O3CPUSet"
WEB_DIR="${STATE_DIR}/webui"
BKDIR="${STATE_DIR}/backups"
TMPD="/data/local/tmp/_wui"
SCHEME=$(active_scheme); [ -z "$SCHEME" ] && SCHEME="sweet_bal"
MODCFG="${MODDIR}/Config/4+4+2/O3/${SCHEME}"
AETHER_CTL="$MODDIR/Scripts/4+4+2/O3/aether/aether_ctl.sh"
# ★ 本模块专属的 aether-optext 二进制完整路径（用于「是否运行中」判定与启停）。
#   设备上存在另一个同名 KSU 模块 aether-optext（/data/adb/modules/aether-optext/aether-optext），
#   其进程 cmdline 也含 "aether-optext"。若用 pgrep -f "aether-optext" 会误判那个兄弟模块的进程，
#   导致本模块「线程引擎启用后仍显示未运行 / 误判运行中」。
#   ⚠ 双重坑：本模块路径含 "4+4+2"，「+」是正则元字符，pgrep -f 必须转义，否则匹配不到本模块进程。
AETHER_BIN_PATH="$MODDIR/Scripts/4+4+2/O3/aether/aether-optext"
# 转义后的正则（供 pgrep -f / pkill -f 精确匹配本模块进程）
AETHER_BIN_RE="$AETHER_BIN_PATH"
AETHER_BIN_RE=$(printf '%s' "$AETHER_BIN_RE" | sed 's/[][\.*+?(){}|^$]/\\&/g')
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
cmd_conf() { echo "ERR v18 起不再读取 调度App features 配置"; return 1; }

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

# 批量读三簇（L/M/P）频率 + 温度，一次 awk 读完所有节点。
#   ⚠ 每个 `cat` 都是 20~25ms 的 fork；原来 status 要 17 次 cat ≈ 400ms，
#     切到 CPU 频率页明显卡。批量读后只剩 1 个 awk。
#   输出与逐 cat 完全一致（不存在 / 无权限的节点输出空串）。
_sysfs_dump() {
    awk 'function g(f){ if((getline v < f)>0){close(f);return v} close(f); return "" }
         BEGIN{
    b="/sys/devices/system/cpu/cpu"
    split("L 0 M 4 P 8", C, " ")
    for(i=1;i<=6;i+=2){ cl=C[i]; c=C[i+1]
        printf "QMAX_%s=%s\n", cl, g(b c "/qos/max_freq")
        printf "QMIN_%s=%s\n", cl, g(b c "/qos/min_freq")
        printf "SCMAX_%s=%s\n", cl, g(b c "/cpufreq/scaling_max_freq")
        printf "SCUR_%s=%s\n", cl, g(b c "/cpufreq/scaling_cur_freq")
        printf "HWMAX_%s=%s\n", cl, g(b c "/cpufreq/cpuinfo_max_freq")
    }
    printf "TEMP_CPU0=%s\n", g("/sys/class/thermal/thermal_zone9/temp")
    printf "TEMP_CPU8=%s\n", g("/sys/class/thermal/thermal_zone1/temp")
    }' 2>/dev/null
}

# 批量读「档位/上限」类节点（freqview 用）：一次 awk 替代 12 次 cat fork。
_sysfs_dump_steps() {
    awk 'function g(f){ if((getline v < f)>0){close(f);return v} close(f); return "" }
         BEGIN{
    b="/sys/devices/system/cpu/cpu"
    split("L 0 M 4 P 8", C, " ")
    for(i=1;i<=6;i+=2){ cl=C[i]; c=C[i+1]
        printf "STEPS_%s=%s\n", cl, g(b c "/cpufreq/scaling_available_frequencies")
        printf "HWMAX_%s=%s\n", cl, g(b c "/cpufreq/cpuinfo_max_freq")
        printf "QMAX_%s=%s\n",  cl, g(b c "/qos/max_freq")
        printf "QMIN_%s=%s\n",  cl, g(b c "/qos/min_freq")
    }
    }' 2>/dev/null
}

cmd_status() {
    echo "VER=$(grep -m1 '^version=' "$MODDIR/module.prop" 2>/dev/null | cut -d= -f2-)"
    echo "MODNAME=$(grep -m1 '^name=' "$MODDIR/module.prop" 2>/dev/null | cut -d= -f2-)"
    echo "SCHEME=${SCHEME}"
    settings_load
    echo "DEBUG=${SET_DEBUG:-1}"
    pgrep -f "O3/guard\.sh" >/dev/null 2>&1 && echo "DAEMON=1" || echo "DAEMON=0"
    # 调度守护
    pgrep -f scene-daemon >/dev/null 2>&1 && echo "app_DAEMON=1" || echo "app_DAEMON=0"
    # 三簇频率 + 温度：一次 awk 批量读（原来 17 次 cat fork ≈ 400ms，切页卡顿主因）
    local _sf _pinned=0 _v _k
    _sf=$(_sysfs_dump)
    printf '%s\n' "$_sf"
    for _k in L M P; do
        _v=$(printf '%s\n' "$_sf" | sed -n "s/^QMIN_${_k}=//p")
        [ -n "$_v" ] && [ "$_v" = "$(printf '%s\n' "$_sf" | sed -n "s/^QMAX_${_k}=//p")" ] && _pinned=$((_pinned+1))
    done
    echo "FREQ_PINNED=${_pinned}"
    # 当前模式
    local cm; cm=$(active_mode); echo "MODE=${cm}"; echo "MODE_CN=$(mode_name_cn "$cm")"; echo "MODE_LIST=${MODE_LIST}"
    local m cn af inf
    for m in $MODE_LIST; do
        cn=$(mode_name_cn "$m"); af=$(mode_freq "$m" active); inf=$(mode_freq "$m" inactive)
        echo "MODE_${m}=${cn}|${af}|${inf}"
    done
    echo "KSU_UPDATE_MARK=$([ -e "$MODDIR/update" ] && echo 1 || echo 0)"
    # —— 艇长线程引擎 ——
    #   ⚠ 必须按本模块自己的二进制路径判定「是否运行中」：设备上存在另一个同名
    #      KSU 模块 aether-optext，其进程 cmdline 也含 aether-optext，用裸露
    #      pgrep -f "aether-optext" 会误命中它 →「启用后仍显示未运行 / 误判运行中」。
    echo "AETHER_ON=$(sh "$AETHER_CTL" ison 2>/dev/null)"
    local _apids; _apids=$(pgrep -f "$AETHER_BIN_RE" 2>/dev/null | tr '\n' ',' | sed 's/,$//')
    if [ -n "$_apids" ]; then echo "AETHER_RUNNING=1"; echo "AETHER_PID=$_apids"; else echo "AETHER_RUNNING=0"; echo "AETHER_PID="; fi
    echo "AETHER_RULES=$(grep -c '\"friendly\"' "$AETHER_CFG" 2>/dev/null)"
    echo "AETHER_BIN=$([ -x "$AETHER_BIN_PATH" ] && echo 1 || echo 0)"
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
    # v18：不再与外部调度App 无障碍服务交互。改为「立即应用模块配置」：
    #   · 按当前全局模式下发 PM QoS 频率；
    #   · 让舰长引擎按最新配置重载（线程配置由 aether_ctl deploy 自持）。
    log "webui: 应用模块配置（频率 + 线程）"
    local m; m=$(active_mode)
    sh "$MODDIR/Scripts/4+4+2/O3/apply_freq.sh" --mode "$m" >/dev/null 2>&1
    [ -x "$AETHER_CTL" ] && sh "$AETHER_CTL" deploy >/dev/null 2>&1
    [ -f "$STATE_DIR/aether.on" ] && [ -x "$AETHER_CTL" ] && sh "$AETHER_CTL" restart >/dev/null 2>&1
    echo "OK 已应用模块配置（频率[${m}] + 舰长线程已重载）"
}

cmd_mode() {
    local cm; cm=$(active_mode); echo "MODE=${cm}"; echo "MODE_CN=$(mode_name_cn "$cm")"; echo "MODE_LIST=${MODE_LIST}"
    local m cn af inf
    for m in $MODE_LIST; do
        cn=$(mode_name_cn "$m"); af=$(mode_freq "$m" active); inf=$(mode_freq "$m" inactive)
        echo "MODE_${m}=${cn}|${af}|${inf}"
    done
    # v18：频率由模块 QoS 接管，无 调度App profile.json 预设校验；频率表恒为模块自带
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
    echo "STOCKMIN_L=$(stock_min_of 0)"; echo "STOCKMIN_M=$(stock_min_of 4)"; echo "STOCKMIN_P=$(stock_min_of 8)"
    # ★ 可用频率表：O3 某些内核不暴露 scaling_available_frequencies（返回空），
    #   导致前端 min/max 下拉退化成「仅当前值」——点开后最低/最高都一样、无法选档。
    #   这里逐簇读取，空了就退回相邻有值的簇 / 内置档位（DEFAULT_TIERS 同款），
    #   保证下拉里始终有「多档可选」。
    #   ⚠ v18.2.8：STEPS/HWMAX/QMAX/QMIN 全部并入 _sysfs_dump 一次 awk 读完
    #   （原来 3 次读 STEPS + 3 次 hwmax + 6 次 qos ≈ 12 个 fork ≈ 300ms，
    #     是切到频率页「卡一下」的主要原因）。
    local _sf sL sM sP
    _sf=$(_sysfs_dump_steps)
    sL=$(printf '%s\n' "$_sf" | sed -n 's/^STEPS_L=//p')
    sM=$(printf '%s\n' "$_sf" | sed -n 's/^STEPS_M=//p')
    sP=$(printf '%s\n' "$_sf" | sed -n 's/^STEPS_P=//p')
    [ -z "$sL" ] && sL="417792 556800 835200 1113600 1497600 1939200 2246400 3148800"
    [ -z "$sM" ] && sM="$sL"
    [ -z "$sP" ] && sP="$sL"
    echo "STEPS_L=$sL"
    echo "STEPS_M=$sM"
    echo "STEPS_P=$sP"
    printf '%s\n' "$_sf" | grep -E "^(HWMAX|QMAX|QMIN)_"
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

# ---------- 频率档位：保存 + 切到该档 + 下发（「应用」按钮）----------
cmd_frequse() {
    local md="$1" b64="$2"
    mode_valid "$md" || { echo "ERR 未知模式: $md"; return 1; }
    local bad; bad=$(freq_write_tiers "$b64")
    [ $? -eq 0 ] || { echo "ERR 保存失败"; return 1; }
    mkdir -p "$STATE_DIR" 2>/dev/null
    printf '%s' "$md" > "${STATE_DIR}/active_mode" 2>/dev/null
    chmod 0666 "${STATE_DIR}/active_mode" 2>/dev/null
    apply_mode_freq_bg "$md"
    echo "OK 已切到 ${md} 并下发（忽略 ${bad} 条非法）"
}

# ---------- 分应用频率（每应用一个模式档，前台时生效）----------
APP_FREQ_FILE="${WEBUI_DIR}/app_freq.tsv"

cmd_appfreq() {
    if [ -s "$APP_FREQ_FILE" ]; then
        awk -F'\t' 'NF>=2 && $1!="" && $1!~/^#/ { print "AF_"$1"="$2 }' "$APP_FREQ_FILE" 2>/dev/null
    fi
    echo "AF_N=$(awk -F"\t" 'NF>=2 && $1!="" && $1!~/^#/' "$APP_FREQ_FILE" 2>/dev/null | wc -l | tr -d ' ')"
}

# 列出设备上的应用（供「分应用频率 / 线程」的搜索添加用）
#   ⚠ v18.2.x 修正：原版只走 aether_ctl apps，若它因任何原因返回空（如 cmd 不可用、
#      线程引擎未启用等）就会「读不出有界面的 app」。改为：
#        1) aether_ctl apps 可用且非空 → 直接用它（含 系统/第三方 标记 + 艇长配置状态）；
#        2) 否则退回「完整 UI 应用清单」(cmd package query-activities)；
#        3) 再不行退回 pm list packages（含第三方，标 sys=0）。
#      三档兜底保证搜索框始终能列出本机应用。
cmd_appfreqapps() {
    local ctl="$MODDIR/Scripts/4+4+2/O3/aether/aether_ctl.sh"
    local out=""
    [ -f "$ctl" ] && out=$(sh "$ctl" apps 2>/dev/null)
    if [ -n "$out" ]; then
        printf '%s\n' "$out"
        return 0
    fi
    # 兜底 2：完整启动器应用清单
    if has cmd; then
        out=$(cmd package query-activities --brief -a android.intent.action.MAIN -c android.intent.category.LAUNCHER 2>/dev/null \
              | sed -n 's#^[[:space:]]*\([^/][^/]*\)/.*#APP=\1|0#p' | sort -u)
        [ -n "$out" ] && { printf '%s\n' "$out"; return 0; }
    fi
    # 兜底 3：全部包（第三方优先标 0）
    if has pm; then
        out=$(pm list packages 2>/dev/null | sed 's/^package://' | while IFS= read -r p; do
            [ -n "$p" ] && printf 'APP=%s|0\n' "$p"
        done)
        [ -n "$out" ] && { printf '%s\n' "$out"; return 0; }
    fi
    echo ""
}

cmd_appfreqset() {
    local pkg="$1" md="$2"
    [ -n "$pkg" ] || { echo "ERR 缺少包名"; return 1; }
    mode_valid "$md" || { echo "ERR 未知模式: $md"; return 1; }
    case "$pkg" in *[!A-Za-z0-9._:-]*) echo "ERR 包名非法"; return 1 ;; esac
    mkdir -p "$WEBUI_DIR" 2>/dev/null
    local tmp="${TMPD}/app_freq.new"
    : > "$tmp"
    if [ -s "$APP_FREQ_FILE" ]; then
        awk -F'\t' -v P="$pkg" '!($1==P)' "$APP_FREQ_FILE" >> "$tmp" 2>/dev/null
    fi
    printf '%s\t%s\n' "$pkg" "$md" >> "$tmp"
    cp -f "$tmp" "$APP_FREQ_FILE" 2>/dev/null; chmod 0666 "$APP_FREQ_FILE" 2>/dev/null; rm -f "$tmp"
    echo "OK 已为 ${pkg} 设置 ${md}"
}

cmd_appfreqdel() {
    local pkg="$1"
    [ -n "$pkg" ] || { echo "ERR 缺少包名"; return 1; }
    [ -s "$APP_FREQ_FILE" ] || { echo "OK 无此配置"; return 0; }
    local tmp="${TMPD}/app_freq.new"
    awk -F'\t' -v P="$pkg" '!($1==P)' "$APP_FREQ_FILE" > "$tmp" 2>/dev/null
    cp -f "$tmp" "$APP_FREQ_FILE" 2>/dev/null; chmod 0666 "$APP_FREQ_FILE" 2>/dev/null; rm -f "$tmp"
    # 若被删的正是当前前台覆盖档，立刻回落全局模式
    local cm; cm=$(active_mode)
    apply_mode_freq_bg "${cm:-balance}"
    echo "OK 已移除 ${pkg}"
}

cmd_appfreqbatch() {
    local src="$1"
    [ -n "$src" ] || { echo "ERR 缺少输入"; return 1; }
    has base64 || { echo "ERR 缺少 base64"; return 1; }
    local tmp="${TMPD}/app_freq.b64"
    printf '%s' "$src" > "$tmp"
    local lines; lines=$(base64 -d "$tmp" 2>/dev/null)
    rm -f "$tmp"
    [ -n "$lines" ] || { echo "ERR 输入为空"; return 1; }
    local n=0 p m
    printf '%s\n' "$lines" | while IFS='	' read -r p m; do
        [ -z "$p" ] && continue
        cmd_appfreqset "$p" "$m" >/dev/null 2>&1 && n=$((n+1))
    done
    echo "OK 批量设置完成"
}

cmd_freqs() {
    echo "FREQS_L=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_frequencies 2>/dev/null)"
    echo "FREQS_M=$(cat /sys/devices/system/cpu/cpu4/cpufreq/scaling_available_frequencies 2>/dev/null)"
    echo "FREQS_P=$(cat /sys/devices/system/cpu/cpu8/cpufreq/scaling_available_frequencies 2>/dev/null)"
    echo "HWMAX_L=$(hwmax 0)"; echo "HWMAX_M=$(hwmax 4)"; echo "HWMAX_P=$(hwmax 8)"
}

cmd_appmodes() {
    # v18.2.9：直接按月自持的 assign 表输出（game_assign 优先、app_assign 兜底），
    # 原来依赖的 app_pkg_modes 已随老线程链路移除。
    echo "DEFAULT=$(active_mode)"
    local pm="${TMPD}/pkgmode.txt"
    : > "$pm"
    [ -s "$GAME_ASSIGN_FILE" ] && awk -F'\t' 'NF>=2 && $1!="" && $1!~/^#/{print $1"\t"$2}' "$GAME_ASSIGN_FILE" >> "$pm" 2>/dev/null
    [ -s "$APP_ASSIGN_FILE" ]  && awk -F'\t' 'NF>=2 && $1!="" && $1!~/^#/{print $1"\t"$2}' "$APP_ASSIGN_FILE"  >> "$pm" 2>/dev/null
    local md n
    for md in $MODE_LIST; do n=$(awk -F'\t' -v m="$md" '$2==m' "$pm" 2>/dev/null | wc -l | tr -d ' '); echo "COUNT_${md}=${n:-0}"; done
    echo "TOTAL=$(wc -l < "$pm" 2>/dev/null | tr -d ' ')"
    awk -F'\t' 'NF==2 && $2!="" { print "A_"$1"="$2 }' "$pm"
}
cmd_setappmode() {
    # v18：写入模块自有的 app_assign.tsv（pkg<TAB>mode），调度App 不再参与
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
    # 线程不再由这里联动重建（v18.2.9：线程完全归舰长，档位由 WebUI 线程页单独设置）
    echo "OK 已把 ${pkg} 设为模块频率档「${mode}」"
}

cmd_fasxres() {
    echo "ERR v18 起调速器不再写入 调度App features/fas.conf；O3 的 FAS 由内核 schedutil/xres 直接管理，无需模块干预"
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
        if [ -d /data/adb/modules_update/O3CPUSet ]; then echo "OK 已合并待更新副本 + 清标记 + 重拉服务"; else echo "OK 已清孤儿 update 标记"; fi
    else echo "ERR 待更新副本校验不通过，已保留副本未删除"; fi
}

cmd_live() {
    local m; m=$(active_mode)
    # 后台异步下发，WebUI 调用不阻塞（真正的写入在后台跑，守护每轮兜底）
    apply_mode_freq_bg "$m"
    echo "OK 频率配置下发中（模式 ${m}）"
}

# 自愈：若调度守护没在跑，由 WebUI/action 打开时拉起它（免重启）。
#  判定与 guard.sh 单例一致：仅当 /proc/$pid/cmdline 含 guard.sh 才算活着，
#  避免陈旧 pidfile + pid 回收复用造成的「假已运行」。
cmd_ensureguard() {
    local pf="${STATE_DIR}/guard.pid" pid="" alive=0
    [ -f "$pf" ] && pid=$(cat "$pf" 2>/dev/null)
    if [ -n "$pid" ] && [ -r "/proc/$pid/cmdline" ] && case "$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)" in *guard.sh*) ;; *) false ;; esac; then
        alive=1
    else
        # 再兜底扫一遍进程表，防止 pidfile 丢失但进程还在
        for d in /proc/[0-9]*; do
            [ -r "$d/cmdline" ] || continue
            case "$(tr '\0' ' ' < "$d/cmdline" 2>/dev/null)" in
                *guard.sh*) alive=1; pid="${d#/proc/}"; break ;;
            esac
        done
    fi
    if [ "$alive" = "1" ]; then
        echo "OK 守护已在运行（pid $pid）"
        return 0
    fi
    local g="$MODDIR/Scripts/4+4+2/O3/guard.sh"
    [ -f "$g" ] || { echo "ERR 找不到 guard.sh"; return 1; }
    nohup sh "$g" </dev/null >> "$LOG_FILE" 2>&1 &
    sleep 1
    echo "OK 已重新拉起调度守护（pid $!）"
}

# 应用元信息兜底（当 WebUI 桥没有 getPackagesInfo 时）：
#   输出 PKG=<pkg>\t<label>\t<sys(1/0)>。label 用兄弟模块自带 aapt 解析 APK：
#     优先中文 application-label-zh-CN（再 zh-*），最后才用默认 application-label
#     ——修「应用名全是英文」。结果写进 pkg_labels.tsv 缓存，只对未命中的包跑 aapt
#     ——修「加载太慢」（首次只解析可见切片，之后命中缓存近乎瞬时）。
#   系统/第三方以 pm path 落在 /system|/vendor|/product|/system_ext 判定。
PKGINFO_AAPT=""
for _pa in /data/adb/modules/Hyper_MagicWindow/common/utils/aapt /data/adb/modules/*/common/utils/aapt; do
    [ -x "$_pa" ] && { PKGINFO_AAPT="$_pa"; break; }
done
PKG_LABEL_CACHE="${WEBUI_DIR}/pkg_labels.tsv"
_cmd_pkginfo_one() {   # $1=pkg；输出该包 label（含缓存写回）
    local pkg="$1" apk label sys=0 l bad
    apk=$(pm path "$pkg" 2>/dev/null | head -1 | sed 's/package://')
    case "$apk" in /system/*|/vendor/*|/product/*|/system_ext/*|/odm/*) sys=1 ;; esac
    label="$pkg"
    if [ -n "$PKGINFO_AAPT" ] && [ -n "$apk" ]; then
        bad=$("$PKGINFO_AAPT" d badging "$apk" 2>/dev/null)
        # ① 简体中文 ② 其它中文变体 ③ 默认（多为英文）
        l=$(printf '%s\n' "$bad" | grep -m1 "^application-label-zh-CN:'" | sed "s/^[^:]*:'//;s/'$//")
        [ -z "$l" ] && l=$(printf '%s\n' "$bad" | grep -m1 -E "^application-label-zh(-[A-Za-z-]+)?'" | sed "s/^[^:]*:'//;s/'$//")
        [ -z "$l" ] && l=$(printf '%s\n' "$bad" | grep -m1 "^application-label:'" | sed "s/^[^:]*:'//;s/'$//")
        [ -n "$l" ] && label="$l"
    fi
    printf '%s\t%s\t%s\n' "$pkg" "$label" "$sys" >> "$PKG_LABEL_CACHE" 2>/dev/null
    echo "$label	$sys"
}
cmd_pkginfo() {
    local pkgs="$1"; [ -n "$pkgs" ] || { echo "ERR 缺少包名列表"; return 1; }
    mkdir -p "$WEBUI_DIR" 2>/dev/null
    [ -f "$PKG_LABEL_CACHE" ] || : > "$PKG_LABEL_CACHE"
    echo "$pkgs" | while IFS= read -r pkg; do
        [ -z "$pkg" ] && continue
        # 命中缓存 → 直接回（跳过 aapt，瞬时）
        local hit; hit=$(awk -F'\t' -v P="$pkg" '$1==P{print $2"\t"$3; exit}' "$PKG_LABEL_CACHE" 2>/dev/null)
        if [ -n "$hit" ]; then echo "PKG=${pkg}	${hit}"; continue; fi
        # 未命中 → aapt 解析（zh 优先）并写回缓存
        echo "PKG=${pkg}	$(_cmd_pkginfo_one "$pkg")"
    done
}

# 取某簇「最接近目标频率、且不超过目标」的可用档位（目标用于省电上限）。
#   $1=可用档位(空格分隔,升序)  $2=目标Hz  →  返回 ≤目标 的最高档；若全超目标则返回最低档。
nearest_le() {
    local steps="$1" t="$2" best="" b=0
    for s in $steps; do
        [ -z "$best" ] && best="$s"
        if [ "$s" -le "$t" ]; then best="$s"; fi
    done
    echo "$best"
}
# 取某簇「绝对最接近目标」的可用档位（大核用：档位稀疏，2G 附近只有 2.04G 一档，
# 若强行取 ≤2G 会掉到 1.49G，反而把大核压死）。
nearest_abs() {
    local steps="$1" t="$2" best="" bd=999999999
    for s in $steps; do
        local d=$(( s > t ? s - t : t - s ))
        if [ "$d" -lt "$bd" ]; then bd="$d"; best="$s"; fi
    done
    echo "$best"
}

# 省电默认：把「省电模式」的预设频率按本机可用档位对齐到
#   小核/中核 ≈1.5~1.6GHz、大核 ≈2.0GHz 附近（取 ≤目标 的最高可用档），
#   并把全局默认模式设为 powersave、立即下发。
#   说明：玄戒O3 的能效点目前没有公开的逐频功耗表，最接近「能效行」的可行取法就是
#   「落到目标上限以下的最高可用档位」——既压住峰值功耗，又不至于卡在低能效的极低频。
cmd_powersave_default() {
    # 可用档位（缺则退回内置）
    local sL sM sP
    sL=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_frequencies 2>/dev/null)
    sM=$(cat /sys/devices/system/cpu/cpu4/cpufreq/scaling_available_frequencies 2>/dev/null)
    sP=$(cat /sys/devices/system/cpu/cpu8/cpufreq/scaling_available_frequencies 2>/dev/null)
    [ -z "$sL" ] && sL="417792 556800 835200 1113600 1497600 1939200 2246400 3148800"
    [ -z "$sM" ] && sM="$sL"
    [ -z "$sP" ] && sP="$sL"
    local lmax mmax pmax
    # 小核：≤1.56G 的最高档（实测 1.5G 档即 1497600，能效区）
    lmax=$(nearest_le "$sL" 1560000); [ -z "$lmax" ] && lmax=$(echo $sL | awk '{print $1}')
    # 中核：≤1.55G 的最高档。O3 实测「中核 1550MHz 以上纯浪费」，故硬顶在 1.55G，
    #       本机档位落到 1468800（1.47G）。
    mmax=$(nearest_le "$sM" 1550000); [ -z "$mmax" ] && mmax=$(echo $sM | awk '{print $1}')
    # 大核：取最接近 2.0G 的档。本机 2G 附近只有 2044800 一档，用绝对最近避免掉到 1.49G。
    pmax=$(nearest_abs "$sP" 2000000); [ -z "$pmax" ] && pmax=$(echo $sP | awk '{print $1}')
    # 下限用各簇 stock 地板（放开低频睡眠），上限即上面的省电上限。
    # freq_write_tiers 的入参是 base64；传空串则从 stdin 读明文（每行 mode<TAB>六值）。
    local bad rc
    bad=$(freq_write_tiers "" <<EOF
powersave	417792 ${lmax} 556800 ${mmax} 1113600 ${pmax}
EOF
)
    rc=$?
    [ "$rc" -eq 0 ] || { echo "ERR 写入省电档失败（freq_write_tiers rc=$rc）"; return 1; }
    mkdir -p "$STATE_DIR" 2>/dev/null
    printf '%s' "powersave" > "${STATE_DIR}/active_mode" 2>/dev/null
    chmod 0666 "${STATE_DIR}/active_mode" 2>/dev/null
    apply_mode_freq_bg "powersave"
    echo "OK 已将省电档设为默认（小≤${lmax} 中≤${mmax} 大≤${pmax}）并立即下发"
}

# ============================================================
#  线程接管（艇长 Aether）—— 角色档 → 分进程五层策略
#   ⚠ 不再暴露「应用→单核簇」：模板由 aether_ctl 的 tpl_cpuset 展开成
#     主线程 / 最重线程 / 重线程 / 按线程名 comm 路由 / 其余 五层。
# ============================================================
cmd_aether() {
    sh "$AETHER_CTL" status 2>&1
    emit_topo
    sh "$AETHER_CTL" featlist 2>&1
    sh "$AETHER_CTL" rules 2>&1
}

# 真实 CPU 拓扑：从 /sys cpufreq policy 读出各簇核区间，按 cpuinfo_max_freq 由低到高
#   排成 小核(E) → 中核(P1) → 大核(HP)。aether 的 detect_topo 有时返回空，这里兜底，
#   保证 WebUI「拓扑」行显示真实簇区间（如 0-3）而不是一排横杠。
_topo_fmt_cpus() {   # "0 1 2 3" -> "0-3"；"8 9" -> "8-9"；非连续则逗号分段
    local in="$1" out="" start="" prev="" c
    for c in $in; do
        [ -z "$start" ] && { start=$c; prev=$c; continue; }
        if [ "$c" -eq $((prev+1)) ] 2>/dev/null; then prev=$c; continue; fi
        if [ "$start" = "$prev" ]; then out="${out:+$out,}$start"; else out="${out:+$out,}$start-$prev"; fi
        start=$c; prev=$c
    done
    [ -n "$start" ] || { echo ""; return; }
    if [ "$start" = "$prev" ]; then out="${out:+$out,}$start"; else out="${out:+$out,}$start-$prev"; fi
    echo "$out"
}
emit_topo() {
    local p cpus mx lines="" i=0
    for p in /sys/devices/system/cpu/cpufreq/policy*; do
        [ -d "$p" ] || continue
        cpus=$(_topo_fmt_cpus "$(cat "$p/related_cpus" 2>/dev/null)")
        mx=$(cat "$p/cpuinfo_max_freq" 2>/dev/null || echo 0)
        [ -z "$cpus" ] && continue
        lines="${lines}${mx} ${cpus}
"
        i=$((i+1))
    done
    [ "$i" -eq 0 ] && return 0
    # 按 max_freq 升序（小→大），取前 3 簇分别作为 E / P1 / HP
    local sorted; sorted=$(printf '%s' "$lines" | sort -n | cut -d' ' -f2)
    local e p1 hp
    e=$(printf '%s\n' "$sorted" | sed -n '1p')
    p1=$(printf '%s\n' "$sorted" | sed -n '2p')
    hp=$(printf '%s\n' "$sorted" | sed -n '3p')
    [ -z "$p1" ] && p1="$e"
    [ -z "$hp" ] && hp="${p1:-$e}"
    echo "TOPO_E=$e"; echo "TOPO_P1=$p1"; echo "TOPO_HP=$hp"
    echo "TOPO_CLUSTERS=$i"
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
    sh "$AETHER_CTL" feat "$1" "$2" 2>&1
    [ -n "$2" ] && sh "$AETHER_CTL" restart >/dev/null 2>&1
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

# ---------- 应用级线程档位（角色档，不是单簇核位）----------
cmd_aetherapps() { sh "$AETHER_CTL" apps 2>&1; }
cmd_aetherset() {
    [ -n "$2" ] || { echo "ERR 用法: aetherset <包名> <角色档>"; return 1; }
    sh "$AETHER_CTL" set "$2" "$3" 2>&1
}
cmd_aetherdel() {
    [ -n "$2" ] || { echo "ERR 用法: aetherdel <包名>"; return 1; }
    sh "$AETHER_CTL" del "$2" 2>&1
}
cmd_aethersetbatch() {
    # 入参两种：① 标准输入 pkg<TAB>role（多行）；② 单个位置参数 base64(同上)
    # role=auto 表示移除该包自定义
    if [ -n "$1" ]; then
        has base64 || { echo "ERR 缺少 base64"; return 1; }
        local d="${TMPD}/aetherbatch.b64"
        printf '%s' "$1" > "$d"
        base64 -d "$d" 2>/dev/null | sh "$AETHER_CTL" setbatch 2>&1
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
  # （profilebackup/restore/list 已随 profile_sync.sh 一并移除：v18 模块自持，不再向外部 App 灌配置）
  mode)          cmd_mode ;;
  modeset)       cmd_modeset "$2" ;;
  freqs)         cmd_freqs ;;
  freqview)      cmd_freqview ;;
  freqsave)      cmd_freqsave "$2" ;;
  frequse)       cmd_frequse "$2" "$3" ;;
  freqedit)      cmd_freqedit "$2" ;;
  appfreq)       cmd_appfreq ;;
  appfreqapps)   cmd_appfreqapps ;;
  appfreqset)    cmd_appfreqset "$2" "$3" ;;
  appfreqdel)    cmd_appfreqdel "$2" ;;
  appfreqbatch)  cmd_appfreqbatch "$2" ;;
  appmodes)      cmd_appmodes ;;
  setappmode)    shift; cmd_setappmode "$1" "$2" ;;
  fasxres)       cmd_fasxres ;;
  log)           cmd_log "$2" ;;
  daemonlog)     cmd_daemonlog "$2" ;;
  launchables)   cmd_launchables ;;
  apps)          cmd_apps ;;
  ksufix)        cmd_ksufix ;;
  live)          cmd_live ;;
  ensureguard)   cmd_ensureguard ;;
  powersave_default) cmd_powersave_default ;;
  pkginfo)       cmd_pkginfo "$2" ;;
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
