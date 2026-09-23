#!/system/bin/sh
# ============================================================
#  migrate_nobig —— 受管进程迁入/迁出「自有受限组」nobig（v17）
# ------------------------------------------------------------
#  入参: $1 = run 表路径（enforce_threads.sh 产出的 pid|o|m|h|ht|hr|cm|uni|tids|pkg）
#  由 enforce_threads.sh 在 taskset 模式调用；pin_cgroup 模式不走这里。
#
#  做法：把**受管进程**整体迁进 /dev/cpuset/SceneO3Tuner/nobig（cpus=0-7）。
#    · 写一次 cgroup.procs = 全部线程继承 0-7 预算；
#    · enforce 的逐线程 taskset 与预算取交集，自然挡住大核 8-9；
#    · 新线程自动继承 0-7，不必每轮逐线程重绑。
#  不再冻结 top-app/foreground → 不与 scene-daemon 互写打架（v16 卡顿根因）。
#
#  逐应用判定（替代旧「极速档解冻 top-app」）：
#    · 目标核位含 8/9（fast 要上探大核）→ 不进 nobig，留在 top-app；
#      当前在 nobig 则迁回 top-app（切档动态生效）。
#    · 目标不含 8/9 且非空（受管、要限制）→ 进 nobig。
#    · 目标为空（系统接管 / 未配置）→ 不限制；当前在 nobig 则迁回 top-app。
#  只在「当前组 ≠ 目标组」时发命令（幂等）；组不存在则整段跳过（退化为不过问）。
#
#  离线测试覆写: CG_ROOT / STATE_DIR / TMPD
# ============================================================
RUN="${1:-}"
[ -n "$RUN" ] && [ -s "$RUN" ] || exit 0
# ★ v17.3：$2..$5 = 四档的**升级目标核位**（powersave balance performance fast，
#   由调用方从 mode_sched_row 取好传入，避免这里再拉一份 util.sh 造成双份事实源）。
#   用途：判定「本应用要不要 8-9」。以前只看静态模板的 o/m/h/comm —— 而 fast 档的
#   静态目标是 0-7（不含 8/9），只有**负载感知的升级目标 4-9** 才需要大核。
#   于是极速档被自己的 nobig(0-7) 夹死，8-9 永远到不了。现在把 esc 一并计入。
E_PS="${2:-}"; E_BA="${3:-}"; E_PE="${4:-}"; E_FA="${5:-}"

CG_ROOT="${CG_ROOT:-/dev/cpuset}"
ST="${STATE_DIR:-/data/adb/SceneO3Tuner}"
TMP="${TMPD:-$ST/tmp}"
PROC_ROOT="${PROC_ROOT:-/proc}"
NOBIG_G="$CG_ROOT/SceneO3Tuner/nobig"
TOPAPP_G="$CG_ROOT/top-app"
mkdir -p "$TMP" 2>/dev/null

# 关闭开关：不过问
[ -f "$ST/allow_bigcore" ] && exit 0
[ -d "$CG_ROOT" ] || exit 0

# 确保 nobig 组存在（cpus=0-7，mems 取自根组）
if [ ! -d "$NOBIG_G" ]; then
    mkdir -p "$NOBIG_G" 2>/dev/null
    _m="0"; [ -f "$CG_ROOT/cpuset.mems" ] && read -r _m < "$CG_ROOT/cpuset.mems" 2>/dev/null
    printf '%s\n' "$_m" > "$NOBIG_G/mems" 2>/dev/null
    printf '0-7\n' > "$NOBIG_G/cpus" 2>/dev/null
fi
[ -d "$NOBIG_G" ] || exit 0

MIG="$TMP/t.mig"; : > "$MIG"
awk -F'[|]' -v NOBIG="$NOBIG_G" -v TOPAPP="$TOPAPP_G" -v MIG="$MIG" -v PROC_ROOT="$PROC_ROOT" \
    -v EPS="$E_PS" -v EBA="$E_BA" -v EPE="$E_PE" -v EFA="$E_FA" '
function rdline(f,   _l) { while ((getline _l < f) > 0) break; close(f); sub(/[\r\n]+$/,"",_l); return _l }
# 档位 → 本档升级目标（空 = 未知档位，按「不需要大核」处理，保守留在 nobig）
function tieresc(t) { return (t=="powersave"?EPS:(t=="balance"?EBA:(t=="performance"?EPE:(t=="fast"?EFA:"")))) }
# 表达式里**是否包含**核 8 或 9 —— 必须展开区间，不能做子串匹配！
#   ★ v17.4 真机事故：原来写 `index(o,"8")>0`，而 fast 档的升级目标是字符串
#     "4-9" —— 里面根本没有字符 '8'，判定恒为假 → 极速档被自己的 nobig(0-7)
#     夹死，8-9 永远拿不到（用户报「极速档上不了大核」的本体）。
#   支持 "8-9" / "0-9" / "4-9" / "8" / "0-3,8-9" 等写法。
function has89(e,   _n,_a,_i,_lo,_hi,_b) {
    gsub(/[ \t]/, "", e)
    _n = split(e, _a, ",")
    for (_i = 1; _i <= _n; _i++) {
        if (_a[_i] == "" || _a[_i] == "-") continue
        if (_a[_i] ~ /^[0-9]+-[0-9]+$/) { split(_a[_i], _b, "-"); _lo=_b[1]+0; _hi=_b[2]+0 }
        else if (_a[_i] ~ /^[0-9]+$/)   { _lo=_a[_i]+0; _hi=_lo }
        else continue
        if (8 >= _lo && 8 <= _hi) return 1
        if (9 >= _lo && 9 <= _hi) return 1
    }
    return 0
}
function wantbig(o,m,h,cm,esc,   _r) {
    _r = (has89(o) || has89(m) || has89(h) || has89(cm) || has89(esc))
    return _r
}
{
    pid=$1; o=$2; m=$3; h=$4; cm=$7; tier=$10
    if (pid=="" || pid+0<=0) next
    if (!(pid in SEEN)) { SEEN[pid]=1 } else next
    cg = rdline(PROC_ROOT "/" pid "/cpuset")
    inNobig = (index(cg, "/SceneO3Tuner/nobig") > 0)
    restricted = ((o!="" || m!="") && wantbig(o,m,h,cm,tieresc(tier)) == 0)
    if (restricted) {
        if (!inNobig) print "echo " pid " > " NOBIG "/cgroup.procs" > MIG
    } else {
        if (inNobig) print "echo " pid " > " TOPAPP "/cgroup.procs" > MIG
    }
}
' "$RUN" 2>/dev/null
[ -s "$MIG" ] && sh "$MIG" >/dev/null 2>&1
exit 0
