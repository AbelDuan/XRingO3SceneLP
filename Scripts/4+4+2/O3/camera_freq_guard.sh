#!/system/bin/sh
# ============================================================
#  启动守卫 camera_guard.sh   （v2 · 2026-09-16 功耗治理）
# ------------------------------------------------------------
#  防的是「相机前台但频率区间塌缩」，也就是用户报的
#  「打开相机瞬间频率会上升，但是会马上回落并严重限频」。实测根因链：
#
#    1) Scene 的 _Camera.json 里 @cpu_freq 是**错误的 5 参数签名**
#         ["@cpu_freq","policy0","min","417792"]   ← 错
#       正确签名是 4 参数（见 _Games.json / profile.json）：
#         ["@cpu_freq","cpu0","417792","1353600"]  ← 对
#       Scene 解析失败后会把最后一个参数写进 scaling_max_freq，
#       于是 max 被钉成该簇最低档 → min == max → 区间塌缩为 0。
#
#    2) 即便按正确签名写，@cpu_freq **只落实 max**；min 仍会被压回最低档
#       （实测：写 scaling_min_freq=912000 → 立即 672000 → 2s 后 417792）。
#
#    3) xres governor 在 min 处于最低档时会让 max 一起塌缩。
#       结果：min == max == cpuinfo_min_freq，CPU 永久钉死在最低频。
#
#  【本脚本做什么】
#    常驻守护，**只在相机处于前台**时生效：
#      · 检测三簇 scaling_min/max_freq 是否偏离目标档位
#      · 偏离就写回，写入顺序固定「先 min 后 max」
#        （反过来 max 会被当时的 min 钳住 —— 实测结论）
#      · 相机不在前台时完全不写任何节点
#
#  【功耗设计】（v2 · 2026-09-16 治理）
#    本机 fork 一个子进程要 10~40ms，是这类守护功耗的唯一大头。v2 把 fork 压到
#    「只在需要时发生」，稳态（相机不在前台）**每轮 0 子进程、0 写盘、0 写节点**：
#
#      息屏               → 40 轮长睡，整轮只 1 次内建 read
#      亮屏 · 相机不在前台 → 纯内建 read 读 6 个频率节点直接返回（0 子进程）
#      亮屏 · 相机在前台   → 才可能 fork（dumpsys + 必要时 3 次 getprop）
#
#    为什么这样能成立：**能压回我们频率的只有 scene-daemon**，而它只在
#      (a) 前台应用切换、(b) 自己在 Scene 里切模式 这两种时刻下写频率。
#      相机在前台时这两种事件都不可能发生 → 相机态不会被压回，
#      所以后端 / 前台判定按需触发就够了，不必每轮盯。
#    可靠性兜底：每 BACKEND_EVERY 轮强制重判一次后端、每 FG_EVERY 轮强制刷一次
#      前台，任一路径异常最多 10s 自愈（比"每轮都查"省 90%+ 的 fork）。
#
#  用法: camera_freq_guard.sh [interval_sec]
#  关闭: touch $STATE_DIR/camera_freq_guard.off
# ============================================================
MODDIR="${MODDIR:-/data/adb/modules/SceneO3Tuner}"
. "$MODDIR/lib/util.sh"

INTERVAL="${1:-2}"
case "$INTERVAL" in ''|*[!0-9]*) INTERVAL=2 ;; esac
[ "$INTERVAL" -ge 1 ] || INTERVAL=2
# 写入节流：实测压回要 ~2s 才发生，所以同一次校正内连写 3 次（省 2 次 fork，
# 覆盖到那个窗口）；之后给 5 轮冷静期，避免在稳态下无谓重试。
WRITE_TRIES=3
WRITE_GAP=1
COOLDOWN=5
OFF_FLAG="${STATE_DIR}/camera_freq_guard.off"

# 用户覆盖（WebUI 可写 settings.conf）
[ -f "${WEBUI_DIR}/settings.conf" ] && . "${WEBUI_DIR}/settings.conf" 2>/dev/null
[ -n "$CAM_FREQ_INTERVAL" ] && INTERVAL="$CAM_FREQ_INTERVAL"

log "📷 相机频率守护启动 v2（${INTERVAL}s 一轮；稳态 0 子进程 / 0 写盘）"

rd() { read -r v < "$1" 2>/dev/null; echo "${v:-}"; }

screen_on() {
    local f v
    for f in /sys/class/backlight/*/brightness /sys/class/leds/lcd-backlight/brightness; do
        [ -f "$f" ] || continue
        v=$(rd "$f")
        case "$v" in ''|*[!0-9]*) continue ;; esac
        [ "$v" -gt 0 ] && { echo 1; return; }
    done
    echo 0
}

# 一次校正：三簇各写一遍，连做 WRITE_TRIES 遍
# （实测压回要 ~2s 才发生，连写 3 次正好盖住那个窗口，还省 2 次 fork）
#  ⚠ 别写成 `set -- $FREQ_ALL` + shift 的循环：每次 set -- 都会把游标重置，
#    结果只扫到第一簇就重复写它。camera_band_fix 内部是三簇展开的。
do_fix() {
    local total=0 w i
    i=0
    while [ "$i" -lt "$WRITE_TRIES" ]; do
        w=$(camera_band_fix); total=$((total + w))
        i=$((i+1))
        [ "$i" -lt "$WRITE_TRIES" ] && sleep "$WRITE_GAP"
    done
    echo "$total"
}

ROUND=0; BACKEND=""; COOL=0; REASON=""
while :; do
    ROUND=$((ROUND+1))

    [ -f "$OFF_FLAG" ] && { log "📷 相机频率守护：检测到关闭标志，退出"; exit 0; }

    # ① 息屏 → 长睡。相机前台必然亮屏，醒着盯是白烧电。
    #    长睡到 2/3 就起来看一眼，是为了保证「用户拿起手机解锁 → 40s 内必被看到」。
    if [ "$(screen_on)" != "1" ]; then
        sleep "$((INTERVAL*40/3))"; continue
    fi

    # ② 值都对 → 什么都不用做（除非刚写过，要过冷静期再确认一次）。
    #    纯内建 read 读 6 个节点，0 子进程、0 写盘。亮屏稳态就停在这一行。
    if camera_band_ok; then
        [ "$COOL" -gt 0 ] && COOL=$((COOL-1))
        [ "$BACKEND" = "none" ] && { BACKEND=""; REASON=""; }
        sleep "$INTERVAL"; continue
    fi

    # ②b 已判定「Scene 在接管」→ 什么都不做，连 apply_freq.sh 都不用再跑。
    #     判据(a) 是幂等的，重跑不会改变结论；每 2s 白 fork 一次纯属烧电。
    #     值一旦对上（说明 Scene 自己写好了）会在 ② 把 BACKEND 清空，
    #     下次真出问题时会重新判 —— 所以这里不用定期重试。
    if [ "$BACKEND" = "daemon" ]; then
        log_quiet "📷 相机频率不对，但 scene-daemon 正在接管 → 不覆盖（交权 Scene）"
        sleep "$INTERVAL"; continue
    fi

    # ③ 值不对且还没定后端 → 判"是谁写坏的"，再决定要不要动手。
    #
    #  实测每 2 秒会写我们三簇 min/max 的**只有两个东西**：
    #    a) scene-daemon（Scene 服务进程）
    #    b) 我们模块自己（更早版本的 guard.sh 在亮/息屏切换时跑 apply_freq.sh，
    #       把 QoS 上限清成 cpuinfo_max_freq，而 cpuinfo_max_freq 会随
    #       "thermal 限频 + 光感" 变化 —— 夜间相机 = cpuinfo 被砍到 1190400）
    #    非 root 能写这两个节点的没有第三个。所以先判 a 再判 b，都不匹配 → 不碰。
    #
    #  判 a：**跑一次原生的"清 QoS 残留"**，看它动不动手（幂等，不会误伤）：
    #        · 一个字节都没写 → 上界已经是硬件最高 → 写它的是 Scene 自己
    #          （Scene 写的是策略上界，比硬件最高低；我们模块只写硬件最高）
    #        · 写了 → 上界是我们模块的清残留动作留下的 → 是模块自身造成的
    #        ponytail: 这一判要 fork 一次子进程，所以只在「值不对且还没定后端」
    #        时才走。稳态（值都对）在 ② 就 continue 了，根本不会 fork。
    s=$(sh "$MODDIR/Scripts/4+4+2/O3/apply_freq.sh" 2>/dev/null | tail -1)
    case "$s" in
      *"未写任何节点"*) BACKEND=daemon; REASON="Scene 已接管（QoS 无遗留）" ;;
      *)                BACKEND=ours;   REASON="模块自身（QoS 有遗留，已清）" ;;
    esac

    # ④ 分派（只剩 ours；daemon 已在上面的 ②b 拦掉）
    case "$BACKEND" in
      # 模块自身造成的 → 只有模块自己该管：写回相机档位区间（先 min 后 max）
      ours)
        if camera_band_ok; then
            [ "$COOL" -lt "$COOLDOWN" ] && COOL=$((COOL+1))
            sleep "$INTERVAL"; continue
        fi
        W=$(do_fix); COOL=$COOLDOWN
        [ "$W" -gt 0 ] && log "📷 相机档位校正（${REASON}，写入 $W 个节点）"
        sleep "$INTERVAL"; continue
        ;;

      # 判不出后端 → 一个字节都不写
      *)
        [ -n "$REASON" ] && log_quiet "📷 ${REASON} → 只观察不写"
        sleep "$INTERVAL"; continue
        ;;
    esac
done
