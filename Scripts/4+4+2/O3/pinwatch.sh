#!/system/bin/sh
# ============================================================
#  pinwatch.sh —— 事件驱动落核（v16.19）
# ------------------------------------------------------------
#  【为什么要它】
#    taskset 模式的亲和性**不继承**给新线程（实测：父线程绑 0-3，新建线程
#    allowed=0-9）。所以新线程要么等守护的 5s work 轮，要么等最长 120s 的兜底轮。
#    本脚本用 eBPF（`pinwatch` 二进制，raw_tracepoint 挂 sched_process_fork）
#    在内核侧捕获 fork，毫秒级把「哪个进程新生了线程」送到用户态，立刻只对该包
#    跑一次精确落核 —— 把窗口从 120s 压到毫秒级。
#
#  【分工（重要）】
#    · pinwatch(C)：只回答「谁 fork 了」，零策略
#    · 本脚本：把事件翻成「给哪几个包落核」+ 频次闸门 + helper 生命周期
#    · enforce_threads.sh：真正的策略（四档语义/模板/负载感知）
#    调度策略仍集中在 shell 一处，eBPF 侧不重复实现任何调度逻辑。
#
#  【为什么整包落核而不是逐线程 taskset】
#    逐线程 taskset 只能处理「当前已存在」的线程，还得自己重算目标核位 ——
#    那是 enforce_threads 的活。走 `enforce_threads.sh <pkg>` 复用**已验证**的
#    路径，也顺带把该包其它漂移的线程一起修正。
#
#  用法: pinwatch.sh [loop]     不带参数跑一轮（守护每轮调用）；带 loop 常驻
#  关闭: touch $STATE_DIR/pinwatch_off
# ============================================================
MODDIR="${MODDIR:-/data/adb/modules/SceneO3Tuner}"
. "$MODDIR/lib/util.sh"

TAB="$(printf '\t')"
BIN="$MODDIR/Scripts/4+4+2/O3/pinwatch"
ST="$STATE_DIR"
EV="$ST/pinwatch.events"
PIDF="$ST/pinwatch.pids"
POS="$ST/pinwatch.pos"
REC="$ST/pinwatch.recent"
OFF="$ST/pinwatch_off"
GAP="${PINWATCH_MIN_GAP:-3}"        # 同一进程两次落核的最小间隔（秒）
MAXEV=4096                          # 事件文件超过这么多行就轮转

[ -f "$OFF" ] && exit 0
[ -x "$BIN" ] || exit 0

# 目标进程 pid 表：交给 helper 做内核侧过滤（只有这些进程的 fork 才上报）
write_pids() {
    : > "$PIDF"
    local t="$TMPD/t.tids"
    [ -s "$t" ] || return 0
    awk -F'|' '$1 != "" { print $1 }' "$t" 2>/dev/null | sort -u > "$PIDF"
    wc -l < "$PIDF"
}

# 事件 → 包名（与 enforce_threads 的匹配口径一致：cmdline 第一段）
pkg_of() {
    _c=$(tr '\0' '\n' < "/proc/$1/cmdline" 2>/dev/null | head -1)
    [ -n "$_c" ] || _c=$(cat "/proc/$1/comm" 2>/dev/null)
    printf '%s' "$_c"
}

consume() {
    [ -s "$EV" ] || return 0
    local total last
    total=$(wc -l < "$EV" 2>/dev/null); case "$total" in ''|*[!0-9]*) total=0 ;; esac
    last=$(cat "$POS" 2>/dev/null);      case "$last"  in ''|*[!0-9]*) last=0 ;; esac
    [ "$total" -le "$last" ] && return 0

    local now; now=$(date +%s 2>/dev/null); case "$now" in ''|*[!0-9]*) now=0 ;; esac
    local todo; todo=$(tail -n "+$((last + 1))" "$EV" 2>/dev/null)
    echo "$total" > "$POS" 2>/dev/null

    # 频次表清理（超龄的丢掉）
    : > "${REC}.new"
    if [ -f "$REC" ]; then
        while IFS="$TAB" read -r _p _t; do
            [ -n "$_p" ] || continue
            [ "$now" -gt 0 ] && [ $((now - _t)) -lt "$GAP" ] 2>/dev/null && \
                printf '%s\t%s\n' "$_p" "$_t" >> "${REC}.new"
        done < "$REC"
    fi

    local pkgs="" _pid _pkg _hit
    for _pid in $(printf '%s\n' "$todo" | awk '{print $2}' | sort -u); do
        [ -n "$_pid" ] || continue
        [ -d "/proc/$_pid" ] || continue
        _hit=0
        [ -s "${REC}.new" ] && while IFS="$TAB" read -r _p _t; do
            [ "$_p" = "$_pid" ] && { _hit=1; break; }
        done < "${REC}.new"
        [ "$_hit" = "1" ] && continue
        _pkg=$(pkg_of "$_pid")
        [ -n "$_pkg" ] || continue
        pkgs="$pkgs $_pkg"
        printf '%s\t%s\n' "$_pid" "$now" >> "${REC}.new"
    done
    mv -f "${REC}.new" "$REC" 2>/dev/null

    local out=""
    for p in $(printf '%s\n' $pkgs | sort -u); do
        [ -n "$p" ] || continue
        sh "$MODDIR/Scripts/4+4+2/O3/enforce_threads.sh" "$p" >/dev/null 2>&1
        out="$out $p"
    done
    [ -n "$out" ] && log_quiet "pinwatch: 新线程即时落核$out"
    return 0
}

# 事件文件轮转：清空 + 位置归零（此时 helper 仍在追加，短暂丢几条可接受）
rotate_if_big() {
    local total; total=$(wc -l < "$EV" 2>/dev/null); case "$total" in ''|*[!0-9]*) total=0 ;; esac
    if [ "$total" -ge "$MAXEV" ]; then
        : > "$EV"; echo 0 > "$POS"
    fi
}

start_helper() {
    write_pids >/dev/null 2>&1
    : > "$EV"; echo 0 > "$POS"
    nohup "$BIN" >/dev/null 2>&1 &
    HPID=$!
}

case "$1" in
  loop)
    start_helper
    i=0
    while :; do
        [ -f "$OFF" ] && break
        # helper 掉了就重拉（同时刷新 pid 表并轮转事件）
        if ! kill -0 "$HPID" 2>/dev/null; then start_helper; fi
        # 每 10 轮（约 10s）刷新目标 pid 表；表为空时立即重试
        #   ⚠ 实测：pinwatch 可能比守护更早启动，此时 $TMPD/t.tids 还没生成，
        #     写成 60s 会让内核过滤长时间"无目标"→ 一个事件都收不到。
        i=$((i + 1))
        if [ $((i % 10)) -eq 0 ]; then
            n=$(write_pids 2>/dev/null)
            case "$n" in ''|*[!0-9]*) n=0 ;; esac
            [ "$n" -gt 0 ] || i=9          # 表为空 → 下一轮立刻再试
        fi
        consume
        rotate_if_big
        sleep 1
    done
    kill "$HPID" 2>/dev/null
    exit 0 ;;
  *)
    write_pids >/dev/null 2>&1
    consume ;;
esac
exit 0
