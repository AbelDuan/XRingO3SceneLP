#!/system/bin/sh
# ============================================================
#  webui.sh —— WebUI 后端（唯一有权写配置的入口）
#
#  设计原则
#    · 前端只传「简单参数」，所有路径 / 权限 / SELinux / 备份 / 自检都在本脚本里，
#      避免把 shell 逻辑散进 JS（引号地狱 + 无法审计）。
#    · 文件写入走 base64 分块：wbegin → wappend ×N → wcommit。
#      不用 heredoc、不用命令行内嵌内容，彻底规避引号 / ARG_MAX / 编码问题。
#    · 每次写入前自动备份，写入后结构自检 + 通过才落盘（失败保留旧文件）。
#    · 每次写入自动把同一份内容同步进模块 Config 目录（用户铁律：配置必须固化进模块）。
#
#  用法:  sh webui.sh <子命令> [参数...]
#  子命令
#    status                       状态（K=V 行）
#    read   <id>                  读文件到 stdout
#    wbegin <id> / wappend <id> <b64> / wcommit <id>
#    conf   <name>                读 features/<name>.conf
#    apply                        让配置生效（重绑 Scene 无障碍 + 重启 daemon）
#    lock | unlock | repair       已废除锁定 ⇒ 三者都等价于「修复可写性」
#    scene                        Scene 实时状态握手（WebUI 打开/刷新时用）
#    topo                         拓扑与语义占位符映射
#    scheme <name> | restore      切换/落地方案、恢复出厂频率
#    mode | modeset <模式>        读模式阶梯 / 切换全局模式（省电|流畅|性能|极速）
#    profilepush | profilebackup | profilerestore | profilelist
#                                  传递/备份/恢复/列出调度配置
#    importscene                  从 Scene 一次性导入档位（不实时跟随）
#    syncmode                     按当前档位表重建线程分配 + 全量落核
#    ksufix                       删除 KSU 孤儿 update 标记（修复开关点不动）
#    live                         让配置生效（轻量：校正开关 + 重启核心分配服务）
#    fasxres                      把 Scene 的 FAS 调速器（features/fas.conf 三簇）统一为 xres
#    apps                         应用清单（兜底用；正常路径走桥的 listPackages）
#    launchables                  有前台界面（启动器能点开）的包清单 —— 应用页过滤用
#    log [n] | daemonlog [n]      日志
# ============================================================
MODDIR="${MODDIR:-/data/adb/modules/SceneO3Tuner}"
. "$MODDIR/lib/util.sh"

STATE_DIR="/data/adb/SceneO3Tuner"
WEB_DIR="${STATE_DIR}/webui"
BKDIR="${STATE_DIR}/backups"
TMPD="/data/local/tmp/_wui"
SCHEME=$(active_scheme); [ -z "$SCHEME" ] && SCHEME="sweet_bal"
MODCFG="${MODDIR}/Config/4+4+2/O3/${SCHEME}"

mkdir -p "$WEB_DIR" "$BKDIR" "$TMPD" 2>/dev/null

# ---------- 访问即自愈：合并 KSU 待更新副本（免重启）----------
#  本机禁止重启，而 KSU 更新已存在模块走「暂存 + 待重启」。
#  customize.sh 收尾的异步自愈若因后台进程被回收而没兜住，这里兜底：
#  用户一打开 WebUI（本脚本每次都被调用）就触发合并，把 modules_update 合进
#  正在服务的 modules/<id>，清标记、拉服务。只在新版本暂存副本存在时才动作，
#  否则零开销直接返回。
selfheal_pending_update

has(){ command -v "$1" >/dev/null 2>&1; }

# ---------- 文件 ID → 真实路径（白名单，杜绝任意路径写入）----------
path_of() {
    case "$1" in
      threads)            echo "${SCENE_DIR}/threads.json" ;;
      games)              echo "${SCENE_DIR}/_Games.json" ;;
      profile)            echo "${SCENE_DIR}/profile.json" ;;
      model)              echo "${WEB_DIR}/model.json" ;;
      activemode)         echo "${STATE_DIR}/active_mode" ;;
      gamesjson)          echo "${MODCFG}/threads_games.json" ;;
      gametpl)            echo "${WEBUI_DIR}/game_templates.tsv" ;;
      gameassign)         echo "${WEBUI_DIR}/game_assign.tsv" ;;
      apptpl)             echo "${WEBUI_DIR}/app_templates.tsv" ;;
      appassign)          echo "${WEBUI_DIR}/app_assign.tsv" ;;
      settings)           echo "${WEBUI_DIR}/settings.conf" ;;
      conf:cpuset)        echo "${SCENE_DIR}/features/cpuset.conf" ;;
      *) echo "" ;;
    esac
}
# 同名文件在模块 Config 目录里的对应路径（用于自动固化）
modpath_of() {
    case "$1" in
      threads) echo "${MODCFG}/threads.json" ;;
      games)   echo "${MODCFG}/_Games.json" ;;
      profile) echo "${MODCFG}/profile.json" ;;
      conf:*)  echo "${MODCFG}/features/${1#conf:}.conf" ;;
      gamesjson) echo "${MODCFG}/threads_games.json" ;;
      *) echo "" ;;
    esac
}
# ---------- 结构自检 / 权限：已提到 lib/util.sh ----------
# ⚠ 原先 validate() / perm_file() / first_sig() / last_sig() 只在本文件里定义，
#   而 lib/util.sh 的 gen_threads_from_scene() 也要用它们（守护会调用）——
#   结果是守护调用时 command not found、静默失败。现在统一放在公共库。
#   这里刻意不再重复定义：两份实现必然发散。

# ---------- 写：分块接收 ----------
cmd_wbegin() { : > "${TMPD}/$1.b64"; : > "${TMPD}/$1.raw"; }
cmd_wappend() {
    [ -f "${TMPD}/$1.b64" ] || return 1
    printf '%s' "$2" >> "${TMPD}/$1.b64"
    return 0
}
cmd_wcommit() {
    local id="$1" b64="${TMPD}/$1.b64" raw="${TMPD}/$1.raw" dst mod
    dst=$(path_of "$id"); [ -z "$dst" ] && { echo "ERR 未知文件 id: $id"; return 1; }

    if has base64; then base64 -d "$b64" > "$raw" 2>/dev/null
    elif [ -x "$BB" ]; then "$BB" base64 -d "$b64" > "$raw" 2>/dev/null
    else echo "ERR 缺少 base64 工具"; return 1; fi
    [ -s "$raw" ] || { echo "ERR base64 解码结果为空"; return 1; }

    # ⚠ 行式配置文件（TSV）必须以保证结尾有换行再落盘：
    #   否则下一次 `while read` 会丢掉最后一行（见上）。
    case "$id" in
      appassign|gameassign|apptpl|gametpl)
        if [ -n "$(tail -c 1 "$raw" 2>/dev/null)" ]; then
            printf '\n' >> "$raw"
        fi
        ;;
    esac

    local bad; bad=$(validate "$id" "$raw")
    if [ -n "$bad" ]; then echo "ERR 自检未通过：$bad"; return 1; fi

    # 备份（保留最近 30 份）
    if [ -f "$dst" ]; then
        local ts; ts=$(date +%Y%m%d_%H%M%S)
        cp -af "$dst" "${BKDIR}/$(echo "$id" | tr ':' '_').${ts}.bak" 2>/dev/null
        ls -1t "${BKDIR}/" 2>/dev/null | tail -n +31 | while read -r o; do
            rm -f "${BKDIR}/${o}" 2>/dev/null
        done
    fi

    # 覆盖目标文件。
    # ⚠ 必须用 write_replace（替换 inode），不能只用 cp -f：
    #   实测个别 inode 即使 chattr 标志已清也仍拒写（open 返回 ENOTSUP），
    #   只有 unlink 重建才能落地 —— write_replace 内部就是这么兜底的。
    case "$id" in
      model|activemode|gametpl|gameassign|apptpl|appassign|settings) ;;
      *) unlock_tree "$SCENE_DIR" ;;
    esac
    write_replace "$raw" "$dst" || { echo "ERR 覆盖失败: $dst"; return 1; }
    case "$id" in
      model|activemode|gametpl|gameassign|apptpl|appassign|settings) chmod 0666 "$dst"; chown 0:0 "$dst" 2>/dev/null ;;
      *) perm_file "$dst"; ensure_scene_dir_perm >/dev/null 2>&1 ;;
    esac

    # 自动固化进模块 Config（用户铁律）
    mod=$(modpath_of "$id")
    if [ -n "$mod" ] && [ -d "$(dirname "$mod")" ]; then
        cp -f "$raw" "$mod" 2>/dev/null
        chmod 0644 "$mod" 2>/dev/null; chown 0:0 "$mod" 2>/dev/null
        log_quiet "webui: ${id} → scene + module 已同步（$(wc -c < "$raw" | tr -d ' ') B）"
    else
        log_quiet "webui: ${id} 已写入（$(wc -c < "$raw" | tr -d ' ') B）"
    fi

    # 不再恢复加锁 —— 锁定机制已废除（实测会让 Scene 自己存不下配置）。
    # 详见 lib/util.sh 顶部关于「文件锁已废弃」的说明。

    # 开关状态变了 → 同步刷新模块卡片上的「功能状态」描述
    case "$id" in settings) update_module_desc >/dev/null 2>&1 ;; esac

    echo "OK $(wc -c < "$raw" | tr -d ' ')"
}

# ---------- 读 ----------
cmd_read() {
    local p; p=$(path_of "$1")
    [ -z "$p" ] && { echo ""; return 1; }
    [ -f "$p" ] && cat "$p" || echo ""
}
# base64 读取（分片）：规避大 stdout 被截断，也规避 CRLF / 二进制污染
B64BIN="base64"
{ [ -x /system/bin/base64 ] && B64BIN=/system/bin/base64; } 2>/dev/null
if ! command -v "$B64BIN" >/dev/null 2>&1; then
    [ -x "$BB" ] && B64BIN="$BB base64"
fi
cmd_b64len() {
    local p; p=$(path_of "$1"); [ -f "$p" ] || { echo 0; return; }
    $B64BIN "$p" 2>/dev/null | tr -d '\n' | wc -c | tr -d ' '
}
cmd_b64() {   # $1=id $2=start(1-based) $3=len
    local p; p=$(path_of "$1"); [ -f "$p" ] || return 0
    local s="${2:-1}" n="${3:-40000}"
    $B64BIN "$p" 2>/dev/null | tr -d '\n' | cut -c "${s}-$(( s + n - 1 ))"
}
cmd_conf() {
    local p="${SCENE_DIR}/features/$1.conf"
    [ -f "$p" ] && cat "$p" || echo ""
}

# ============================================================
#  「有前台界面」的包清单（应用页过滤用）
# ------------------------------------------------------------
#  判据：能响应 [MAIN + LAUNCHER] 的 Activity —— 也就是**启动器里能点开的应用**。
#  为什么需要：`pm list packages` 那 480+ 个包里有一大半是**没有界面的系统服务/组件**
#  （各种 xxx.provider / xxx.service），给它们绑核既没意义，还可能把系统服务限制坏。
#  实测（本机）：487 个已装包 → 169 个有启动器入口。
#
#  ⚠ 输出必须剥掉前导空格：query-activities 的格式是
#       "170 activities found:" + "  Activity #0:" + "    priority=..." + "    pkg/Act"
#     只有最后一种带 `/`，所以按「有 `/` 的行」取第一段并去空白。
#  ⚠ 拿不到（老版本无 `cmd package query-activities`）就输出空 —— 前端见到空会**不筛选**，
#    宁可多显示，也不能让应用列表变空。
cmd_launchables() {
    cmd package query-activities --brief -a android.intent.action.MAIN \
        -c android.intent.category.LAUNCHER 2>/dev/null \
      | sed -n 's#^[[:space:]]*\([^/][^/]*\)/.*#\1#p' \
      | sort -u
}

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
    echo "SCHEME_CN=$(scheme_name_cn "$SCHEME")"
    # 「配置锁定」功能已按用户要求删除（历史上 chattr +i 会让 Scene 自己存不下配置）
    settings_load
    echo "MODE_SYNC=${SET_MODE_SYNC:-0}"
    echo "FREQ_SYNC=${SET_FREQ_SYNC:-0}"
    echo "DEBUG=${SET_DEBUG:-1}"
    pgrep -f scene-daemon >/dev/null 2>&1 && echo "DAEMON=1" || echo "DAEMON=0"
    # 无障碍服务是否绑定：只读 settings（实测 dumpsys accessibility 要 ~1s，
    # 而 status 会随保存/轮询频繁调用，是"界面卡顿"的主要来源之一）。
    local acc=0
    case "$(settings get secure enabled_accessibility_services 2>/dev/null)" in
      *omarea.vtools*) acc=1 ;;
    esac
    echo "ACC=${acc}"
    pgrep -f "O3/guard\.sh" >/dev/null 2>&1 && echo "GUARD=1" || echo "GUARD=0"

    # Scene 的调度配置是否完整。
    # ⚠ Scene 按 manifest.json 的 name/version + profileInstalled 校验「调度是否已安装」，
    #   一旦标识变了它会**删掉** profile.json/manifest.json/_Apps.json/_Games.json/
    #   _Camera.json/_ELP.json 并清空 objects/、features/ —— 表现就是「Scene 丢失配置」。
    #   这里主动查一遍，前端据此提示用户点「传递调度」把内置配置灌回去。
    {
        local miss="" f
        for f in profile.json manifest.json _Apps.json _Games.json _Camera.json _ELP.json powercfg.sh; do
            [ -f "${SCENE_DIR}/${f}" ] || miss="$miss $f"
        done
        if [ -n "$miss" ]; then
            echo "PROFILE_OK=0"
            echo "PROFILE_MISS=${miss# }"
        else
            echo "PROFILE_OK=1"
        fi
    }
    # files/objects/<mode> 是 Scene **安装**调度时由 profile.json 展开出来的运行产物。
    #   实测本机（Scene 9.3 / HyperOS）这个目录一直是 0 项，包括 Scene 自己装好方案之后，
    #   所以它**不能**用来判断"Scene 有没有启用调度"。真正可靠的判据是 Scene 调节页里
    #   配置行显示的是方案名（正常）还是「未知」（= 没选中任何方案）。
    {
        local n
        n=$(ls -1 "${SCENE_DIR}/objects" 2>/dev/null | wc -l | tr -d ' ')
        echo "SCENE_OBJ=${n:-0}"
    }
    # Scene 当前的「配置身份」（manifest.json 的 author / version）—— 调节页显示的就是它。
    #   ✅ 我们的配置启用后应是 `SCENE9'LP`（调节页显示 SCENE9 + 🌐 Version: LP 20260916）。
    #   · 若是 `SCENE9'9.0 Customized` → 说明 Scene 在用它的内置「自定义」，没读我们的配置。
    #   · 若是 `Unofficial'9.0 Outside` → Scene 认为这是未命名外部配置。
    if [ -f "${SCENE_DIR}/manifest.json" ]; then
        echo "SCENE_AUTHOR=$(sed -n 's/.*\"author\"[ ]*:[ ]*\"\([^\"]*\)\".*/\1/p' "${SCENE_DIR}/manifest.json" 2>/dev/null | head -1)"
        echo "SCENE_ID=$(sed -n 's/.*\"version\"[ ]*:[ ]*\"\([^\"]*\)\".*/\1/p' "${SCENE_DIR}/manifest.json" 2>/dev/null | head -1)"
    fi
    # Scene 的「配置来源」= 它当前启用的是哪一套（决定它读不读我们的 profile.json）。
    #   SOURCE_SCENE_ONLINE   ★ 我们要的：显示「Scene / Version: LP」且能启用
    #   SOURCE_SCENE_CUSTOM   能启用，但显示成「自定义」
    #   SOURCE_OUTSIDE        外部配置通道 —— 实测 Scene 判定其无效、性能调节打不开
    echo "SCENE_SOURCE=$(scene_source_get)"
    # 「性能调节」总开关（Scene 调节页右上角那个 Switch）。
    #   为 false 时 Scene 完全不下发调度 → 用户看到的就是「配置无法启用」。
    echo "SCENE_DYN=$(scene_dyn_get)"

    # 频率：三簇
    local c l
    for pair in "L 0" "M 4" "P 8"; do
        set -- $pair; l=$1; c=$2
        # ⚠「当前实际上限」= min(SCMAX, QMAX)。两者都要报：
        #   · SCMAX = cpufreq 的有效上限（平台/xres 按 thermal 持续改写它）
        #   · QMAX  = 我们写的 PM QoS 硬上限（内核强制执行）
        #   之前前端只显示 QMAX，于是极速档显示成 4.36G（硬件最高）而实际被
        #   SCMAX 压到 1.9G —— 这就是用户说的「当前实际上限似乎也不准」。
        echo "SCMAX_${l}=$(scmax $c)"
        echo "SCMIN_${l}=$(scmin $c)"
        echo "SCUR_${l}=$(scur $c)"
        echo "QMAX_${l}=$(qmax $c)"
        echo "QMIN_${l}=$(qmin $c)"
        echo "HWMAX_${l}=$(hwmax $c)"
    done
    # 是否被钉在最低频（最常见的故障态）
    local pinned=0
    for c in 0 4 8; do
        local a b; a=$(scmax $c); b=$(scmin $c)
        [ -n "$a" ] && [ "$a" = "$b" ] && pinned=$((pinned+1))
    done
    echo "FREQ_PINNED=${pinned}"

    echo "TEMP_CPU0=$(tempof 9)"
    echo "TEMP_CPU8=$(tempof 1)"

    # threads.json
    local tf="${SCENE_DIR}/threads.json"
    echo "THREADS_BYTES=$(wc -c < "$tf" 2>/dev/null | tr -d ' ')"
    echo "THREADS_MD5=$(md5of "$tf")"
    echo "THREADS_RULES=$(grep -c '"friendly"' "$tf" 2>/dev/null)"
    [ -f "${WEB_DIR}/model.json" ] && echo "MODEL=1" || echo "MODEL=0"

    # KSU 孤儿 update 标记
    [ -e "$MODDIR/update" ] && echo "KSU_UPDATE_MARK=1" || echo "KSU_UPDATE_MARK=0"

    # 当前模式 + 模式阶梯（前端渲染 4 个模式卡用）
    local cm; cm=$(active_mode)
    echo "MODE=${cm}"
    echo "MODE_CN=$(mode_name_cn "$cm")"
    echo "MODE_LIST=${MODE_LIST}"
    local m cn af inf
    for m in $MODE_LIST; do
        cn=$(mode_name_cn "$m"); af=$(mode_freq "$m" active)
        inf=$(mode_freq "$m" inactive)
        echo "MODE_${m}=${cn}|${af}|${inf}"
    done
    local pc; pc=$(preset_check)
    [ -z "$pc" ] && echo "PRESET_OK=1" || { echo "PRESET_OK=0"; echo "PRESET_BAD=${pc}"; }

    # 核心分配必需的三项开关（不暴露给用户，但缺一不可）
    local cf="${SCENE_DIR}/features/cpuset.conf" ok=1
    for kv in use_presets in_apps in_games; do
        [ "$(sed -n "s/^${kv}=//p" "$cf" 2>/dev/null | head -1)" = "1" ] || ok=0
    done
    echo "CONF_OK=${ok}"
}

# ============================================================
#  健康检查（精简版 · 只留真正会导致"改了不生效"的项）
# ============================================================

# ============================================================
#  动作
# ============================================================
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
    if [ "$ok" -ge 2 ]; then echo "OK 已重绑无障碍并重启 daemon"; else echo "WARN 重绑完成但状态不完整（daemon/无障碍之一未就绪），可再执行一次"; fi
}

# 锁定机制已废除 ⇒ lock/unlock 都等价于「修复可写性」
cmd_scheme(){ sh "$MODDIR/Scripts/4+4+2/O3/set_scheme.sh" "$1"; }
cmd_restore(){ sh "$MODDIR/Scripts/4+4+2/O3/set_scheme.sh" restore; }

# 频率落地：**只写 PM QoS**（cpuN/qos/{max,min}_freq）。
#
# ⚠ 不要写 cpufreq/scaling_max_freq。实测两件事：
#   1) 它的权限会被 MIUI 在运行时改掉，写它会 Permission denied（10 个核全失败）；
#   2) 它本质是**动态回读值**——写 QoS 之后它会自己跟随，而 MIUI 又会按负载/温度
#      持续把它往下调（实测：freqfix 后 1641600/1804800/2044800 → 静置 20s 变成
#      912000/1468800/2044800 → 加负载又抬起来）。
#      也就是说它根本不是"旋钮"，拿它判断"是否卡死"会得到假警报。
# QoS 才是内核强制执行的硬上下限，也是本模块唯一的限频手段。
#
# 注意：不要把累加逻辑放进嵌套函数（依赖 local 的动态作用域，跨 shell 不稳），一律内联。
# Scene 的「应用 → 模式」表（供前端展示；不写任何东西）
cmd_appmodes() {
    echo "SCENE_DEFAULT=$(scene_default_mode)"
    local pm="${TMPD}/pkgmode.txt"
    scene_pkg_modes > "$pm"
    local md n
    for md in $MODE_LIST; do
        n=$(awk -F'\t' -v m="$md" '$2==m' "$pm" | wc -l | tr -d ' ')
        echo "COUNT_${md}=${n:-0}"
    done
    echo "TOTAL=$(wc -l < "$pm" | tr -d ' ')"
    awk -F'\t' 'NF==2 { print "A_"$1"="$2 }' "$pm"
    # OWN_ = 「在 Scene 里显式设过模式」的包（powercfg.xml 里有条目的）。
    # ⚠ 不能拿 A_ 当「自定义」，因为 scene_pkg_modes 会给**每个**已安装应用都填上
    #   生效模式（未单独设置的填全局默认）——那样前端会把所有应用都当成自定义的。
    scene_mode_map 2>/dev/null | awk -F'\t' '$1!="*" && $1!="" { print "OWN_"$1"="$2 }'
}

# 按模板重建线程分配 + 强制落核（Scene 不读我们的 threads.json，见 enforce_threads.sh）
# ============================================================
#  单个应用在 Scene 里的模式（写 shared_prefs/powercfg.xml）
# ------------------------------------------------------------
#  应用页点「Scene 省电」那个标签就用它。Scene 自己把「哪个应用什么模式」
#  存在 powercfg.xml，我们改的是同一份文件（enforce_threads.sh 也直接读它）。
#  ⚠ 写前备份、写后校验、失败回滚 —— 这个文件是 Scene 全部单应用设置的唯一副本。
#  ⚠ Scene 正在运行时，它内存里的那份有可能在下次提交偏好时覆盖回来；
#    实测多数情况能留住（它不会主动整份重写），若发现被回滚，去 Scene 里改一次即可。
# ============================================================
# ============================================================
#  从 Scene 导入档位（v10）
# ------------------------------------------------------------
#  把 Scene powercfg.xml 里「单独设过模式」的应用，按**同名档位**合并进
#  app_assign.tsv —— powersave/balance/performance/fast 一一对应，不再查映射表。
#    · 只覆盖 Scene 里显式设过模式的条目，其余条目原样保留（不整表重建）
#    · 导入前备份分配表（保留最近 3 份）
#    · 立刻重建 threads.json + 落核，不用等守护周期
#  与旧 applymodes 的区别：旧版是「实时跟随」（Scene 一改模式线程就跟着漂，
#  还会和手动套用打架）；新版是显式的一次性动作，用户不点就不动。
# ============================================================
cmd_importscene() {
    local asg="$APP_ASSIGN_FILE"
    mkdir -p "$TMPD" "${STATE_DIR}/backup" 2>/dev/null

    if [ -f "$asg" ]; then
        cp -f "$asg" "${STATE_DIR}/backup/app_assign.$(date '+%H%M%S').tsv" 2>/dev/null
        ls -1t "${STATE_DIR}/backup/"app_assign.*.tsv 2>/dev/null \
          | tail -n +4 | while IFS= read -r f; do rm -f "$f" 2>/dev/null; done
    fi

    local r; r=$(import_scene_apply app)
    case "$r" in ERR*) echo "$r"; return 1 ;; esac

    local so; so=$(gen_threads_from_scene 2>&1)
    sh "$MODDIR/Scripts/4+4+2/O3/enforce_threads.sh" >/dev/null 2>&1
    echo "$r"
    echo "   ${so}"
}

cmd_setappmode() {
    local pkg="$1" mode="$2" uid tmp bak
    if [ -z "$pkg" ] || [ -z "$mode" ]; then
        echo "ERR 用法: setappmode <包名> <powersave|balance|performance|fast>"; return 1
    fi
    mode_valid "$mode" || { echo "ERR 非法模式: $mode"; return 1; }
    case "$pkg" in *'/'*|*'"'*|*'<'*|*'>'*) echo "ERR 包名含非法字符"; return 1 ;; esac
    [ -f "$SCENE_POWERCFG" ] || { echo "ERR 找不到 powercfg.xml"; return 1; }

    tmp="${TMPD}/pc.xml.new"; bak="${TMPD}/pc.xml.bak"
    mkdir -p "$TMPD" 2>/dev/null
    cp -af "$SCENE_POWERCFG" "$bak" 2>/dev/null

    if grep -q "<string name=\"${pkg}\">" "$SCENE_POWERCFG" 2>/dev/null; then
        sed "s|<string name=\"${pkg}\">[^<]*</string>|<string name=\"${pkg}\">${mode}</string>|" \
            "$SCENE_POWERCFG" > "$tmp" 2>/dev/null
    else
        sed "s|</map>|    <string name=\"${pkg}\">${mode}</string>\n</map>|" \
            "$SCENE_POWERCFG" > "$tmp" 2>/dev/null
    fi
    [ -s "$tmp" ] || { rm -f "$tmp"; echo "ERR 生成新 powercfg.xml 失败"; return 1; }

    uid=$(get_package_uid "$SCENE_PKG"); [ -n "$uid" ] || uid=10321
    write_replace "$tmp" "$SCENE_POWERCFG" || { rm -f "$tmp"; echo "ERR 写入 powercfg.xml 失败"; return 1; }
    rm -f "$tmp" 2>/dev/null
    chown "${uid}:${uid}" "$SCENE_POWERCFG" 2>/dev/null
    chmod 0660 "$SCENE_POWERCFG" 2>/dev/null

    if ! grep -q "<string name=\"${pkg}\">${mode}</string>" "$SCENE_POWERCFG" 2>/dev/null; then
        if [ -f "$bak" ]; then
            write_replace "$bak" "$SCENE_POWERCFG" >/dev/null 2>&1
            chown "${uid}:${uid}" "$SCENE_POWERCFG" 2>/dev/null
            chmod 0660 "$SCENE_POWERCFG" 2>/dev/null
        fi
        rm -f "$bak" 2>/dev/null
        echo "ERR 写入后校验失败（已回滚）"; return 1
    fi
    rm -f "$bak" 2>/dev/null

    # ⚠ 刻意**不**重启 scene-daemon：它读到新值的时机不可控，重启还要等好几秒 ——
    #   那就是「点一下标签要等好几秒」的元凶。
    #   注意：这里改的是 **Scene 的频率档位**（powercfg.xml），不是模块的线程档位。
    #   v10 起模块线程档位由 app_assign.tsv 自持，落核器不再读 powercfg.xml，
    #   所以改完只需重建展示用的 threads.json + 落核一次（毫秒级）。
    local so; so=$(gen_threads_from_scene 2>&1)
    sh "$MODDIR/Scripts/4+4+2/O3/enforce_threads.sh" "$pkg" >/dev/null 2>&1 &
    echo "OK 已把 ${pkg} 设为 Scene「${mode}」｜${so}"
}

cmd_syncmode() {
    # 「重建线程分配」：按当前 app_assign.tsv / game_assign.tsv 重生成 threads.json
    #   （Scene 界面用的展示副本）并全量落核一次。
    #   ⚠ 刻意**不重启 scene-daemon**：重启只是白等好几秒（甚至触发完整重绑），
    #     而落核本来就是我们自己做的，跟 daemon 无关。
    local so; so=$(gen_threads_from_scene 2>&1) || { echo "$so"; return 1; }
    sh "$MODDIR/Scripts/4+4+2/O3/enforce_threads.sh" >/dev/null 2>&1
    echo "$so"
}

cmd_enforce() { sh "$MODDIR/Scripts/4+4+2/O3/enforce_threads.sh" 2>&1; echo "OK 已按模板落核"; }

# ============================================================
#  scene —— WebUI 打开/刷新时的一次性握手
#  返回 Scene 侧的真实状态，前端据此实时渲染（Scene 是真源，不是我们的模型）。
# ============================================================
cmd_scene() {
    local def; def=$(scene_default_mode)
    echo "SCENE_DEFAULT=${def}"
    echo "SCENE_DEFAULT_CN=$(mode_name_cn "$def")"

    local pm="${TMPD}/pkgmode.txt" gp="${TMPD}/gamepkgs.txt"
    mkdir -p "$TMPD" 2>/dev/null
    scene_pkg_modes > "$pm" 2>/dev/null
    scene_games > "$gp" 2>/dev/null

    echo "TOTAL=$(wc -l < "$pm" 2>/dev/null | tr -d ' ')"
    local md n
    for md in $MODE_LIST; do
        n=$(awk -F'\t' -v m="$md" '$2==m' "$pm" 2>/dev/null | wc -l | tr -d ' ')
        echo "COUNT_${md}=${n:-0}"
    done

    # 游戏名单（Scene 的 games.xml，value=true）
    echo "GAMES=$(tr '\n' ',' < "$gp" 2>/dev/null | sed 's/,$//')"
    echo "GAME_COUNT=$(wc -l < "$gp" 2>/dev/null | tr -d ' ')"

    # 单独指定了模式的应用（≠ 全局默认）——「应用」页只显示这些
    echo "OVERRIDES=$(awk -F'\t' -v d="$def" '$2!=d {printf "%s=%s,", $1, $2}' "$pm" 2>/dev/null | sed 's/,$//')"
    echo "OVERRIDE_COUNT=$(awk -F'\t' -v d="$def" '$2!=d' "$pm" 2>/dev/null | wc -l | tr -d ' ')"

    # 可写性 & 运行态
    can_write "${SCENE_DIR}/profile.json" 2>/dev/null && echo "WRITABLE=1" || echo "WRITABLE=0"
    pgrep -f "O3/guard\.sh" >/dev/null 2>&1 && echo "GUARD=1" || echo "GUARD=0"
    echo "THREADS_RULES=$(grep -c '"friendly"' "${SCENE_DIR}/threads.json" 2>/dev/null)"
    local cf ok=1 kv
    cf="${SCENE_DIR}/features/cpuset.conf"
    for kv in use_presets in_apps in_games; do
        [ "$(sed -n "s/^${kv}=//p" "$cf" 2>/dev/null | head -1)" = "1" ] || ok=0
    done
    echo "CONF_OK=${ok}"

    # 拓扑与语义占位符（前端要用它展示"实际会绑到哪些核"）
    echo "CPU_ONLINE=$(online_cpus)"
    echo "CPU_PRESENT=$(present_cpus)"
    local n
    for n in e_core p1_core p2_core p_core hp_core all_core; do
        echo "SEM_${n}=$(cpu_semantic "$n")|$(clip_online "$(cpu_semantic "$n")")"
    done
    echo "GAME_TPL_HAS=$([ -f "$GAME_TPL_FILE" ] && echo 1 || echo 0)"
    echo "GAME_ASSIGN_HAS=$([ -f "$GAME_ASSIGN_FILE" ] && echo 1 || echo 0)"
    echo "GAME_ASSIGNED=$(awk -F'\t' 'NF>=2 && $1!="" && $1!~/^#/ {n++} END{print n+0}' "$GAME_ASSIGN_FILE" 2>/dev/null)"
}

# 模式 preset 完整性：Scene 侧 8 个 <mode>_active/inactive 是否齐全且含 @cpu_freq
preset_check() {
    local f="${SCENE_DIR}/profile.json"
    [ -f "$f" ] || { echo "profile.json 缺失"; return; }
    local m st missing=""
    for m in $MODE_LIST; do
        for st in active inactive; do
            grep -q "\"${m}_${st}\"" "$f" 2>/dev/null || missing="$missing ${m}_${st}"
        done
    done
    [ -n "$missing" ] && { echo "缺 preset:$missing"; return; }
    local n; n=$(grep -c '@cpu_freq' "$f" 2>/dev/null)
    [ "${n:-0}" -lt 24 ] && { echo "@cpu_freq 只有 ${n:-0} 条（应 ≥24）"; return; }
    echo ""
}

# 只取拓扑与语义占位符映射（前端「游戏」页的模板编辑器要用）
cmd_topo() {
    echo "CPU_ONLINE=$(online_cpus)"
    echo "CPU_PRESENT=$(present_cpus)"
    local n
    for n in e_core p1_core p2_core p_core hp_core all_core; do
        echo "SEM_${n}=$(cpu_semantic "$n")|$(clip_online "$(cpu_semantic "$n")")"
    done
}

cmd_games() {
  seed_game_templates
  local gp="${TMPD}/gp.txt" pm="${TMPD}/pm.txt" asg="$GAME_ASSIGN_FILE" tpl="$GAME_TPL_FILE"
  mkdir -p "$TMPD" 2>/dev/null
  scene_games > "$gp" 2>/dev/null
  scene_pkg_modes > "$pm" 2>/dev/null
  local def; def=$(scene_default_mode)
  # 游戏 → 模式（频率跟随 Scene 对单应用的设置；未单独设则用全局）
  while IFS= read -r g; do
    [ -z "$g" ] && continue
    local m; m=$(awk -F'\t' -v p="$g" '$1==p{print $2; exit}' "$pm" 2>/dev/null)
    [ -z "$m" ] && m="$def"
    echo "GAME=${g}$(printf '\t')${m}"
  done < "$gp"
  # 已分配模板（pkg<TAB>tpl）
  if [ -f "$asg" ]; then
    # ⚠ 必须带 `|| [ -n "$line" ]`：`read` 在文件**没有结尾换行**时会把最后一行
    #   读出来却返回非 0，于是 while 直接结束 —— 最后一行被静默丢掉。
    #   实测症状：app_assign.tsv 最后那个包明明分配了模板，前端却永远显示「未分配」。
    while IFS= read -r line || [ -n "$line" ]; do
      [ -z "$line" ] && continue; case "$line" in \#*) continue ;; esac
      echo "ASSIGN=${line}"
    done < "$asg"
  fi
  # 模板库（id|friendly|other|heaviest_thread|heaviest_cores|heavy_thread|heavy_cores|comm）
  if [ -f "$tpl" ]; then
    awk -F'\t' 'NF>=2 && $0!~/^#/ {printf "TPL=%s|%s|%s|%s|%s|%s|%s|%s\n", $1, $2, $3, $4, $5, $6, $7, $8}' "$tpl" 2>/dev/null
  fi
  # 语义占位符（前端展示「实际会绑到哪些核」）
  echo "CPU_ONLINE=$(online_cpus)"
  local n
  for n in e_core p1_core p2_core p_core hp_core all_core; do
    echo "SEM_${n}=$(cpu_semantic "$n")"
  done
}


cmd_apps_tpl() {
  seed_app_templates
  local asg="$APP_ASSIGN_FILE" tpl="$APP_TPL_FILE" pm="${TMPD}/apm.txt" gp="${TMPD}/gp.txt"
  mkdir -p "$TMPD" 2>/dev/null
  scene_pkg_modes > "$pm" 2>/dev/null
  scene_games > "$gp" 2>/dev/null
  # 已安装、非游戏的应用 → 包名 + 当前模式
  # ⚠ 必须单次 awk：旧写法对每个包都 fork 一次 cut/grep，430 个包 ≈ 1300 个进程，
  #   实测让「应用」页加载要好几秒（用户反馈"套用模板非常卡顿"）。
  awk -F'\t' -v GFP="$gp" '
    BEGIN { while ((getline g < GFP) > 0) if (g != "") G[g] = 1 }
    $1 == "" { next }
    $1 ~ /(overlay|\.rro|auto_generated)/ { next }
    $1 == "android" { next }
    ($1 in G) { next }
    { printf "APP=%s\t%s\n", $1, $2 }
  ' "$pm" 2>/dev/null
  # 已分配模板（pkg<TAB>tpl）
  if [ -f "$asg" ]; then
    # ⚠ 必须带 `|| [ -n "$line" ]`：`read` 在文件**没有结尾换行**时会把最后一行
    #   读出来却返回非 0，于是 while 直接结束 —— 最后一行被静默丢掉。
    #   实测症状：app_assign.tsv 最后那个包明明分配了模板，前端却永远显示「未分配」。
    while IFS= read -r line || [ -n "$line" ]; do
      [ -z "$line" ] && continue; case "$line" in \#*) continue ;; esac
      echo "ASSIGN=${line}"
    done < "$asg"
  fi
  # 模板库（同格式）
  if [ -f "$tpl" ]; then
    awk -F'\t' 'NF>=2 && $0!~/^#/ {printf "TPL=%s|%s|%s|%s|%s|%s|%s|%s\n", $1, $2, $3, $4, $5, $6, $7, $8}' "$tpl" 2>/dev/null
  fi
  echo "CPU_ONLINE=$(online_cpus)"
  local n
  for n in e_core p1_core p2_core p_core hp_core all_core; do
    echo "SEM_${n}=$(cpu_semantic "$n")"
  done
  # ---- 进程级条目（EXTRA=）----
  #  Scene 的 powercfg.xml 里除了包名，还有「进程名」条目，形如
  #    <string name="com.tencent.mm:appbrand">balance</string>
  #  这就是**微信小程序**（小程序跑在 appbrand 进程里）。它不是一个已安装包，
  #  所以不会出现在 scene_pkg_modes 的输出里，用户就没法单独给它套模板。
  #  enforce_threads.sh 是按 `ps -A -o ARGS` 的**进程名**匹配的，这种带冒号的名字
  #  能真正命中 → 所以这里把它作为「可配置条目」补出来。
  #  ⚠ 只补带 ":" 的（进程名）。Activity 名（含 "." 但无 ":"）永远匹配不到进程，
  #    列出来只会制造噪音。
  if [ -f "$SCENE_POWERCFG" ]; then
    awk '
      match($0, /<string name="[^"]*">[^<]*<\/string>/) {
        v = $0; sub(/^.*<string name="[^"]*">/, "", v); sub(/<\/string>.*$/, "", v)
        k = $0; sub(/^.*<string name="/, "", k); sub(/">.*/, "", k)
        if (k != "" && k != "*" && index(k, ":") > 0)
          printf "EXTRA=%s\t%s\n", k, v
      }' "$SCENE_POWERCFG" 2>/dev/null
  fi
  # 注：v10 起档位 id 与模式同名，前端不再需要 MODE2TPL_* 映射表
  echo "APP_TPL_HAS=$([ -f "$APP_TPL_FILE" ] && echo 1 || echo 0)"
  echo "APP_ASSIGNED=$(awk -F'\t' 'NF>=2 && $1!="" && $1!~/^#/ {n++} END{print n+0}' "$APP_ASSIGN_FILE" 2>/dev/null)"
}

# 读模式阶梯（前端启动时取一次）
cmd_mode() {
    local cm; cm=$(active_mode)
    echo "MODE=${cm}"
    echo "MODE_CN=$(mode_name_cn "$cm")"
    echo "MODE_LIST=${MODE_LIST}"
    local m cn af inf daf dinf
    for m in $MODE_LIST; do
        cn=$(mode_name_cn "$m"); af=$(mode_freq "$m" active)
        inf=$(mode_freq "$m" inactive)
        echo "MODE_${m}=${cn}|${af}|${inf}"
        # 模块**内置**默认频率（「模式」页「恢复默认频率」按钮用）。
        # 与 profile.json 里读到的现值分开报，前端才知道该恢复成什么。
        daf=$(mode_freq "$m" active); dinf=$(mode_freq "$m" inactive)
        echo "DEF_${m}_active=${daf}"
        echo "DEF_${m}_inactive=${dinf}"
    done
    local pc; pc=$(preset_check)
    [ -z "$pc" ] && echo "PRESET_OK=1" || { echo "PRESET_OK=0"; echo "PRESET_BAD=${pc}"; }
}

# 切换全局模式：只落地 active_mode（线程分配由前端重新生成的 threads.json 承担，
# 频率由 Scene 的模式 preset 承担 —— 两边都不需要重启任何东西）。
cmd_modeset() {
    local m; m=$(mode_from_cn "$1")
    mode_valid "$m" || { echo "ERR 未知模式: $1（可用: $MODE_LIST / 省电|流畅|性能|极速）"; return 1; }
    mkdir -p "$STATE_DIR"
    echo "$m" > "${STATE_DIR}/active_mode"
    log "webui: 全局模式 → $m（$(mode_name_cn "$m")）"
    echo "OK $(mode_name_cn "$m")"
}

# ------------------------------------------------------------
#  四档核心集合：读 / 写（v16.18 · WebUI「模式」页可自定义）
# ------------------------------------------------------------
#  配置文件 $SCHED_CORES_FILE，每行： <mode>\t<baseline>\t<esc>
#    baseline = 中低负载线程的基线核位（同步写进该档模板的 other/heaviest）
#    esc      = 高负载线程的升级目标（"-" = 本档不升级）
#  只接受 SCHED_CORES_VALID 里那 6 个集合，防手滑写进 0-9。
#  该档模板里「其余线程」的内置核位（用于前端显示默认值）
sched_cores_template_other() {
    # 单一来源：lib/util.sh 的 sched_cores_default_base（避免两处漂移）
    sched_cores_default_base "$1"
}

cmd_schedcores() {
    local m
    for m in $MODE_LIST; do
        local row esc esc_def base base_def cn
        row=$(mode_sched_row "$m")
        esc_def=$(printf '%s' "$row" | cut -d' ' -f3)
        base_def=$(sched_cores_template_other "$m")
        esc="$esc_def"; base="$base_def"
        # ⚠ 列序：文件是 <base>\t<esc>，所以第 1 列 → base、第 2 列 → esc
        sched_cores_lookup "$m" 1 && sched_cores_valid "$SCV" && base="$SCV"
        sched_cores_lookup "$m" 2 && sched_cores_valid "$SCV" && esc="$SCV"
        cn=$(mode_name_cn "$m")
        echo "SC_${m}=${cn}|${base}|${esc}|${base_def}|${esc_def}"
    done
    echo "SC_VALID=${SCHED_CORES_VALID}"
    echo "SC_FILE=${SCHED_CORES_FILE}"
    echo "SC_HAS=$([ -f "$SCHED_CORES_FILE" ] && echo 1 || echo 0)"
}

#  把某档模板里 other/heaviest 的核位改成给定集合（用 plain 核位，选什么就是什么）
sched_cores_apply_template() {   # $1=mode $2=coreset
    local m="$1" cs="$2" t
    for t in "$APP_TPL_FILE" "$GAME_TPL_FILE"; do
        [ -f "$t" ] || continue
        awk -F'\t' -v OFS='\t' -v M="$m" -v C="$cs" '
          /^#/ { print; next }
          $1 == M { $3 = C; if ($5 != "") $5 = C; print; next }
          { print }
        ' "$t" > "${TMPD}/sc.tpl" 2>/dev/null
        if [ -s "${TMPD}/sc.tpl" ] && ! cmp -s "${TMPD}/sc.tpl" "$t"; then
            write_replace "${TMPD}/sc.tpl" "$t" && chmod 0666 "$t" 2>/dev/null
        fi
        rm -f "${TMPD}/sc.tpl" 2>/dev/null
    done
}

cmd_setschedcores() {   # $1=mode $2=baseline $3=esc
    local m; m=$(mode_from_cn "$1")
    mode_valid "$m" || { echo "ERR 未知模式: $1"; return 1; }
    local base="$2" esc="$3"
    sched_cores_valid "$base" || { echo "ERR 非法基线核位: ${base:-空}（可选 ${SCHED_CORES_VALID}）"; return 1; }
    sched_cores_valid "$esc"  || { echo "ERR 非法升级目标: ${esc:-空}（可选 ${SCHED_CORES_VALID} 或 -）"; return 1; }
    mkdir -p "$(dirname "$SCHED_CORES_FILE")" 2>/dev/null
    local tmp="${TMPD}/sc.new" x e2 b2
    : > "$tmp"
    for x in $MODE_LIST; do
        if [ "$x" = "$m" ]; then
            b2="$base"; e2="$esc"
        else
            # ⚠ 文件列序是 <base>\t<esc>，别接反（真机实测接反过）
            b2=$(sched_cores_template_other "$x")
            e2=$(mode_sched_row "$x" | cut -d' ' -f3)
            sched_cores_lookup "$x" 1 && sched_cores_valid "$SCV" && b2="$SCV"
            sched_cores_lookup "$x" 2 && sched_cores_valid "$SCV" && e2="$SCV"
        fi
        printf '%s\t%s\t%s\n' "$x" "$b2" "$e2" >> "$tmp"
    done
    write_replace "$tmp" "$SCHED_CORES_FILE" && chmod 0666 "$SCHED_CORES_FILE" 2>/dev/null
    rm -f "$tmp" 2>/dev/null
    log "webui: $m 核心集合 → 基线 $base / 升级 $esc"
    sched_cores_apply_template "$m" "$base"
    # 立刻重算一次（新基线要靠模板生效；升/降档由本轮的 hot 重算承担）
    sh "$MODDIR/Scripts/4+4+2/O3/enforce_threads.sh" >/dev/null 2>&1
    echo "OK $(mode_name_cn "$m")：基线 $base / 升级 $esc"
}


# 校正核心分配的必需开关（用户不需要看见它们，但缺一就不生效）
# 只动这三个键，其余（gold_first / ebpf_enhanced / perf_notify…）保持用户在 Scene 里的选择。
ensure_required_flags() {
    local cf="${SCENE_DIR}/features/cpuset.conf"
    [ -f "$cf" ] || { echo 0; return; }
    local need=0 kv
    for kv in use_presets in_apps in_games; do
        [ "$(sed -n "s/^${kv}=//p" "$cf" 2>/dev/null | head -1)" = "1" ] || need=1
    done
    [ "$need" = "0" ] && { echo 0; return; }
    local tmp="${TMPD}/cpuset.new"
    cp -f "$cf" "$tmp" 2>/dev/null || { echo 0; return; }
    awk -F= -v OFS='=' '
        /^use_presets=/ { $2=1; u=1 }
        /^in_apps=/     { $2=1; i=1 }
        /^in_games=/    { $2=1; g=1 }
        { print }
        END { if(!u) print "use_presets=1"; if(!i) print "in_apps=1"; if(!g) print "in_games=1" }
    ' "$tmp" > "${tmp}.2" 2>/dev/null && mv -f "${tmp}.2" "$tmp"
    write_replace "$tmp" "$cf" || { echo 0; return; }
    perm_file "$cf"
    log "webui: 已校正 cpuset.conf 必需开关"
    echo 1
}

# restart_scene_daemon() 已迁到 lib/util.sh（profile_sync.sh 也要用，那边取不到本文件）。
# 定义见 lib/util.sh 的「重启 Scene 核心分配服务」小节。

# 让配置生效（轻量）：只重启核心分配服务，不动 Scene 进程、不重绑无障碍。
# 频率不在这里处理 —— Scene 的模式 preset（@cpu_freq）自己会随模式/前后台下发。
# 依据：实测 scene-daemon 被 kill 后由 Scene 自身在 4~8 秒内自动拉起，
#       且新配置会随应用切前台实时读取 —— 因此这是最短路径。
# 若 15 秒内没起来，自动升级为完整重绑（重绑会短暂切走前台，所以只作兜底）。
cmd_live() {
    local f; f=$(ensure_required_flags)
    # 顺手按模板重建线程分配：这样「让配置生效」一次就把
    # 开关校正 + 线程分配 + 服务重启 三件事做完，用户不用点两下。
    local so; so=$(gen_threads_from_scene 2>&1)
    local pid; pid=$(restart_scene_daemon) || return 1
    log "webui: live flags_fixed=$f"
    local rules; rules=$(grep -c '"friendly"' "${SCENE_DIR}/threads.json" 2>/dev/null)
    echo "OK 配置已下发（核心分配 PID ${pid}，${rules:-0} 条规则）｜${so}"
}

cmd_ksufix() {
    # 先尝试合并 KSU 待更新副本（modules_update → modules），再清孤儿标记。
    # 单独删 update 标记而不合并，会让「旧模块继续服务」——开关虽能点，但内容还是旧的。
    if selfheal_pending_update; then
        if [ -e "$MODDIR/update" ]; then
            rm -f "$MODDIR/update"
            log "webui: 已删除 KSU 孤儿 update 标记"
        fi
        if [ -d /data/adb/modules_update/SceneO3Tuner ]; then
            echo "OK 已合并待更新副本 + 清标记 + 重拉服务（开关恢复可点、内容已更新）"
        else
            echo "OK 已清孤儿 update 标记（无待更新副本，无需合并）"
        fi
    else
        echo "ERR 待更新副本校验不通过，已保留副本未删除（请检查 /data/adb/modules_update/SceneO3Tuner 完整性）"
    fi
}

cmd_apps() {
    if has cmd; then
        cmd package list packages 2>/dev/null | sed 's/^package://' | while read -r p; do
            case "$p" in
              *overlay*|*.rro*|*.auto_generated*|android|*shared_library*) continue ;;
            esac
            echo "$p"
        done
    else
        pm list packages 2>/dev/null | sed 's/^package://'
    fi
}

# 三簇真实可用频率档位（前端滑块必须用真档位，不能按等差数列猜）
cmd_freqs() {
    echo "FREQS_L=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_frequencies 2>/dev/null)"
    echo "FREQS_M=$(cat /sys/devices/system/cpu/cpu4/cpufreq/scaling_available_frequencies 2>/dev/null)"
    echo "FREQS_P=$(cat /sys/devices/system/cpu/cpu8/cpufreq/scaling_available_frequencies 2>/dev/null)"
    echo "HWMAX_L=$(hwmax 0)"
    echo "HWMAX_M=$(hwmax 4)"
    echo "HWMAX_P=$(hwmax 8)"
}

# ============================================================
#  Scene 的 FAS 调速器：一键统一为 xres（游戏页的按钮）
# ------------------------------------------------------------
#  为什么需要这个按钮：
#    · O3 三簇**实际只有** xres / conservative / powersave / performance / schedutil，
#      且「CPU 控制」页默认值、profile.json 各模式 preset（12 处）都是 xres；
#    · 但 Scene 的「FAS 调速器」候选是**它 APK 里硬编码的**（O3 上只有
#      auto / performance / conservative —— 反汇编 a.sq0.d() 得到），UI 里选不到 xres，
#      于是「FAS/FEAS 工作期间」这几簇的调速器就可能不是 xres，与其余三处不一致；
#    · Scene 不校验写入值（实测写 xres 后重启 daemon 被原样保留），所以直接写文件有效。
#  动作：features/fas.conf 的 governor_{little,middle,prime} → xres，然后重启 scene-daemon
#        （这几个键它只在启动时读一次，不重启不生效）。
#  ⚠ 副作用与 customize.sh 的 e) 步一致：FAS 运行期间改用 xres 调速，属既定设计。
cmd_fasxres() {
    local f="${SCENE_DIR}/features/fas.conf"
    [ -f "$f" ] || { echo "ERR 找不到 features/fas.conf（Scene 目录不可读？）"; return 1; }

    # 读现三值（分开读是为了回显能写成 小/中/大，而不是含糊的一串）
    local ol om op
    ol=$(sed -n 's/^governor_little=//p' "$f" 2>/dev/null | head -1)
    om=$(sed -n 's/^governor_middle=//p' "$f" 2>/dev/null | head -1)
    op=$(sed -n 's/^governor_prime=//p'  "$f" 2>/dev/null | head -1)

    local tmp="${TMPD}/fas.conf.new"
    awk -F= -v OFS='=' '
        /^governor_little=/ { $2="xres"; a=1 }
        /^governor_middle=/ { $2="xres"; b=1 }
        /^governor_prime=/  { $2="xres"; c=1 }
        { print }
        END {
            if(!a) print "governor_little=xres"
            if(!b) print "governor_middle=xres"
            if(!c) print "governor_prime=xres"
        }
    ' "$f" > "$tmp" 2>/dev/null || { echo "ERR 生成新 fas.conf 失败"; return 1; }
    # 先自检：行数不能变少、必须三条 governor_ 都在（防 awk 把文件写坏）
    local n_old n_new
    n_old=$(grep -c . "$f" 2>/dev/null); n_new=$(grep -c . "$tmp" 2>/dev/null)
    if [ "${n_new:-0}" -lt "${n_old:-0}" ] || [ "$(grep -c '^governor_' "$tmp" 2>/dev/null)" -lt 3 ]; then
        rm -f "$tmp"; echo "ERR 新内容自检未过（行数 $n_old→$n_new），已放弃写入"; return 1
    fi
    if ! write_replace "$tmp" "$f"; then rm -f "$tmp"; echo "ERR 写回 fas.conf 失败"; return 1; fi
    perm_file "$f"
    rm -f "$tmp"

    local nl nm np
    nl=$(sed -n 's/^governor_little=//p' "$f" 2>/dev/null | head -1)
    nm=$(sed -n 's/^governor_middle=//p' "$f" 2>/dev/null | head -1)
    np=$(sed -n 's/^governor_prime=//p'  "$f" 2>/dev/null | head -1)
    restart_scene_daemon >/dev/null 2>&1
    log_quiet "fasxres: ${ol:-?}/${om:-?}/${op:-?} -> ${nl:-?}/${nm:-?}/${np:-?}"
    echo "OK FAS 调速器已设为 ${nl:-?}/${nm:-?}/${np:-?}（原 ${ol:-?}/${om:-?}/${op:-?}）· scene-daemon 已重启"
}

cmd_log(){ tail -n "${1:-40}" "$LOG_FILE" 2>/dev/null; }
cmd_daemonlog(){
    local n="${1:-30}"
    echo "--- daemon.log ---"
    tail -n "$n" "${SCENE_DIR}/daemon.log" 2>/dev/null
    echo "--- daemon.stderr.log ---"
    tail -n "$n" "${SCENE_DIR}/daemon.stderr.log" 2>/dev/null
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
  scene)         cmd_scene ;;
  topo)          cmd_topo ;;
  games)         cmd_games ;;
  apps_tpl)      cmd_apps_tpl ;;
  scheme)        cmd_scheme "$2" ;;
  restore)       cmd_restore ;;
  # 调度配置：传递（内置默认 → Scene）/ 备份 / 恢复 / 列出
  profilepush)   shift; sh "$MODDIR/Scripts/4+4+2/O3/profile_sync.sh" push "$1" ;;
  profilebackup) sh "$MODDIR/Scripts/4+4+2/O3/profile_sync.sh" backup ;;
  profilerestore) shift; sh "$MODDIR/Scripts/4+4+2/O3/profile_sync.sh" restore "$1" ;;
  profilelist)   sh "$MODDIR/Scripts/4+4+2/O3/profile_sync.sh" list ;;
  mode)          cmd_mode ;;
  modeset)       cmd_modeset "$2" ;;
  schedcores)    cmd_schedcores ;;
  setschedcores) shift; cmd_setschedcores "$1" "$2" "$3" ;;
  appmodes)      cmd_appmodes ;;
  setappmode)    shift; cmd_setappmode "$1" "$2" ;;
  importscene)   cmd_importscene ;;
  syncmode)      cmd_syncmode ;;
  enforce)       cmd_enforce ;;
  # CPU 调频已交回 Scene 接管；下面两条只做「清理 v2 遗留 QoS 值」的幂等动作
  freqapply)     sh "$MODDIR/Scripts/4+4+2/O3/apply_freq.sh" 2>&1; echo "OK 频率由 Scene 接管（已清理遗留 QoS）" ;;
  freqrestore)   sh "$MODDIR/Scripts/4+4+2/O3/apply_freq.sh" --restore 2>&1; echo "OK 频率由 Scene 接管（已恢复不限频）" ;;
  # 只落核指定的几个包：前端「套用到所选」之后立刻生效用，比全量快得多
  enforcep)      shift; sh "$MODDIR/Scripts/4+4+2/O3/enforce_threads.sh" "$@" >/dev/null 2>&1; echo "OK 已落核 $# 个应用" ;;
  # 「极速」档 = 不绑核 → 切档后要把它从旧绑核里放出来（还原到 cgroup 预算）
  unbindfast)    sh "$MODDIR/Scripts/4+4+2/O3/unbind_fast.sh" 2>&1 ;;
  ksufix)        cmd_ksufix ;;
  live)          cmd_live ;;
  apps)          cmd_apps ;;
  freqs)         cmd_freqs ;;
  # 应用页过滤：有前台界面（启动器能点开）的包清单
  launchables)   cmd_launchables ;;
  # 游戏页按钮：把 Scene 的 FAS 调速器（features/fas.conf 三簇）统一成 xres
  fasxres)       cmd_fasxres ;;
  log)           cmd_log "$2" ;;
  daemonlog)     cmd_daemonlog "$2" ;;
  *) echo "err: unknown command '$1'"; exit 1 ;;
esac
