#!/system/bin/sh
# ============================================================
#  玄戒O3 · Abel 调度工具箱 —— 公共函数库  (v2 · 实测校正版)
#
#  v2 关键变更（基于 2026-09-14 对照实验，详见 REPORT-o3-freq-mechanism.md）：
#    · 限频机制  pl_max_freq(无效)  →  cpuN/qos/max_freq(真硬上限)
#    · 新增下限  cpuN/qos/min_freq (真硬下限)
#    · 移除 xres 调速器死参数写入（实测对稳态频率零影响）
#    · 移除 thermal cur_state（写入后 <4s 被热框架夺回）
# ============================================================
export PATH="${PATH}:/data/adb/magisk:/data/adb/ksu/bin:/data/adb/ap/bin"
export TZ="Asia/Shanghai"

# ---------- busybox ----------
BB=""
for c in /data/adb/ksu/bin/busybox /data/adb/magisk/busybox \
         /data/data/com.omarea.vtools/files/busybox busybox; do
    if command -v "$c" >/dev/null 2>&1 || [ -x "$c" ]; then BB="$c"; break; fi
done
[ -n "$BB" ] && chattr() { "$BB" chattr "$@"; }

SCENE_PKG="com.omarea.vtools"
SCENE_DIR="/data/data/${SCENE_PKG}/files"
MODDIR="${MODDIR:-${0%/*}}"
[ -f "${MODDIR}/module.prop" ] || MODDIR="/data/adb/modules/SceneO3Tuner"

STATE_DIR="/data/adb/SceneO3Tuner"
ACTIVE_FILE="${STATE_DIR}/active_scheme"
UNLOCK_FILE="${STATE_DIR}/unlocked"
LOG_FILE="${STATE_DIR}/sceneo3.log"
mkdir -p "$STATE_DIR" 2>/dev/null

# WebUI 后端与公共库共用的临时目录。
# ⚠ 必须在这里定义：gen_threads_from_scene() 会用到 TMPD，而它会被 guard.sh
#   调用 —— 原先 TMPD 只在 webui.sh 里定义，守护调用时 TMPD 是空的，
#   于是临时文件被写到 "/appmode.txt" 这种根路径下（静默失败）。
TMPD="${TMPD:-/data/local/tmp/_wui}"
WEBUI_DIR="${STATE_DIR}/webui"
mkdir -p "$TMPD" "$WEBUI_DIR" 2>/dev/null

# ============================================================
#  日志开关（settings.conf: debug=0|1）
# ------------------------------------------------------------
#  守护每 5 秒一轮，若每轮都往 LOG_FILE 追加，会持续唤醒磁盘 / 触发 fsync 抖动，
#  是「待机功耗」里一笔看不见但实实在在的开销。所以：
#    · log()        → **始终**回显（WebUI 命令的输出要靠它），只在开关打开时落盘
#    · log_quiet()  → 只落盘，开关关闭时完全不写
#  默认「开」：首次安装/升级后仍能拿到完整日志，用户可在 WebUI「日志」页一键关掉。
SET_MODE_SYNC=""; SET_FREQ_SYNC="0"; SET_DEBUG="1"; LOG_ON=1

# 读 settings.conf。用 shell 内建 read 循环而不是 sed：
#   · 不起子进程（sed 每次约 5ms，守护每轮都要读）
#   · 一次读出全部键，避免多处各自 grep 一遍
settings_load() {
    SET_MODE_SYNC=""; SET_FREQ_SYNC="0"; SET_DEBUG="1"
    local line
    if [ -f "${WEBUI_DIR}/settings.conf" ]; then
        while IFS= read -r line; do
            case "$line" in
              mode_sync=*)    SET_MODE_SYNC="${line#*=}" ;;
              # ⚠ CPU 调频已按用户要求**交回 Scene 接管**（模块不写任何频率节点）。
              #   这个键现在恒为 0，只用于模块卡片描述里如实标注状态；
              #   历史 settings.conf 里残留的 freq_sync=1 一律忽略（否则会误报「频率同步 开」）。
              debug=*)        SET_DEBUG="${line#*=}" ;;
            esac
        done < "${WEBUI_DIR}/settings.conf"
    fi
    [ "${SET_DEBUG:-1}" = "1" ] && LOG_ON=1 || LOG_ON=""
    return 0
}
settings_load

# ------------------------------------------------------------
#  动态「模块描述」—— KernelSU 模块卡片上只显示功能启用状态
# ------------------------------------------------------------
#  用户要求：模块描述不写说明文字，只列功能开关状态。
#  写回 module.prop 的 description= 行；内容没变就不落盘（守护会定期调用它）。
#    例：功能状态｜Scene 配置 已启用 · 自动切换 开 · 频率同步 开 · 守护 运行中 · 日志 关
update_module_desc() {
    local prop="${MODDIR}/module.prop"
    [ -f "$prop" ] || return 0
    settings_load

    local scene dyn freq guard logv desc old tmp
    if [ "$(scene_source_get)" = "$SCENE_SOURCE_WANT" ]; then scene="已启用"; else scene="未启用"; fi
    [ "${SET_MODE_SYNC:-0}" = "1" ] && dyn="开" || dyn="关"
    [ "${SET_FREQ_SYNC:-0}" = "1" ] && freq="本模块" || freq="Scene 接管"
    [ "${SET_DEBUG:-1}" = "1" ] && logv="开" || logv="关"
    if pgrep -f "O3/guard\.sh" >/dev/null 2>&1; then guard="运行中"; else guard="停止"; fi

    desc="功能状态｜Scene 配置 ${scene} · 自动切换 ${dyn} · 频率同步 ${freq} · 守护 ${guard} · 日志 ${logv}"

    old=$(sed -n 's/^description=//p' "$prop" 2>/dev/null | head -1)
    [ "$old" = "$desc" ] && return 0

    mkdir -p "$TMPD" 2>/dev/null
    tmp="${TMPD}/module.prop.new"
    if grep -q '^description=' "$prop" 2>/dev/null; then
        sed "s|^description=.*|description=${desc}|" "$prop" > "$tmp" 2>/dev/null
    else
        cat "$prop" > "$tmp" 2>/dev/null
        printf 'description=%s\n' "$desc" >> "$tmp"
    fi
    [ -s "$tmp" ] || { rm -f "$tmp" 2>/dev/null; return 1; }
    write_replace "$tmp" "$prop" || { rm -f "$tmp" 2>/dev/null; return 1; }
    rm -f "$tmp" 2>/dev/null
    chmod 0644 "$prop" 2>/dev/null
    chown 0:0 "$prop" 2>/dev/null
    return 0
}

log()       { if [ -n "$LOG_ON" ]; then echo "[$(date '+%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"; fi; echo "$*"; }
log_quiet() { [ -n "$LOG_ON" ] || return 0; echo "[$(date '+%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"; }

# ---------- 簇布局（O3: 10核 4+4+2）----------
CL_L="0 1 2 3"      # 小核
CL_M="4 5 6 7"      # 中核
CL_P="8 9"          # 大核
ALL_CPUS="0 1 2 3 4 5 6 7 8 9"

# ---------- UID ----------
get_package_uid() {
    local pkg="$1" uid=""
    [ -z "$pkg" ] && return
    uid=$(grep -m1 "^${pkg} " /data/system/packages.list 2>/dev/null | cut -d' ' -f2)
    [ -z "$uid" ] && uid=$(cmd package list package -U "$pkg" 2>/dev/null | grep -Eo "uid:[0-9]+" | cut -d: -f2)
    [ -z "$uid" ] && uid=$(dumpsys package "$pkg" 2>/dev/null | grep -m1 "userId=" | cut -d= -f2)
    [ -n "$uid" ] && echo "${uid%%$'\n'*}"
}

# ============================================================
#  文件锁：**已废弃**（2026-09-15 实测结论）
# ------------------------------------------------------------
#  ⚠ chattr +i 会**让 Scene 自己无法保存配置**：
#    用户在 Scene 里点小齿轮改特性、切全局模式时，Scene 需要写
#    features/*.conf 与 profile.json；这些文件被 +i 锁住后 open() 直接失败
#    （ENOTSUP: Operation not supported on transport endpoint），
#    用户看到的现象就是「改了没反应 / 切换不生效」。
#  而锁定的初衷是防云同步替换 —— 本机型（Xiaomi 18 Fold / 玄戒O3）云端并无对应
#  配置，没有可被替换的风险，所以锁定弊远大于利。**全部取消。**
#
#  保留这些函数名（action.sh / switch.sh / set_scheme.sh 都在用），一律降级：
#    lock_file / lock_scene_all  → 什么都不做
#    unlock_*                    → 保留「清标志 + 修权限」的实用价值，作为修复入口
# ============================================================
unlock_file() {
    [ -e "$1" ] || return 0
    chattr -i -a "$1" 2>/dev/null
    [ -n "$BB" ] && "$BB" chattr -i -a "$1" 2>/dev/null
    return 0
}
unlock_tree() {
    [ -e "$1" ] || return 0
    chattr -R -i -a "$1" 2>/dev/null
    [ -n "$BB" ] && "$BB" chattr -R -i -a "$1" 2>/dev/null
    return 0
}
unlock_scene_all() {
    local uid; uid=$(get_package_uid "$SCENE_PKG")
    unlock_tree "$SCENE_DIR"
    [ -n "$uid" ] && chown -R "${uid}:${uid}" "$SCENE_DIR" 2>/dev/null
    ensure_scene_dir_perm
    log_quiet "scene dir unlocked (chattr cleared)"
}

# ============================================================
#  可写性自检与修复
# ------------------------------------------------------------
#  ⚠ 判定**不能靠 lsattr**。实测遇到过这种情况：lsattr 显示无 i 标志
#    （只有正常的 E = EA_INODE），chattr -i 也返回成功，但 open(O_WRONLY)
#    依然 ENOTSUP，只有**替换 inode** 才能恢复。
#    所以唯一可靠的判据是「真的开一次写试试」。
# ============================================================
can_write() {   # 返回 0=可写。count=0 的 dd 只打开写、不改内容，安全
    [ -e "$1" ] || return 1
    dd if=/dev/zero of="$1" bs=1 count=0 conv=notrunc >/dev/null 2>&1
}

# 强制恢复可写：先清标志；不行就替换 inode（cp -f 遇 open 失败会 unlink 重建，
# 实测这是唯一能摆脱那种残留态的办法）。
force_writable() {
    local f="$1" t
    [ -e "$f" ] || return 1
    chattr -i -a "$f" 2>/dev/null
    [ -n "$BB" ] && "$BB" chattr -i -a "$f" 2>/dev/null
    can_write "$f" && return 0
    t="${f}.rw.$$"
    cp -f "$f" "$t" 2>/dev/null || return 1
    if ! cp -f "$t" "$f" 2>/dev/null; then
        rm -f "$f" 2>/dev/null
        cp -f "$t" "$f" 2>/dev/null || { rm -f "$t" 2>/dev/null; return 1; }
    fi
    rm -f "$t" 2>/dev/null
    can_write "$f"
}

# 以「替换 inode」的方式把 src 内容写到 dst（绕开 in-place 写入被拒）
write_replace() {   # $1=源 $2=目标
    local src="$1" dst="$2"
    [ -f "$src" ] || return 1
    unlock_file "$dst"
    mkdir -p "$(dirname "$dst")" 2>/dev/null
    if cp -f "$src" "$dst" 2>/dev/null && can_write "$dst"; then return 0; fi
    rm -f "$dst" 2>/dev/null
    cp -f "$src" "$dst" 2>/dev/null && can_write "$dst"
}

# 全量修复 Scene 配置可写性；stdout 返回「可写的文件数」
repair_scene_writable() {
    local f n=0 total=0
    for f in "${SCENE_DIR}"/*.json "${SCENE_DIR}"/*.sh "${SCENE_DIR}"/features/*.conf; do
        [ -f "$f" ] || continue
        total=$((total+1))
        force_writable "$f" && n=$((n+1))
    done
    log_quiet "repair: writable ${n}/${total}"
    echo "$n $total"
}

# ---------- 权限修复 ----------
# ⚠ 血泪教训：绝不能把「文件模式」套用到目录上。
# 曾用 chmod 0666 处理目录，抹掉了目录的执行位(x)，导致 Scene 进不去自己的
# files 目录，attachBaseContext 写 rish.sh / categories.json / features/*.conf
# 全部 EACCES → App 永久卡在启动 splash。目录只允许「补 x」，不做降权。
fix_perm() {
    local f="$1" uid="$2"
    [ -e "$f" ] || return
    chown "${uid}:${uid}" "$f" 2>/dev/null
    if [ -d "$f" ]; then
        ensure_dir_x "$f"                       # 目录：只补执行位，绝不用文件模式
    else
        chmod 0666 "$f" 2>/dev/null
    fi
    chcon u:object_r:app_data_file:s0:c65,c257,c512,c768 "$f" 2>/dev/null
}

# 目录是否「可进入」（owner 有 x 位）
# ⚠ 不要用 $(( m & 0100 )) 做位运算：shell 对前导零常量的解析不可靠
#   （实测 mksh 把 0100 当十进制 100，导致 0644 被误判为「有 x」）。
#   改为解析 stat 的符号模式串第 4 位（drwx… 的 x 位置），跨 shell 稳定。
dir_x_ok() {
    [ -d "$1" ] || return 1
    local xs
    xs=$(stat -c %A "$1" 2>/dev/null | cut -c4)
    case "$xs" in
        x|s) return 0 ;;
        *)   return 1 ;;
    esac
}

# 目录缺 owner 执行位时补回（最小改动，不影响其他位）。返回 0=补了 1=本来就正常
ensure_dir_x() {
    local d="$1"
    [ -d "$d" ] || return 1
    if dir_x_ok "$d"; then return 1; fi
    chmod u+x "$d" 2>/dev/null && return 0
    return 1
}

# Scene 数据目录自检与修复：目录必须可进入，否则 Scene 直接起不来。
# 修复动作会写日志（log 同时落盘与 stdout），无问题时静默。
ensure_scene_dir_perm() {
    [ -d "$SCENE_DIR" ] || { log_quiet "scene dir missing: $SCENE_DIR"; return 1; }
    local d
    if ensure_dir_x "$SCENE_DIR"; then
        log "⚠ Scene files 目录缺执行位 → 已补回（否则 App 会卡在启动 splash）"
    fi
    # 一级子目录同样检查（Scene 的目录约定是 0722）
    for d in "$SCENE_DIR"/*/; do
        [ -d "$d" ] || continue
        if ensure_dir_x "${d%/}"; then
            log "⚠ 子目录 $(basename "${d%/}") 缺执行位 → 已补回"
        fi
    done
    return 0
}

# ============================================================
#  ★ Scene 的「启用配置」两个开关 —— 决定 Scene 用不用我们灌进去的配置
# ------------------------------------------------------------
#  Scene 把状态放在 shared_prefs/global.xml 里，两个键决定我们能不能被启用：
#
#   ① scene_profile_source —— 当前启用的是哪一套配置（调节页那行显示的就是它）
#        SOURCE_SCENE_ONLINE   ★★ 我们要的值。Scene 把这一档当成「已安装的方案」，
#                            调节页显示 `Scene` + `🌍 Version: LP 20260916`
#                            （author 取 manifest 的 SCENE9，显示成 Scene），
#                            并且**按我们 files/profile.json 里的参数下发**。
#        SOURCE_SCENE_CUSTOM      Scene 内置「自定义」通道。能启用、也会用我们的
#                            profile.json，但调节页那行被硬编码显示成「自定义」，
#                            看起来不像我们的方案（用户会以为没生效）。
#        SOURCE_OUTSIDE           外部配置通道。⚠ **实测走不通**：界面会显示
#                            SCENE9 + 🌐 Version: LP（看着像成功），但 Scene 判定
#                            它不是「有效的性能调节配置」→「性能调节未启用，无法切换
#                            模式」，dynamic_control 被强行按回 false。不要用。
#
#   ② dynamic_control —— 「性能调节」总开关（Scene 调节页右上角那个 Switch）
#        必须是 true。它为 false 时 Scene 完全不下发调度，表现就是
#        「配置无法启用 / 在安装有效的性能调节配置之前，不能开启」。
#
#  ⚠ 2026-09-16 实测定论（三条通道都跑过一遍）：可用组合是
#      scene_profile_source = SOURCE_SCENE_ONLINE   ← 唯一「显示对 + 能启用」的值
#      dynamic_control      = true                  ← 「性能调节」总开关
#      manifest.json        = 我们 Config/<scheme>/manifest.json（SCENE9 / LP）
#      profile.json         = 我们 Config/<scheme>/profile.json（原样，Scene 不回写）
#    实测结果：调节页显示「Scene / 🌍 Version: LP 20260916」，性能调节保持开启，
#    manifest 与 profile 的 md5 与模块源完全一致（没有被 Scene 覆盖）。
#
#  ⚠ 写入顺序铁律：**先 am force-stop Scene** 再改这两个键。
#    运行中的 Scene 会把内存里的偏好整份写回 global.xml，我们改的值会被冲掉；
#    同时它还会用自己的格式重写 profile.json。停掉 → 写 → 再启动，才留得住。
# ============================================================
SCENE_GLOBAL_XML="/data/data/${SCENE_PKG}/shared_prefs/global.xml"
SCENE_SOURCE_KEY="scene_profile_source"
SCENE_DYN_KEY="dynamic_control"
SCENE_SOURCE_WANT="SOURCE_SCENE_ONLINE"

# 读一个字符串型偏好（读不到输出空串）
scene_pref_get() {
    [ -f "$SCENE_GLOBAL_XML" ] || { echo ""; return; }
    sed -n "s/.*name=\"$1\">\([^<]*\)<.*/\1/p" "$SCENE_GLOBAL_XML" 2>/dev/null | head -1
}
# 读一个布尔型偏好（值在 value="..." 属性里，不是标签内容）
# ⚠ 别拿 scene_pref_get 去读 boolean：dynamic_control 是
#   `<boolean name="dynamic_control" value="true" />`，没有标签内容，
#   用字符串式正则读出来永远是空 —— 会误报「性能调节未打开」。
scene_bool_get() {
    [ -f "$SCENE_GLOBAL_XML" ] || { echo ""; return; }
    sed -n "s/.*name=\"$1\" value=\"\([^\"]*\)\".*/\1/p" "$SCENE_GLOBAL_XML" 2>/dev/null | head -1
}
scene_source_get() { scene_pref_get "$SCENE_SOURCE_KEY"; }
scene_dyn_get()    { scene_bool_get "$SCENE_DYN_KEY"; }

# 改一个偏好并校验 + 失败回滚。$1=键名 $2=新值 $3=类型(string|boolean)
# 输出 OK... / ERR...
# ⚠ global.xml 是 Scene 全部偏好的唯一副本，写坏 = Scene 设置全归零，
#   所以先落保险、写后读回校验、不一致立即还原。
scene_pref_set() {
    local key="$1" want="$2" kind="$3" cur uid tmp bak now wrote=""
    if [ ! -f "$SCENE_GLOBAL_XML" ]; then
        echo "ERR 找不到 ${SCENE_GLOBAL_XML}（Scene 是否装好并启动过一次？）"
        return 1
    fi

    # 当前值：string 型按标签内容取，boolean 型取 value 属性
    if [ "$kind" = "boolean" ]; then
        cur=$(sed -n "s/.*name=\"${key}\" value=\"\([^\"]*\)\".*/\1/p" "$SCENE_GLOBAL_XML" 2>/dev/null | head -1)
    else
        cur=$(scene_pref_get "$key")
    fi
    if [ "$cur" = "$want" ]; then
        echo "OK ${key} 已是 ${want}"
        return 0
    fi

    tmp="${TMPD}/global.xml.new"
    if [ "$kind" = "boolean" ]; then
        if [ -n "$cur" ]; then
            sed "s|name=\"${key}\" value=\"[^\"]*\"|name=\"${key}\" value=\"${want}\"|" \
                "$SCENE_GLOBAL_XML" > "$tmp" 2>/dev/null
        else
            sed "s|</map>|    <boolean name=\"${key}\" value=\"${want}\" />\n</map>|" \
                "$SCENE_GLOBAL_XML" > "$tmp" 2>/dev/null
        fi
    else
        if [ -n "$cur" ]; then
            sed "s|name=\"${key}\">[^<]*<|name=\"${key}\">${want}<|" \
                "$SCENE_GLOBAL_XML" > "$tmp" 2>/dev/null
        else
            sed "s|</map>|    <string name=\"${key}\">${want}</string>\n</map>|" \
                "$SCENE_GLOBAL_XML" > "$tmp" 2>/dev/null
        fi
    fi
    [ -s "$tmp" ] || { rm -f "$tmp"; echo "ERR 生成新 global.xml 失败"; return 1; }

    bak="${TMPD}/global.xml.bak"
    cp -af "$SCENE_GLOBAL_XML" "$bak" 2>/dev/null

    uid=$(get_package_uid "$SCENE_PKG")
    [ -n "$uid" ] || uid=10321
    write_replace "$tmp" "$SCENE_GLOBAL_XML" && wrote=1
    rm -f "$tmp" 2>/dev/null
    chown "${uid}:${uid}" "$SCENE_GLOBAL_XML" 2>/dev/null
    chmod 0660 "$SCENE_GLOBAL_XML" 2>/dev/null

    if [ "$kind" = "boolean" ]; then
        now=$(sed -n "s/.*name=\"${key}\" value=\"\([^\"]*\)\".*/\1/p" "$SCENE_GLOBAL_XML" 2>/dev/null | head -1)
    else
        now=$(scene_pref_get "$key")
    fi
    if [ "$now" = "$want" ]; then
        rm -f "$bak" 2>/dev/null
        echo "OK ${key} ${cur:-未设置} → ${want}"
        log_quiet "scene: ${key} ${cur:-none} -> ${want}"
        return 0
    fi

    if [ -f "$bak" ]; then
        write_replace "$bak" "$SCENE_GLOBAL_XML" >/dev/null 2>&1
        chown "${uid}:${uid}" "$SCENE_GLOBAL_XML" 2>/dev/null
        chmod 0660 "$SCENE_GLOBAL_XML" 2>/dev/null
        rm -f "$bak" 2>/dev/null
    fi
    echo "ERR ${key} 写入失败（写入${wrote:+过}但读到 ${now:-空}，已回滚原文件）"
    return 1
}

# 便捷包装：启用我们的配置（来源 + 性能调节总开关）
scene_source_set() { scene_pref_set "$SCENE_SOURCE_KEY" "${1:-$SCENE_SOURCE_WANT}" string; }
scene_dyn_set()    { scene_pref_set "$SCENE_DYN_KEY" "${1:-true}" boolean; }

# 重启 Scene 的核心分配服务（scene-daemon），让刚写入的 threads.json/profile.json 立刻生效。
# ⚠ 必须重启：Scene 把配置缓存在内存里，只改文件它不会重读
#   —— 这正是「线程切换太晚」（微信先跑 4-9、过一阵才掉到 0-3）的根因之一。
#   实测被 kill 后 Scene 自身会在 4~8 秒内自动拉起并重读配置。
# ⚠ 它**只**杀这个后台调度进程，不动 Scene 本体：
#   所以不会掉无障碍服务、不会让 Scene 失效 —— 相比 `am force-stop` 安全得多。
#   放在 lib/util.sh 是因为 profile_sync.sh（只 source 本文件）也要用它。
# 输出：重启后的 daemon PID（失败时返回非 0）
restart_scene_daemon() {
    local before after i
    before=$(pgrep -f scene-daemon | tr '\n' ' ')
    pkill -f scene-daemon 2>/dev/null
    i=0
    while [ $i -lt 8 ]; do
        sleep 1
        after=$(pgrep -f scene-daemon | tr '\n' ' ')
        [ -n "$after" ] && break
        i=$((i+1))
    done
    if [ -z "$after" ]; then
        # 兜底：如果本进程里恰好有 webui.sh 的完整重绑函数（会短暂切走前台）就用它
        if command -v cmd_apply >/dev/null 2>&1; then
            log "util: daemon 未自动拉起（before=[$before]），升级为完整重绑"
            cmd_apply >/dev/null 2>&1
            after=$(pgrep -f scene-daemon | tr '\n' ' ')
        fi
        [ -n "$after" ] || { log "util: daemon 仍未拉起"; return 1; }
    fi
    log "util: daemon 已重启 before=[$before] after=[$after]"
    printf '%s' "${after%% *}"
}

# ---------- 采纳当前状态为新基准 ----------
# 用户在「解锁」态手动调整后按「锁定」，若不采纳，守护会把用户的调整当成
# 「被 Scene 替换」而回滚 —— 手动调整功能就废了。
# 因此显式 lock 时把 Scene 当前配置回写进模块方案目录，作为新基线。
ADOPT_LIST="profile.json manifest.json _Apps.json _Games.json _Camera.json _ELP.json powercfg.sh"
ADOPT_FCONF="fas.conf cpuset.conf env.conf limiter.conf refresh_rate.conf"


# ============================================================
#  自检与权限（webui.sh 与守护共用；原先只在 webui.sh 里定义，
#  守护调用 gen_threads_from_scene() 时会报 command not found）
# ============================================================
perm_file() {   # $1=path
    local uid; uid=$(get_package_uid "$SCENE_PKG")
    [ -n "$uid" ] || uid=10321
    chown "${uid}:${uid}" "$1" 2>/dev/null
    chmod 0666 "$1" 2>/dev/null
    chcon u:object_r:app_data_file:s0:c65,c257,c512,c768 "$1" 2>/dev/null
}

# ⚠ 绝不能写 first=$(head -c 1 "$f") / last=$(tail -c 1 "$f")：
#   命令替换 $(...) 会吃掉行尾换行，于是「以换行结尾的合法 JSON」末字符成了空串，
#   被判成「被截断」而拒收。带结尾换行的 JSON 是常态，这个坑必踩。
first_sig() { head -c 4096 "$1" 2>/dev/null | tr -d ' \t\r\n' | cut -c1; }
last_sig()  { tail -c 4096 "$1" 2>/dev/null | tr -d ' \t\r\n' | tail -c 1; }

validate() {   # $1=id  $2=file —— 输出空串=通过
    local id="$1" f="$2" sz first last
    [ -f "$f" ] || { echo "文件不存在"; return 1; }
    # 游戏模板 / 分配是 TSV，空文件也合法（清空分配 / 暂无模板），跳过结构校验
    case "$id" in gameassign|gametpl|appassign|apptpl|settings) return 0 ;; esac
    sz=$(wc -c < "$f" 2>/dev/null | tr -d ' ')
    [ "${sz:-0}" -gt 0 ] || { echo "内容为空"; return 1; }
    case "$id" in
      threads|games|model|selftest|profile|gamesjson)
        first=$(first_sig "$f"); last=$(last_sig "$f")
        case "$first" in
          "["|"{") : ;;
          *) echo "JSON 必须以 [ 或 { 开头（实际 '$first'）"; return 1 ;;
        esac
        case "$last" in
          "]"|"}") : ;;
          *) echo "JSON 结尾不完整（末字符 '$last'）—— 疑似被截断"; return 1 ;;
        esac
        ;;
    esac
    case "$id" in
      threads)
        [ "${sz:-0}" -ge 200 ] || { echo "threads.json 仅 ${sz} 字节，过小，疑似截断"; return 1; }
        grep -q '"friendly"' "$f" || { echo "threads.json 缺 friendly 字段"; return 1; }
        grep -q '"packages"' "$f" || { echo "threads.json 缺 packages 字段"; return 1; }
        ;;
      games)
        [ "${sz:-0}" -ge 200 ] || { echo "_Games.json 仅 ${sz} 字节，过小，疑似截断"; return 1; }
        ;;
      model)
        grep -q '"templates"' "$f" || { echo "$id 缺 templates 字段"; return 1; }
        ;;
      gamesjson)
        grep -q '"friendly"' "$f" || { echo "$id 缺 friendly 字段"; return 1; }
        grep -q '"packages"' "$f" || { echo "$id 缺 packages 字段"; return 1; }
        ;;
      powercfg)
        head -c 200 "$f" | grep -q '^#!' || { echo "powercfg.sh 缺 shebang"; return 1; }
        ;;
    esac
    return 0
}

# ---------- 方案同步（Scene 配置目录）----------
sync_scheme() {
    local src="$1"
    [ -d "$src" ] || { log "方案目录不存在: $src"; return 1; }
    [ -d "$SCENE_DIR" ] || { log "Scene 数据目录不存在，请先安装并启动 Scene"; return 1; }
    local uid; uid=$(get_package_uid "$SCENE_PKG")
    [ -z "$uid" ] && { log "未安装 Scene，终止"; return 1; }

    # 不再 unlock_tree（锁定已废除）；但要确保目录可进入，
    # 否则 Scene 读不到自己的配置、会卡在启动 splash。
    ensure_scene_dir_perm
    local n=0 s b d
    for s in "$src"/*.json "$src"/*.sh "$src"/*.txt; do
        [ -f "$s" ] || continue
        b="${s##*/}"
        d="${SCENE_DIR}/${b}"
        # 用 write_replace（替换 inode）而不是 cp -af：
        # 个别 inode 会拒写（ENOTSUP），cp -f 遇 open 失败时会 unlink 重建，才能落地。
        write_replace "$s" "$d" && n=$((n+1))
        fix_perm "$d" "$uid"
    done
    if [ -d "$src/features" ]; then
        mkdir -p "${SCENE_DIR}/features"
        for s in "$src/features"/*.conf; do
            [ -f "$s" ] || continue
            b="${s##*/}"
            d="${SCENE_DIR}/features/${b}"
            write_replace "$s" "$d" && n=$((n+1))
            fix_perm "$d" "$uid"
        done
    fi
    chown -R "${uid}:${uid}" "$SCENE_DIR" 2>/dev/null

    # 同步后自检：防串档（历史上出过 mksh local 错位导致整目录错位一格）
    local bad
    bad=$(verify_synced "$src")
    if [ -n "$bad" ]; then
        log "❌ 同步自检未通过：$bad"
        return 1
    fi

    log_quiet "synced ${n} files from ${src}"
    echo "$n"
}

# ---------- 配置自检 ----------
# 输出空串=通过；否则输出问题描述
md5of() {
    if [ -n "$BB" ] && [ -x "$BB" ]; then "$BB" md5sum "$1" 2>/dev/null | cut -d' ' -f1
    else md5sum "$1" 2>/dev/null | cut -d' ' -f1; fi
}

# 结构自检：只判断「是否被串档 / 截断」，【不】比对文件内容。
# 供 adopt（采纳用户手动调整）使用 —— 那时 Scene 侧与模块源本就应当不同，
# 若在此比对 md5，用户的正常修改会被误判为坏文件而拒绝采纳。
verify_struct() {   # $1=待检查目录（默认 Scene_DIR）
    local dir="${1:-$SCENE_DIR}" f t sz
    f="${dir}/profile.json"
    if [ -f "$f" ]; then
        t=$(head -c 1 "$f" 2>/dev/null)
        if [ "$t" != "{" ]; then echo "profile.json 首字符为 '$t'，不是 JSON —— 疑似串档"; return; fi
        sz=$(wc -c < "$f" 2>/dev/null | tr -d ' ')
        if [ "${sz:-0}" -lt 10000 ]; then echo "profile.json 仅 ${sz} 字节 —— 疑似截断/串档"; return; fi
    fi
    f="${dir}/manifest.json"
    if [ -f "$f" ]; then
        t=$(head -c 1 "$f" 2>/dev/null)
        if [ "$t" != "{" ]; then echo "manifest.json 首字符为 '$t'，不是 JSON —— 疑似串档"; return; fi
        grep -q '"version"' "$f" 2>/dev/null || { echo "manifest.json 缺 version 字段 —— 疑似串档"; return; }
    fi
    for f in "${dir}/_Apps.json" "${dir}/_Games.json" \
             "${dir}/_Camera.json" "${dir}/_ELP.json"; do
        [ -f "$f" ] || continue
        t=$(head -c 1 "$f" 2>/dev/null)
        case "$t" in
          "{"|"[") : ;;
          *) echo "$(basename "$f") 首字符为 '$t'，不是 JSON —— 疑似串档"; return ;;
        esac
    done
    f="${dir}/powercfg.sh"
    if [ -f "$f" ]; then
        head -1 "$f" 2>/dev/null | grep -q '^#!' || { echo "powercfg.sh 缺 shebang —— 疑似串档"; return; }
    fi
    echo ""
}

# 同步自检：结构自检 + 与源 md5 一致 + 目录可进入。
# 仅用于 sync_scheme 拷贝【之后】（此时 Scene 侧应当等于源）。
verify_synced() {   # $1=方案源目录
    local src="$1" f bad
    bad=$(verify_struct "$SCENE_DIR")
    [ -n "$bad" ] && { echo "$bad"; return; }
    # 目录可进入性 —— 缺 x 是「Scene 卡启动」的直接原因，必须阻断
    if [ -d "$SCENE_DIR" ] && ! dir_x_ok "$SCENE_DIR"; then
        echo "Scene files 目录 ($SCENE_DIR) 模式 $(stat -c %a "$SCENE_DIR" 2>/dev/null) 缺 owner 执行位 —— App 将无法访问任何配置"
        return
    fi
    for f in profile.json manifest.json _Apps.json _Games.json _Camera.json _ELP.json powercfg.sh; do
        [ -f "${src}/${f}" ] || continue
        [ -f "${SCENE_DIR}/${f}" ] || continue
        if [ "$(md5of "${src}/${f}")" != "$(md5of "${SCENE_DIR}/${f}")" ]; then
            echo "同步后 ${f} 与源 md5 不一致"; return
        fi
    done
    echo ""
}

# ============================================================
#  限频核心 —— PM QoS（O3 上唯一被强制执行的频率旋钮）
# ============================================================
# 写单个 CPU 的 QoS 上限；返回 0=成功
qos_set_max() {   # $1=cpu $2=freq
    local f="/sys/devices/system/cpu/cpu$1/qos/max_freq"
    [ -e "$f" ] || return 1
    echo "$2" > "$f" 2>/dev/null || return 1
    return 0
}

qos_set_min() {   # $1=cpu $2=freq
    local f="/sys/devices/system/cpu/cpu$1/qos/min_freq"
    [ -e "$f" ] || return 1
    echo "$2" > "$f" 2>/dev/null || return 1
    return 0
}

# 读取某簇 stock 策略天花板（只读汇报值）
cluster_stockmax() {
    local c
    case "$1" in L) c=0 ;; M) c=4 ;; P) c=8 ;; *) c=0 ;; esac
    cat "/sys/devices/system/cpu/cpu$c/cpufreq/scaling_max_freq" 2>/dev/null
}

# ============================================================
#  统一模式阶梯（4 级）—— 频率 与 线程分配 的「对应关系」
# ------------------------------------------------------------
#  这是本模块的唯一调优轴。命名沿用 Scene 原生的 4 个模式，这样：
#    · 在 Scene 里切模式（全局 schemes / 单应用应用配置）→ 频率跟着变；
#    · threads.json 用同一套模式名 → 线程分配也跟着变；
#    · 两边语义一致，不再出现"频率一档、线程另一档"的错配。
#
#  频率数值直接对齐 Scene profile.json 里 <mode>_active / <mode>_inactive
#  preset 的 @cpu_freq（实测读出来的值，不是自己臆造的）：
#     mode           L min/max        M min/max        P min/max
#     powersave      417792/1353600   556800/1468800   1113600/2044800
#     balance        417792/1939200   556800/1968000   1113600/2371200
#     performance    672000/2246400   835200/2294400   1497600/2860800
#     fast           912000/3148800   1142400/3686400  2044800/4358400
#  inactive 各自更低一档（后台不抢性能）。
# ============================================================
MODE_LIST="powersave balance performance fast"

mode_name_cn() {
    case "$1" in
      powersave)   echo "省电" ;;
      balance)     echo "均衡" ;;
      performance) echo "性能" ;;
      fast)        echo "极速" ;;
      *)           echo "$1" ;;
    esac
}
mode_from_cn() {
    case "$1" in
      省电|powersave)   echo powersave ;;
      均衡|balance)     echo balance ;;
      性能|performance) echo performance ;;
      极速|fast)        echo fast ;;
      *)                echo "" ;;
    esac
}
mode_valid() { case " $MODE_LIST " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

# 频率表：输出 "Lmin Lmax Mmin Mmax Pmin Pmax"。$2=active|inactive
mode_freq() {
    case "$1:$2" in
      powersave:active)     echo "417792 1353600 556800 1468800 1113600 2044800" ;;
      powersave:inactive)   echo "417792 1065600 556800 1142400 1113600 2044800" ;;
      balance:active)       echo "417792 1939200 556800 1968000 1113600 2371200" ;;
      balance:inactive)     echo "417792 1785600 556800 1804800 1113600 2198400" ;;
      performance:active)   echo "672000 2246400 835200 2294400 1497600 2860800" ;;
      performance:inactive) echo "672000 2092800 835200 2131200 1497600 2707200" ;;
      fast:active)          echo "912000 3148800 1142400 3686400 2044800 4358400" ;;
      fast:inactive)        echo "912000 2860800 1142400 3148800 2044800 3648000" ;;
      *)                    echo "" ;;
    esac
}

# ------------------------------------------------------------
#  各簇的 stock 频率下限（不强制抬频时的地板）
# ------------------------------------------------------------
stock_min_of() {   # $1 = 簇代表核 0/4/8
    case "$1" in
      0|1|2|3)    echo 417792 ;;
      4|5|6|7)    echo 556800 ;;
      8|9)        echo 1113600 ;;
      *)          echo 0 ;;
    esac
}

# ------------------------------------------------------------
#  相机档位（从设备上正在用的 _Camera.json 现读，不写死）
# ------------------------------------------------------------
#  ⚠ 三个方案包的相机档位并不一样：
#      sweet_bal / sweet_perf : 912000/3148800  1142400/3686400  2044800/4358400
#      sweet_eco              : 672000/2246400   835200/2294400  1497600/2860800
#    写死就等于「用 eco 时把频率拉到 bal 的档位」。Scene 正在用的那份
#    _Camera.json 是唯一真源，直接读它最省事也最准。
#
#  格式是「路径一行、值在下一行」，所以用两行滑动窗口取值（__pend 记上一行）。
#  读不全就返回 1，调用方回退到保守档位（sweet_bal），绝不猜。
#  输出: 全局 CAM_ALL="核 min max  核 min max  核 min max"
CAM_ALL=""
camera_freq_load() {
    local cm="${SCENE_DIR}/_Camera.json"
    local line cpu kind val __pend="" in_active=0
    local l_min="" l_max="" m_min="" m_max="" p_min="" p_max=""
    [ -r "$cm" ] || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
          *'"active"'*)   in_active=1; __pend=""; continue ;;
          *'"inactive"'*) in_active=0; __pend=""; continue ;;
        esac
        [ "$in_active" = "1" ] || continue
        case "$line" in
          *cpufreq/scaling_min_freq*|*cpufreq/scaling_max_freq*)
            __pend="$line"; continue ;;
        esac
        [ -n "$__pend" ] || continue
        val=$(printf '%s' "$line" | tr -cd '0-9')
        if [ -n "$val" ]; then
            cpu=$(printf '%s' "$__pend" | sed -n 's#.*cpu\([0-9]\{1,2\}\)/cpufreq.*#\1#p')
            kind=$(printf '%s' "$__pend" | sed -n 's#.*scaling_\(min\|max\)_freq.*#\1#p')
            case "${cpu}:${kind}" in
              0:min) l_min="$val" ;; 0:max) l_max="$val" ;;
              4:min) m_min="$val" ;; 4:max) m_max="$val" ;;
              8:min) p_min="$val" ;; 8:max) p_max="$val" ;;
            esac
        fi
        __pend=""
    done < "$cm"
    [ -n "$l_min" ] && [ -n "$l_max" ] && [ -n "$m_min" ] && \
    [ -n "$m_max" ] && [ -n "$p_min" ] && [ -n "$p_max" ] || return 1
    CAM_ALL="0 $l_min $l_max  4 $m_min $m_max  8 $p_min $p_max"
    return 0
}

# 回退档位 = sweet_bal（最保守的一档；读不到配置时才用）
CAM_FALLBACK="0 912000 3148800  4 1142400 3686400  8 2044800 4358400"
camera_freq_load || CAM_ALL="$CAM_FALLBACK"

# 值都在相机档位 → 0；纯内建 read，0 子进程。$1 = 档位串（默认 CAM_ALL）
camera_band_ok() {
    local list="${1:-$CAM_ALL}" e
    [ -n "$list" ] || return 0
    set -- $list
    while [ $# -ge 3 ]; do
        e=$(read -r v < "/sys/devices/system/cpu/cpu$1/cpufreq/scaling_min_freq" 2>/dev/null && echo "$v")
        [ "$e" = "$2" ] || return 1
        e=$(read -r v < "/sys/devices/system/cpu/cpu$1/cpufreq/scaling_max_freq" 2>/dev/null && echo "$v")
        [ "$e" = "$3" ] || return 1
        shift 3
    done
    return 0
}

# 写回相机档位，**先 min 后 max**（反过来 max 会被当时的 min 钳住）。输出写入节点数
camera_band_fix() {
    local list="${1:-$CAM_ALL}" n=0 c wmin wmax base cmin cmax
    [ -n "$list" ] || { echo 0; return; }
    set -- $list
    while [ $# -ge 3 ]; do
        c=$1; wmin=$2; wmax=$3; shift 3
        base="/sys/devices/system/cpu/cpu${c}/cpufreq"
        cmin=$(read -r v < "$base/scaling_min_freq" 2>/dev/null && echo "$v")
        cmax=$(read -r v < "$base/scaling_max_freq" 2>/dev/null && echo "$v")
        if [ -n "$wmin" ] && [ "$cmin" != "$wmin" ]; then
            echo "$wmin" > "$base/scaling_min_freq" 2>/dev/null && n=$((n+1))
        fi
        cmin=$(read -r v < "$base/scaling_min_freq" 2>/dev/null && echo "$v")
        if [ -n "$wmax" ] && { [ "$cmax" != "$wmax" ] || [ "$cmin" != "$wmin" ]; }; then
            echo "$wmax" > "$base/scaling_max_freq" 2>/dev/null && n=$((n+1))
        fi
    done
    echo "$n"
}

# ------------------------------------------------------------
#  频率预设缓存：Scene profile.json 的 <mode>_active/_inactive @cpu_freq
# ------------------------------------------------------------
#  输出文件每行： <mode>|<active|inactive>|Lmin Lmax Mmin Mmax Pmin Pmax
#
#  ⚠ 为什么要缓存：profile.json 有 57KB，纯 awk 解析一次约 170ms；而 apply_freq.sh
#    每当前台一变就要跑一次。输入是 Scene 自己写的配置，绝大多数时间不变，
#    所以按 profile.json 的 md5 做缓存，命中时只花一次 md5sum（约 5ms）。
FREQ_CACHE="${TMPD}/f.presets"
FREQ_CACHE_SIG="${TMPD}/f.presets.sig"

freq_presets_ensure() {
    # ⚠ 用 mtime 判断「profile.json 是否比缓存新」，而不是 md5sum：
    #   本机一次 fork 要 10~40ms，md5sum+awk+cat 三个子进程 ≈ 60ms，
    #   而 apply_freq.sh 每当前台一变就会跑一次 —— 这是亮屏功耗的一大来源。
    #   `[ a -nt b ]` 是 shell 内建，零子进程。
    local p="$SCENE_DIR/profile.json"
    if [ -s "$FREQ_CACHE" ] && { [ ! -f "$p" ] || [ ! "$p" -nt "$FREQ_CACHE" ]; }; then
        return 0
    fi
    local sig
    sig=$(md5sum "$p" 2>/dev/null | awk '{print substr($1,1,10)}')
    awk -v P="$SCENE_DIR/profile.json" '
    function trim(x){gsub(/^[ \t\r]+/,"",x);gsub(/[ \t\r]+$/,"",x);return x}
    BEGIN {
        s = ""
        while ((getline l < P) > 0) s = s l
        close(P)
        n = split("powersave balance performance fast", MODES, " ")
        m = split("active inactive", STS, " ")
        for (mi = 1; mi <= n; mi++) {
            for (si = 1; si <= m; si++) {
                key = MODES[mi] "_" STS[si]
                Lmin=""; Lmax=""; Mmin=""; Mmax=""; Pmin=""; Pmax=""
                if (match(s, "\"" key "\"[ \t]*:[ \t]*[[]")) {
                    rest = substr(s, RSTART + RLENGTH)
                    e = index(rest, "]")
                    if (e > 0) {
                        blk = substr(rest, 1, e-1)
                        while (match(blk, /\[[^]]*@cpu_freq[^]]*\]/)) {
                            one = substr(blk, RSTART, RLENGTH)
                            blk = substr(blk, RSTART + RLENGTH)
                            gsub(/[]["]/, "", one)
                            q = split(one, a, ",")
                            cpu = trim(a[2]); mn = trim(a[3]); mx = trim(a[q])
                            if (cpu == "cpu0") { Lmin = mn; Lmax = mx }
                            else if (cpu == "cpu4") { Mmin = mn; Mmax = mx }
                            else if (cpu == "cpu8") { Pmin = mn; Pmax = mx }
                        }
                    }
                }
                if (Lmax != "") printf "%s|%s|%s %s %s %s %s %s\n", MODES[mi], STS[si], Lmin, Lmax, Mmin, Mmax, Pmin, Pmax
            }
        }
    }' > "${FREQ_CACHE}.new" 2>/dev/null

    # 解析失败（结构异常）→ 用内置表兜底，保证永远有可用值
    if [ ! -s "${FREQ_CACHE}.new" ]; then
        : > "${FREQ_CACHE}.new"
        for md in $MODE_LIST; do
            for st in active inactive; do
                set -- $(mode_freq "$md" "$st")
                [ -n "$1" ] && printf '%s|%s|%s %s %s %s %s %s\n' \
                    "$md" "$st" "$1" "$2" "$3" "$4" "$5" "$6" >> "${FREQ_CACHE}.new"
            done
        done
    fi
    mv -f "${FREQ_CACHE}.new" "$FREQ_CACHE" 2>/dev/null
    [ -n "$sig" ] && printf '%s' "$sig" > "$FREQ_CACHE_SIG"
    return 0
}

# 取某个模式的六值串；读不到返回空
freq_preset_of() {   # $1=mode $2=active|inactive
    freq_presets_ensure
    sed -n "s/^$1|$2|//p" "$FREQ_CACHE" 2>/dev/null | head -1
}


# 当前全局模式
active_mode() {
    local m; m=$(cat "${STATE_DIR}/active_mode" 2>/dev/null)
    mode_valid "$m" && { echo "$m"; return; }
    echo "balance"
}

# ---------- 方案频率表（基于能效悬崖实测取值）----------
# 上限：只能往下压（超出 stock 策略天花板时被内核 policy 压住，不报错）
#    eco  : 压到能效陡坡之前，真省电
#    bal  : 等于 stock（Xiaomi 自身策略已落在甜点，亦是安全回退档）
#    perf : 放开我方限制（实际仍受 stock 天花板约束，无法突破）
# 下限：抬地板以换持续性能（防掉频致卡顿），perf 档启用
scheme_max_freq() {   # $1=scheme -> 输出 "L M P"
    case "$1" in
      sweet_eco)  echo "1353600 1468800 1497600" ;;
      sweet_perf) echo "3148800 3686400 4358400" ;;
      *)          echo "1641600 1804800 2044800" ;;
    esac
}
scheme_min_freq() {   # $1=scheme -> 输出 "L M P"
    case "$1" in
      sweet_perf) echo "912000 1142400 1497600" ;;
      *)          echo "417792 556800 1113600" ;;
    esac
}

# 把一组 (maxL maxM maxP minL minM minP) 真正写进 PM QoS。返回 "ok fail"
apply_qos_triplet() {
    local lmax="$1" mmax="$2" pmax="$3" lmin="$4" mmin="$5" pmin="$6"
    local ok=0 fail=0 c
    # 先抬地板（避免瞬时低于新上限的中间态被钳）
    for c in $CL_L; do qos_set_min "$c" "$lmin" && ok=$((ok+1)) || fail=$((fail+1)); done
    for c in $CL_M; do qos_set_min "$c" "$mmin" && ok=$((ok+1)) || fail=$((fail+1)); done
    for c in $CL_P; do qos_set_min "$c" "$pmin" && ok=$((ok+1)) || fail=$((fail+1)); done
    for c in $CL_L; do qos_set_max "$c" "$lmax" && ok=$((ok+1)) || fail=$((fail+1)); done
    for c in $CL_M; do qos_set_max "$c" "$mmax" && ok=$((ok+1)) || fail=$((fail+1)); done
    for c in $CL_P; do qos_set_max "$c" "$pmax" && ok=$((ok+1)) || fail=$((fail+1)); done
    log_quiet "qos applied: max=[$lmax $mmax $pmax] min=[$lmin $mmin $pmin] ok=$ok fail=$fail"
    echo "$ok $fail"
}



# 恢复 stock（卸载 / 复位用）：放开上限、地板回最低
restore_stock_freq() {
    for c in $ALL_CPUS; do
        qos_set_max "$c" "$(cat /sys/devices/system/cpu/cpu$c/cpufreq/cpuinfo_max_freq 2>/dev/null)"
    done
    qos_set_min 0 417792; qos_set_min 1 417792; qos_set_min 2 417792; qos_set_min 3 417792
    qos_set_min 4 556800; qos_set_min 5 556800; qos_set_min 6 556800; qos_set_min 7 556800
    qos_set_min 8 1113600; qos_set_min 9 1113600
    log_quiet "restored stock qos"
}


# ============================================================
#  A) 语义占位符（借鉴 Aether_OptExt 的多拓扑自适应）
# ------------------------------------------------------------
#  让同一套配置能在任意核心拓扑上复用：规则里写 {hp_core} 而不是写死 "8-9"。
#  O3 是 4+4+2 三层：
#     {e_core}  = 0-3     最低频层（小核 / 能效核）
#     {p1_core} = 4-7     中核
#     {p2_core} = (空)    只有 4 层 SOC 才有第二级中核
#     {p_core}  = 4-9     中核 ∪ 大核
#     {hp_core} = 8-9     最高频层（超大核）
#     {all_core}= 0-9     全部
# ============================================================
cpu_semantic() {   # $1=占位符名 -> 核号表达式
    case "$1" in
      e_core)   echo "0-3" ;;
      p1_core)  echo "4-7" ;;
      p2_core)  echo "" ;;
      p_core)   echo "4-9" ;;
      hp_core)  echo "8-9" ;;
      all_core) echo "0-9" ;;
      *)        echo "" ;;
    esac
}

# 把 "{hp_core}" / "{e_core},{p1_core}" 之类展开成真实核号
expand_semantic() {
    local v="$1" n
    case "$v" in *'{'*) ;; *) echo "$v"; return ;; esac
    for n in e_core p1_core p2_core p_core hp_core all_core; do
        case "$v" in
          *"{$n}"*) v=$(echo "$v" | sed "s/{$n}/$(cpu_semantic "$n")/g") ;;
        esac
    done
    # 展开后可能出现空段（例：p2_core 在 3 层 SOC 上为空），清掉多余分隔
    echo "$v" | sed 's/[, ][, ]*/,/g; s/^,//; s/,$//'
}

# ============================================================
#  B) 按在线核动态裁剪（同样借鉴 Aether_OptExt）
# ------------------------------------------------------------
#  热框架会把大核整个下线（/sys/devices/system/cpu/online 变成 "0-5" 之类）。
#  这时如果还往 sched_setaffinity / cpuset 里写含离线核的掩码，会报 EINVAL
#  并被每个周期重试 → 日志刷屏、绑核失效。
#  出配置前统一裁剪到在线核 ∩ present，核回线后下一轮自动恢复满配。
# ============================================================
# 零 fork 版：把结果写进全局 SEM_VAL，而不是用 $( ) 取回（$( ) 会开子 shell）
cpu_semantic_read() {   # $1=占位符名
    case "$1" in
      e_core)   SEM_VAL="0-3" ;;
      p1_core)  SEM_VAL="4-7" ;;
      p2_core)  SEM_VAL="" ;;
      p_core)   SEM_VAL="4-9" ;;
      hp_core)  SEM_VAL="8-9" ;;
      all_core) SEM_VAL="0-9" ;;
      *)        SEM_VAL="" ;;
    esac
    return 0
}

# 零 fork 版：读 /sys/devices/system/cpu/online → 全局 ONLINE_RAW
online_cpus_read() {
    ONLINE_RAW=""
    [ -r /sys/devices/system/cpu/online ] && read -r ONLINE_RAW < /sys/devices/system/cpu/online
    [ -n "$ONLINE_RAW" ] || ONLINE_RAW="0-9"
    return 0
}

# 零 fork 版 cpu_expr_to_list：把 "0-3,8-9" 展开成 "0 1 2 3 8 9" → 全局 CPU_LIST
#   （逻辑与 cpu_expr_to_list 完全一致，只是写全局变量、不起子 shell）
cpu_expr_to_list_read() {
    CPU_LIST=""
    local e="$1" c a b i
    while [ -n "$e" ]; do
        case "$e" in
          *,*) c="${e%%,*}"; e="${e#*,}" ;;
          *)   c="$e"; e="" ;;
        esac
        case "$c" in
          *-*) a="${c%%-*}"; b="${c##*-}" ;;
          *)   a="$c"; b="$c" ;;
        esac
        case "$a$b" in *[!0-9]*) continue ;; esac
        i="$a"
        while [ "$i" -le "$b" ]; do CPU_LIST="$CPU_LIST $i"; i=$((i+1)); done
    done
    return 0
}
online_cpus()  { cat /sys/devices/system/cpu/online  2>/dev/null; }
present_cpus() { cat /sys/devices/system/cpu/present 2>/dev/null; }

# "0-3,8-9" -> "0 1 2 3 8 9"
cpu_expr_to_list() {
    local e="$1" c a b i out=""
    while [ -n "$e" ]; do
        case "$e" in
          *,*) c="${e%%,*}"; e="${e#*,}" ;;
          *)   c="$e"; e="" ;;
        esac
        case "$c" in
          *-*) a="${c%%-*}"; b="${c##*-}" ;;
          *)   a="$c"; b="$c" ;;
        esac
        case "$a$b" in *[!0-9]*) continue ;; esac
        i="$a"
        while [ "$i" -le "$b" ]; do out="$out $i"; i=$((i+1)); done
    done
    echo "$out"
}

# "0 1 2 3 8 9" -> "0-3,8-9"
cpu_list_to_expr() {
    local out="" st="" prev="" c
    for c in $1; do
        if [ -n "$prev" ] && [ "$c" -eq "$((prev+1))" ]; then prev="$c"; continue; fi
        if [ -n "$st" ]; then
            if [ "$st" = "$prev" ]; then out="$out,$st"; else out="$out,$st-$prev"; fi
        fi
        st="$c"; prev="$c"
    done
    if [ -n "$st" ]; then
        if [ "$st" = "$prev" ]; then out="$out,$st"; else out="$out,$st-$prev"; fi
    fi
    echo "${out#,}"
}

# 裁剪到在线核。交集为空时**原样返回**（宁可不动，也不要写出空集合，
# 空 cpuset 会让内核拒绝整条规则、比不裁剪更糟）。
clip_online() {
    local expr="$1" on lst c
    on=$(cpu_expr_to_list "$(online_cpus)")
    [ -z "$on" ] && { echo "$expr"; return; }
    lst=$(cpu_expr_to_list "$expr")
    [ -z "$lst" ] && { echo "$expr"; return; }
    local res=""
    for c in $lst; do
        case " $on " in *" $c "*) res="$res $c" ;; esac
    done
    [ -z "$res" ] && { echo "$expr"; return; }
    cpu_list_to_expr "$res"
}


# ============================================================
#  C) 游戏线程规则：模板 + 分配（TSV 驱动）
# ------------------------------------------------------------
#  用户要求：游戏的 CPU 频率跟随 Scene 对它的单应用设置，但**线程单独定义**、
#  通过模板套用。所以游戏不进「应用→模式」的分组，走这里的模板。
#
#  game_templates.tsv（制表符分隔，8 列，首行 # 注释）：
#     id  friendly  other  heaviest_thread  heaviest_cores  heavy_thread  heavy_cores  comm
#  comm 格式：用 ';' 分组，每组 "核号=线程名,线程名"
#     例：{p1_core}=RenderThread,GLThread;{e_core}=Audio,FMOD
#  核号列支持语义占位符（{hp_core} 等），生成时才展开。
#
#  game_assign.tsv（制表符分隔，2 列）：
#     pkg  template_id
# ============================================================
GAME_TPL_FILE="${WEBUI_DIR}/game_templates.tsv"
GAME_ASSIGN_FILE="${WEBUI_DIR}/game_assign.tsv"
# 应用（非游戏）线程模板：与游戏模板同格式、同生成器。
# 线程只由模板驱动（不再跟随全局模式的「核心」集合，见 gen_threads_from_scene）。
APP_TPL_FILE="${WEBUI_DIR}/app_templates.tsv"
APP_ASSIGN_FILE="${WEBUI_DIR}/app_assign.tsv"

# 生成规则 JSON 到 stdout（通用：游戏 / 应用共用同一套生成器）
#   $1=模板文件(TSV)  $2=分配文件(TSV: pkg<TAB>tpl_id)
#
# ⚠ 用纯 awk 而不是 shell 的 `while IFS=... read`：
#   1) shell 里用单引号包 \t 得到的是**字面反斜杠+t**，不是制表符；
#   2) IFS 里的制表符属"空白"，read 会把连续制表符**折叠**，
#      于是 TSV 一旦有空字段就整体错位（本项目模板里确实有空字段）。
#   awk 的 -F/-v 对 \t 的解释是可靠的，且不会折叠空字段。
gen_rules_json() {
    local tpl="$1" asg="$2" shape="${3:-game}"
    [ -f "$tpl" ] || return 0
    [ -s "$asg" ] || return 0

    awk \
      -v SHAPE="$shape" \
      -v FS="$(printf '\t')" \
      -v TAB="$(printf '\t')" \
      -v ONLINE="$(cpu_expr_to_list "$(online_cpus)")" \
      -v SEMe="$(cpu_semantic e_core)" \
      -v SEMp1="$(cpu_semantic p1_core)" \
      -v SEMp2="$(cpu_semantic p2_core)" \
      -v SEMp="$(cpu_semantic p_core)" \
      -v SEMhp="$(cpu_semantic hp_core)" \
      -v SEMall="$(cpu_semantic all_core)" \
      -v TPL="$tpl" -v ASG="$asg" '
    function sem(n) {
        if (n=="e_core")   return SEMe
        if (n=="p1_core")  return SEMp1
        if (n=="p2_core")  return SEMp2
        if (n=="p_core")   return SEMp
        if (n=="hp_core")  return SEMhp
        if (n=="all_core") return SEMall
        return ""
    }
    # 展开 {占位符}；未识别的占位符保留原样（由调用方判断）
    function expand(v,   n, guard) {
        guard = 0
        while (match(v, /\{[a-z0-9_]+\}/) && guard++ < 20) {
            n = substr(v, RSTART+1, RLENGTH-2)
            v = substr(v, 1, RSTART-1) sem(n) substr(v, RSTART+RLENGTH)
        }
        return v
    }
    # "0-3,8-9" -> " 0 1 2 3 8 9 "
    function plist(v,   n, p, i, a, b, j, out) {
        out = " "
        n = split(v, p, ",")
        for (i = 1; i <= n; i++) {
            if (p[i] == "") continue
            if (p[i] ~ /-/) { split(p[i], ab, "-"); a = ab[1]+0; b = ab[2]+0 }
            else { a = p[i]+0; b = a }
            for (j = a; j <= b; j++) out = out j " "
        }
        return out
    }
    # " 0 1 2 3 8 9 " -> "0-3,8-9"
    function lexpr(lst,   n, p, i, st, prev, out) {
        gsub(/ +/, " ", lst); sub(/^ /, "", lst); sub(/ $/, "", lst)
        n = split(lst, p, " ")
        out = ""; st = ""
        for (i = 1; i <= n; i++) {
            if (p[i] == "") continue
            if (st != "" && p[i]+0 == prev+1) { prev = p[i]+0; continue }
            if (st != "") out = out "," (st == prev ? st : st "-" prev)
            st = p[i]+0; prev = p[i]+0
        }
        if (st != "") out = out "," (st == prev ? st : st "-" prev)
        return substr(out, 2)
    }
    # 展开占位符 + 裁剪到在线核；结果为不可解析时返回空串
    function norm(v,   ex, lst, n, p, i, res) {
        if (v == "") return ""
        ex = expand(v)
        if (ex ~ /\{/) return ""
        lst = plist(ex); res = ""
        n = split(lst, p, " ")
        for (i = 1; i <= n; i++) {
            if (p[i] == "") continue
            if (index(" " ONLINE " ", " " p[i] " ") > 0) res = res " " p[i]
        }
        if (res == "") return lexpr(lst)
        return lexpr(res)
    }
    function jstr(v) { return "\"" v "\"" }
    function trim(x) { gsub(/^[ \t\r]+/, "", x); gsub(/[ \t\r]+$/, "", x); return x }
    BEGIN {
        # 读分配表 pkg -> tpl
        while ((getline line < ASG) > 0) {
            if (line == "" || line ~ /^#/) continue
            n = split(line, f, TAB)
            p = trim(f[1]); tid = trim(f[2])
            if (p != "" && tid != "") {
                cnt[tid]++
                pkgs[tid, cnt[tid]] = p
            }
        }
        close(ASG)
        printed = 0
    }
    {
        if ($0 == "" || $0 ~ /^#/) next
        id = trim($1)
        if (id == "" || cnt[id] == 0) next
        friendly = trim($2); other = trim($3)
        ht = trim($4); hc = trim($5); et = trim($6); ec = trim($7); comm = trim($8)
        oc = norm(other); ohc = norm(hc); oec = norm(ec)
        # ---- 应用形状：Scene 的 app_cpuset{main,render,other} ----
        # ⚠ 应用必须用这个形状。写成游戏的 cpuset{comm} 形状时，Scene 只按线程名零星
        #   匹配，应用整体（主线程/渲染线程）不会立刻落核，表现为「线程切换太晚」
        #   —— 实测：微信套「轻量·省电」后先跑在 4-9，过一阵才掉到 0-3。
        if (SHAPE == "app") {
            mn = ohc
            rd = (oec != "" ? oec : ohc)
            ot = oc
            if (mn == "" && ot == "") next      # 没有可用绑核 → 不生成这条规则
            if (printed) print ","
            printed = 1
            printf "  {\n    \"friendly\": %s,\n    \"packages\": [", jstr(friendly)
            for (k = 1; k <= cnt[id]; k++) printf "%s\"%s\"", (k > 1 ? ", " : ""), pkgs[id, k]
            printf "],\n    \"app_cpuset\": {\n"
            if (mn != "") printf "      \"main\": %s,\n", jstr(mn)
            if (rd != "") printf "      \"render\": %s,\n", jstr(rd)
            if (ot != "") printf "      \"other\": %s,\n", jstr(ot)
            printf "      \"children\": true\n    }\n  }"
            next
        }

        # ---- 游戏形状：cpuset（线程名 / comm 级精细绑核） ----
        if (ht == "" && et == "" && oc == "" && comm == "") next
        if (printed) print ","
        printed = 1
        printf "  {\n    \"friendly\": %s,\n    \"packages\": [", jstr(friendly)
        for (k = 1; k <= cnt[id]; k++) printf "%s\"%s\"", (k > 1 ? ", " : ""), pkgs[id, k]
        printf "],\n    \"cpuset\": {\n"
        if (ht != "")     printf "      \"heaviest_thread\": %s,\n", jstr(ht)
        if (ohc != "")    printf "      \"heaviest_cores\": %s,\n", jstr(ohc)
        if (et != "")     printf "      \"heavy_thread\": %s,\n", jstr(et)
        if (oec != "")    printf "      \"heavy_cores\": %s,\n", jstr(oec)
        if (oc != "")     printf "      \"other\": %s", jstr(oc)
        # comm：分组用分号，每组写成 核号=名1,名2
        if (comm != "") {
            ng = split(comm, grp, ";")
            buf = ""; cf = 0
            for (gi = 1; gi <= ng; gi++) {
                g = trim(grp[gi]); if (g == "") continue
                eq = index(g, "=")
                if (eq < 2) continue
                cn = norm(substr(g, 1, eq-1))
                cl = trim(substr(g, eq+1))
                if (cn == "" || cl == "") continue
                nn = split(cl, nm, ",")
                arr = ""
                for (k = 1; k <= nn; k++) { t = trim(nm[k]); if (t != "") arr = arr (arr == "" ? "" : ", ") jstr(t) }
                if (arr == "") continue
                buf = buf (cf++ ? ",\n      " : "\n      ") jstr(cn) ": [" arr "]"
            }
            if (buf != "") printf ",\n      \"comm\": {%s\n      }", buf
        }
        printf "\n    }\n  }"
    }
    END { if (printed) printf "\n" }
    ' "$tpl"
}
gen_game_rules_json() { gen_rules_json "$GAME_TPL_FILE" "$GAME_ASSIGN_FILE" game; }
# ============================================================
#  模式同步线程 —— Scene 里给应用设的模式 → 线程模板
# ------------------------------------------------------------
#  WebUI「应用」页早就有一个「跟随 Scene 模式自动切换线程模板」开关（settings.conf
#  的 mode_sync），但后端一直**只读 app_assign.tsv**，这个映射从没真正参与生成 ——
#  结果就是「在 Scene 里把相机设成性能，线程却还是 light」。
#  这里把它补上：映射只在后端定义一份，前端由 cmd_apps_tpl 下发同一份常量。
#
#  规则（与 WebUI 文案一致）：
#    · 只在「Scene 里**显式**设过模式」的应用上生效（powercfg.xml 里 key != "*"）；
#      只跟随全局默认的应用不参与，避免把没调过的应用全绑一遍。
#    · 优先级高于手动「套用模板」；被覆盖的包会从手动表里剔除（不是重复出现）。
#    · 映射到空串的档（fast）表示「不接管」，即该应用不生成线程规则。
#    · 关掉开关即完全回到手动模式。
# ============================================================
MODE2TPL_powersave="light"
MODE2TPL_balance="smooth"
MODE2TPL_performance="perf"
MODE2TPL_fast=""

mode2tpl() {   # $1=mode → 模板 id（空 = 不接管）
    case "$1" in
      powersave)   echo "$MODE2TPL_powersave" ;;
      balance)     echo "$MODE2TPL_balance" ;;
      performance) echo "$MODE2TPL_performance" ;;
      fast)        echo "$MODE2TPL_fast" ;;
      *)           echo "" ;;
    esac
}

# 列出「Scene 里显式设过模式」的 包<TAB>模板id（mode_sync 关闭时输出为空）
# ⚠ 用 awk 单进程解析，不要用 while-read + 参数展开去抠引号：
#   `"` 在 ${var#pat} 里各家 shell 的处理不一致（能过 dash 也可能被 sh 当字符串结尾），
#   实测直接写 `line="${line#*name="}"` 就触发了 unexpected EOF。
#   而且 powercfg.xml 有几百行，纯 shell 逐行处理还慢。
mode_sync_assign() {
    settings_load
    [ "$SET_MODE_SYNC" = "1" ] || return 0
    [ -f "$SCENE_POWERCFG" ] || return 0
    awk -v MAP="powersave=$MODE2TPL_powersave balance=$MODE2TPL_balance performance=$MODE2TPL_performance fast=$MODE2TPL_fast" '
      BEGIN {
        n = split(MAP, kv, " ")
        for (i = 1; i <= n; i++) { split(kv[i], a, "="); m[a[1]] = a[2] }
      }
      {
        # 行形如：  <string name="com.foo.bar">balance</string>
        if (!match($0, /name="[^"]*"/)) next
        pkg = substr($0, RSTART + 6, RLENGTH - 7)
        if (!match($0, />[^<]*</)) next
        mode = substr($0, RSTART + 1, RLENGTH - 2)
        if (pkg == "" || pkg == "*") next
        if (pkg !~ /\./) next                 # 非包名（如 device_info 之类）跳过
        if (!(mode in m)) next
        if (m[mode] == "") next               # fast → 不接管
        printf "%s\t%s\n", pkg, m[mode]
      }' "$SCENE_POWERCFG" 2>/dev/null
    return 0
}

# 合并「手动分配」+「模式同步覆盖」→ $1（模式同步优先，被覆盖的包不再出现两次）
build_app_assign_merged() {
    local out="$1" ov="${TMPD}/mode_ov.tsv"
    mode_sync_assign > "$ov" 2>/dev/null
    awk -F'\t' -v OV="$ov" -v ASG="$APP_ASSIGN_FILE" '
      BEGIN {
        while ((getline l < OV) > 0) {
          if (l == "") continue
          n = split(l, f, "\t"); if (f[1] != "" && f[2] != "") ovr[f[1]] = f[2]
        }
        close(OV)
        while ((getline l < ASG) > 0) {
          if (l == "" || l ~ /^#/) continue
          n = split(l, f, "\t"); if (f[1] == "" || f[2] == "") continue
          if (f[1] in ovr) continue          # 模式同步优先
          printf "%s\t%s\n", f[1], f[2]
        }
        close(ASG)
        for (p in ovr) printf "%s\t%s\n", p, ovr[p]
      }' > "$out" 2>/dev/null
    return 0
}

gen_app_rules_json()  {
    local merged="${TMPD}/app_asg.merged"
    build_app_assign_merged "$merged"
    gen_rules_json "$APP_TPL_FILE" "$merged" app
}

# ---------- 从 Scene 读取「应用 → 模式」与「游戏名单」----------
SCENE_PREFS_DIR="/data/data/com.omarea.vtools/shared_prefs"
SCENE_POWERCFG="${SCENE_PREFS_DIR}/powercfg.xml"
# 哪些应用被 Scene 当作游戏：shared_prefs/games.xml 里 value="true" 的包。
# ⚠ 这是权威来源（用户在 Scene 里勾的就是它），WebUI 的游戏板块与线程分配都读它。
SCENE_GAMES_XML="/data/data/com.omarea.vtools/shared_prefs/games.xml"

scene_mode_map() {   # 输出 "pkg<TAB>mode"，含 "*" 全局默认
    [ -f "$SCENE_POWERCFG" ] || return 1
    sed -n 's/.*<string name="\([^"]*\)">\([^<]*\)<\/string>.*/\1\t\2/p' "$SCENE_POWERCFG"
}

scene_default_mode() {
    local m; m=$(scene_mode_map 2>/dev/null | awk -F'\t' '$1=="*"{print $2}' | head -1)
    mode_valid "$m" || m=balance
    echo "$m"
}

# ============================================================
#  零 fork 读法（守护/落核每轮都要用，必须避免 $( ) 与 sed）
# ------------------------------------------------------------
#  原理：本机 fork 一次约 10~40ms；`$(cmd)` 会开子 shell，`sed`/`awk`/`md5sum`
#  更是整进程。所以这些热路径改成「纯 shell 内建 read + case + 参数展开」，
#  结果写入全局变量而不是用 $( ) 取回。
# ============================================================

# 读某个包在 powercfg.xml 里的**显式**模式 → 全局 SCENE_MODE_ONE（空 = 没单独设过）
scene_mode_one_read() {   # $1=pkg（"*" 取全局默认）
    SCENE_MODE_ONE=""
    [ -f "$SCENE_POWERCFG" ] || return 0
    local line pat="<string name=\"$1\">"
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
          *"$pat"*)
            line="${line#*$pat}"
            SCENE_MODE_ONE="${line%%<*}"
            break
            ;;
        esac
    done < "$SCENE_POWERCFG"
    return 0
}

# 全局默认模式 → 全局 SCENE_MODE_DEF
scene_mode_def_read() {
    scene_mode_one_read "*"
    SCENE_MODE_DEF="${SCENE_MODE_ONE:-balance}"
    mode_valid "$SCENE_MODE_DEF" || SCENE_MODE_DEF="balance"
    return 0
}

# 取某模式某状态的六值串 → 全局 PRESET6（"Lmin Lmax Mmin Mmax Pmin Pmax"）
freq_preset_read() {      # $1=mode $2=active|inactive
    PRESET6=""
    freq_presets_ensure
    [ -s "$FREQ_CACHE" ] || return 0
    local line pre="$1|$2|"
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
          "$pre"*) PRESET6="${line#$pre}"; break ;;
        esac
    done < "$FREQ_CACHE"
    return 0
}

installed_pkgs() {   # 与 WebUI 的过滤口径一致
    # ⚠ 只查一次包管理器：旧写法同时跑 `cmd package` + `pm` 两遍（各 ~100ms+），
    #   而本函数在 status/appmodes/apps_tpl 里都会被间接调用。
    local out
    out=$(cmd package list packages 2>/dev/null | sed 's/^package://')
    [ -n "$out" ] || out=$(pm list packages 2>/dev/null | sed 's/^package://')
    printf '%s\n' "$out" | sort -u | grep -v '^android$' \
      | grep -v -E 'overlay|\.rro|auto_generated|shared_library'
}

scene_games() {   # 被 Scene 标记为游戏的包名
    [ -f "$SCENE_GAMES_XML" ] || return 0
    sed -n 's/.*<boolean name="\([^"]*\)" value="true".*/\1/p' "$SCENE_GAMES_XML" \
      | grep -v '^$' | sort -u
}

# 每个已安装应用 → 它该用的模式。
#   · xml 里显式指定且在 4 档内 → 用它的
#   · 指定为 igoned/none → 跳过（不给规则 = 不接管）
#   · 其它/未列出 → 用全局默认（"*"）
scene_pkg_modes() {
    local def map inst
    def=$(scene_default_mode)
    map="${TMPD}/appmode.txt"; inst="${TMPD}/inst.txt"
    mkdir -p "$TMPD" 2>/dev/null
    scene_mode_map > "$map" 2>/dev/null || : > "$map"
    installed_pkgs > "$inst"
    awk -F'\t' -v def="$def" '
        NR==FNR { if ($1!="" && $1!="*") m[$1]=$2; next }
        {
            p=$1; v=m[p]
            if (v=="") v=def
            if (v=="igoned" || v=="none" || v=="disabled") next
            if (v!="powersave" && v!="balance" && v!="performance" && v!="fast") v=def
            print p"\t"v
        }
    ' "$map" "$inst"
}

# ============================================================
#  按「模板分配」重建 threads.json
# ------------------------------------------------------------
#  · 线程只由模板驱动（游戏模板 + 应用模板），**不再跟随全局模式的「核心」集合**。
#    理由（用户要求 #3）：线程分配不该由全局模式配置决定，统一走模板，
#    这样「模式」页只管频率，「应用/游戏」页管线程，职责清晰、不会错配。
#  · 游戏（Scene 的 games.xml 里 value="true"）→ 游戏模板（game_templates.tsv）。
#  · 普通应用 → 应用模板（app_templates.tsv）。未分配模板的应用不写规则，
#    由 Scene 走它自己的默认 cpuset（不会误绑核）。
#  · 不再 chattr 加锁（锁定已废除）。
#
#  ⚠ 防误覆盖：当「没有任何模板分配」时**不动** threads.json，
#    保留 Scene 自带的默认线程规则（否则会把整机关成无规则、全走默认核）。
# ============================================================
gen_threads_from_scene() {
    local out gp gf gfcount ag gg
    out="${TMPD}/threads.new"; gp="${TMPD}/gamepkgs.txt"
    mkdir -p "$TMPD" 2>/dev/null

    scene_games > "$gp"

    # 应用规则：由 应用模板 + 应用分配 现场生成
    gen_app_rules_json > "${TMPD}/apps.gen" 2>/dev/null
    # 游戏规则：由 游戏模板 + 游戏分配 现场生成
    gen_game_rules_json > "${TMPD}/games.gen" 2>/dev/null

    ag=$(grep -c '"friendly"' "${TMPD}/apps.gen" 2>/dev/null)
    gg=$(grep -c '"friendly"' "${TMPD}/games.gen" 2>/dev/null)
    ag=${ag:-0}; gg=${gg:-0}

    # 没有任何分配 → 不覆盖 Scene 默认规则
    if [ "$ag" = 0 ] && [ "$gg" = 0 ]; then
        if [ ! -s "$APP_ASSIGN_FILE" ] && [ ! -s "$GAME_ASSIGN_FILE" ]; then
            log_quiet "gen: 无模板分配，保留 Scene 默认线程规则（未覆盖）"
            echo "OK 无模板分配，保留 Scene 默认线程规则"
            return 0
        fi
    fi

    # 游戏规则同时落一份到模块 Config 便于查看/备份
    if [ -s "${TMPD}/games.gen" ]; then
        gf="${MODCFG}/threads_games.json"
        if [ -d "$(dirname "$gf")" ]; then
            { printf '[\n'; cat "${TMPD}/games.gen"; printf '\n]\n'; } > "$gf" 2>/dev/null
            chmod 0644 "$gf" 2>/dev/null
        fi
    fi

    {
        printf '[\n'
        first=1
        if [ -s "${TMPD}/apps.gen" ]; then cat "${TMPD}/apps.gen"; first=0; fi
        if [ -s "${TMPD}/games.gen" ]; then [ $first -eq 0 ] && printf ',\n'; cat "${TMPD}/games.gen"; first=0; fi
        printf '\n]\n'
    } > "$out" 2>/dev/null

    local bad; bad=$(validate threads "$out")
    [ -n "$bad" ] && { echo "ERR 生成结果自检未通过：$bad"; return 1; }

    write_replace "$out" "${SCENE_DIR}/threads.json" || { echo "ERR 写入 Scene 失败"; return 1; }
    perm_file "${SCENE_DIR}/threads.json"
    ensure_scene_dir_perm >/dev/null 2>&1
    if [ -d "$(dirname "${MODCFG}/threads.json")" ]; then
        cp -f "$out" "${MODCFG}/threads.json" 2>/dev/null
        chmod 0644 "${MODCFG}/threads.json" 2>/dev/null
    fi
    log_quiet "generated threads.json from templates: apps=${ag} games=${gg}"

    # 未被分配模板的游戏 —— 报出来让用户在「游戏」页选模板。
    local unc="" g cov
    if [ -s "$gp" ]; then
        cov=$(awk -F'\t' 'NF>=2 && $1!="" && $1!~/^#/ {print $1}' "$GAME_ASSIGN_FILE" 2>/dev/null | sort -u)
        for g in $(cat "$gp"); do
            echo "$cov" | grep -qx "$g" || unc="$unc $g"
        done
    fi
    gfcount=$((ag + gg))

    if [ -n "$unc" ]; then
        echo "OK 已重建线程分配（${gfcount} 条规则：应用 ${ag} / 游戏 ${gg}）｜未配置模板的游戏:$unc"
    else
        echo "OK 已重建线程分配（${gfcount} 条规则：应用 ${ag} / 游戏 ${gg}）"
    fi
}

# ---------- 状态 ----------
active_scheme() { cat "$ACTIVE_FILE" 2>/dev/null; }
# 锁定已废除 ⇒ 永远「未锁定」。保留此函数是因为 action.sh / switch.sh 在用；
# 回 true 让它们统一走「可自由修改」的分支，不会再显示「已锁定」。
is_unlocked()   { return 0; }
scheme_name_cn() {
    case "$1" in
      sweet_eco)  echo "极致能效" ;;
      sweet_bal)  echo "日常均衡" ;;
      sweet_perf) echo "性能甜点" ;;
      *)          echo "$1" ;;
    esac
}

# ============================================================
#  线程模板：种子生成 + 显示名迁移
# ------------------------------------------------------------
#  ⚠ 2026-09-16 从 webui.sh 迁到这里：integrity.sh（一键还原/审计）也要用，
#    而它不是通过 webui.sh 调起的 —— 放在 webui.sh 里会导致「命令找不到」，
#    又不想把同一份实现复制两遍。util.sh 是所有脚本的公共前置，放这里最合适。
# ============================================================

# ============================================================
#  游戏（Scene 标记）+ 模板
#  实时读 Scene 的 games.xml，输出「游戏 → 模式」与模板分配，
#  供前端「游戏」页渲染：频率跟随 Scene 对单应用的设置，
#  线程由 GAME_TPL_FILE / GAME_ASSIGN_FILE 模板驱动（语义占位符，
#  方案与 Aether_OptExt 一致：{e_core}/{p_core}/{hp_core} + 线程名 comm 规则）。
# ============================================================
seed_game_templates() {
  [ -f "$GAME_TPL_FILE" ] && return 0
  mkdir -p "$(dirname "$GAME_TPL_FILE")" 2>/dev/null
  {
    printf '# id\tfriendly\tother\theaviest_thread\theaviest_cores\theavy_thread\theavy_cores\tcomm\n'
    printf 'unity\tUnity 游戏\t{p1_core}\tUnityMain\t{hp_core}\tUnityGfx\t{p_core}\t{hp_core}=RenderThread,GLThread;{p1_core}=Job.,Loading.;{e_core}=Audio,FMOD\n'
    printf 'default\t通用游戏\t{p1_core}\t\t\t\t\t{p_core}=RenderThread,GLThread;{e_core}=Audio\n'
  } > "$GAME_TPL_FILE" 2>/dev/null
  chmod 0666 "$GAME_TPL_FILE" 2>/dev/null
  log_quiet "webui: 已生成默认游戏线程模板"
}

# 模板显示名迁移（幂等）：老机器上 app_templates.tsv 已经存在，seed 不会再生成，
#   所以每次读取模板前都跑一次改名 —— 内容没变时不落盘（cmp + write_replace）。
#   只改 friendly 列，模板 id 与核心/线程定义一律不动。
TPL_RENAME_MAP="light:轻量·省电:省电 smooth:流畅日常:均衡 perf:高性能:性能"
fix_tpl_labels() {   # $1 = tsv 路径
    [ -f "$1" ] || return 0
    mkdir -p "$TMPD" 2>/dev/null
    local t="${TMPD}/tpl.rename"
    awk -F'\t' -v OFS='\t' -v MAP="$TPL_RENAME_MAP" '
      BEGIN { n = split(MAP, kv, " "); for (i = 1; i <= n; i++) { split(kv[i], a, ":"); OLD[a[1]] = a[2]; NEW[a[1]] = a[3] } }
      { if ($1 in OLD && $2 == OLD[$1]) $2 = NEW[$1]; print }
    ' "$1" > "$t" 2>/dev/null || { rm -f "$t"; return 0; }
    [ -s "$t" ] || { rm -f "$t"; return 0; }
    if ! cmp -s "$t" "$1" 2>/dev/null; then
        write_replace "$t" "$1" && chmod 0666 "$1" 2>/dev/null \
            && log_quiet "webui: 模板名已更新（$(basename "$1")）"
    fi
    rm -f "$t" 2>/dev/null
    return 0
}

# 应用（非游戏）线程模板：参考 Aether_OptExt 的负载分级思路，结合玄戒 O3（4+4+2）。
#   e_core=0-3（小核） p1_core=4-7（中核） p_core=4-9（中+大） hp_core=8-9（超大核）
#   other=该应用全部「其它线程」的默认核；comm=按线程名单独挑核。
#   设计：省电应用压到小核；均衡应用主线程上中核、渲染线程上超大核；
#   性能应用主线程上超大核、重负载全放开到中+大核。
#   （2026-09-16 改名：轻量·省电→省电 / 流畅日常→均衡 / 高性能→性能，模板 id 不变）
seed_app_templates() {
  [ -f "$APP_TPL_FILE" ] && return 0
  mkdir -p "$(dirname "$APP_TPL_FILE")" 2>/dev/null
  {
    printf '# id\tfriendly\tother\theaviest_thread\theaviest_cores\theavy_thread\theavy_cores\tcomm\n'
    # 列语义（应用模板走 Scene 的 app_cpuset 形状）：
    #   other          → app_cpuset.other   （其余线程）
    #   heaviest_cores → app_cpuset.main    （主线程）
    #   heavy_cores    → app_cpuset.render  （渲染/GL 线程）
    # 省电（原「轻量·省电」）：整条应用都压小核（含主线程/渲染）
    printf 'light\t省电\t{e_core}\tmain\t{e_core}\trender\t{e_core}\t{e_core}=IO,Network,Http,Binder,Pool\n'
    # 均衡（原「流畅日常」）：主线程中核、渲染上超大核、其余小核
    printf 'smooth\t均衡\t{e_core}\tmain\t{p1_core}\trender\t{hp_core}\t{hp_core}=RenderThread,GLThread,Vulkan;{p1_core}=Worker,Job,Async\n'
    # 性能（原「高性能」）：主线程/渲染上超大核，其余中+大核
    printf 'perf\t性能\t{p_core}\tmain\t{hp_core}\trender\t{hp_core}\t{hp_core}=RenderThread,GLThread,Vulkan;{p1_core}=Worker,Job,Async,Compute\n'
  } > "$APP_TPL_FILE" 2>/dev/null
  chmod 0666 "$APP_TPL_FILE" 2>/dev/null
  log_quiet "webui: 已生成默认应用线程模板"
}
