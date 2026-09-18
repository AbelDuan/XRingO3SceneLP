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
#    ⇒ 默认升级目标是 **{p1_core}（中核 4-7）**，**不升 8-9**（已是 v16.10 的结论）。
#      `LW_HP=1` 时才再往上探 —— 而且给的是 **4-9 窗口**（中核 ∪ 超大核），
#      **不是裸的 8-9**：8-9 只有 2 核，写上去等于把线程钉死在超大核；
#      4-9 让内核按负载在 4-7 / 8-9 之间自选，低负载仍留在中核。
#
#  ⚠⚠ v16.10 修正（重要）：v16.9 曾写成「基集已含中核时再并 8-9」，
#     而 performance 档的 other 本来就是 4-7 → **所有忙线程被推上 8-9**。
#     真机实测：微信等应用打开后线程显示 4-9（40 个目标里 31 个是 performance 档）。
#     与 O3 结论冲突（大核频窗 1.1~2.0GHz 在低效区）且违背档位语义 → 改为默认不升。
#
#  用法: load_aware.sh <tids文件> <hot输出文件> <p1表达式> <hp表达式> <e表达式> \
#                       <模式> <升级目标> <允许上探4-9> <间隔> <忙阈值> <闲阈值> <禁用空闲收缩>
#  状态: $TMP/lw.state（tid<TAB>ticks）+ $TMP/lw.ts（上次采样时间戳）
#  关闭: touch $STATE_DIR/lw_off   （默认开启）
#  ★ v16.13：升级目标/阈值不再写死，由调用方按**当前模式**从 lib/util.sh 的
#    mode_sched_row()（四档语义单一事实源）取好传进来。$6..$12 缺省时按
#    balance 档兜底，便于单独手测。
#  调参（环境变量仍可覆写，优先级高于位置参数）:
#        LW_INTERVAL（秒）—— 采样间隔，越大越省电、响应越慢
#        LW_HOT ———— 升级阈值（占用率百分数）
#        LW_IDLE ——— 收缩阈值（占用率百分数）
#        LW_HP —— 1 = 忙线程上探「4-9 窗口」（中核 ∪ 超大核，内核按负载自选）
#                 0 = 只并中核 4-7
# ============================================================
TMP="${TMPD:-/data/adb/SceneO3Tuner/tmp}"
ST="${STATE_DIR:-/data/adb/SceneO3Tuner}"
mkdir -p "$TMP" 2>/dev/null

TIDS="$1"; OUT="$2"; SP1="$3"; SHP="$4"; SE="$5"
MODE="${6:-balance}"
SESC="${7:-4-7}"                # 忙线程升级目标；"-" = 本档不升级
HOTOK="${8:-0}"                 # 1 = 允许上探 4-9
INTERVAL="${9:-12}"
HOTVAL="${10:-10}"
IDLEVAL="${11:-4}"
IDLEOFF="${12:-0}"
[ -s "$TIDS" ] || { : > "$OUT" 2>/dev/null; exit 0; }
[ -n "$OUT" ] || OUT="$TMP/lw.hot"

# 关闭开关（项目惯例：STATE_DIR 下的标记文件）
[ -f "$ST/lw_off" ] && { : > "$OUT"; exit 0; }

LW_INTERVAL="${LW_INTERVAL:-$INTERVAL}"
LW_HOT="${LW_HOT:-$HOTVAL}"
LW_IDLE="${LW_IDLE:-$IDLEVAL}"
LW_IDLEOFF="${LW_IDLEOFF:-$IDLEOFF}"
# 忙线程是否上探「4-9 窗口」。**默认 0** —— 见下方 awk 里的说明：
#   O3 的大核在 1.1~2.0GHz 频窗内能效不如中核（C1-Ultra 只在 >2.2GHz 才有优势），
#   所以默认只并中核 4-7。设 1 时并的是 4-9（中核 ∪ 超大核，内核按负载自选），
#   **不是裸的 8-9** —— 后者会把线程钉死在 2 个超大核上。
#   v16.13：只有 fast（极速）档的 HOTOK=1。
LW_HP="${LW_HP:-$HOTOK}"

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
} | awk -v SP1="$SP1" -v SHP="$SHP" -v SE="$SE" -v SESC="$SESC" \
        -v ET="$ETICKS" -v FIRST="$FIRST" -v HOT="$LW_HOT" -v IDLE="$LW_IDLE" \
        -v LWHP="$LW_HP" -v IDLEOFF="$LW_IDLEOFF" -v MODE="$MODE" \
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
#  升级是否**真的会改变**基集（addList 里有 baseList 没有的核位）。
#  ⚠ 不能用 `te != be` 判断：目标可能是 "4-9"、base 是 "4-7" 时，
#    listof("4-7") ⊆ listof("4-9") → 并出来的表达式等于**目标**而不是 base。
#  ⚠ "-" 是调用方（enforce_threads.sh）给「本档不升级」的占位符 —— 这里也要
#    显式判掉，否则会被当成一个核位字符串而恒真。
function added(baseList, addList,   _n,_a,_i) {
    if (addList == "" || addList == "-" || addList == " ") return 0
    _n = split(addList, _a, " ")
    for (_i = 1; _i <= _n; _i++)
        if (_a[_i] != "" && _a[_i] != "-" && index(" " baseList " ", " " _a[_i] " ") == 0) return 1
    return 0
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
    be = list2expr(baseL)
    # ⚠⚠ 阈值一律 **+0 强制数值化**：`awk -v HOT="$LW_HOT"` 传进来的是**字符串**，
    #   而 awk 在「字符串 vs 数字」比较时走**字符串比较**（实测：lvl=7 >= HOT=9
    #   为假、lvl=10 >= HOT=12 也为假 —— 结果取决于字典序而非数值）。
    #   手测时字面量是 number → 数值比较，所以「手测正常、走脚本失效」。
    #   这是上游移植时就带的隐患（v16.13 一并修掉）。
    lvlN = lvl + 0; hotN = HOT + 0; idleN = IDLE + 0
    # 该线程是否正停在「上一轮被我们升级过」的核位上（base == 本档升级目标）。
    #   空闲时要能收回来，否则它会被永久钉在中核/大核上（热点过去也不下来）。
    esce = list2expr(listof(SESC))
    on_esc = (esce != "" && be == esce) ? 1 : 0
    if (lvlN >= hotN) {
        # 忙线程：升到**本档的升级目标**（SESC，由调用方从 mode_sched_row() 取）。
        #   powersave   SESC="-"   → **本档不升级**（线程一律留在 0-3 小核省电）
        #   balance     SESC=4-7   → 并中核
        #   performance SESC=4-7   → 同上（8-9 不碰）
        #   fast        SESC=4-9 + LWHP=1 → 并「4-9 窗口」（中核 ∪ 超大核）
        # ★★ 给的是「4-9」而不是「8-9」：8-9 只有 2 核，直接并上去等于把线程钉在超大核；
        #    给 4-9 则让内核按实际负载在 4-7（4 核）和 8-9（2 核）之间自己挑，
        #    低负载自然留在中核。所以 fast 档优先用 SESC，只有 SESC 缺失时才走
        #    「LW_HP=1 → merge(L_P1, L_HP)」的老路径（保持向后兼容）。
        # ⚠ 默认 LW_HP=0（只并中核），因为 O3 实测 C1-Ultra 只在 >2.2GHz 才有能效优势，
        #    而 sweet_hq 下大核频窗是 1.1~2.0GHz —— 常态上探大核是负收益。
        # ⚠ "-" 是「本档不升级」的占位符，必须**显式跳过整个升级逻辑**，
        #   不能靠「目标已包含于基集」兜底 —— 否则省电档会被兜底规则升到中核。
        if (SESC == "-" || SESC == "") {
            # 本档不升级：什么都不做（省电档）
        } else {
            upL = listof(SESC)
            if (LWHP == 1) upL = merge(upL, merge(L_P1, L_HP))
            if (added(baseL, upL)) {
                t = merge(baseL, upL); te = list2expr(t)
                # ⚠⚠ `print ... > FILE` 的重定向会**吃掉后面的分号表达式**：
                #   `{ print x > F; done = 1 }` 是 awk 语法错误（实测踩过）——
                #   awk 整个程序解析失败 → 主规则完全不执行 → 状态文件空白、永不升级，
                #   而调用方的 `2>/dev/null` 把语法错误吞掉，表现为「静默失效」。
                if (te != "" && te != be) print tid " " curPid " " te > HOTF
            }
        }
    } else if (lvlN <= idleN && L_E != "" && IDLEOFF != 1) {
        # 空闲线程：收缩到能效核（仅当基集本来就更大时才动）
        #   fast（极速）档 IDLEOFF=1：中低负载线程保持在 0-7 由系统分配，不收缩回 0-3。
        ee = list2expr(L_E)
        if (on_esc || hasany(baseL, L_P1) || hasany(baseL, L_HP))
            if (ee != "" && ee != be) print tid " " curPid " " ee > HOTF
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
