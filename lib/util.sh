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
[ -f "${MODDIR}/module.prop" ] || MODDIR="/data/adb/modules/O3CPUSet"

# ⚠ 用 ${VAR:-默认} 而不是硬赋值：单元测试要在沙盒里跑落盘逻辑，
#   硬赋值会让测试**静默地**去操作真机路径（本测试套件踩过：沙盒参数不生效，
#   测试"通过"其实是假阳性）。生产路径不变，只是允许外部覆盖。
STATE_DIR="${STATE_DIR:-/data/adb/O3CPUSet}"
ACTIVE_FILE="${STATE_DIR}/active_scheme"
LOG_FILE="${STATE_DIR}/o3cpuset.log"
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
SET_FREQ_SYNC="0"; SET_DEBUG="1"; LOG_ON=1

# 读 settings.conf。用 shell 内建 read 循环而不是 sed：
#   · 不起子进程（sed 每次约 5ms，守护每轮都要读）
#   · 一次读出全部键，避免多处各自 grep 一遍
settings_load() {
    SET_FREQ_SYNC="0"; SET_DEBUG="1"
    local line
    if [ -f "${WEBUI_DIR}/settings.conf" ]; then
        while IFS= read -r line; do
            case "$line" in
              # ⚠ v10 起**没有 mode_sync 了**：线程档位由 app_assign.tsv 自持，
              #   与 Scene 的关系改成「点一次『从 Scene 导入』」。历史 settings.conf
              #   里残留的 mode_sync=1 一律忽略 —— 否则又会退回
              #   「在 Scene 改一下模式，线程分组就跟着漂」的老问题。
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

    local guard logv desc old tmp mode
    mode=$(current_mode_read 2>/dev/null; echo "${CUR_MODE:-balance}")
    [ "${SET_DEBUG:-1}" = "1" ] && logv="开" || logv="关"
    if pgrep -f "O3/guard\.sh" >/dev/null 2>&1; then guard="运行中"; else guard="停止"; fi

    # v18 分工：频率 = 模块 PM QoS 接管；线程 = 艇长 Aether 引擎；调度器 = 模块 powercfg
    desc="功能状态｜频率 模块QoS(${mode}) · 线程 Aether · 调度器 powercfg · 守护 ${guard} · 日志 ${logv}"

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

# 重启 Scene 的核心分配服务（scene-daemon），让刚写入的 threads.json/profile.json 立刻生效。
# ⚠ 必须重启：Scene 把配置缓存在内存里，只改文件它不会重读
#   —— 这正是「线程切换太晚」（微信先跑 4-9、过一阵才掉到 0-3）的根因之一。
#   实测被 kill 后 Scene 自身会在 4~8 秒内自动拉起并重读配置。
# ⚠ 它**只**杀这个后台调度进程，不动 Scene 本体：
#   所以不会掉无障碍服务、不会让 Scene 失效 —— 相比 `am force-stop` 安全得多。
#   放在 lib/util.sh 是因为 profile_sync.sh（只 source 本文件）也要用它。
# 输出：重启后的 daemon PID（失败时返回非 0）
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
        # ⚠ 空数组（[]）是**合法结果**：把全部档位分配清空后，生成的就是它。
        #   不豁免的话「重建线程分配」会一直报「过小、疑似截断」而拒绝落盘。
        if [ "$(tr -d ' \t\r\n' < "$f" 2>/dev/null)" != "[]" ]; then
        [ "${sz:-0}" -ge 200 ] || { echo "threads.json 仅 ${sz} 字节，过小，疑似截断"; return 1; }
        grep -q '"friendly"' "$f" || { echo "threads.json 缺 friendly 字段"; return 1; }
        grep -q '"packages"' "$f" || { echo "threads.json 缺 packages 字段"; return 1; }
        fi
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

# ---------- 频率档位校验工具 ----------
clamp_freq() {  # $1=cpu $2=target -> 最接近且 ≤ target 的可用频率
    local c="$1" t="$2" avail f best="" hi lo
    avail="$(cat /sys/devices/system/cpu/cpu$c/cpufreq/scaling_available_frequencies 2>/dev/null)"
    if [ -z "$avail" ]; then
        hi="$(cat /sys/devices/system/cpu/cpu$c/cpufreq/cpuinfo_max_freq 2>/dev/null)"
        lo="$(cat /sys/devices/system/cpu/cpu$c/cpufreq/cpuinfo_min_freq 2>/dev/null)"
        [ -n "$hi" ] && [ "$t" -gt "$hi" ] && { echo "$hi"; return; }
        [ -n "$lo" ] && [ "$t" -lt "$lo" ] && { echo "$lo"; return; }
        echo "$t"; return
    fi
    for f in $avail; do
        if [ "$f" -le "$t" ]; then
            if [ -z "$best" ] || [ "$f" -gt "$best" ]; then best="$f"; fi
        fi
    done
    [ -z "$best" ] && best="$(echo "$avail" | tr ' ' '\n' | sort -n | head -n1)"
    echo "$best"
}

# 写单个 CPU 的 QoS 上限；返回 0=成功
qos_set_max() {   # $1=cpu $2=freq
    local f="/sys/devices/system/cpu/cpu$1/qos/max_freq"
    [ -e "$f" ] || return 1
    echo "$(clamp_freq "$1" "$2")" > "$f" 2>/dev/null || return 1
    return 0
}

qos_set_min() {   # $1=cpu $2=freq
    local f="/sys/devices/system/cpu/cpu$1/qos/min_freq"
    [ -e "$f" ] || return 1
    echo "$(clamp_freq "$1" "$2")" > "$f" 2>/dev/null || return 1
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
#     powersave      417792/1560000   556800/1651200   1113600/2169600
#     balance        417792/1939200   556800/1968000   1113600/2371200
#     performance    672000/2246400   835200/2294400   1497600/2860800
#     fast           912000/3148800   1142400/3686400  2044800/4358400
#  ⚠ v18.2 校正（对齐 O3 实测能效，见 README §「档位现读，不写死」）：
#     · 省电档取实测偏低档（折中：比 sweet_eco 略高一点，日常仍跟手）；
#     · 流畅/性能的**中核上限**曾被抬到 2419200/3148800 —— 实测「M 簇 1550MHz
#       以上纯浪费」（能效 33.5→25.9 fps/W），已收回 1968000/2294400。
#  inactive 各自更低一档（后台不抢性能）。
# ============================================================
MODE_LIST="powersave balance performance fast"

# 用户自定义频率档位表（模块自有，覆盖内置 mode_freq 默认值）
# 每行: 模式<TAB>Lmin Lmax Mmin Mmax Pmin Pmax （active 档，前台频率）
FREQ_TIERS_FILE="${WEBUI_DIR}/freq_tiers.tsv"

mode_name_cn() {
    case "$1" in
      powersave)   echo "省电" ;;
      balance)     echo "流畅" ;;
      performance) echo "性能" ;;
      fast)        echo "极速" ;;
      *)           echo "$1" ;;
    esac
}
mode_from_cn() {
    case "$1" in
      省电|powersave)          echo powersave ;;
      均衡|流畅|balance)       echo balance ;;
      性能|performance)        echo performance ;;
      极速|fast)               echo fast ;;
      *)                       echo "" ;;
    esac
}
mode_valid() { case " $MODE_LIST " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

# ------------------------------------------------------------
#  频率档位：以 freq_tiers.tsv 为准，缺省回落内置四档
# ------------------------------------------------------------
mode_freq() {
    local md="$1"
    if [ -s "$FREQ_TIERS_FILE" ]; then
        local row; row=$(awk -F'\t' -v m="$md" '$1==m{print $2; exit}' "$FREQ_TIERS_FILE" 2>/dev/null)
        if [ -n "$row" ]; then
            local n; n=$(echo "$row" | wc -w | tr -d ' ')
            [ "$n" -ge 6 ] && { echo "$row"; return; }
        fi
    fi
    case "$md" in
      powersave)     echo "417792 1560000 556800 1651200 1113600 2169600" ;;
      balance)       echo "417792 1939200 556800 1968000 1113600 2371200" ;;
      performance)   echo "912000 2899200 1142400 3427200 2044800 4051200" ;;
      fast)          echo "912000 3148800 1142400 3686400 2044800 4358400" ;;
      *)             echo "" ;;
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
    # ⚠ v18.2.8：频率档位早已由 freq_tiers.tsv + 内置 mode_freq 接管，profile.json
    #   不再参与频率定义；但本函数仍会被 status/freqview 间接触发，逐次重建
    #   （md5sum + 解析 100KB profile.json ≈ 365ms）是切页卡顿的一大来源。
    #   现加 5 分钟 TTL：缓存存在且重建时间在 5 分钟内就直接返回（一次 date，≈15ms）。
    local now mtime age
    if [ -s "$FREQ_CACHE" ]; then
        now=$(date +%s 2>/dev/null); mtime=$(stat -c %Y "$FREQ_CACHE" 2>/dev/null || echo 0)
        [ -z "$mtime" ] && mtime=0
        age=$(( now - mtime ))
        [ "$age" -lt 300 ] && return 0
    fi
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
#  ★ 模块自有：全局模式 / 应用→模式 / 频率下发（v18 起不再依赖 Scene）
# ------------------------------------------------------------
#  v18 把频率/调度器/线程全部收归本模块，Scene 仅作为「可选的前端」存在（不再强依赖）。
#  下面三个函数是新的「真源」：全局模式 = active_mode 文件；应用→模式 = 模块自带
#  app_assign.tsv / game_assign.tsv；频率下发 = PM QoS（O3 上唯一被强制执行的旋钮）。
# ============================================================
ACTIVE_MODE_FILE="${ACTIVE_MODE_FILE:-${STATE_DIR}/active_mode}"
AETHER_THREADS="${AETHER_THREADS:-/sdcard/Android/Aether/threads.json}"

# 读模块自有「当前全局模式」：优先 active_mode 文件，回退方案名映射
current_mode_read() {
    CUR_MODE=""
    if [ -f "$ACTIVE_MODE_FILE" ]; then
        CUR_MODE=$(cat "$ACTIVE_MODE_FILE" 2>/dev/null | tr -d '\r' | head -1)
        case "$CUR_MODE" in
          powersave|balance|performance|fast) ;;
          *) CUR_MODE="" ;;
        esac
    fi
    if [ -z "$CUR_MODE" ]; then
        case "$(active_scheme 2>/dev/null)" in
          sweet_eco)  CUR_MODE="powersave" ;;
          sweet_bal)  CUR_MODE="balance" ;;
          sweet_hq)   CUR_MODE="performance" ;;
          sweet_perf) CUR_MODE="fast" ;;
          *)          CUR_MODE="balance" ;;
        esac
    fi
    export CUR_MODE
}
# 应用→模式：读模块自带 assign TSV（game_assign 优先，app_assign 兜底）
pkg_mode_of() {
    local p="$1" m=""
    [ -z "$p" ] && { echo ""; return; }
    [ -s "$GAME_ASSIGN_FILE" ] && m=$(awk -F'\t' -v P="$p" '$1==P{print $2; exit}' "$GAME_ASSIGN_FILE" 2>/dev/null)
    [ -z "$m" ] && [ -s "$APP_ASSIGN_FILE" ] && m=$(awk -F'\t' -v P="$p" '$1==P{print $2; exit}' "$APP_ASSIGN_FILE" 2>/dev/null)
    echo "$m"
}

# 分应用频率（WebUI「分应用频率」页）—— 优先级高于 pkg_mode_of。
#   app_freq.tsv 每行: 包名<TAB>模式档（powersave/balance/performance/fast）
#   未配置返回空。
APP_FREQ_FILE="${WEBUI_DIR}/app_freq.tsv"
pkg_freq_of() {
    local p="$1" m=""
    [ -z "$p" ] && { echo ""; return; }
    [ -s "$APP_FREQ_FILE" ] && m=$(awk -F'\t' -v P="$p" '$1==P{print $2; exit}' "$APP_FREQ_FILE" 2>/dev/null)
    mode_valid "$m" || m=""
    echo "$m"
}

# 把某模式的频率下发到 PM QoS（active 档：前台频率）
# 每簇 min<=max：UI 手拖可能把某簇「最低」设得比「最高」还大，写下去会被
#   内核钳死（频率卡在错误区间 → 冻屏/卡顿）。这里强制归正，绝不把反置值写进 QoS。
reorder_triplet() {   # in: Lmin Lmax Mmin Mmax Pmin Pmax -> out: 同序但每簇 min<=max
    local a=$1 b=$2 c=$3 d=$4 e=$5 f=$6
    [ "${a:-0}" -gt "${b:-0}" ] 2>/dev/null && { a=$2; b=$1; }
    [ "${c:-0}" -gt "${d:-0}" ] 2>/dev/null && { c=$4; d=$3; }
    [ "${e:-0}" -gt "${f:-0}" ] 2>/dev/null && { e=$6; f=$5; }
    echo "$a $b $c $d $e $f"
}

# 后台异步下发（WebUI「应用频率」调用不阻塞）：通过 ( ... & ) 双 fork 脱离 KSU
#   进程组，命令立即回 OK，真正的 QoS 写入在后台跑（守护每轮也会再次兜底）。
#   这样即便某个 sysfs 写入偶发较慢，也不会把 WebUI 调用卡住导致「模块冻死」。
apply_mode_freq_bg() {
    local md="${1:-$(active_mode)}"
    ( sh "$MODDIR/Scripts/4+4+2/O3/apply_freq.sh" --mode "$md" >/dev/null 2>&1 & )
    return 0
}

apply_mode_freq() {
    local md="$1"
    case "$md" in powersave|balance|performance|fast) ;; *) echo "ERR 未知模式: $md"; return 1 ;; esac
    set -- $(reorder_triplet $(mode_freq "$md" active))
    [ $# -lt 6 ] && { echo "ERR 无频率表: $md"; return 1; }
    # mode_freq 输出顺序: Lmin Lmax Mmin Mmax Pmin Pmax
    # apply_qos_triplet 入参: lmax mmax pmax lmin mmin pmin
    apply_qos_triplet "$2" "$4" "$6" "$1" "$3" "$5"
    echo "OK 频率已按模式[$md]下发 (L $1-$2 M $3-$4 P $5-$6)"
}

# 切换全局模式：写 active_mode 文件 + 立即下发频率
set_global_mode() {
    local md="$1"
    case "$md" in powersave|balance|performance|fast) ;; *) echo "ERR 未知模式: $md"; return 1 ;; esac
    echo "$md" > "$ACTIVE_MODE_FILE" 2>/dev/null
    apply_mode_freq "$md"
    echo "OK 全局模式 → $md ($(mode_name_cn "$md"))"
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
#     {lead_core}= 随当前模式变的「主力核」（见下）
#     {all_core}= 0-9     全部
# ============================================================

# ── {lead_core}：当前模式下的「主力核」（2026-09-17 新增）──────────────────
#  背景（极客湾实测 + 本机 profile 佐证）：
#    · C1-Ultra(cpu8-9) **只在 >2.2GHz 才有能效优势**，低频段反而最差，
#      而且**只有 2 个核** —— 把主线程/渲染线程直接绑上去是错的：
#      若该簇被压在低频，主线程会卡在「名义最强、实际最慢」的核上。
#    · C1-Premium(cpu4-7) 有 4 个核，且覆盖中间频段（能效甜点），
#      是**中高负载真正的主力**。
#  所以按「当前默认模式」决定主力核：
#      省电 / 均衡 / 性能 → 4-7（Premium 4 核）
#      极速               → 8-9（此时 Ultra 常驻 >2.2GHz，才划算）
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

# ---------- 模块自持的「应用/游戏 → 频率档」分配表 ----------
#   线程已完全由舰长引擎接管，这里的两张表只服务**频率**（pkg_mode_of 读取）。
GAME_ASSIGN_FILE="${WEBUI_DIR}/game_assign.tsv"
APP_ASSIGN_FILE="${WEBUI_DIR}/app_assign.tsv"

# ------------------------------------------------------------
#  系统相机：线程**默认「不接管」**（放开全核，交系统调度）
# ------------------------------------------------------------
#  相机不参与任何线程档位，WebUI 应用列表里也不展示它的线程入口。
#  ✅ 为什么相机适合「不接管」：相机线程模型（HAL / ISP / 编码 / AI）跨进程跨线程，
#     硬绑主线程反而会把它挤到 2 核 Ultra 上；交回系统调度器最稳。
#     舰长的 none 角色即「main_thread/other 全开 0-9」，与这里的语义一致。
CAMERA_GLOB='com.android.camera*|com.xiaomi.camera*'          # shell case 用
CAMERA_RE='com[.]android[.]camera|com[.]xiaomi[.]camera'      # awk 用（子串匹配，含 cameraextensions/mind/tools）


# ---------- 状态 ----------
active_scheme() { cat "$ACTIVE_FILE" 2>/dev/null; }


# 方案名 → 中文
scheme_name_cn() {
    case "$1" in
      sweet_eco)  echo "极致能效" ;;
      sweet_bal)  echo "日常均衡" ;;
      sweet_perf) echo "性能甜点" ;;
      sweet_hq)   echo "满画质游戏" ;;
      *)          echo "$1" ;;
    esac
}

# ============================================================
#  线程档位表：种子生成（唯一定义处）
# ------------------------------------------------------------
#  ⚠ 2026-09-16 从 webui.sh 迁到这里：当时 integrity.sh（已于 v16.6 按用户要求移除）
#    也要用，而它不是通过 webui.sh 调起的 —— 放在 webui.sh 里会导致「命令找不到」，
#    又不想把同一份实现复制两遍。util.sh 是所有脚本的公共前置，放这里最合适。
#    （v16.6 移除 integrity.sh 之后，这里的 seed_* 仍被 customize.sh / webui.sh 调用，故保留。）
# ============================================================

# ============================================================
#  安装后自愈：合并 modules_update 暂存副本
#  （KSU 就地安装会留一份待更新副本；这里负责合并进在服目录）
# ============================================================
selfheal_pending_update() {
  local NVBASE="/data/adb" ID="O3CPUSet"
  local UPD="${NVBASE}/modules_update/${ID}" FIN="${NVBASE}/modules/${ID}"
  [ -d "$UPD" ] || return 0
  [ -f "$UPD/module.prop" ] || return 0

  local vc_u vc_m="0"
  vc_u=$(grep '^versionCode=' "$UPD/module.prop" 2>/dev/null | head -1 | cut -d= -f2 | tr -d '\r')
  [ -z "$vc_u" ] && vc_u="0"
  if [ -f "$FIN/module.prop" ]; then
    vc_m=$(grep '^versionCode=' "$FIN/module.prop" 2>/dev/null | head -1 | cut -d= -f2 | tr -d '\r')
    [ -z "$vc_m" ] && vc_m="0"
  fi

  # 不是更高版本：只清可能残留的 update 标记（修开关灰），不碰内容
  if [ "$vc_u" -le "$vc_m" ] 2>/dev/null; then
    [ -e "$FIN/update" ] && rm -f "$FIN/update" 2>/dev/null
    # ★ 顺手补回 .sh 的可执行位 —— 这是安装后最常被触发的一条路径（用户一开 WebUI 就跑），
    #   而 customize.sh 的就地合并会把文件设成 0644；不补的话 KSU 不会执行 service.sh，
    #   整个模块静默停摆（2026-09-18 实测踩到）。
    chmod 0755 "$FIN/service.sh" "$FIN/action.sh" "$FIN/uninstall.sh" 2>/dev/null
    chmod 0755 "$FIN"/lib/*.sh "$FIN"/Scripts/*/*/*.sh \
               "$FIN"/Config/*/*/*.sh "$FIN"/Config/*/*/*/*.sh 2>/dev/null
    # ⚠ 舰长引擎是**编译好的 ELF（无 .sh 后缀）**，合并后若丢了可执行位，
    #   service.sh 会起不来它 —— 而且是静默失败（`[ -x ... ]` 判 false 直接跳过）。
    chmod 0755 "$FIN/Scripts/4+4+2/O3/aether/aether-optext" 2>/dev/null
    return 0
  fi

  # 合并暂存副本进正在服务的目录
  cp -af "$UPD"/. "$FIN"/ 2>/dev/null
  if [ -f "$FIN/module.prop" ] && [ -f "$FIN/service.sh" ] \
     && [ -f "$FIN/webroot/index.html" ] && [ -f "$FIN/lib/util.sh" ]; then
    rm -f "$FIN/update" "$FIN/remove" 2>/dev/null
    chmod 0755 "$FIN/service.sh" "$FIN/action.sh" "$FIN/uninstall.sh" 2>/dev/null
    chmod 0755 "$FIN"/Scripts/*/*/*.sh "$FIN"/Config/*/*/*.sh "$FIN"/Config/*/*/*/*.sh 2>/dev/null
    chmod 0755 "$FIN/Scripts/4+4+2/O3/pinwatch" 2>/dev/null
    # 让正在服务的守护用上新脚本（不重启）
    local KSUD=""
    for c in /data/adb/ksu/bin/ksud /data/adb/ksud; do [ -x "$c" ] && { KSUD="$c"; break; }; done
    [ -z "$KSUD" ] && KSUD=$(command -v ksud 2>/dev/null)
    [ -n "$KSUD" ] && "$KSUD" services >/dev/null 2>&1
    [ -d "$UPD" ] && rm -rf "$UPD" 2>/dev/null
    return 0
  fi
  # 校验不通过：保留 modules_update 副本，绝不删（下次访问再试）
  return 1
}
