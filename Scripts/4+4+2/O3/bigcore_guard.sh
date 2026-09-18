#!/system/bin/sh
# ============================================================
#  bigcore_guard —— 让系统 cpuset 组**不使用超大核 8-9**
# ------------------------------------------------------------
#  【为什么需要】
#  用户的观察：桌面 / 切换应用时会看到线程掩码是 0-9 和 4-9。
#  原因**不在本模块的落核**（模块从不把线程放 8-9），而在系统自己的 cpuset 组：
#    · /dev/cpuset/top-app/cpus        —— 前台大类，出厂常见 0-9
#    · /dev/cpuset/foreground/boost    —— 「提权」组，常见就是大核簇（4-9/8-9）
#    · /dev/cpuset/top-app/{main,render,other} —— Scene 的「核心分配」按
#      files/threads.json 写的子组（那份 v8 遗留里有 0-9 / 1-9 / 8-9）
#  于是**桌面、SystemUI、正在启动的应用**都会用到 8-9。
#
#  【做法】
#  把这些组的 cpus 与「允许集 0-7」取交集 —— 只在**确实含 8 或 9** 时才写（幂等）。
#  · 先处理二级子组（top-app/main 等），再处理一级组 —— cpuset 要求 child ⊆ parent，
#    顺序反了会 EINVAL。**而一旦父组被收到 0-7，外部再想给子组写 0-9 就会失败**
#    （kernel 直接拒），这正好从根上堵住 Scene 的「核心分配」。
#  · 全是 8-9 的组（如 top-app/kswapd）收缩后为空 → 落到中核 4-7，而不是留空
#    （空 cpus 非法）。
#  · 原值会存到 $ST/bigcore.saved，随时 `bigcore_guard.sh restore` 还原（**不需要重启**）。
#
#  【开销】读 cpus 全部用 shell 内建 `read`（0 fork）；只在需要改时才写（也是内建重定向）。
#         正常一轮 ≈ 0 fork。所以可以放心每 60s 跑一次。
#
#  用法: bigcore_guard.sh [quiet]      应用/校正（quiet = 不往 stdout 打日志）
#        bigcore_guard.sh status       只打印各组的 cpus（只读）
#        bigcore_guard.sh restore      把 bigcore.saved 里的原值写回
#  关闭: touch $STATE_DIR/allow_bigcore     （模块不再动这些组）
#  冻结: touch $STATE_DIR/bigcore_freeze    （写完再 bind-mount 冻结，防外部改回）
# ============================================================
ST="${STATE_DIR:-/data/adb/SceneO3Tuner}"
CG="${CG_ROOT:-/dev/cpuset}"
TMP="${TMPD:-$ST/tmp}"
SAVED="$ST/bigcore.saved"
LOG="$ST/bigcore.log"
ALLOW_HI=7                 # 允许使用的最大核号（0-7 不含超大核 8-9）
FALLBACK="4-7"             # 整段都在 8-9 时的落点（中核）

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
#  把 cpus 表达式裁到 0-7（**只用内建字符串操作 + $(())**，不 fork）
#  结果写入全局 SHRUNK；返回 0 = 有变化，1 = 无需改
#  ⚠ 纯字符串替换会踩坑：`8-9` 也会匹配 `*-9` → 变成 `87`。
#    所以按「逗号分段 → 解析上下界 → 算术裁剪」来做。
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
        # 非纯数字段（理论上不该有）→ 丢弃
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

# 保存原值（每个组只存第一次，便于 restore）
save_orig() {   # $1=组路径 $2=当前值
    [ -f "$SAVED" ] || : > "$SAVED"
    grep -q "^$1	" "$SAVED" 2>/dev/null && return 0
    echo "$1	$2" >> "$SAVED"
}

apply_group() {   # $1 = 组目录（带斜杠）
    _d="$1"
    [ -d "$_d" ] || return 0
    case "$_d" in
        *"/SceneO3Tuner/"*) return 0 ;;              # 我们自己的树，不动
        *"/cpuset/")        return 0 ;;              # 根组，必须保持全核（是父）
    esac
    read -r _cur < "${_d}cpus" 2>/dev/null || return 0
    [ -n "$_cur" ] || return 0
    # 不含 8/9 → 无事可做（这一步是纯字符串匹配，0 fork）
    case "$_cur" in *8*|*9*) ;; *) return 0 ;; esac
    shrink "$_cur" || return 0
    [ -n "$SHRUNK" ] || SHRUNK="$FALLBACK"
    save_orig "${_d}cpus" "$_cur"
    if echo "$SHRUNK" > "${_d}cpus" 2>/dev/null; then
        sayq "no-bigcore: ${_d}cpus  $_cur → $SHRUNK"
    else
        sayq "no-bigcore: ${_d}cpus  $_cur → $SHRUNK 写失败（可能有子组仍占 8-9）"
    fi
    return 0
}

# 可选：bind-mount 冻结（外部再写无效）
freeze_group() {   # $1 = 组目录（带斜杠）
    _d="$1"
    [ -f "$ST/bigcore_freeze" ] || return 0
    [ -d "$_d" ] || return 0
    case "$_d" in *"/SceneO3Tuner/"*|*"/cpuset/") return 0 ;; esac
    _t="${TMP}/bc${_d#/dev/cpuset}"      # 固定路径，复用同一个文件
    [ -f "${_d}cpus" ] || return 0
    mkdir -p "${_t%/*}" 2>/dev/null
    umount "${_d}cpus" 2>/dev/null
    cp -f "${_d}cpus" "$_t" 2>/dev/null || return 0
    mount --bind "$_t" "${_d}cpus" 2>/dev/null && sayq "no-bigcore: 冻结 ${_d}cpus"
}

do_apply() {
    if [ -f "$ST/allow_bigcore" ]; then
        [ "$QUIET" = "1" ] || echo "no-bigcore: 已关闭（存在 $ST/allow_bigcore）"
        return 0
    fi
    [ -d "$CG" ] || return 0
    # ① 二级子组优先（child ⊆ parent 的约束）
    for d in "$CG"/*/*/; do [ -d "$d" ] || continue; apply_group "$d"; done
    # ② 再一级组
    for d in "$CG"/*/;   do [ -d "$d" ] || continue; apply_group "$d"; done
    # ③ 冻结（仅当用户开了 bigcore_freeze）
    [ -f "$ST/bigcore_freeze" ] || return 0
    for d in "$CG"/*/*/; do freeze_group "$d"; done
    for d in "$CG"/*/;   do freeze_group "$d"; done
    return 0
}

do_status() {
    echo "=== $CG 各组 cpus（只读）==="
    for d in "$CG"/ "$CG"/*/ "$CG"/*/*/; do
        [ -d "$d" ] || continue
        [ -f "${d}cpus" ] || continue
        read -r v < "${d}cpus" 2>/dev/null
        printf "  %-46s cpus=%s\n" "$d" "$v"
    done
    echo
    echo "保存的原值: $([ -f "$SAVED" ] && wc -l < "$SAVED" || echo 0) 条（$SAVED）"
    echo "关闭标记 allow_bigcore: $([ -f "$ST/allow_bigcore" ] && echo 存在 || echo 无)"
    echo "冻结标记 bigcore_freeze: $([ -f "$ST/bigcore_freeze" ] && echo 存在 || echo 无)"
}

do_restore() {
    [ -s "$SAVED" ] || { echo "没有 $SAVED，无需还原"; return 0; }
    n=0
    while IFS='	' read -r p v; do
        [ -n "$p" ] && [ -n "$v" ] || continue
        f="${p%cpus}cpus"
        umount "$f" 2>/dev/null
        echo "$v" > "$f" 2>/dev/null && n=$((n+1))
    done < "$SAVED"
    echo "已还原 $n 个组的 cpus（来源 $SAVED）"
    rm -f "$SAVED"
}

case "$1" in
    status)  do_status ;;
    restore) do_restore ;;
    *)       do_apply ;;
esac
exit 0
