#!/system/bin/sh
# ============================================================
#  调度守护 guard.sh  (原 lock_guard.sh，2026-09-15 更名)
#
#  【为什么改名】「配置锁定」功能已按用户要求整体删除（历史上 chattr +i 会让
#    调度App 自己存不下配置：点小齿轮改特性、切模式都会 ENOTSUP 失败，
#    现象就是「改了没反应」）。这个脚本从来就不是锁，而是**同步 + 落核**守护，
#    名字里的 lock 会误导，故更名。
#
#  【职责】
#    1) 调度App 数据目录必须可进入（缺 x 会让 调度App 卡在启动 splash）
#    2) 调度App 配置必须可写（清掉历史残留的 chattr 标志，调度App 才存得下设置）
#    3) 调度App 的「应用→模式」表 / 游戏名单 / 模板分配一变 → 重建 threads.json
#    4) 把模板真正落到线程亲和性（调度App 自己不会应用 threads.json，见 enforce_threads.sh）
#
#  【功耗设计】（2026-09-15 二次治理，实测数据见 README §6）
#    · 亮屏：每 5s 一轮。但「廉价 tick」只在**亮屏**时查前台（dumpsys 约 32ms）；
#      息屏时完全不查 —— 屏幕内容不变、前台也不会切，查它纯属白烧电。
#    · 落核器带「已落核缓存」（pid + 规格 + cgroup 组，TTL 180s）：
#      稳定态下一轮只做一次比对，不再逐线程扫 /proc（300ms → 约 60ms）。
#    · 每 24 轮（120s）兜底一次全量核对，防外部改了亲和性。
#    · 日志可关（WebUI「日志」页），关闭后守护完全不写盘。
#
#  用法: guard.sh [interval_sec]       默认 5s
# ============================================================
MODDIR="${MODDIR:-/data/adb/modules/O3CPUSet}"
. "$MODDIR/lib/util.sh"

INTERVAL="${1:-5}"
ROUND=0
# ★ 自保：守护及其所有子进程都不持有模块目录（service.sh 已 cd /，这里再兜底一次，
#   防止被其它路径直接拉起时 CWD 停在模块目录 → KSU 禁用/卸载时 umount EBUSY 闪退）。
cd / || cd /data
# 「QoS 遗留值只清一次」的标记（见主循环里亮/息屏切换那段的原因说明）
QOS_CLEARED="${STATE_DIR}/qos_cleared"

# 线程配置：v18.2.9 起本守护只保证「配置存在」+「引擎在跑」，生成与落核全归舰长引擎。
AETHER_CTL="$MODDIR/Scripts/4+4+2/O3/aether/aether_ctl.sh"
AETHER_THREADS="/sdcard/Android/Aether/threads.json"
ONF="${STATE_DIR}/aether.on"
# 本模块二进制路径（pgrep -f 的完整路径已 regex 转义；「+」是元字符）
AETHER_BIN="$MODDIR/Scripts/4+4+2/O3/aether/aether-optext"
AETHER_BIN_RE="$(printf '%s' "$AETHER_BIN" | sed 's/[.[\*^$()+?{}|]/\\&/g')"

log "🛡 守护启动（亮屏 ${INTERVAL}s / 息屏 $((INTERVAL*6))s；频率兜底 + 线程配置保活，线程落核归舰长引擎）"

# ── 单例保护 ───────────────────────────────────────────────
#  service.sh 可能在开机 / `ksud services` 重跑时多次执行，若每次都拉起一个 guard，
#  会出现多实例抢写 调度App 配置、互相打架。这里用 pidfile 去重：已有存活实例就退出。
#  ⚠ 2026-10-10 修正：旧写法只 `kill -0 $old`，但 pid 会被**回收复用**（实测 pid 21378
#    被 com.tencent.wework:push 复用）→ `kill -0` 仍成功 → 守护误判「自己还活着」并立即
#    退出，导致守护实际从未运行（WebUI 一直显示「未运行」）。改为校验 /proc/$old/cmdline
#    确实含 guard.sh，避免陈旧 pidfile 造成的假单例。
GUARD_PIDFILE="${STATE_DIR}/guard.pid"
guard_alive() {  # $1=pid；仅当 /proc/$1/cmdline 含本脚本名才算活着
    [ -n "$1" ] || return 1
    [ -r "/proc/$1/cmdline" ] || return 1
    case "$(tr '\0' ' ' < "/proc/$1/cmdline" 2>/dev/null)" in
        *guard.sh*) return 0 ;;
    esac
    return 1
}
if [ -f "$GUARD_PIDFILE" ]; then
    old=$(cat "$GUARD_PIDFILE" 2>/dev/null)
    if guard_alive "$old"; then
        log "· 守护已在运行（pid $old），跳过重复拉起"
        exit 0
    fi
fi
rm -f "$GUARD_PIDFILE" 2>/dev/null
echo $$ > "$GUARD_PIDFILE" 2>/dev/null

# 亮屏=1 / 息屏=0：所有背光都为 0 视为息屏
screen_on() {
    local f v
    for f in /sys/class/backlight/*/brightness /sys/class/leds/lcd-backlight/brightness; do
        [ -f "$f" ] || continue
        v=$(cat "$f" 2>/dev/null)
        case "$v" in ''|*[!0-9]*) continue ;; esac
        [ "$v" -gt 0 ] && { echo 1; return; }
    done
    echo 0
}

# ============================================================
#  省 fork 的判据（本机 fork 一次 10~40ms，是亮屏功耗的主因）
# ============================================================

# （src_changed / pkg_in_targets / SRC_MARK 已随老线程落核链路移除：
#   v18.2.9 起线程完全归舰长引擎，守护不再需要「输入变了没」「包在不在目标表」）

# 当前焦点窗口的包名（约 45ms，权威且稳定）。
#
# ⚠ 曾经用「/dev/cpuset/top-app 组里的 pid 集合」当信号，实测有两个致命问题：
#   1) 那里面混着本模块自己 fork 出来的进程（sh / resetprop / busybox / zn-*），
#      它们每次调用都在变 → 几乎每轮都误判「前台换过」，白跑一次完整落核（功耗翻几倍）；
#   2) 它只能告诉你「一组进程」，无法回答「现在前台是哪个应用」，而频率要按应用定。
#
# ⚠⚠ 2026-09-17 真机修正（本函数曾经**恒返回空**，导致落核从来没跑过）：
#    `dumpsys window` 里会出现**多行** `mCurrentFocus`，而且**第一行是 `null`**
#    （非默认 display 的占位行）。旧写法 `grep -m1 mCurrentFocus` 恰好取到那个
#    null → `FG=""` → `pkg_in_targets ""` 为假 → `enforce_threads.sh` 永不执行。
#    真机实测（lhasa / 2608BPX34C）同一份 dump：
#        mCurrentFocus=null
#        ...
#        mCurrentFocus=Window{92e4e34 u0 com.omarea.vtools/...}   ← 真实焦点在下面
#    修法两条：
#      1) 跳过所有 `=null` 的行，取**第一个非 null** 的；
#      2) 解析改用内建 `while read` + `case`，顺带省掉 grep 的一次 fork
#         （本机一次 fork 约 10~40ms，是亮屏功耗主因）。
fg_pkg() {
    local l pkg fg=""
    fg=$(dumpsys window 2>/dev/null | {
        while IFS= read -r l; do
            case "$l" in
              *"mCurrentFocus="*)
                case "$l" in *"=null"*) continue ;; esac
                printf '%s' "$l"; break
                ;;
            esac
        done
    })
    case "$fg" in
      *"Window{"*)
        pkg="${fg##* }"; pkg="${pkg%%/*}"; pkg="${pkg##* }"
        case "$pkg" in *.*) printf '%s' "$pkg" ;; *) printf '' ;; esac
        ;;
      *) printf '' ;;
    esac
}

# ============================================================
#  相机档位看护（辅助 camera_freq_guard.sh，只做「进相机那一刻」这一半）
# ------------------------------------------------------------
#  档位与读写逻辑都在 lib/util.sh 里（camera_freq_load / camera_band_ok /
#  camera_band_fix）—— 两个脚本用同一份，避免「守护读到 eco 档位、这里还按
#  bal 档位写」这种漂移。
# ============================================================
rd() { read -r v < "$1" 2>/dev/null; echo "${v:-}"; }

while :; do
    ROUND=$((ROUND+1))
    # ★ 自保 / 配合 KSU 禁用：KSU 禁用或卸载模块时会撤掉模块挂载，
    #   ${MODDIR}/Scripts 目录随之消失 → 守护立刻退出，避免常驻进程挡住 KSU
    #   卸载时的目录释放（否则 KSU 卡死闪退、模块无法禁用/卸载）。
    if [ ! -d "${MODDIR}/Scripts" ]; then
        # 模块要没了：顺手把独立的线程引擎（aether-optext）也停掉，
        # 否则它仍持有二进制文件、挡住卸载目录释放。
        pkill -f "O3/aether/aether-optext" 2>/dev/null
        exit 0
    fi
    on=$(screen_on)

    # 每轮重读开关（内建 read，不起子进程）：日志开关/频率开关改了立刻生效
    settings_load

    # 每 24 轮（≈120s）刷新模块卡片描述（内容没变就不落盘）
    [ $(( ROUND % 24 )) -eq 1 ] && update_module_desc >/dev/null 2>&1

    # ---- 亮/息屏切换 ----
    #   v18：频率完全由本模块 PM QoS 接管。屏幕状态切换时把「全局模式」频率重新
    #   下发一遍（只做一次，落标记避免反复写），确保 QoS 上下限回到模块设定的档位
    #   （thermal 可能在息屏期间把上限砍低，亮屏后由本模块拉回）。
    if [ "$on" != "$ON_PREV" ]; then
        if [ ! -f "$QOS_CLEARED" ]; then
            sh "$MODDIR/Scripts/4+4+2/O3/apply_freq.sh" >/dev/null 2>&1
            touch "$QOS_CLEARED" 2>/dev/null
        fi
        ON_PREV="$on"
        FG_SIG=""
    fi

    # ---- 廉价 tick ----
    #  ⚠ 息屏时**完全不查前台**：`dumpsys window` 一次约 32ms，息屏下屏幕内容不变、
    #    前台也不会切，查它纯属白烧电（每 5s 一次 ≈ 0.6% 单核 × 整夜）。
    #    亮屏时才查；前台包名一变就做重活（应用一打开，下一轮就生效）。
    #  · ROUND_STEP(5s) 一轮：前台变了 → 立刻处理（用户要的「打开就应用」）
    #  · 每 24 轮（120s）兜底一次全量：万一有进程被外部改了亲和性，最多 2 分钟自愈
    if [ "$on" = "1" ]; then
        FG=$(fg_pkg)
        # 相机前台标记（纯字符串匹配，0 子进程）——曾用于相机档位看护，v12 起
        # 该功能已移除；保留这个变量只为了前台识别时不被相机包名干扰
        case "$FG" in
          *camera*|*cameramind*) FG_CAM=1 ;;
          *)                     FG_CAM=0 ;;
        esac
        if [ "$FG" != "$FG_SIG" ] || [ $(( (ROUND - 1) % 24 )) -eq 0 ]; then
            FG_SIG="$FG"
            WORK=1
        else
            WORK=0
        fi
    else
        FG_CAM=0
        # 息屏：每 6 轮（30s）做一次兜底（重建线程分配 / 可写性自检）
        if [ $(( (ROUND - 1) % 6 )) -eq 0 ]; then WORK=1; else WORK=0; fi
    fi

    # ==== 线程核心分配：**完全由舰长引擎（aether-optext）负责** ====
    #  v18.2.9 起本守护不再做任何线程落核：老的 enforce_threads / pin_cgroup /
    #  load_aware / bigcore_guard / pinwatch 全链路已移除。
    #  · 规则源：aether/threads.json（模板）+ 用户自定义 → aether_ctl.sh deploy
    #  · 落核方：aether-optext（eBPF + 负载模型），守护不介入、不抢 cgroup 命名空间
    #  这里只保证「配置文件存在」，其余交给引擎自身。

    if [ "$WORK" = "1" ]; then

        # 只在「真的干活」时记一行（便于用户/我们判断功耗来源；WORK 轮很少）
        log_quiet "▶ work 第 $ROUND 轮 · 前台=${FG:-（息屏/无）}"

        # ---- 1) 频率兜底：每 WORK 轮把「全局模式」频率重新下发 ----
        #  v18：频率完全由本模块 PM QoS 接管（不再交给 调度App）。
        #  这里做兜底，防止被 thermal / 其它进程改掉；前台变化时再由 ② 做更精细的按-app 覆盖。
        current_mode_read 2>/dev/null
        if ! apply_mode_freq "${CUR_MODE:-balance}" >/dev/null 2>&1; then
            log_quiet "⚠ 全局模式频率下发失败（下轮重试）"
        fi

        # ---- 2) 前台应用频率覆盖（优先级：app_freq > app_assign/game_assign）----
        #  ① app_freq.tsv：用户在「分应用频率」页为该应用单独指定的模式档（最高优先）
        #  ② pkg_mode_of：app_assign / game_assign 里的模式档
        #  都没有则保持全局模式，避免无谓改写。
        if [ -n "$FG" ]; then
            APP_MODE=$(pkg_freq_of "$FG")
            [ -z "$APP_MODE" ] && APP_MODE=$(pkg_mode_of "$FG")
            if [ -n "$APP_MODE" ] && [ "$APP_MODE" != "${CUR_MODE:-balance}" ]; then
                if apply_mode_freq "$APP_MODE" >/dev/null 2>&1; then
                    log_quiet "▶ 前台 $FG → 按应用频率覆盖[$APP_MODE]"
                fi
            fi
        fi

        # ---- 3) 确保舰长的线程配置存在（规则生成 + 覆盖合并都归 aether_ctl）----
        #   v18.3.1：本守护**不再**生成/落核线程 —— 只负责「配置在不在」。
        #   · threads.json 丢失/为空 → 让 aether_ctl deploy 重新生成
        #   · 用户改了自定义分配 → WebUI 调 aetherset 时已即时 deploy，此处无需轮询
        if [ ! -s "$AETHER_THREADS" ]; then
            sh "$AETHER_CTL" deploy >/dev/null 2>&1
            log_quiet "🔁 threads.json 缺失 → 已让舰长重新部署配置"
        fi

        # （相机档位看护、超大核 8-9 cpuset 限制、camera_freq_guard 拉起 —— 均已移除。
        #   前者根因在 v12 从源头修掉；后两者随老落核链路（bigcore_guard.sh）一并删除，
        #   线程与 cpuset 现在完全由舰长引擎自行管理。）
    fi

    # ---- 引擎看护（每轮，不限于 WORK）----
    #   ⚠ v18.3.1 新增：线程完全交舰长后，**引擎是否活着**就成了唯一的线程保障。
    #   此前守护只查「threads.json 在不在」，引擎崩了/没起来一律无人察觉 ——
    #   实测强杀引擎后守护连等 3 轮都不会自愈，线程分配静默失效。
    #   这里每轮用一次 pgrep（≈30ms）比对，掉了就用 aether_ctl start 拉起（幂等）。
    if [ -f "$ONF" ] && [ -x "$AETHER_CTL" ]; then
        if ! pgrep -f "$AETHER_BIN_RE" >/dev/null 2>&1; then
            sh "$AETHER_CTL" start >/dev/null 2>&1
            log_quiet "🔄 舰长引擎未运行 → 已自动拉起（守护看护）"
        fi
    fi

    sleep "$INTERVAL"
done
