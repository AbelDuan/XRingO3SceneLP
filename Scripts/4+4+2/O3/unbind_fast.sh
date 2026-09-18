#!/system/bin/sh
# ============================================================
#  「极速」档解绑器 —— 把被标为 fast 的包还原成「系统默认」
# ------------------------------------------------------------
#  【为什么需要它】
#    极速档的设计是「不绑核」：模板核位全空 → enforce_threads.sh 的目标表里
#    根本不会出现这个包 → 一条 taskset 都不发。
#    但「不发」只保证**将来**不绑，解除不了**过去**绑过的：
#    把一个应用从「流畅」改成「极速」时，它的线程还留在 4-7 上。
#
#  【还原目标 = cgroup 预算，不是全核】
#    进程在哪个 cpuset 组，组里的 cpus 就是它的「系统默认可用范围」。
#    直接 taskset 到 0-9 是错的：后台组（/dev/cpuset/background，cpus=0-3）
#    里的进程写成 0-9 会直接 EINVAL（只能在预算内收窄）。
#    所以这里读 /proc/<pid>/cpuset 拿到组路径，再取该组的 cpus。
#
#  【幂等】当前亲和性 == 预算时一条命令都不发。
#  【开销】只在「保存分配表 / 套用档位」这类低频动作后调用一次，
#         不进守护循环，常驻开销为 0。
#  用法: unbind_fast.sh [pkg...]     不带参数 = 检查全部 fast 档的包
# ============================================================
MODDIR="${MODDIR:-/data/adb/modules/SceneO3Tuner}"
. "$MODDIR/lib/util.sh"

CG_ROOT="/dev/cpuset"
TASK="taskset"

# ---- v12：cgroup 分组模式下的解绑 ----
#   我们的组树里，被标为「系统接管」的包应当**不在**树里。
#   pin_cgroup.sh --apply 本身就会做这件事；这里额外补一刀，
#   让「切档 → 只调解绑器」这条路径也能把线程从组里放出来。
if [ -x "$MODDIR/Scripts/4+4+2/O3/pin_cgroup.sh" ] && [ -n "$PKGS" ]; then
    sh "$MODDIR/Scripts/4+4+2/O3/pin_cgroup.sh" --unbind $PKGS >/dev/null 2>&1
fi

# ---- 收集目标包：命令行给的，或从两份分配表里挑 fast ----
if [ $# -gt 0 ]; then
    PKGS="$*"
else
    PKGS=$(awk -F'\t' '$1!="" && $1!~/^#/ && $2=="fast" { print $1 }' \
        "$APP_ASSIGN_FILE" "$GAME_ASSIGN_FILE" 2>/dev/null | sort -u)
fi
# 注：PKGS 为空不代表没事干 —— 相机永远在解绑名单里（见 awk 里的 CAMRE 分支）

# ---- 一次 ps 拿全表，避免逐包 fork ----
PSF="${TMPD}/ub.ps"
mkdir -p "$TMPD" 2>/dev/null
ps -A -o PID,ARGS > "$PSF" 2>/dev/null || exit 0

# 单个 awk 进程完成：匹配进程 → 读组预算 → 比当前亲和性 → 输出待执行命令
CMDS="${TMPD}/ub.cmds"
awk -v PKGS="$PKGS" -v PSF="$PSF" -v CGROOT="$CG_ROOT" -v CAMRE="$CAMERA_RE" '
function listof(e,   _i,_n,_a,_lo,_hi,_c,_out) {
    _out = ""
    _n = split(e, _a, ",")
    for (_i = 1; _i <= _n; _i++) {
        _a[_i] = _a[_i]
        gsub(/^[ \t\r]+|[ \t\r]+$/, "", _a[_i])
        if (_a[_i] == "") continue
        if (_a[_i] ~ /^[0-9]+-[0-9]+$/) { split(_a[_i], _b, "-"); _lo = _b[1]+0; _hi = _b[2]+0 }
        else if (_a[_i] ~ /^[0-9]+$/)   { _lo = _a[_i]+0; _hi = _lo }
        else continue
        for (_c = _lo; _c <= _hi; _c++) _out = _out " " _c
    }
    return _out
}
function maskof(l,   _i,_n,_a,_m) {
    _m = 0
    _n = split(l, _a, " ")
    for (_i = 1; _i <= _n; _i++) if (_a[_i] != "") _m += 2^_a[_i]
    return sprintf("%x", _m)
}
# /proc/<pid>/status 的 Cpus_allowed_list（该内核没有独立的 cpus_allowed_list 文件）
function affof(pid,   _l,_f) {
    _f = "/proc/" pid "/status"
    while ((getline _l < _f) > 0) {
        if (_l ~ /^Cpus_allowed_list:/) {
            sub(/^Cpus_allowed_list:[ \t]*/, "", _l)
            gsub(/[ \t\r\n]/, "", _l)
            close(_f); return _l
        }
    }
    close(_f); return ""
}
# 该进程所在 cpuset 组的 cpus
function budgetof(pid,   _g,_l,_f) {
    _g = ""
    while ((getline _l < ("/proc/" pid "/cpuset")) > 0) { _g = _l; break }
    close("/proc/" pid "/cpuset")
    gsub(/[ \r\n]/, "", _g)
    if (_g == "" || _g == "/") return ""
    _f = CGROOT _g "/cpus"
    _l = ""
    while ((getline _l < _f) > 0) break
    close(_f)
    gsub(/[ \r\n]/, "", _l)
    return _l
}
BEGIN {
    n = split(PKGS, pa, " ")
    for (i = 1; i <= n; i++) if (pa[i] != "") WANT[pa[i]] = 1
}
{
    pid = $1 + 0
    if (pid <= 0) next
    cmd = $0
    sub(/^[ \t]*[0-9]+[ \t]+/, "", cmd)
    hit = 0
    # 相机固定「极速（不接管）」→ 每次解绑都顺带把它放回 cgroup 预算（幂等，已放开则不发命令）
    if (CAMRE != "" && cmd ~ CAMRE) hit = 1
    for (p in WANT) {
        if (hit) break
        # 进程名精确匹配，或 "包名:后缀" 形式（微信小程序那类进程级条目）
        if (cmd == p || index(cmd, p ":") == 1) { hit = 1; break }
    }
    if (!hit) next
    b = budgetof(pid)
    if (b == "") next
    bm = maskof(listof(b))
    cur = affof(pid)
    if (cur == "") next
    cm = maskof(listof(cur))
    if (cm != bm) printf "taskset -a -p %s %s\n", bm, pid
}
' "$PSF" > "$CMDS" 2>/dev/null

[ -s "$CMDS" ] || { rm -f "$CMDS" "$PSF" 2>/dev/null; exit 0; }

# 执行（busybox/toybox 的 sh 没有 mapfile，用 while read）
n=0
while IFS= read -r c; do
    [ -n "$c" ] || continue
    $c 2>/dev/null && n=$((n+1))
done < "$CMDS"
rm -f "$CMDS" "$PSF" 2>/dev/null
[ "$n" -gt 0 ] 2>/dev/null && echo "已解绑 ${n} 个进程（极速档 = 交回系统调度）"
exit 0
