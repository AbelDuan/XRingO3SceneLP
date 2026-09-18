#!/system/bin/sh
# ============================================================
#  调度守护 guard.sh  (原 lock_guard.sh，2026-09-15 更名)
#
#  【为什么改名】「配置锁定」功能已按用户要求整体删除（历史上 chattr +i 会让
#    Scene 自己存不下配置：点小齿轮改特性、切模式都会 ENOTSUP 失败，
#    现象就是「改了没反应」）。这个脚本从来就不是锁，而是**同步 + 落核**守护，
#    名字里的 lock 会误导，故更名。
#
#  【职责】
#    1) Scene 数据目录必须可进入（缺 x 会让 Scene 卡在启动 splash）
#    2) Scene 配置必须可写（清掉历史残留的 chattr 标志，Scene 才存得下设置）
#    3) Scene 的「应用→模式」表 / 游戏名单 / 模板分配一变 → 重建 threads.json
#    4) 把模板真正落到线程亲和性（Scene 自己不会应用 threads.json，见 enforce_threads.sh）
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
MODDIR="${MODDIR:-/data/adb/modules/SceneO3Tuner}"
. "$MODDIR/lib/util.sh"

INTERVAL="${1:-5}"
ROUND=0
# 「QoS 遗留值只清一次」的标记（见主循环里亮/息屏切换那段的原因说明）
QOS_CLEARED="${STATE_DIR}/qos_cleared"

log "🛡 守护启动（亮屏 ${INTERVAL}s / 息屏 $((INTERVAL*6))s；同步线程分配 + 落核，不锁定配置）"

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
#  省 fork 的两个判据（本机 fork 一次 10~40ms，是亮屏功耗的主因）
# ============================================================

# 输入（模板 / 分配 / Scene 模式表 / 游戏名单 / 开关）里有没有比「上次重建标记」更新的
#   —— 用内建 `-nt`，0 子进程；旧写法是 7 次 md5sum（约 70~150ms）
SRC_MARK="${STATE_DIR}/scene.mark"
src_changed() {
    [ -f "$SRC_MARK" ] || return 0
    local f
    for f in "$SCENE_POWERCFG" "$SCENE_GAMES_XML" "$GAME_ASSIGN_FILE" "$GAME_TPL_FILE" \
             "$APP_ASSIGN_FILE" "$APP_TPL_FILE" "${WEBUI_DIR}/settings.conf"; do
        [ -f "$f" ] && [ "$f" -nt "$SRC_MARK" ] && return 0
    done
    return 1
}

# 某个包是否在落核目标表里（纯内建 read，0 子进程）
pkg_in_targets() {
    [ -s "$TMPD/t.targets" ] || return 1
    local line pre="$1|"
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in "$pre"*) return 0 ;; esac
    done < "$TMPD/t.targets"
    return 1
}

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
    on=$(screen_on)

    # 每轮重读开关（内建 read，不起子进程）：日志开关/频率开关改了立刻生效
    settings_load

    # 每 24 轮（≈120s）刷新模块卡片描述（内容没变就不落盘）
    [ $(( ROUND % 24 )) -eq 1 ] && update_module_desc >/dev/null 2>&1

    # ---- 亮/息屏切换 ----
    #   ⚠ CPU 调频已**交回 Scene 接管**（本模块不写任何频率节点）。
    #   ⚠⚠ 这里曾经每次都跑 apply_freq.sh 清 v2 遗留的 QoS 值。实测它有个坑：
    #      它把 QoS 上限清成 `cpuinfo_max_freq`，而 **cpuinfo_max_freq 会跟着
    #      thermal 限频 + 光感变**（夜间相机 = 被砍到 1190400）。于是「亮屏/息屏」
    #      这个和相机毫无关系的动作，会把相机正在用的频率区间直接掀掉 ——
    #      这正是用户看到的「打开相机频率冲高后马上回落并严重限频」。
    #      QoS 是跨重启持久化的，遗留值只在**模块刚升级/改过档位**时才存在，
    #      不是每次亮息屏都会有。所以改成「只清一次」：清过就落个标记，不再碰。
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

    if [ "$WORK" = "1" ]; then

        # 只在「真的干活」时记一行（便于用户/我们判断功耗来源；WORK 轮很少）
        log_quiet "▶ work 第 $ROUND 轮 · 前台=${FG:-（息屏/无）}"

        # ---- 1) 目录可进入（Scene 卡 splash 的直接原因）----
        if ! dir_x_ok "$SCENE_DIR"; then
            log_quiet "⚠ Scene files 目录缺执行位 → 修复"
            ensure_scene_dir_perm >/dev/null
        fi

        # ---- 2) Scene 配置必须可写 ----
        # 只在「确实写不进去」时才修复，避免每轮都 cp 一遍文件。
        if ! can_write "${SCENE_DIR}/profile.json" 2>/dev/null; then
            r=$(repair_scene_writable)
            log "🔧 Scene 配置被锁住 → 已修复可写性（$r）"
        fi

        # ---- 3) 输入变了才会重建线程分配（0 子进程判据）----
        CHANGED=0
        if src_changed; then
            CHANGED=1
            if out=$(gen_threads_from_scene 2>&1); then
                touch "$SRC_MARK" 2>/dev/null
                log "🔁 Scene 配置变化 → 已重建线程分配（默认模式=$(scene_default_mode)）"
            else
                log_quiet "⚠ 重建线程分配失败（下轮重试）：$out"
            fi
        fi

        # ---- 4) threads.json 丢了/空了 → 重建 ----
        if [ ! -s "${SCENE_DIR}/threads.json" ]; then
            gen_threads_from_scene >/dev/null 2>&1
            touch "$SRC_MARK" 2>/dev/null
            CHANGED=1
        fi

        # ---- 5) 把「模板分配」真正落到线程亲和性 ----
        # ⚠ 必须由我们落核：Scene **不会**应用 threads.json 里的规则（实测冷启动 60s
        #   主线程/工作线程仍是 0-9）。
        # ⚠⚠ 这里加了「要不要跑」的闸门：落核脚本本身约 300ms（本机一个子进程 10~40ms），
        #    而绝大多数前台应用根本没配模板 —— 那种情况下跑它纯属白烧电。
        #    只在「输入变了」或「新前台在目标表里」时才跑；应用切到后台的情形由
        #    每 24 轮（120s）的兜底覆盖（而且后台组预算只有 0-3，内核本来就会夹住）。
        if [ "$CHANGED" = "1" ] || pkg_in_targets "$FG"; then
            sh "$MODDIR/Scripts/4+4+2/O3/enforce_threads.sh" >/dev/null 2>&1
        fi

        # ---- 6) 相机档位看护：**已移除（v12，2026-09-17）** ----
        #   它原本是 v7 的 workaround，修的是「Scene 的 _Camera.json 里 @cpu_freq
        #   签名错（5 参数）导致相机态 min==max 区间塌缩」。当时的做法是模块
        #   自己把档位写回 sysfs —— 但那与「CPU 频率交回 Scene」的约定是矛盾的。
        #
        #   现在根因已经在源头修掉：
        #     · 新的 _Camera.json 里**一个 @cpu_freq 都没有**，全部改引用
        #       profile.json 的 fast_active（合法 4 参数签名）→ 塌缩的成因结构性消失；
        #     · 相机固定走 fast 档 + 关掉 Scene 的「日用 app 辅助调速器」，
        #       实测打开相机 cpu0 稳定 1.5~2.9GHz（修前是 557056 单点锁死）。
        #   继续留着这段的坏处很实在：camera_freq_load() 在新结构下读不到档位，
        #   会退回内置兜底表，于是**每次打开相机都往 sysfs 写 3 个节点**
        #   （日志里那串「📷 相机档位校正」），等于模块还在抢频率。
        #
        #   camera_freq_guard.sh / apply_freq.sh 仍保留在原位，仅作**手动应急工具**，
        #   开机与守护都不再拉起。

        # ---- 6.5) 系统 cpuset 组不使用超大核 8-9（v16.11）----
        #   用户实测：桌面 / 切换应用时会看到 0-9、4-9 —— 来源不是本模块的落核
        #   （模块从不把线程放 8-9），而是系统自己的 cpuset 组：
        #     · top-app/cpus       出厂常见 0-9
        #     · foreground/boost   常见就是大核簇（4-9）
        #     · top-app/{main,render,other}  Scene「核心分配」按 v8 的 threads.json 写的
        #   bigcore_guard.sh 把这些组的 cpus 收到 0-7；父组一旦收到 0-7，
        #   外部再想给子组写 0-9 会被内核直接拒 → 从根上堵住。
        #   它读 cpus 全用 shell 内建 read（0 fork），只在需要改时才写，所以放在
        #   work 轮里几乎不花钱；另加「每 12 轮（60s）兜底」防外部改回去。
        if [ "$WORK" = "1" ] || [ $(( ROUND % 12 )) -eq 0 ]; then
            sh "$MODDIR/Scripts/4+4+2/O3/bigcore_guard.sh" quiet >/dev/null 2>&1
        fi

        # ---- 7) 频率：**不再由本模块处理** ----
        #   CPU 调频权限已交回 Scene（profile.json 的 <mode>_active/inactive @cpu_freq）。
        #   原来这里每当前台一变就跑一次 apply_freq.sh -f "$FG"，已移除。
    fi

    sleep "$INTERVAL"
done
