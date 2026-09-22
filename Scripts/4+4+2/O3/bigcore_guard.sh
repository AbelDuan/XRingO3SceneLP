#!/system/bin/sh
# ============================================================
#  bigcore_guard —— 禁止「受管线程」使用超大核 8-9（v17 · 自有 cpuset 组）
# ------------------------------------------------------------
#  【v17 重构：不再冻结系统组，改用自己的 cpuset 组】
#   旧方案（v16）把 /dev/cpuset/top-app、/dev/cpuset/foreground 的 cpus 用
#   bind 挂载冻到 0-7。但 scene-daemon 每 3~4 秒会把这两个父组写回 0-9，
#   于是本脚本每 5 秒一轮「重申 0-7」→ 与 scene-daemon **互相打架**：
#     · 双守护都被对方唤醒，常驻 CPU 占用高、卡顿；
#     · bigcore.log 每轮记一行「重申 0-9→0-7」，长期刷屏。
#   实测（lhasa / 2026-09-21）：scene-daemon 累计 CPU 8+ 分钟、bigcore 751 行重申。
#
#   艇长 NetizenNemo/Aether_OptExt 的同款问题用 Rust+eBPF 解决：**不碰系统组**，
#   自建 /dev/cpuset/OptExt/* 并把受管线程迁进去。本脚本照搬这个思路：
#     · 自建 /dev/cpuset/SceneO3Tuner/nobig（cpus = 0-7，即在线的 0-7）；
#     · 只把**本模块受管的进程**迁进 nobig（enforce_threads.sh 负责）；
#     · top-app / foreground 完全不动 → scene-daemon 无的放矢，打架消失。
#   线程落在 nobig 后，其 cgroup 预算就是 0-7；enforce_threads 的逐线程 taskset
#   再把目标与预算取交集，天然把大核 8-9 挡在门外，且新线程自动继承 0-7。
#
#  【为什么比冻结更安全】
#   冻结改的是系统全局组（影响所有 app，含 SystemUI）→ 一旦逻辑出错，整机行为异常；
#   自有组只影响**本模块登记过的受管进程**，且只限制到 0-7（进程仍能跑，只是不上大核）。
#   最坏情况（组建不出来）= 不限制，退化为「不过问」，不会让任何进程卡死。
#
#  【极速档（需要 8-9）怎么办】
#   旧方案是「极速时解冻 top-app」。现在改为**逐应用**判定：enforce_threads.sh 看到
#   某应用的目标核位含 8/9（fast 档）→ 不把它迁进 nobig，留在 top-app（预算 0-9），
#   于是 taskset 可以设到 4-9。切换档位时再迁回 nobig。无需本脚本感知模式。
#
#  【开销】建组 + 幂等维护：读 2 个文件、按需写 2 次，≈0 fork。守护每轮调用本脚本
#   现在近乎免费（不再扫 15 个系统组、不再每轮写后备文件）。
#
#  用法: bigcore_guard.sh [quiet]       维护 nobig 组（quiet = 不往 stdout 打日志）
#        bigcore_guard.sh status        打印自有组 + 遗留冻结态（只读）
#        bigcore_guard.sh restore       解组 + 迁回线程 + 清遗留冻结（不用重启）
#  关闭: touch $STATE_DIR/allow_bigcore     （模块不再动任何 cpuset）
#  离线测试覆写: CG_ROOT / STATE_DIR / TMPD / ALLOW_HI / NOBIG_CPUS
# ============================================================
ST="${STATE_DIR:-/data/adb/SceneO3Tuner}"
CG="${CG_ROOT:-/dev/cpuset}"
OUR="${CG_NAME:-SceneO3Tuner}"
NOBIG="$CG/$OUR/nobig"
LOG="$ST/bigcore.log"
ALLOW_HI="${ALLOW_HI:-7}"                 # 允许使用的最大核号（0-7，不含超大核 8-9）
RMDIR_BIN="${RMDIR_BIN:-rmdir}"            # 真机删 cpuset cgroup（无视内部文件）；离线测试可覆写成 rm -rf
TAB="$(printf '\t')"

mkdir -p "$ST" 2>/dev/null
QUIET=0
[ "$1" = "quiet" ] && QUIET=1

say() { [ "$QUIET" = "1" ] || echo "$@"; echo "$@" >> "$LOG"; }
# 日志超过 64KB 就清一次（避免长期堆积）。只在真的要写日志时才查一次大小。
_log_rotate() {
    _sz=$(wc -c < "$LOG" 2>/dev/null)
    case "$_sz" in ''|*[!0-9]*) ;; *) [ "$_sz" -gt 65536 ] && : > "$LOG" ;; esac
}
sayq() { say "$@"; _log_rotate; }

# 在线核（零 fork 读 /sys，回退 0-9）
online_cpus() {
    local o=""
    [ -r /sys/devices/system/cpu/online ] && read -r o < /sys/devices/system/cpu/online
    [ -n "$o" ] || o="0-9"
    echo "$o"
}

# 把 "0-9" 与在线核表达式取交集，输出紧凑区间（纯 shell，零 fork）
#   先展开在线核为单个核号集合，再保留 0..ALLOW_HI 中在线的部分，
#   最后把连续核号压成 "0-7" 这种区间写法（cpuset 原生格式，也与本模块
#   其它脚本硬写的 "0-7" 一致）。在线核若有空洞（如某核离线）也会如实
#   压成 "0-2,4-7" 之类，避免写出不存在的核。
nobig_cpus() {
    _onl="$1"; _set=""; _rest="$_onl"
    while [ -n "$_rest" ]; do
        case "$_rest" in
          *,*) _seg="${_rest%%,*}"; _rest="${_rest#*,}" ;;
          *)   _seg="$_rest"; _rest="" ;;
        esac
        case "$_seg" in
          *-*) _lo="${_seg%-*}"; _hi="${_seg#*-}" ;;
          *)   _lo="$_seg"; _hi="$_seg" ;;
        esac
        case "$_lo$_hi" in *[!0-9]*) continue ;; esac
        _i="$_lo"
        while [ "$_i" -le "$_hi" ]; do _set="$_set $_i"; _i=$((_i+1)); done
    done
    _start=""; _prev=""; _out=""
    _i=0
    while [ "$_i" -le "$ALLOW_HI" ]; do
        _on=0
        case " $_set " in *" $_i "*) _on=1 ;; esac
        if [ "$_on" = 1 ]; then
            [ -z "$_start" ] && _start="$_i"
        else
            if [ -n "$_start" ]; then
                if [ "$_start" = "$_prev" ]; then _seg="$_start"; else _seg="$_start-$_prev"; fi
                _out="${_out:+$_out,}$_seg"
                _start=""
            fi
        fi
        _prev="$_i"
        _i=$((_i+1))
    done
    if [ -n "$_start" ]; then
        if [ "$_start" = "$_prev" ]; then _seg="$_start"; else _seg="$_start-$_prev"; fi
        _out="${_out:+$_out,}$_seg"
    fi
    [ -n "$_out" ] && echo "$_out" || echo "0-$ALLOW_HI"
}

# cpuset.mems（父组的 mems；新子组必须 ≤ 父 mems）。读不到回退 "0"
mems_of() {
    local m=""
    [ -r "$1/cpuset.mems" ] && read -r m < "$1/cpuset.mems" 2>/dev/null
    [ -n "$m" ] && echo "$m" || echo "0"
}

# 确保一个 cpuset 组存在且 cpus==$2（幂等，只在必要时写）
ensure_group() {   # $1=组目录 $2=cpus
    [ -d "$1" ] || mkdir -p "$1" 2>/dev/null
    [ -d "$1" ] || return 0
    # mems 必须先于 cpus（新建组时 cpus 在 mems 空时会 EINVAL）
    [ -f "$1/mems" ] || printf '%s\n' "$MEMS" > "$1/mems" 2>/dev/null
    _c=""
    [ -f "$1/cpus" ] && read -r _c < "$1/cpus" 2>/dev/null
    if [ "$_c" != "$2" ]; then
        printf '%s\n' "$2" > "$1/cpus" 2>/dev/null \
            && sayq "no-bigcore: 组 $1 设为 $2"
    fi
    return 0
}

# 把一个 pid 迁回标准组（按 oom_score_adj 选 top-app/foreground/background）
_std_group_for() {
    _pid="$1"; _adj=""
    read -r _adj < "/proc/$_pid/oom_score_adj" 2>/dev/null
    case "$_adj" in ''|*[!0-9-]*) echo "$CG_ROOT"; return ;; esac
    if   [ "$_adj" -le -800 ] 2>/dev/null && [ -d "$CG_ROOT/top-app" ]; then echo "$CG_ROOT/top-app"
    elif [ "$_adj" -le 100 ] 2>/dev/null && [ -d "$CG_ROOT/foreground" ]; then echo "$CG_ROOT/foreground"
    elif [ -d "$CG_ROOT/background" ]; then echo "$CG_ROOT/background"
    else echo "$CG_ROOT"; fi
}

# 解组前把组内线程迁回标准组（先快照再迁，避免 tasks 实时变化漏项）
_evacuate() {
    _d="$1"; [ -d "$_d" ] || return 0
    for _f in tasks cgroup.procs; do
        [ -r "$_d/$_f" ] || continue
        _snap="${TMPD:-$ST/tmp}/evac.$$"
        mkdir -p "${TMPD:-$ST/tmp}" 2>/dev/null
        cat "$_d/$_f" > "$_snap" 2>/dev/null
        while IFS= read -r _t; do
            [ -n "$_t" ] || continue
            kill -0 "$_t" 2>/dev/null || continue
            _g=$(_std_group_for "$_t")
            echo "$_t" > "$_g/$_f" 2>/dev/null || echo "$_t" > "$CG_ROOT/$_f" 2>/dev/null
        done < "$_snap"
        rm -f "$_snap" 2>/dev/null
    done
    return 0
}

do_apply() {
    [ -f "$ST/allow_bigcore" ] && { [ "$QUIET" = "1" ] || echo "no-bigcore: 已关闭（存在 $ST/allow_bigcore）"; return 0; }
    [ -d "$CG" ] || return 0
    MEMS="$(mems_of "$CG")"
    ONL="$(online_cpus)"
    NOBIG_WANT="${NOBIG_CPUS:-$(nobig_cpus "$ONL")}"
    # ① 父组（cpus=全在线，mems）
    ensure_group "$CG/$OUR" "$ONL"
    # ② 受限组（cpus=0-7 ∩ 在线）
    ensure_group "$NOBIG" "$NOBIG_WANT"
    [ "$QUIET" = "1" ] || echo "no-bigcore: nobig 组就绪（$NOBIG_WANT；受管线程将迁入）"
    return 0
}

do_status() {
    echo "=== 自有 cpuset 组（v17，不碰系统组）==="
    if [ -d "$NOBIG" ]; then
        read -r v < "$NOBIG/cpus" 2>/dev/null
        read -r e < "$NOBIG/effective_cpus" 2>/dev/null
        echo "  $NOBIG"
        echo "      cpus=$([ -n "$v" ] && echo "$v" || echo ?)  eff=$([ -n "$e" ] && echo "$e" || echo ?)"
        nt=$(grep -c . "$NOBIG/tasks" 2>/dev/null)
        echo "      线程数=$nt"
    else
        echo "  （nobig 组未建立）"
    fi
    echo
    echo "关闭标记 allow_bigcore : $([ -f "$ST/allow_bigcore" ] && echo 存在 || echo 无)"
    # 遗留冻结（v16 升级残留）
    if [ -f "$ST/bigcore.frozen" ]; then
        echo "⚠ 检测到 v16 遗留冻结清单："; cat "$ST/bigcore.frozen" 2>/dev/null
        echo "  建议执行 bigcore_guard.sh restore 清理"
    else
        echo "遗留冻结：无"
    fi
}

do_restore() {
    n=0; m=0
    # ① 解自有组（迁回标准组 + 删组）
    if [ -d "$NOBIG" ]; then
        _evacuate "$NOBIG"
        ${RMDIR_BIN:-rmdir} "$NOBIG" 2>/dev/null && n=$((n+1))
    fi
    if [ -d "$CG/$OUR" ]; then
        for _sub in "$CG/$OUR"/*/; do [ -d "$_sub" ] && _evacuate "${_sub%/}"; done
        ${RMDIR_BIN:-rmdir} "$CG/$OUR" 2>/dev/null && n=$((n+1))
    fi
    # ② 解 v16 遗留冻结（bind 挂载的后备文件）
    if [ -s "$ST/bigcore.frozen" ]; then
        while IFS="$TAB" read -r _p _t; do
            [ -n "$_p" ] || continue
            ${UMOUNT_BIN:-umount} "$_p" 2>/dev/null && n=$((n+1))
            [ -n "$_t" ] && rm -f "$_t" 2>/dev/null
        done < "$ST/bigcore.frozen"
        rm -f "$ST/bigcore.frozen"
    fi
    [ -s "$ST/bigcore.saved" ] && rm -f "$ST/bigcore.saved"
    rm -f "$ST/bigcore.intent" "$ST/bigcore.intent.new" "$ST/bigcore.mode.fast" 2>/dev/null
    echo "已解组 $n 个、清理遗留冻结；受管线程已迁回标准组（不用重启）"
}

case "$1" in
    status)  do_status ;;
    restore) do_restore ;;
    *)       do_apply ;;
esac
exit 0
