#!/system/bin/sh
# ============================================================
#  bigcore_guard —— 让系统 cpuset 组**不使用超大核 8-9**
# ------------------------------------------------------------
#  【为什么需要】
#  用户观察：桌面 / 切换应用时会看到线程掩码是 0-9 和 4-9。
#  原因**不在本模块的落核**（模块从不把线程放 8-9），而在系统自己的 cpuset 组：
#    · /dev/cpuset/top-app/cpus        —— 前台大类，出厂 0-9
#    · /dev/cpuset/foreground/boost    —— 「提权」组，出厂 4-9/0-9
#    · /dev/cpuset/misf、foreground_window、camera-daemon —— 0-9 / 4-9
#    · /dev/cpuset/top-app/{main,render,other,trashy} —— Scene 的「核心分配」写的子组
#  于是**桌面、SystemUI、正在启动的应用**都会用到 8-9。
#
#  【真凶：scene-daemon 会持续把父组写回 0-9】（2026-09-18 实测）
#  用 SIGSTOP 逐个隔离嫌疑进程：冻结 scene-daemon 15 秒 → cpus 的 mtime **完全不动**；
#  冻结 vendor.xring.hardware.perfflinger.service（它持有 fd）→ 写入照旧。
#  ⇒ **写入者是 scene-daemon**，周期约 3~4 秒，且只重写 top-app / foreground 两个父组。
#  （perfflinger 只是持有这 5 个 cpus 文件的 fd，不是写入者。）
#
#  【做法：两步】
#  ① 裁剪：把各组的 cpus 与「允许集 0-7」取交集（先二级子组、再一级组）。
#     只在**确实含 8 或 9** 时才写（幂等）。读 cpus 全用内建 read → 0 fork。
#  ② 冻结：对**会被外部持续重写**的组做 `mount --bind`（后备文件在 $FSDIR/）。
#     这样外部写进的是后备文件，真实 cgroup 值不再变。
#
#  【为什么「冻结父组」就够了 —— cpuset 的 effective_cpus 语义】
#  ⚠ v16.11 这里写错了：以为「父组收到 0-7 后，外部给子组写 0-9 会被内核拒（EINVAL）」。
#  **实测是错的** —— 子组的 cpus 照样能写成 0-9（写入返回 0）。
#  真正起作用的是 **effective_cpus = 与所有祖先取交集**：
#      top-app/cpus      = 0-7（被我们冻结）
#      top-app/main/cpus = 0-9（Scene 写的）
#      → main 的 effective_cpus = 0-7，实际跑在上面的进程 Cpus_allowed_list:0-7 ✓
#  实测印证：故意把 main/render/other/trashy/boost 全写成 0-9，
#  它们的 effective_cpus 全部是 0-7，top-app 里 8 个真实进程的
#  Cpus_allowed_list 全是 0-7。⇒ **冻结父组即可压住整棵子树**。
#
#  【自动升级冻结】
#  每轮把「应有值」记到 $INTENT；下一轮若发现某组的 cpus 与它不符（被外部改回），
#  就把该组升级为冻结。所以即使换手机 / Scene 改了行为，也会在 1~2 轮内自动锁住。
#  另外 $PREFREEZE 里的两个组（已知被 scene-daemon 重写）从第一轮就直接冻结。
#
#  【开销】读 cpus / 读挂载表全用内建 read（0 fork）；只在需要改时才写。
#         正常一轮 ≈ 0 fork（+1 次 mv 写意图表）。可以放心每 60s 跑一次。
#
#  用法: bigcore_guard.sh [quiet]      应用/校正（quiet = 不往 stdout 打日志）
#        bigcore_guard.sh status       打印各组 cpus / effective_cpus / 冻结态（只读）
#        bigcore_guard.sh restore      解冻 + 把 bigcore.saved 的原值写回（**不用重启**）
#  关闭: touch $STATE_DIR/allow_bigcore     （模块不再动这些组）
#  全冻: touch $STATE_DIR/bigcore_freeze    （把所有触到的组都 bind-mount 冻结）
#  离线测试覆写: CG_ROOT / STATE_DIR / TMPD / MOUNTS_FILE / MOUNT_BIN / UMOUNT_BIN
#    （test_bigcore_guard.py 用假 cpuset 树 + 假 mount/umount shim 跑真脚本，47 断言）
# ============================================================
ST="${STATE_DIR:-/data/adb/SceneO3Tuner}"
CG="${CG_ROOT:-/dev/cpuset}"
TMP="${TMPD:-$ST/tmp}"
SAVED="$ST/bigcore.saved"        # 原值存档（restore 用）
INTENT="$ST/bigcore.intent"      # 上一轮「应有值」
FROZENF="$ST/bigcore.frozen"     # 已冻结：cpus路径<TAB>后备文件
FSDIR="$ST/bigcore_fs"           # 后备文件目录
LOG="$ST/bigcore.log"
ALLOW_HI=7                 # 允许使用的最大核号（0-7，不含超大核 8-9）
FALLBACK="4-7"             # 整段都在 8-9 时的落点（中核）
PREFREEZE="top-app foreground"   # 已知会被外部重写的父组
MOUNTS_FILE="${MOUNTS_FILE:-/proc/mounts}"
MOUNT_BIN="${MOUNT_BIN:-mount}"       # 测试可覆写成假 mount
UMOUNT_BIN="${UMOUNT_BIN:-umount}"    # 测试可覆写成假 umount
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

# ------------------------------------------------------------
#  cpus 表达式 → 裁到 ALLOW_HI（**只用内建字符串操作 + $(())**，不 fork）
#  结果放全局 SHRUNK；返回 0 = 有变化，1 = 无需改
#  ⚠ 纯字符串替换会踩坑：`8-9` 也会匹配 `*-9` → 变成 `87`。
#    所以按「逗号分段 → 解析上下界 → 算术裁剪」做。
# ------------------------------------------------------------
shrink() {
    _o=""; _r="$1"
    while [ -n "$_r" ]; do
        case "$_r" in
            *,*) _p="${_r%%,*}"; _r="${_r#*,}" ;;
            *)   _p="$_r"; _r="" ;;
        esac
        case "$_p" in
            *-*) _lo="${_p%-*}"; _hi="${_p#*-}" ;;
            *)   _lo="$_p"; _hi="$_p" ;;
        esac
        case "$_lo" in ''|*[!0-9]*) continue ;; esac
        case "$_hi" in ''|*[!0-9]*) continue ;; esac
        [ "$_hi" -gt "$ALLOW_HI" ] && _hi="$ALLOW_HI"
        [ "$_lo" -gt "$ALLOW_HI" ] && continue          # 整段都在 8-9 → 丢掉
        if [ "$_lo" -eq "$_hi" ]; then _seg="$_lo"; else _seg="$_lo-$_hi"; fi
        _o="${_o:+$_o,}$_seg"
    done
    SHRUNK="$_o"
    [ "$SHRUNK" = "$1" ] && return 1
    return 0
}

# 挂载表一次性读进 MOUNTS（内建 read → 0 fork）
read_mounts() {
    MOUNTS=" "
    [ -r "$MOUNTS_FILE" ] || return 0
    while IFS= read -r _l; do MOUNTS="$MOUNTS$_l "; done < "$MOUNTS_FILE"
}
is_mounted() {   # $1 = 绝对路径
    case "$MOUNTS" in *" $1 "*) return 0 ;; esac
    return 1
}

# 保存原值（每个组只存第一次，便于 restore）
#  ⚠ 这里**不能用 grep 做「已存在」判断**：路径里含反斜杠（Windows 沙盒测试）时，
#    BRE 会把 `\U` 当转义 → 模式永远匹配不上 → 同一条目被写两遍 → restore 时
#    后写的（意图值）覆盖先写的（出厂值）。改用内建 read 循环比对（顺带 0 fork）。
save_orig() {   # $1=组路径 $2=当前值
    [ -n "$2" ] || return 0
    [ -f "$SAVED" ] || : > "$SAVED"
    while IFS="$TAB" read -r _a _b; do
        [ "$_a" = "$1" ] && return 0
    done < "$SAVED"
    echo "$1$TAB$2" >> "$SAVED"
}

# 已冻结？是则 FT = 后备文件路径
frozen_tmp() {   # $1 = cpus 路径
    FT=""
    [ -f "$FROZENF" ] || return 1
    while IFS="$TAB" read -r _a _b; do
        [ "$_a" = "$1" ] && { FT="$_b"; return 0; }
    done < "$FROZENF"
    return 1
}

# 从意图表取「应有值」→ IV     $1 = cpus 路径   $2 = 表文件（默认 $INTENT）
intent_lookup() {
    _lf="${2:-$INTENT}"
    IV=""
    [ -f "$_lf" ] || return 1
    while IFS="$TAB" read -r _a _b; do
        [ "$_a" = "$1" ] && { IV="$_b"; return 0; }
    done < "$_lf"
    return 1
}

# ------------------------------------------------------------
#  冻结：把 $1(cpus 文件) 固定为 $2
#    · 已冻结且挂载还在 → 只刷新后备文件内容（让 `cat cpus` 显示我们定的值）
#    · 已冻结但挂载没了（被 umount）→ 复用同一后备文件重新挂
#    · 未冻结 → 先把真实值写成 $2，再 mount --bind
# ------------------------------------------------------------
freeze_cpus() {
    _f="$1"; _want="$2"
    [ -f "$_f" ] || return 0
    [ -n "$_want" ] || return 0
    case "$_f" in *"/SceneO3Tuner/"*) return 0 ;; esac
    if frozen_tmp "$_f"; then
        if is_mounted "$_f"; then
            # ★ 值真的变了才写（否则每轮都写 → 破坏幂等，也让 mtime 无意义）
            if [ -n "$FT" ]; then
                read -r _tv < "$FT" 2>/dev/null
                [ "$_tv" = "$_want" ] || printf '%s\n' "$_want" > "$FT" 2>/dev/null
            fi
            return 0
        fi
        _t="$FT"
    else
        _t="$FSDIR/$(printf '%s' "$_f" | tr '/ ' '__')"
    fi
    mkdir -p "$FSDIR" 2>/dev/null
    # ⚠ 只有值真的不同才写真实 cgroup —— 否则每轮都会写一次，破坏幂等
    read -r _cv < "$_f" 2>/dev/null
    [ "$_cv" = "$_want" ] || printf '%s\n' "$_want" > "$_f" 2>/dev/null
    printf '%s\n' "$_want" > "$_t" 2>/dev/null || return 0
    if "$MOUNT_BIN" --bind "$_t" "$_f" 2>/dev/null; then
        frozen_tmp "$_f" || echo "$_f$TAB$_t" >> "$FROZENF"
        sayq "no-bigcore: 冻结 ${_f}（锁定为 ${_want}）"
    fi
    return 0
}

# ------------------------------------------------------------
#  处理一个组：裁剪 + 记意图
# ------------------------------------------------------------
fix_group() {   # $1 = 组目录（带斜杠）
    _d="$1"
    [ -d "$_d" ] || return 0
    _f="${_d}cpus"
    [ -f "$_f" ] || return 0
    case "$_f" in
        *"/SceneO3Tuner/"*) return 0 ;;            # 我们自己的树，不动
        *"/cpuset/cpus")    return 0 ;;            # 根组必须保持全核（它是父）
    esac
    if frozen_tmp "$_f"; then
        # 已冻结：cpus 读到的是后备文件（可能被外部写成 0-9）→ 意图沿用上一轮，别被污染
        intent_lookup "$_f" && echo "$_f$TAB$IV" >> "$INTENT.new"
        return 0
    fi
    read -r _cur < "$_f" 2>/dev/null
    [ -n "$_cur" ] || return 0
    case "$_cur" in
        *8*|*9*) ;;
        *) echo "$_f$TAB$_cur" >> "$INTENT.new"; return 0 ;;   # 干净 → 只记意图
    esac
    shrink "$_cur" || { echo "$_f$TAB$_cur" >> "$INTENT.new"; return 0; }
    [ -n "$SHRUNK" ] || SHRUNK="$FALLBACK"
    save_orig "$_f" "$_cur"
    if printf '%s\n' "$SHRUNK" > "$_f" 2>/dev/null; then
        sayq "no-bigcore: $_f  $_cur → $SHRUNK"
    else
        sayq "no-bigcore: $_f  $_cur → $SHRUNK 写失败"
    fi
    echo "$_f$TAB$SHRUNK" >> "$INTENT.new"
    return 0
}

# 回退检测：上一轮记了意图、这一轮值不对 → 升级为冻结
pass_revert() {
    [ -s "$INTENT" ] || return 0
    while IFS="$TAB" read -r _p _v; do
        [ -n "$_p" ] && [ -n "$_v" ] || continue
        [ -f "$_p" ] || continue
        case "$_p" in
            *"/SceneO3Tuner/"*) continue ;;
            *"/cpuset/cpus")    continue ;;
        esac
        frozen_tmp "$_p" && continue          # 已冻结的跳过
        read -r _cur < "$_p" 2>/dev/null
        [ "$_cur" = "$_v" ] && continue        # 正常
        save_orig "$_p" "$_v"
        freeze_cpus "$_p" "$_v"
    done < "$INTENT"
    return 0
}

do_apply() {
    if [ -f "$ST/allow_bigcore" ]; then
        [ "$QUIET" = "1" ] || echo "no-bigcore: 已关闭（存在 $ST/allow_bigcore）"
        return 0
    fi
    [ -d "$CG" ] || return 0
    read_mounts
    : > "$INTENT.new"
    # ⓪ ★★ 回退检测必须在「修正」之前 —— 否则 fix_group 已经把值改回 0-7，
    #    再比对意图就成了「没被改回」，永远升级不到冻结。这是本脚本的关键顺序。
    pass_revert
    # ① 二级子组优先（可能要做 child ⊆ parent，先小后大）
    for d in "$CG"/*/*/; do [ -d "$d" ] || continue; fix_group "$d"; done
    # ② 再一级组
    for d in "$CG"/*/;   do [ -d "$d" ] || continue; fix_group "$d"; done
    # ③ 已知会被外部（scene-daemon）重写的父组 → 直接冻结（用刚记下的意图）
    for _g in $PREFREEZE; do
        _f="$CG/$_g/cpus"
        [ -f "$_f" ] || continue
        intent_lookup "$_f" "$INTENT.new" && freeze_cpus "$_f" "$IV"
    done
    # ④ 可选：把剩余触到的组也全冻
    if [ -f "$ST/bigcore_freeze" ] && [ -s "$INTENT.new" ]; then
        while IFS="$TAB" read -r _p _v; do
            [ -n "$_p" ] && [ -n "$_v" ] || continue
            freeze_cpus "$_p" "$_v"
        done < "$INTENT.new"
    fi
    mv -f "$INTENT.new" "$INTENT" 2>/dev/null
    return 0
}

do_status() {
    echo "=== $CG 各组（cpus / effective_cpus / 冻结）==="
    read_mounts
    for d in "$CG"/ "$CG"/*/ "$CG"/*/*/; do
        [ -d "$d" ] || continue
        [ -f "${d}cpus" ] || continue
        read -r v < "${d}cpus" 2>/dev/null
        read -r e < "${d}effective_cpus" 2>/dev/null
        if frozen_tmp "${d}cpus"; then _z="冻结"; else
            case "$e" in *8*|*9*) _z="★ 含 8/9";; *) _z="-";; esac
        fi
        printf "  %-46s cpus=%-8s eff=%-8s %s\n" "$d" "$v" "$e" "$_z"
    done
    echo
    echo "原值存档 : $([ -f "$SAVED" ]  && wc -l < "$SAVED"  || echo 0) 条"
    echo "已冻结组 : $([ -f "$FROZENF" ] && wc -l < "$FROZENF" || echo 0) 个"
    echo "关闭标记 allow_bigcore  : $([ -f "$ST/allow_bigcore" ]  && echo 存在 || echo 无)"
    echo "全冻标记 bigcore_freeze : $([ -f "$ST/bigcore_freeze" ] && echo 存在 || echo 无)"
    echo "（判断是否生效看 eff 列 —— 冻结组的 cpus 列显示的是后备文件内容，可能被外部写入污染）"
}

do_restore() {
    n=0; m=0
    # ① 解冻
    if [ -s "$FROZENF" ]; then
        while IFS="$TAB" read -r _p _t; do
            [ -n "$_p" ] || continue
            "$UMOUNT_BIN" "$_p" 2>/dev/null && n=$((n+1))
            [ -n "$_t" ] && rm -f "$_t" 2>/dev/null
        done < "$FROZENF"
        rm -f "$FROZENF"
    fi
    # ② 原值写回
    if [ -s "$SAVED" ]; then
        while IFS="$TAB" read -r _p _v; do
            [ -n "$_p" ] && [ -n "$_v" ] || continue
            "$UMOUNT_BIN" "$_p" 2>/dev/null
            printf '%s\n' "$_v" > "$_p" 2>/dev/null && m=$((m+1))
        done < "$SAVED"
        rm -f "$SAVED"
    fi
    rm -f "$INTENT" "$ST/bigcore.intent.new" 2>/dev/null
    rmdir "$FSDIR" 2>/dev/null
    echo "已解冻 $n 个组，还原 $m 个组的 cpus（不用重启）"
}

case "$1" in
    status)  do_status ;;
    restore) do_restore ;;
    *)       do_apply ;;
esac
exit 0
