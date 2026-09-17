#!/system/bin/sh
# ============================================================
#  cgroup 分组落核（艇长 / aether-optext 式）—— v12，2026-09-17
# ------------------------------------------------------------
#  【为什么要换掉逐线程 taskset】
#    逐线程 `taskset` 只能管**当下已存在**的线程。应用起来之后新创建的线程
#    （渲染子线程、线程池 Worker、Unity 的 Job 线程…）要等守护下一轮才会绑上；
#    而一轮完整核对实测 226~244ms（146 线程的相机进程）→ 根本不可能每轮都跑。
#
#  【艇长的两手】cgroup 分组（OptExt）+ taskset 亲和。
#    cgroup 那手是关键：**新线程会自动继承「创建者所在的 cgroup」**，
#    组级 `cpus` 一旦设好，之后新建的线程不需要任何人去绑。
#    本脚本就是把这手移植过来，让「新建线程」这件事从「靠轮询」变成「靠继承」。
#
#  【本机实测（2026-09-17，玄戒 O3 / HyperOS）】
#    · /dev/cpuset 下可自由 mkdir 子组；把单个 tid 写进 tasks 立刻生效；
#    · 应用**活跃使用**时 framework 不会把线程挪走
#      （30 秒持续触摸后组内 143 = 进程总线程 143，覆盖 100%）；
#    · 写入是 shell 内建重定向 → 几乎不 fork，每轮跑得起。
#    ⚠ 应用退到后台时 framework 会把它整组挪去 /background（这是对的，
#      后台就该吃 background 预算）；回到前台再由本脚本重新收进来。
#
#  【组结构】每个包一棵树：
#      /dev/cpuset/SceneO3Tuner/<pkg_slug>/        ← 父组，cpus = 各角色并集
#          ├ c0-3/    ← 「其余线程」的核位，**整进程默认落这里**
#          └ c4-7/    ← 主线程 / 渲染线程 / comm 命中线程落这里
#    组名直接带核位（c4-7）。档位一改就自然产生新组名，旧组由清扫步骤回收，
#    不会出现「组还在、cpus 却是旧值」这种最难查的状态。
#
#  【为什么父组要大一圈】cpuset 要求子组 cpus ⊆ 父组 cpus，所以先放并集再收窄。
#
#  用法:
#    pin_cgroup.sh --apply <tids文件>  按目标表落核（enforce_threads.sh 调用）
#    pin_cgroup.sh --unbind-all        全部解绑：线程按 oom_score_adj 归位并删组
#    pin_cgroup.sh --unbind <pkg>...   只解绑指定包（包名，不是 slug）
#    pin_cgroup.sh --status            打印组树与线程数
# ============================================================
CG_ROOT="${CG_ROOT:-/dev/cpuset}"
CG_NAME="${CG_NAME:-SceneO3Tuner}"
CROOT="$CG_ROOT/$CG_NAME"
TMP="${TMPD:-/data/adb/SceneO3Tuner/tmp}"
ST="$TMP/cg.state"
CMD="$TMP/cg.cmds"
KEEP="$TMP/cg.keep"
UNB="$TMP/cg.unbind"

log() { [ "${QUIET:-0}" = "1" ] || echo "$@"; }

[ -d "$CG_ROOT" ] || { log "ERR $CG_ROOT 不存在（内核没挂 cpuset？）"; exit 3; }

slugof() { echo "$1" | tr -c 'A-Za-z0-9_' '_'; }

# ------------------------------------------------------------
#  解绑：线程先按 oom_score_adj 归回标准组，再删组
#  （学 cleanup_optext.sh —— 直接 rmdir 会把线程丢在原地）
# ------------------------------------------------------------
_std_group_for() {
    _pid="$1"; _adj=""
    # ⚠ oom_score_adj 在 **/proc** 里，不在 cpuset 挂载点里。
    #   写成 "$CG_ROOT/$_pid/oom_score_adj" 会满屏 "can't open"（踩过）。
    read -r _adj < "/proc/$_pid/oom_score_adj" 2>/dev/null
    case "$_adj" in ''|*[!0-9-]*) echo "$CG_ROOT"; return ;; esac
    if   [ "$_adj" -le -800 ] 2>/dev/null && [ -d "$CG_ROOT/top-app" ]; then echo "$CG_ROOT/top-app"
    elif [ "$_adj" -le 100 ] 2>/dev/null && [ -d "$CG_ROOT/foreground" ]; then echo "$CG_ROOT/foreground"
    elif [ -d "$CG_ROOT/background" ]; then echo "$CG_ROOT/background"
    else echo "$CG_ROOT"; fi
}

_evacuate() {   # $1 = 要腾空的组目录
    _d="$1"; [ -d "$_d" ] || return 0
    # ⚠ **必须先快照再迁**：直接 `while read < tasks` 的同时往别处写，
    #   tasks 的内容会随迁移实时变化 → 读到一半就漏项（真机实测：组清不空、
    #   rmdir 一直失败、组树残留）。所以先 cat 到临时文件，再按快照迁。
    _snap="${TMP}/evac.$$"
    for _f in tasks cgroup.procs; do
        [ -r "$_d/$_f" ] || continue
        cat "$_d/$_f" > "$_snap" 2>/dev/null
        while IFS= read -r _t; do
            [ -n "$_t" ] || continue
            kill -0 "$_t" 2>/dev/null || continue
            _g=$(_std_group_for "$_t")
            [ -n "$_g" ] || _g="$CG_ROOT"
            echo "$_t" > "$_g/$_f" 2>/dev/null || echo "$_t" > "$CG_ROOT/$_f" 2>/dev/null
        done < "$_snap"
    done
    rm -f "$_snap" 2>/dev/null
    return 0
}

# 把一个 slug（或全部）的树腾空 + 删掉。线程还活着/占用中就先留着，下一轮再收。
_unbind_tree() {
    [ -d "$CROOT" ] || return 0
    _sel="$1"
    for _d in "$CROOT"/*/; do
        [ -d "$_d" ] || continue
        _s=${_d%/}; _s=${_s##*/}
        [ -n "$_sel" ] && [ "$_s" != "$_sel" ] && continue
        for _sub in "$_d"*/; do [ -d "$_sub" ] && _evacuate "${_sub%/}"; done
        _evacuate "${_d%/}"
        for _sub in "$_d"*/; do [ -d "$_sub" ] && rmdir "${_sub%/}" 2>/dev/null; done
        rmdir "${_d%/}" 2>/dev/null
    done
    [ -n "$_sel" ] || rmdir "$CROOT" 2>/dev/null
    return 0
}

case "$1" in
  --unbind-all)
    # 重试 3 轮：线程一边死一边生，一轮常常迁不干净（死 tid 写不进去是正常的，
    # 下一轮它们就不在 tasks 里了）
    _r=0
    while [ $_r -lt 3 ]; do
        _unbind_tree ""
        [ -d "$CROOT" ] || break
        sleep 0.2
        _r=$((_r + 1))
    done
    if [ -d "$CROOT" ]; then log "OK 已解绑（个别线程仍在占用，组下次回收）"
    else log "OK 已全部解绑，组树已清"; fi
    exit 0 ;;
  --unbind)
    shift
    for p in "$@"; do _unbind_tree "$(slugof "$p")"; done
    log "OK 已解绑 $# 个包"
    exit 0 ;;
  --status)
    [ -d "$CROOT" ] || { log "（无组树）"; exit 0; }
    for d in "$CROOT"/*/; do
        [ -d "$d" ] || continue
        log "$(basename "$d")  union=$(cat "$d/cpus" 2>/dev/null)"
        for s in "$d"*/; do
            [ -d "$s" ] || continue
            log "    $(basename "$s")  cpus=$(cat "$s/cpus" 2>/dev/null)  tasks=$(wc -l < "$s/tasks" 2>/dev/null)"
        done
    done
    exit 0 ;;
  --apply) shift ;;
  *)
    echo "用法: $0 --apply <tids> | --unbind <pkg>... | --unbind-all | --status"
    exit 2 ;;
esac

TIDS="$1"
[ -s "$TIDS" ] || { log "OK 无目标"; exit 0; }
mkdir -p "$TMP" 2>/dev/null
: > "$CMD"; : > "$KEEP"; : > "$UNB"; : > "$ST.new"

# ============================================================
#  把 t.tids（pid|other|main|heavy|ht|hr|comm|uni|tids|pkg）翻成
#  「建组 / 设 cpus / 迁进程 / 迁线程」的命令序列。
#  全程只用 awk 的 getline 读文件（不 fork）；不需要改的地方一条命令都不发。
# ============================================================
awk -F'[|]' -v ROOT="$CROOT" -v CGNAME="$CG_NAME" -v ST="$ST" \
    -v CMD="$CMD" -v KEEP="$KEEP" -v UNB="$UNB" -v TAB="$TAB" \
    -v MAXC="$(cat /sys/devices/system/cpu/present 2>/dev/null | sed 's/.*-//')" '
function trim(x) { gsub(/^[ \t\r]+/, "", x); gsub(/[ \t\r]+$/, "", x); return x }
function emit(s) { print s > CMD }
function listof(e,   _i,_n,_a,_lo,_hi,_c,_out,_b) {
    _out = ""
    _n = split(e, _a, ",")
    for (_i = 1; _i <= _n; _i++) {
        _a[_i] = trim(_a[_i]); if (_a[_i] == "") continue
        if (_a[_i] ~ /^[0-9]+-[0-9]+$/) { split(_a[_i], _b, "-"); _lo = _b[1]+0; _hi = _b[2]+0 }
        else if (_a[_i] ~ /^[0-9]+$/)    { _lo = _a[_i]+0; _hi = _lo }
        else continue
        for (_c = _lo; _c <= _hi; _c++) if (!(_c in _S)) { _S[_c] = 1; _out = _out " " _c }
    }
    for (_i in _S) delete _S[_i]
    return _out
}
function rdline(f,   _l) {
    _l = ""
    while ((getline _l < f) > 0) break
    close(f); sub(/[\r\n]+$/, "", _l); return _l
}
function nthr(pid,   _l) {
    while ((getline _l < ("/proc/" pid "/status")) > 0) {
        if (_l ~ /^Threads:/) {
            sub(/^Threads:[ \t]*/, "", _l); sub(/[^0-9].*$/, "", _l)
            close("/proc/" pid "/status"); return _l
        }
    }
    close("/proc/" pid "/status"); return ""
}
# 组名直接带核位（c4-7）。只把逗号等换成 '_'，短横线保留 —— 组名是给人看的。
function gname(c,   _g) { _g = c; gsub(/[^A-Za-z0-9-]/, "_", _g); return "c" _g }
# 确保 dir 存在且 cpus == want；不足就发命令（幂等）
function ensuredir(dir, want,   _p, _c) {
    _c = rdline(dir "/cpus"); _p = dir "/"
    if (_c == "") {
        emit("mkdir -p " _p)
        emit("echo 0 > " _p "mems")
        emit("echo " want " > " _p "cpus")
        emit("chmod 666 " _p "cpus " _p "mems 2>/dev/null")
        return
    }
    if (_c != want) emit("echo " want " > " _p "cpus")
}
BEGIN {
    # 上一轮的「线程数 + 规格」缓存：线程数没变、且进程就在目标 lo 组里
    #   → 新线程都是继承来的、位置正确 → 跳过整轮逐线程扫描。
    #   这是把每轮开销压到「每进程一次读」的关键。
    while ((getline l < ST) > 0) {
        n = split(l, a, TAB)
        if (n >= 8 && a[1] != "") S[a[1]] = a[2] TAB a[3] TAB a[4] TAB a[5] TAB a[6] TAB a[7] TAB a[8]
    }
    close(ST)
}
{
    pid = $1; o = $2; m = $3; h = $4; ht = $5; hr = $6; cm = $7; uni = $8; tl = $9; pkg = $10
    if (pid == "" || pkg == "") next
    if (!(pid in SL)) SL[pid] = pkg
    sg = SL[pid]; gsub(/[^A-Za-z0-9_]/, "_", sg)
    dir = ROOT "/" sg

    cg = rdline("/proc/" pid "/cpuset")

    # ---- 档位 = 系统接管（核位全空）→ 该进程不该待在我们的组里 ----
    if (o == "" && m == "") {
        if (index(cg, "/" CGNAME "/") > 0) print sg > UNB
        next
    }

    lo = (o == "" ? m : o)
    # ---- 需要哪几个组：其余线程的核位 + 主线程/重线程/comm 用到的核位 ----
    delete ND
    ND[gname(lo)] = lo
    if (m != "" && m != lo) ND[gname(m)] = m
    if (h != "" && h != lo) ND[gname(h)] = h
    if (cm != "") {
        nc = split(cm, cps, ",")
        for (k = 1; k <= nc; k++) {
            if (cps[k] == "") continue
            at = index(cps[k], "@"); if (at < 1) continue
            ce = substr(cps[k], at+1)
            if (ce != "" && ce != lo) ND[gname(ce)] = ce
        }
    }
    # ---- 父组 cpus = 各角色核位的并集（压成 0-3,4-7 形式）----
    delete UU; una = ""
    for (g in ND) una = (una == "" ? ND[g] : una "," ND[g])
    nl = listof(una); nn = split(nl, ua, " ")
    for (i = 1; i <= nn; i++) if (ua[i] != "") UU[ua[i]+0] = 1
    us = ""; i = 0
    while (i <= MAXC + 1) {
        if (i in UU) {
            j = i; while ((j+1) in UU) j++
            us = us (us == "" ? "" : ",") (i == j ? i "" : i "-" j)
            i = j + 1
        } else i++
    }
    if (us == "") next

    ensuredir(dir, us)
    for (g in ND) { ensuredir(dir "/" g, ND[g]); print dir "/" g > KEEP }

    # ---- 进程整体迁到 lo 组：1 次写，之后新建的线程全部自动继承 ----
    loPath = "/" CGNAME "/" sg "/" gname(lo)
    # ⚠ 判定必须是「在不在我们这棵子树里」，**不能**比 /proc/<pid>/cpuset 是否等于 loPath：
    #   /proc/<pid>/cpuset 反映的是**主线程**所在的组，而主线程本来就该待在
    #   gname(m) 那个组里 → 用 loPath 比会永远不等 → 每轮都把整进程打回 lo，
    #   把刚提上大核的主线程/渲染线程又拽下来（真机实测踩过：c4_7 一装就空）。
    inTree = (index(cg, "/" CGNAME "/" sg "/") == 1)
    if (!inTree) emit("echo " pid " > " dir "/" gname(lo) "/cgroup.procs")

    # ---- 逐线程修正：只在必要时做 ----
    #   跳过条件（三个都满足才跳）：
    #     ① 进程在我们子树里（没被 framework 挪走）
    #     ② 线程数没变（没有新线程 → 不存在「继承错位」需要纠正）
    #     ③ 主线程就在它该在的组（说明上一次的逐线程修正确实落地了）
    nt = nthr(pid)
    sig = lo TAB m TAB h TAB ht TAB hr TAB cm
    mainWant = "/" CGNAME "/" sg "/" gname(m == "" ? lo : m)
    skip = 0
    if (pid in S && inTree && cg == mainWant) {
        split(S[pid], ov, TAB)
        if (ov[1] == nt && (ov[3] TAB ov[4] TAB ov[5] TAB ov[6] TAB ov[7]) == sig) skip = 1
    }
    print pid TAB nt TAB loPath TAB m TAB h TAB ht TAB hr TAB cm > (ST ".new")
    if (skip || tl == "" || nt == "") next

    n = split(tl, tids, " ")
    for (i = 1; i <= n; i++) {
        tid = tids[i]; if (tid == "") continue
        c = rdline("/proc/" pid "/task/" tid "/comm")
        w = lo
        if (tid == pid) w = m
        if (c != "" && hr != "" && index(c, hr) > 0) w = h
        if (c != "" && ht != "" && index(c, ht) > 0) w = m
        if (cm != "" && c != "") {
            ng = split(cm, pairs, ",")
            for (k = 1; k <= ng; k++) {
                if (pairs[k] == "") continue
                at = index(pairs[k], "@"); if (at < 1) continue
                tn = substr(pairs[k], 1, at-1); tm = substr(pairs[k], at+1)
                if (tn != "" && index(c, tn) > 0) { w = tm; break }
            }
        }
        if (w == "" || w == lo) continue                      # 默认组就是进程组，不必单独迁
        want = "/" CGNAME "/" sg "/" gname(w)
        if (rdline("/proc/" pid "/task/" tid "/cpuset") != want)
            emit("echo " tid " > " dir "/" gname(w) "/tasks")
    }
}
' "$TIDS" 2>/dev/null

# ------------------------------------------------------------
#  执行命令（只有确实要改的才在里面）
# ------------------------------------------------------------
[ -s "$CMD" ] && sh "$CMD" >/dev/null 2>&1

# ------------------------------------------------------------
#  「系统接管」档的包：从我们的组里放出来
# ------------------------------------------------------------
if [ -s "$UNB" ]; then
    while IFS= read -r s; do
        [ -n "$s" ] && _unbind_tree "$s"
    done < "$UNB"
fi

# ------------------------------------------------------------
#  清扫：父组下不再需要的子组（档位换过之后留下的）
#  ⚠ 用 case 匹配而不是 grep —— 组可能有几百个，grep 每个一次 fork 太贵
# ------------------------------------------------------------
if [ -s "$KEEP" ]; then
    KV=" $(tr '\n' ' ' < "$KEEP") "
    for d in "$CROOT"/*/*/; do
        [ -d "$d" ] || continue
        p="${d%/}"
        case "$KV" in *" $p "*) ;; *) rmdir "$p" 2>/dev/null ;; esac
    done
fi

# ------------------------------------------------------------
#  状态落盘（下一轮读它决定要不要重扫线程）
# ------------------------------------------------------------
[ -s "$ST.new" ] && mv -f "$ST.new" "$ST" 2>/dev/null
exit 0
