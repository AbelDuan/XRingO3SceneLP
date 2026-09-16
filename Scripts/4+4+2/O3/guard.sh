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
fg_pkg() {
    local line pkg
    line=$(dumpsys window 2>/dev/null | grep -m1 mCurrentFocus)
    case "$line" in
      *"Window{"*)
        pkg="${line##* }"; pkg="${pkg%%/*}"; pkg="${pkg##* }"
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
        # 相机前台标记（纯字符串匹配，0 子进程）——相机档位看护要用
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

        # ---- 6) 相机档位看护 ----
        #   本机相机有个「冲高 → 回落 → 严重限频」的三段式问题，根因在 Scene 的
        #   _Camera.json（详见 camera_freq_guard.sh 头部）。这里做的是**最省事的那一半**：
        #   · 相机在前台时，值不对就写回相机档位（先 min 后 max）
        #   · 但先跑一次原生「清 QoS 残留」：
        #       一个字节都没写 → 上界已是硬件最高 → 写它的是 Scene 自己，
        #                         我们绝不覆盖（交权 Scene，这也是当初的约定）
        #       写了               → 上界是**我们模块自己**留下的 → 写回相机档位
        #   ⚠ 为什么放在这里而不是单开一个守护进程：本函数所在的分支**只在前台
        #     切换时**进入，也就是「进入相机的这一刻」正好天然命中；其余时间
        #     （包括整个相机期间）一次都不会跑。常驻轮询没有存在的必要。
        #     QOS_CLEARED 那个门闸保证「清残留」这件事全模块只发生一次。
        if [ "$FG_CAM" = "1" ] && ! camera_band_ok; then
            s=$(sh "$MODDIR/Scripts/4+4+2/O3/apply_freq.sh" 2>/dev/null | tail -1)
            case "$s" in
              *"未写任何节点"*)
                log_quiet "📷 相机频率不对但 Scene 正在接管 → 不覆盖" ;;
              *)
                W=$(camera_band_fix)
                [ "$W" -gt 0 ] && log "📷 相机档位校正（模块自身造成，写入 $W 个节点）" ;;
            esac
        fi

        # ---- 7) 频率：**不再由本模块处理** ----
        #   CPU 调频权限已交回 Scene（profile.json 的 <mode>_active/inactive @cpu_freq）。
        #   原来这里每当前台一变就跑一次 apply_freq.sh -f "$FG"，已移除。
    fi

    sleep "$INTERVAL"
done
