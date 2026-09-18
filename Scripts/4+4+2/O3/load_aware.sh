#!/system/bin/sh
# ============================================================
#  动态负载感知（load_aware）—— 移植自 Aether OptExt
# ------------------------------------------------------------
#  原理（NetizenNemo/Aether_OptExt · src/process.rs:182 load_level）：
#    读 /proc/{tid}/stat 的 utime+stime，与上次采样求差 → 实测占用率，
#    高负载并到更强的核簇、空闲收缩到能效核。
#    tick 单位 = 1/USER_HZ 秒（Android USER_HZ=100 → 1 tick = 10ms）。
#
#  ★★ 与艇长的关键差异：升级目标按**玄戒 O3**调优，不是照搬 ★★
#    艇长的默认是「高负载并入 {hp_core}（超大核 8-9）」。
#    但本项目在 O3 上的实测结论是：
#      · C1-Ultra（8-9）**只在 >2.2GHz 才有能效优势**，低频大核不如中核；
#      · 中核（4-7）在 835200~1468800MHz 就能跑满 120fps（UnityMain 87%）；
#      · 大核在游戏里只承担 0.7%~1.7% 的计算量。
#    ⇒ 本移植的升级第一目标是 **{p1_core}（中核 4-7）**；
#      只有基集**已经含中核**时，才再往上并 8-9。
#      这样既不会把线程推去低频空转的大核，也保留了「中核也不够用」时的上限。
#
#  用法: load_aware.sh <tids文件> <hot输出文件> <p1表达式> <hp表达式> <e表达式>
#  状态: $TMP/lw.state（tid<TAB>ticks）+ $TMP/lw.ts（上次采样时间戳）
#  关闭: touch $STATE_DIR/lw_off   （默认开启）
#  调参: LW_INTERVAL（秒，默认 25）—— 采样间隔，越大越省电、响应越慢
#        LW_HOT（默认 8）—— 升级阈值，对应占用率 >60%
#        LW_IDLE（默认 2）—— 收缩阈值，对应占用率 ≤5%
# ============================================================
TMP="${TMPD:-/data/adb/SceneO3Tuner/tmp}"
ST="${STATE_DIR:-/data/adb/SceneO3Tuner}"
mkdir -p "$TMP" 2>/dev/null

TIDS="$1"; OUT="$2"; SP1="$3"; SHP="$4"; SE="$5"
[ -s "$TIDS" ] || { : > "$OUT" 2>/dev/null; exit 0; }
[ -n "$OUT" ] || OUT="$TMP/lw.hot"

# 关闭开关（项目惯例：STATE_DIR 下的标记文件）
[ -f "$ST/lw_off" ] && { : > "$OUT"; exit 0; }

LW_INTERVAL="${LW_INTERVAL:-25}"
LW_HOT="${LW_HOT:-8}"
LW_IDLE="${LW_IDLE:-2}"

STATEF="$TMP/lw.state"; TSF="$TMP/lw.ts"; NEWF="$TMP/lw.state.new"

# ---- 采样节流：不到间隔就直接沿用上一轮的 hot 结果（零开销）----
NOW=$(date +%s 2>/dev/null)
LAST=""
[ -f "$TSF" ] && LAST=$(cat "$TSF" 2>/dev/null)
case "$NOW" in ''|*[!0-9]*) NOW=0 ;; esac
case "$LAST" in ''|*[!0-9]*) LAST=0 ;; esac
if [ "$NOW" -gt 0 ] && [ "$LAST" -gt 0 ] && [ $((NOW - LAST)) -lt "$LW_INTERVAL" ]; then
    [ -f "$OUT" ] || : > "$OUT"
    exit 0
fi

# ---- 实际窗口（秒）→ tick 数 ----
#   ⚠ 必须用**真实间隔**而不是 LW_INTERVAL：首轮、跳轮、脚本被拖慢都会让
#     窗口不等于标称值，用错会让占用率整体偏高/偏低。
WIN=$(( NOW - LAST ))
if [ "$LAST" -eq 0 ] || [ "$WIN" -le 0 ] || [ "$WIN" -gt 600 ]; then
    WIN="$LW_INTERVAL"     # 首轮/异常值：用标称窗口，且本轮不产出 hot（无 prev）
    FIRST=1
else
    FIRST=0
fi
ETICKS=$(( WIN * 100 ))     # USER_HZ=100

# ---- 采样：一次读完所有目标进程的全部线程 ----
#   fork 预算：每进程 1 次 cat + 1 次 awk（与线程数无关）。
#   echo 是 shell 内建 → 循环里不 fork（本机 printf 不是内建，别用）。
{
  while IFS='|' read -r p o m h ht hr cm uni tl pkg; do
      [ -n "$p" ] || continue
      [ -d "/proc/$p" ] || continue
      echo "@$p|$o"
      cat "/proc/$p/task"/*/stat 2>/dev/null
  done < "$TIDS"
# ⚠ 输出文件用的变量名**绝不能叫 NF / NR / FS / OFS** 这些 awk 内置名 ——
#   写 `-v NF=xxx` 会把内置的「字段数」覆盖成字符串，重定向静默失败
#   （测试实测：状态文件根本写不出来）。这里用 STNW / HOTF。
} | awk -v SP1="$SP1" -v SHP="$SHP" -v SE="$SE" \
        -v ET="$ETICKS" -v FIRST="$FIRST" -v HOT="$LW_HOT" -v IDLE="$LW_IDLE" \
        -v STF="$STATEF" -v STNW="$NEWF" -v HOTF="$OUT" '
#   ⚠⚠ 这三个函数的字符串**首尾都必须带空格**（" 4 5 6 7 "），
#      否则 `index(s, " 7 ")` 对**最后一个元素**恒为 0 —— 实测踩过：
#      末位核位判不出来 → hasany 误判为假、merge 把已有的核位又加一遍
#      → 生成 "4-7,7" 这种畸形表达式（内核直接 EINVAL）。
function listof(e,   _i,_n,_a,_lo,_hi,_c,_out,_b) {
    _out = ""
    _n = split(e, _a, ",")
    for (_i = 1; _i <= _n; _i++) {
        gsub(/^[ \t]+|[ \t]+$/, "", _a[_i])
        if (_a[_i] == "") continue
        if (_a[_i] ~ /^[0-9]+-[0-9]+$/) { split(_a[_i], _b, "-"); _lo = _b[1]+0; _hi = _b[2]+0 }
        else if (_a[_i] ~ /^[0-9]+$/)    { _lo = _a[_i]+0; _hi = _lo }
        else continue
        for (_c = _lo; _c <= _hi; _c++) if (!(_c in _S)) { _S[_c] = 1; _out = _out " " _c }
    }
    for (_i in _S) delete _S[_i]
    return _out " "                    # 尾空格：见上方警告
}
#  核位集合 → 压缩表达式（" 4 5 6 7 8 9 " → "4-9"）
#  按 0..31 升序扫（核心数有限），顺带完成**去重 + 排序** ——
#  merge 之后的顺序是「基集顺序 + 追加」，不排序会吐出 "0-3,8-9,4-7"
#  （内核接受，但难读且不利于比对）。
function list2expr(s,   _i,_n,_a,_st,_pv,_out) {
    for (_i = 0; _i <= 31; _i++) _Q[_i] = 0
    _n = split(s, _a, " ")
    for (_i = 1; _i <= _n; _i++) if (_a[_i] != "") _Q[_a[_i]+0] = 1
    _out = ""; _st = ""; _pv = ""
    for (_i = 0; _i <= 31; _i++) {
        if (!(_i in _Q) || _Q[_i] != 1) continue
        if (_pv != "" && _i == _pv + 1) { _pv = _i; continue }
        if (_st != "") _out = _out (_st == _pv ? _st : _st "-" _pv) ","
        _st = _i; _pv = _i
    }
    if (_st != "") _out = _out (_st == _pv ? _st : _st "-" _pv)
    return _out
}
function hasany(baseList, addList,   _n,_a,_i) {
    _n = split(addList, _a, " ")
    for (_i = 1; _i <= _n; _i++)
        if (_a[_i] != "" && index(" " baseList " ", " " _a[_i] " ") > 0) return 1
    return 0
}
function merge(baseList, addList,   _n,_a,_i,_out) {
    _out = " " baseList " "
    _n = split(addList, _a, " ")
    for (_i = 1; _i <= _n; _i++)
        if (_a[_i] != "" && index(_out, " " _a[_i] " ") == 0) _out = _out _a[_i] " "
    return _out
}
BEGIN {
    L_P1 = listof(SP1); L_HP = listof(SHP); L_E = listof(SE)
    while ((getline l < STF) > 0) {
        n = split(l, a, "\t")
        if (n >= 2 && a[1] != "") PREV[a[1]] = a[2] + 0
    }
    close(STF)
}
/^@/ {
    split(substr($0, 2), b, "|")
    curPid = b[1]; curBase = b[2]
    next
}
{
    # /proc/{tid}/stat：pid (comm) state ppid ... utime stime ...
    # ⚠ comm 可能含空格与括号 → 必须按**第一个右括号**截断（不能用正则贪婪匹配）
    if (curPid == "") next
    i = index($0, ")")
    if (i == 0) next
    tid = $1 + 0
    if (tid <= 0) next
    rest = substr($0, i + 2)
    n = split(rest, a, " ")
    if (n < 13) next
    ticks = a[12] + a[13]
    print tid "\t" ticks > STNW

    if (FIRST == 1 || ET <= 0) next
    if (!(tid in PREV)) next                 # 新线程：本轮只登记，下轮才有基线
    d = ticks - PREV[tid]
    if (d < 0) d = 0
    ratio = int(d * 100 / ET)
    if (ratio <= 5)       lvl = 1
    else if (ratio <= 15) lvl = 3
    else if (ratio <= 35) lvl = 5
    else if (ratio <= 60) lvl = 7
    else                  lvl = 10

    baseL = listof(curBase)
    if (lvl >= HOT) {
        # 忙线程：先并中核；基集已含中核时才再上超大核（O3 调优）
        if (hasany(baseL, L_P1)) t = merge(baseL, L_HP)
        else                     t = merge(baseL, L_P1)
        # 输出 tid pid 核位表达式 —— 带上 pid，pin_cgroup 才能按进程判断「要不要跳过全量扫描」
        print tid " " curPid " " list2expr(t) > HOTF
    } else if (lvl <= IDLE && L_E != "") {
        # 空闲线程：收缩到能效核（仅当基集本来就更大时才有实际变化）
        if (hasany(baseL, L_P1) || hasany(baseL, L_HP))
            print tid " " curPid " " list2expr(L_E) > HOTF
    }
}
END {
    close(STNW); close(HOTF)
}
' 2>/dev/null

# ---- 状态落盘（重建，顺带清掉已退出的 tid）----
[ -s "$NEWF" ] && mv -f "$NEWF" "$STATEF" 2>/dev/null
echo "$NOW" > "$TSF" 2>/dev/null
[ -f "$OUT" ] || : > "$OUT"
exit 0
