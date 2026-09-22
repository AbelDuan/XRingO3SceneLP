#!/system/bin/sh
# ============================================================
#  线程绑核「落地」器 v3（2026-09-15）
# ------------------------------------------------------------
#  【为什么必须自己做】
#    2026-09-17 实测修正（此前"Scene 不会应用 threads.json"的结论**已被推翻**）：
#    Scene 的「核心分配」**会**读 files/threads.json 的 app_cpuset，并在**触摸时**
#    把值写进 /dev/cpuset/top-app/{main,render,other}/cpus（真实手指或内核级
#    sendevent 都能触发；input swipe 注入的是 InputManager 事件，不经过 /dev/input，
#    所以触发不了）。而且它的 @cpuset 预算是**按 Scene 全局模式**给的，写子组时
#    还会自己裁到预算内 —— 结果是「省电」这类窄预算把所有档位压平成同一核位，
#    per-app 差异全部消失（用户实测：效果很差）。
#
#    所以 v10 的取舍是：
#      · Scene 侧关闭核心分配（Config/*/features/cpuset.conf: in_apps/in_games=0），
#        它只负责它擅长的部分 —— 按模式下发 CPU 频率；
#      · 线程由本脚本逐线程落核（sched_setaffinity），能精确到 UnityMain /
#        RenderThread / 任意 comm 名字，这是 Scene 做不到的。
#
#  【v3 的关键发现：cgroup 预算】
#    本机是 cgroup v1 cpuset（挂载在 /dev/cpuset，cpuset_v2_mode），
#    每个应用被放进一个组，组里的 CPU 掩码就是它的**硬预算**：
#        /dev/cpuset/background      cpus = 0-3
#        /dev/cpuset/foreground      cpus = 0-9
#        /dev/cpuset/top-app         cpus = 0-9
#        /dev/cpuset/top-app/main    ← Scene 的「核心分配」写的就是这几个子组
#        /dev/cpuset/top-app/render     （实测 2026-09-17；main/render/other 三个
#        /dev/cpuset/top-app/other      子组由 Scene 自己创建，task_profiles.json 里没有）
#    sched_setaffinity 只能在预算**之内**收窄：对 background 组里的进程
#    `taskset -p f0`（4-7）会直接 EINVAL（实测）。
#    所以本脚本把目标核与当前组的预算取交集：
#      · 前台/顶层组（0-9）→ 模板完整生效（这才是交互时真正需要的）
#      · 后台组（0-3）    → 系统本身已把整个应用限在 0-3，交集就是 0-3，
#                            与现状一致 → **一条命令都不发**（也几乎不耗电）
#    这也顺带解释了「v2 每轮猛发任务却是无效功」的原因。
#
#  【v2 的性能教训】
#    v1 对每条分配 fork 一次 pidof、命中后再 fork 6 次 tplcol(awk)、3 次
#    cores2mask、expand_semantic 里还有 sed；800 条分配 ≈ 上万次 fork，
#    单次 >180 秒，而守护每 5 秒跑一轮 → 守护永远跑不完，CPU 常驻打满。
#    v2/v3：解析 + 判断 + 生成命令全在一个 awk 进程里，shell 只做 glob 与执行，
#    基础开销固定 5 次 fork，与分配条数无关。
#      ⚠ 本机 `printf` **不是内建**（/system/bin/printf），循环里逐行 printf
#        等于每行 fork 一次（72 行就要 1 秒，还会打断 read 缓冲）→ 必须攒好再一次写。
#
#  目标解析优先级（v10）：
#    ① Scene 游戏名单（games.xml）里的包 → game_assign.tsv 的档位
#    ② 其余包                            → app_assign.tsv 的档位
#    ⚠ v10 起**不再**从 Scene 的 powercfg.xml 实时推导档位。档位（powersave/
#      balance/performance/fast）是模块自持数据，只在用户点「从 Scene 导入」时
#      被覆盖一次。旧版那条实时分支的副作用很实在：Scene 把 com.android.camera
#      等包设成 fast 后映射为空，这些包会从目标表里彻底消失，界面上却仍显示
#      「已套高性能」，实际一条 taskset 都没发。
#    核位全空（fast 档）= 该包一条 taskset 都不发 → 不绑核，交回系统。
#    历史残留由 unbind_fast.sh 在档位变更时清一次（cgroup 预算是它的还原目标）。

#  幂等：逐线程比对「目标∩预算」与当前值，一致就一条命令都不发。
#  用法: enforce_threads.sh [pkg...]      不带参数 = 全部目标
# ============================================================
MODDIR="${MODDIR:-/data/adb/modules/SceneO3Tuner}"
. "$MODDIR/lib/util.sh"

TASK="taskset"
CG_ROOT="/dev/cpuset"
TMP="${TMPD:-/data/adb/SceneO3Tuner/tmp}"
mkdir -p "$TMP" 2>/dev/null

TGT="$TMP/t.targets"; PSF="$TMP/t.ps"; RUN="$TMP/t.run"; TIDS="$TMP/t.tids"; CMDS="$TMP/t.cmds"
SIGF="$TMP/t.sig"
# 已落核缓存 + 本轮待办（省功耗的关键，见下面 3.5 的说明）
APL="$TMP/t.applied"; KEEP="$TMP/t.keep"; TODO="$TMP/t.todo"
# 缓存有效期（秒）。到期后即使规格没变也会重新逐线程核对一遍 —— 外部（系统/框架）
# 万一改了亲和性，最多 TTL 秒后自愈。
APL_TTL="${APL_TTL:-180}"
rm -f "$KEEP" "$TODO" 2>/dev/null

# ============================================================
#  落核模式（v16.17）—— 默认改为逐线程 taskset
# ------------------------------------------------------------
#  taskset = 默认：逐线程 sched_setaffinity（艇长 Aether_OptExt 的原始手段）。
#  group   = 可选回退：整进程放进 cgroup 子组，**新线程靠继承**。
#
#  【为什么把默认从 group 换成 taskset】（2026-09-18 真机 A/B，同 TMPD、各 4 轮稳态）
#      cgroup 分组   459 / 488 / 528 ms
#      逐线程 taskset 268 / 321 / 396 ms
#    taskset 稳态快约 1.4~1.7 倍，来源是：① 值已正确时一条命令都不发（幂等短路）；
#    ② 不必每轮维护 96+ 个 cgroup 组目录、也不做组迁移。
#    实测单次 `taskset -p` 12ms、fork+exec 6ms（proot 下 fork 特别贵）。
#
#  【代价（实测，必须知情）】taskset 的亲和性**不继承**给新线程：
#      父线程 taskset 到 0-3 → 它之后新建的线程 allowed=0-9
#    而 cgroup 组的 cpus 会强制约束组内（含新建）线程。
#    所以 taskset 模式下新线程最多要等一轮才被绑上；有 APL_TTL（180s）兜底自愈。
#
#  调试/单测可用环境变量强制：PIN_MODE=group|taskset
#  切回 cgroup：touch $STATE_DIR/pin_cgroup（重装即失效）
#  ⚠ 旧版的 pin_taskset 标记已废弃（默认就是 taskset），留着也不影响。
# ============================================================
PIN_MODE="${PIN_MODE:-taskset}"
[ -f "${STATE_DIR}/pin_cgroup" ] && PIN_MODE="group"
CG_PIN="$MODDIR/Scripts/4+4+2/O3/pin_cgroup.sh"

# ------------------------------------------------------------
#  taskset 模式：一次性清掉遗留的 cgroup 组树（v16.17）
# ------------------------------------------------------------
#  为什么必须清：从旧布局升级上来的设备，/dev/cpuset/SceneO3Tuner 下还留着
#  各组，**组内线程仍受组 cpus 约束**（cgroup 的 cpus 是硬约束，taskset 只在其
#  之上收窄）。不清的话「默认走 taskset」名不副实 —— 线程依然被组锁着，
#  而且新线程继续继承组的掩码。
#  只在切换后跑一次（标记 $STATE_DIR/cg_unbound），幂等。
# ------------------------------------------------------------
if [ "$PIN_MODE" = "taskset" ] && [ ! -f "${STATE_DIR}/cg_unbound" ]; then
    if [ -d "$CG_ROOT/SceneO3Tuner" ]; then
        sh "$CG_PIN" --unbind-all >/dev/null 2>&1
        log_quiet "enforce: 已清理遗留 cgroup 组树（切到 taskset 模式）"
    fi
    : > "${STATE_DIR}/cg_unbound" 2>/dev/null
fi

# 输入是否变了：用**文件 mtime** 与 $SIGF 比较（shell 内建 -nt，0 子进程）。
#   ⚠ 原来用 md5sum + awk 算签名，两个子进程 ≈ 30~80ms；而本脚本前台一变就会被调用，
#     这笔开销是亮屏功耗的固定部分。mtime 判据同样可靠（输入都是整体重写的配置文件）。
sig_inputs_newer() {   # 0 = 有输入比标记新（需要重算）
    local f
    # ⚠ v10：Scene 的 powercfg.xml / settings.conf 已**不再是输入**
    #   （档位改由 app_assign.tsv 自持，详见 util.sh 的 import_scene_apply）——
    #   继续拿它们当 mtime 判据只会让守护白重算一遍目标表。
    for f in "$APP_TPL_FILE" "$APP_ASSIGN_FILE" "$GAME_TPL_FILE" "$GAME_ASSIGN_FILE" \
             "$SCENE_GAMES_XML"; do
        [ -f "$f" ] && [ "$f" -nt "$SIGF" ] && return 0
    done
    return 1
}

# ---- 语义占位符 / 在线核：走零 fork 读法 ----
#   ⚠ 原来是 `$(cpu_semantic …)` × 6 + `$(cpu_expr_to_list "$(online_cpus)")`：
#     9 个子 shell ≈ 90~150ms，每次前台一变都要付一遍。现在全是内建赋值。
cpu_semantic_read e_core;   SEM_e="$SEM_VAL"
cpu_semantic_read p1_core;  SEM_p1="$SEM_VAL"
cpu_semantic_read p2_core;  SEM_p2="$SEM_VAL"
cpu_semantic_read p_core;   SEM_p="$SEM_VAL"
cpu_semantic_read hp_core;  SEM_hp="$SEM_VAL"
cpu_semantic_read all_core; SEM_all="$SEM_VAL"
online_cpus_read
cpu_expr_to_list_read "$ONLINE_RAW"   # "0-3,8-9" → "0 1 2 3 8 9"（与旧版语义一致）
ONLINE="$CPU_LIST"

# ---- 当前模式的调度语义（v16.13）----
#   四档语义集中在 lib/util.sh 的 mode_sched_row()；这里读出本档的
#   升级目标/阈值/间隔，供下面的 load_aware 使用。零 fork 读法：
#   Scene state → 方案名兜底。
scene_current_mode_read
mode_sched_read "$CUR_MODE"
# 升级目标为空（省电档）时用单个 "-" 占位，保证 load_aware 的位置参数不错位
SESC="$MS_ESC"; [ -n "$SESC" ] || SESC="-"

# ============================================================
#  1) 解析目标表
#     PKG|other|main|heavy|heaviest_thread|heavy_thread|commPairs|uni
#     前三列是已展开并裁剪到在线核的核号表达式；commPairs 形如
#     "RenderThread@8-9,Working@4-7,"（v3 起存表达式，掩码留给最后一步算）。
# ============================================================
if [ ! -s "$TGT" ] || [ ! -s "$SIGF" ] || sig_inputs_newer; then
awk \
    -v TAB="$(printf '\t')" \
    -v APPTPL="$APP_TPL_FILE" -v APPASG="$APP_ASSIGN_FILE" \
    -v GTPL="$GAME_TPL_FILE" -v GASG="$GAME_ASSIGN_FILE" -v GAMEXML="$SCENE_GAMES_XML" \
    -v ONL="$ONLINE" \
    -v CAMRE="$CAMERA_RE" \
    -v SE="$SEM_e" -v SP1="$SEM_p1" -v SP2="$SEM_p2" \
    -v SP="$SEM_p" -v SHP="$SEM_hp" -v SALL="$SEM_all" '
function trim(x) { gsub(/^[ \t\r]+/, "", x); gsub(/[ \t\r]+$/, "", x); return x }

# 占位符展开（[{] / [}] 用字符类，避免 ERE 花括号歧义）
function expand(v,   _k, _n, _out) {
    _out = v
    _n = split("e_core p1_core p2_core p_core hp_core all_core", K, " ")
    for (_k = 1; _k <= _n; _k++) gsub("[{]" K[_k] "[}]", SEM[K[_k]], _out)
    return _out
}
function expr2list(e,   _i, _n, _a, _lo, _hi, _c, _out) {
    _out = ""
    _n = split(e, _a, ",")
    for (_i = 1; _i <= _n; _i++) {
        _a[_i] = trim(_a[_i]); if (_a[_i] == "") continue
        if (_a[_i] ~ /^[0-9]+-[0-9]+$/) { split(_a[_i], _b, "-"); _lo = _b[1]+0; _hi = _b[2]+0 }
        else if (_a[_i] ~ /^[0-9]+$/)    { _lo = _a[_i]+0; _hi = _lo }
        else continue
        for (_c = _lo; _c <= _hi; _c++) if (!(_c in SEEN)) { SEEN[_c] = 1; _out = _out " " _c }
    }
    for (_i in SEEN) delete SEEN[_i]
    return _out
}
function list2expr(s,   _i, _n, _a, _st, _pv, _out) {
    _out = ""; _st = ""; _pv = ""
    _n = split(s, _a, " ")
    for (_i = 1; _i <= _n; _i++) {
        if (_a[_i] == "") continue
        if (_pv != "" && _a[_i] == _pv + 1) { _pv = _a[_i]; continue }
        if (_st != "") _out = _out (_st == _pv ? _st : _st "-" _pv) ","
        _st = _a[_i]; _pv = _a[_i]
    }
    if (_st != "") _out = _out (_st == _pv ? _st : _st "-" _pv)
    return _out
}
# 展开 → 裁剪到在线核 → 规范表达式
function norm(e,   _i, _n, _a, _out) {
    e = expand(e)
    _n = split(expr2list(e), _a, " ")
    _out = ""
    for (_i = 1; _i <= _n; _i++) if (ON[_a[_i]]) _out = _out " " _a[_i]
    return list2expr(_out)
}
# 表达式 → 规范式 的 memo（同样几个 {e_core}/{p1_core} 会被算上千次）
function normm(e,   _r) {
    if (e in NRM) return NRM[e]
    _r = norm(e); NRM[e] = _r; return _r
}
function load_tpl(f, T, P,   _l, _n, _a, _id) {
    while ((getline _l < f) > 0) {
        if (_l == "" || _l ~ /^#/) continue
        _n = split(_l, _a, TAB)
        if (_n < 2) continue
        _id = trim(_a[1]); if (_id == "") continue
        T[P _id] = trim(_a[3]) "|" trim(_a[4]) "|" trim(_a[5]) "|" trim(_a[6]) "|" trim(_a[7]) "|" trim(_a[8])
    }
    close(f)
}
BEGIN {
    SEM["e_core"]=SE; SEM["p1_core"]=SP1; SEM["p2_core"]=SP2
    SEM["p_core"]=SP; SEM["hp_core"]=SHP; SEM["all_core"]=SALL
    m = split(ONL, oa, " "); for (i = 1; i <= m; i++) if (oa[i] != "") ON[oa[i]] = 1

    load_tpl(APPTPL, T, "A")
    load_tpl(GTPL,    T, "G")
    while ((getline l < APPASG) > 0) { if (l == "" || l ~ /^#/) continue; split(l, f, TAB); if (f[1] != "" && f[2] != "") ASGA[f[1]] = f[2] }
    close(APPASG)
    while ((getline l < GASG) > 0)   { if (l == "" || l ~ /^#/) continue; split(l, f, TAB); if (f[1] != "" && f[2] != "") ASGG[f[1]] = f[2] }
    close(GASG)

    # Scene 真正标记为游戏的包（唯一权威来源 games.xml；不能只看 game_assign.tsv，
    # 历史脏数据里可能塞了几百个普通应用）
    while ((getline l < GAMEXML) > 0) {
        if (match(l, /<boolean name="[^"]*" value="true"/)) {
            g = l; sub(/^.*<boolean name="/, "", g); sub(/".*/, "", g)
            if (g != "") GSET[g] = 1
        }
    }
    close(GAMEXML)

    # ⚠ 相机固定「极速（不接管）」→ 下面两个循环都强制跳过，任何档位都绑不上它。
    #   用 CAMRE != "" 兜底：-v 传空串时 p ~ "" 恒真，会把整张目标表清空。
    # ① 游戏：game_assign.tsv 的档位
    for (p in GSET) {
        if (CAMRE != "" && p ~ CAMRE) continue
        if (p in ASGG) { s = T["G" ASGG[p]]; if (s != "") pick[p] = s }
    }
    # ② 其余：app_assign.tsv 的档位
    #   ⚠ v10 起**不再**从 Scene 的 powercfg.xml 实时推导档位（原 ③ 分支已删除）。
    #     它的副作用很实在：Scene 把 com.android.camera 等包设成 fast 时映射为空，
    #     那些包会从目标表里彻底消失，界面上却仍显示「已套高性能」，
    #     实际一条 taskset 都没发。现在档位是模块自持数据，只在用户点
    #     「从 Scene 导入」时才会被覆盖一次（import_scene_apply）。
    for (p in ASGA) {
        if (p in GSET) continue
        if (CAMRE != "" && p ~ CAMRE) continue
        s = T["A" ASGA[p]]; if (s != "") pick[p] = s
    }
    for (p in pick) {
        split(pick[p], c, "|")
        ao = normm(c[1]); am = normm(c[3]); ah = normm(c[5])
        if (ao == "" && am == "") continue
        cp = ""
        if (c[6] != "") {
            ng = split(c[6], grp, ";")
            for (gi = 1; gi <= ng; gi++) {
                g = trim(grp[gi]); if (g == "") continue
                eq = index(g, "="); if (eq < 2) continue
                cn = normm(substr(g, 1, eq-1)); cl = trim(substr(g, eq+1))
                if (cn == "" || cl == "") continue
                nn = split(cl, nam, ",")
                for (k = 1; k <= nn; k++) { tn = trim(nam[k]); if (tn != "") cp = cp tn "@" cn "," }
            }
        }
        # uni=1：全进程所有线程目标核一致（例如 light 全是 0-3）→ 只看一个线程即可
        uni = 0
        if (am == ao && ah == ao) {
            uni = 1
            if (cp != "") {
                ng2 = split(cp, cps, ",")
                for (gi2 = 1; gi2 <= ng2; gi2++) {
                    if (cps[gi2] == "") continue
                    at2 = index(cps[gi2], "@"); if (at2 < 1) continue
                    if (substr(cps[gi2], at2+1) != ao) { uni = 0; break }
                }
            }
        }
        printf "%s|%s|%s|%s|%s|%s|%s|%s\n", p, ao, am, ah, c[2], c[4], cp, uni
    }
}
' > "$TGT" 2>/dev/null
    [ -s "$TGT" ] && touch "$SIGF" 2>/dev/null
fi

[ -s "$TGT" ] || exit 0

# ============================================================
#  2) 运行中的进程（1 次 fork 取全表，不再逐包 pidof）
# ============================================================
ps -A -o PID,ARGS > "$PSF" 2>/dev/null

#  3) 目标 ∩ 运行中 → PID|other|main|heavy|ht|hr|commPairs|uni
#     ⚠ 用 -F'[|]' 而不是 -F'|'：管道符在正则里是「或」，单字符 FS 会被当正则用。
#  ⚠⚠ v17：必须同时匹配「主进程 + 冒号子进程」（2026-09-18 移植 Aether OptExt 的思路）
#    旧写法 `if (!(p in PID)) next` 是**精确名匹配** —— 只有 ps 里名字完全等于目标名的
#    进程才会被绑。Android 应用普遍有 `:push` / `:appbrand0` / `:xweb_*` / `:remote`
#    这类子进程，名字不等于主包 → **一条都匹配不上，全部漏绑**。
#    真机实测（微信 6 进程 / 酷安 2 进程）：只有主进程进了 c0-3，
#    5 个子进程（518 线程）全留在系统默认组 0-9 → 用户看到「有的 0-3、有的 0-9」。
#    子进程往往是干活的（`:appbrand0` = 小程序环境 214 线程、`:xweb_*` = WebView 沙箱）。
#
#    修法：ps 里凡含 ':' 的名字（`com.foo.bar:xxx`）额外登记到 SUB[`com.foo.bar`]，
#    于是给 `com.foo.bar` 配的档位会**连带它所有子进程**一起生效。
#    两趟处理保证「显式子进程条目优先」：先做精确匹配（含用户自己写的
#    `com.tencent.mm:appbrand` 这类条目），子进程兜底放 END，且跳过已匹配的 pid。
awk -F'[|]' -v PS="$PSF" '
BEGIN {
    # ps 输出形如 "   1 init second_stage"（前面有空格）→ 先去前导空白，
    # 否则按空白切分会得到一个空的首字段（这个坑踩过）。
    while ((getline l < PS) > 0) {
        l2 = l; sub(/^[ \t]+/, "", l2)
        if (l2 ~ /^PID[ \t]/) continue
        pid = l2 + 0
        if (pid <= 0) continue
        nm = l2; sub(/^[0-9]+[ \t]+/, "", nm); sub(/[ \t].*$/, "", nm)
        if (nm == "") continue
        if (nm in PID) PID[nm] = PID[nm] " " pid; else PID[nm] = pid
        # ---- 子进程登记：com.foo.bar:xxx → SUB[com.foo.bar] ----
        ci = index(nm, ":")
        if (ci > 1) {
            base = substr(nm, 1, ci - 1)
            if (base in SUB) SUB[base] = SUB[base] " " pid; else SUB[base] = pid
        }
    }
    close(PS)
}
{
    L[NR] = $0
    p = $1
    if (!(p in PID)) next
    n = split(PID[p], a, " ")
    for (i = 1; i <= n; i++) {
        if (a[i] in SEEN) continue
        SEEN[a[i]] = 1
        printf "%s|%s|%s|%s|%s|%s|%s|%s|%s\n", a[i], $2, $3, $4, $5, $6, $7, $8, $1
    }
}
END {
    for (k = 1; k <= NR; k++) {
        split(L[k], f, "|")
        p = f[1]
        if (p == "") continue
        # ⚠ 这里**不能**写 `if (p in PID) continue`：PID 的键是「ps 里存在的进程名」，
        #   而主包名（如 com.tencent.mm）**一定**在 PID 里 → 那样会把自己整条子进程
        #   分支短路掉（测试实测：只剩主进程被绑，子进程依然全漏）。
        #   正确的去重靠 SEEN —— 第一趟精确匹配已经认领的 pid 才跳过。
        if (!(p in SUB)) continue
        n = split(SUB[p], a, " ")
        for (i = 1; i <= n; i++) {
            if (a[i] in SEEN) continue               # 已被更精确的条目认领
            SEEN[a[i]] = 1
            printf "%s|%s|%s|%s|%s|%s|%s|%s|%s\n", a[i], f[2], f[3], f[4], f[5], f[6], f[7], f[8], p
        }
    }
}
' "$TGT" > "$RUN" 2>/dev/null

[ -s "$RUN" ] || { : > "$APL"; exit 0; }

# ============================================================
#  3.4) 受管进程迁入「自有受限组」nobig（v17，对齐艇长 Aether OptExt）
# ------------------------------------------------------------
#  bigcore_guard.sh 自建了 /dev/cpuset/SceneO3Tuner/nobig（cpus=0-7）。
#  这里把**受管进程**整体迁进去（写一次 cgroup.procs = 全部线程继承 0-7 预算），
#  于是 enforce 的逐线程 taskset 与预算取交集时，自然把大核 8-9 挡在门外，
#  且新线程自动继承 0-7 —— 不必每轮逐线程重绑。
#
#  ★ 不再冻结 top-app/foreground：那会与 scene-daemon 每 3~4s 互写打架
#    （v16 的常驻高占用/卡顿根因）。自有组只影响本模块登记过的进程，无打架。
#
#  逐应用判定（替代旧方案的「极速档解冻 top-app」）：
#    · 目标核位含 8/9（fast 档要上探大核）→ 不迁 nobig，留在 top-app（预算 0-9），
#      taskset 可设到 4-9；若当前在 nobig 则迁回 top-app（切档动态生效）。
#    · 目标不含 8/9 且非空（受管、要限制）→ 迁进 nobig。
#    · 目标为空（系统接管 / 未配置）→ 不限制，若当前在 nobig 则迁回 top-app。
#  只在「当前组 ≠ 目标组」时发命令（幂等）；组不存在则整段跳过（退化为不过问）。
#  仅 taskset 模式需要；pin_cgroup 模式由子组 cpus 自行限制，不走这里。
# ============================================================
NOBIG_G="$CG_ROOT/SceneO3Tuner/nobig"
# 3.4) 受管进程迁入「自有受限组」nobig（v17，对齐艇长 Aether_OptExt）
#   逻辑抽到 migrate_nobig.sh（自带建组 + 幂等迁移，可离线单测）。
#   仅 taskset 模式需要；pin_cgroup 模式由子组 cpus 自行限制，不走这里。
if [ "$PIN_MODE" != "group" ]; then
    sh "$MODDIR/Scripts/4+4+2/O3/migrate_nobig.sh" "$RUN" >/dev/null 2>&1
fi

# ============================================================
#  3.5) 已落核缓存 —— 把稳定态的开销从「每轮扫全部线程」降到「一次比对」
# ------------------------------------------------------------
#  实测：一轮完整核对要 300~400ms（59 个运行中的目标进程、逐个读
#  /proc/<tid>/status 与 comm）。但稳定态下这些进程的亲和性**本来就是对的**，
#  每 5 秒重扫一遍纯属白烧 CPU（约占单核 1.5%~4%）。
#
#  缓存键 = pid | 规格(other/main/heavy/两个线程名/comm/uni) | cgroup 组
#    · 规格变了（用户改了模板 / Scene 改了模式）→ 键不同 → 重扫
#    · 应用切了前后台 → cgroup 组变了 → 键不同 → 重扫（预算变了，目标也就变了）
#    · 键还在且未过期 → 跳过
#  过期时间 APL_TTL（默认 180s）兜底自愈。
#
#  ⚠ 键里必须带 cgroup：目标核要先与「该进程所在组的 CPU 预算」取交集，
#    同一个模板在 top-app(0-9) 与 background(0-3) 下算出来的目标完全不同。
# ============================================================
if [ -s "$APL" ]; then :; else : > "$APL"; fi
# 注意 cgroup 模式下不用这个缓存：它的粒度是「这个 pid 已核对过」，
#   而 cgroup 路径的核对本来就便宜（每进程读一次 /proc/<pid>/cpuset）；
#   缓存反而会挡住「进程被 framework 挪回标准组」这种要立刻纠正的情况。
if [ -s "$RUN" ] && [ "$PIN_MODE" != "group" ]; then
    NOW=$(date +%s)
    # ⚠ 缓存行字段用**制表符**分隔，不能用 |：spec 本身就是用 | 拼起来的，
    #   拿 | 当字段分隔符会把 spec 拆碎，回读时拼不回原键 → 缓存永远命中不了
    #   （实测表现：每一轮 62 个目标全部重扫，耗时 665ms、功耗反而比优化前高）。
    awk -F'[|]' -v TAB="$(printf '\t')" -v APL="$APL" -v NOW="$NOW" -v TTL="$APL_TTL" \
        -v KEEP="$KEEP" -v TODO="$TODO" '
    BEGIN {
        while ((getline l < APL) > 0) {
            n = split(l, a, TAB)
            if (n >= 4 && a[1] != "") AT[a[1] TAB a[2] TAB a[3]] = a[4]
        }
        close(APL)
    }
    {
        spec = $2 "|" $3 "|" $4 "|" $5 "|" $6 "|" $7 "|" $8
        cg = ""
        getline cg < ("/proc/" $1 "/cpuset"); close("/proc/" $1 "/cpuset")
        sub(/[\r\n]+$/, "", cg)
        key = $1 TAB spec TAB cg
        ts = AT[key]
        if (ts != "" && (NOW - ts) < TTL) { print key TAB ts > KEEP; next }
        print key TAB NOW > TODO
        print
    }
    ' "$RUN" > "$RUN.todo" 2>/dev/null
    mv -f "$RUN.todo" "$RUN" 2>/dev/null
fi

[ -s "$RUN" ] || { cat "$KEEP" > "$APL" 2>/dev/null; exit 0; }

# ============================================================
#  4) 线程号列表（shell 内建 glob，不 fork）
#     uni=1 的进程不扫线程（目标全进程一致，看一个线程就够），
#     绝大多数应用都是 uni —— 这是把每轮耗时压到百毫秒级的关键。
#     ⚠ printf 不是内建，循环里不能用；这里攒到一个变量后一次写出。
# ============================================================
buf=""
while IFS='|' read -r p o m h ht hr cm uni pkg; do
    [ -n "$p" ] || continue
    [ -d "/proc/$p" ] || continue
    tl=""
    # cgroup 模式必须拿到全部 tid：pin_cgroup.sh 要判断「哪些线程得从默认组
    # 提到大核组」，靠继承进来的线程不会自己报上来。glob 是 shell 内建，不 fork。
    if [ "$PIN_MODE" = "group" ] || [ "$uni" != "1" ]; then
        for t in "/proc/$p/task"/*; do tl="$tl ${t##*/}"; done
    fi
    buf="$buf$p|$o|$m|$h|$ht|$hr|$cm|$uni|$tl|$pkg
"
done < "$RUN"
printf '%s' "$buf" > "$TIDS"

# ============================================================
#  4.5) 动态负载感知（load_aware）—— 移植自 Aether OptExt
# ------------------------------------------------------------
#  给「其余线程」按 /proc/{tid}/stat 的 tick 增量实测占用率调档。
#  ★ v16.13：升级目标/阈值不再是写死的 {p1_core}，而是**按当前模式**取：
#      powersave   → 目标 "-"（不升级，线程留在 0-3 省电）
#      balance     → 4-7
#      performance → 4-7（8-9 不碰）
#      fast        → 4-9（只有高负载线程才上探；且不做空闲收缩）
#    参数全部来自 lib/util.sh 的 mode_sched_row()（单一事实源）。
#  产出 $TMP/lw.hot 供 pin_cgroup.sh 消费；不在间隔内则零开销直接返回。
#  ⚠ 必须在 5a) 之前跑：pin_cgroup 依赖它决定组集合与是否跳过缓存。
# ============================================================
if [ "$PIN_MODE" = "group" ] && [ $# -eq 0 ]; then
    sh "$MODDIR/Scripts/4+4+2/O3/load_aware.sh" "$TIDS" "$TMP/lw.hot" \
        "$SEM_p1" "$SEM_hp" "$SEM_e" \
        "$CUR_MODE" "$SESC" "$MS_HOTOK" "$MS_INT" "$MS_HOT" "$MS_IDLE" "$MS_IDLEOFF" \
        >/dev/null 2>&1
fi

# ============================================================
#  5a) cgroup 分组落核（首选）—— 原理见 pin_cgroup.sh 头部
# ============================================================
CG_OK=0
if [ "$PIN_MODE" = "group" ]; then
    sh "$CG_PIN" --apply "$TIDS" >/dev/null 2>&1 && CG_OK=1
fi

if [ "$CG_OK" != "1" ]; then
# ============================================================
#  5b) 回退：逐线程 taskset（目标 ∩ cgroup 预算 → 只写确实要改的）
#     awk 内部 getline 读 /proc 与 /dev/cpuset，不 fork。
# ============================================================
awk -F'[|]' -v CGROOT="$CG_ROOT" '
function trim(x) { gsub(/^[ \t\r]+/, "", x); gsub(/[ \t\r]+$/, "", x); return x }
function listof(e,   _i, _n, _a, _lo, _hi, _c, _out, _b) {
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
# 表达式 → 核号列表 的 memo（每个进程都对同一批表达式重算，缓存后省一大截）
function lom(e,   _r) {
    if (e in LM) return LM[e]
    _r = listof(e); LM[e] = _r; return _r
}
function maskof(l,   _i, _n, _a, _m) {
    _m = 0
    _n = split(l, _a, " ")
    for (_i = 1; _i <= _n; _i++) if (_a[_i] != "") _m += 2^_a[_i]
    return sprintf("%x", _m)
}
function inter(a, b,   _i, _n, _a, _out) {
    for (_i in BSET) delete BSET[_i]
    _n = split(b, _a, " ")
    for (_i = 1; _i <= _n; _i++) if (_a[_i] != "") BSET[_a[_i]] = 1
    _out = ""
    _n = split(a, _a, " ")
    for (_i = 1; _i <= _n; _i++) if (_a[_i] != "" && (_a[_i] in BSET)) _out = _out " " _a[_i]
    return _out
}
# 读 /proc/<tid>/status 的 Cpus_allowed_list（不 fork）。
# ⚠ 不用 split(...,/regex/)：toybox awk 对「正则字面量当分隔符」支持不稳，
#   实测会让这里一直返回空串，于是每轮都判定全线程不一致、每轮白下发一遍。
function affof(f,   _l) {
    while ((getline _l < f) > 0) {
        if (_l ~ /^Cpus_allowed_list:/) {
            sub(/^Cpus_allowed_list:[ \t]*/, "", _l)
            sub(/[ \t\r\n].*$/, "", _l)
            close(f); return _l
        }
    }
    close(f); return ""
}
# 该进程所在 cgroup 的 CPU 预算（v1 cpuset，cpuset_v2_mode 下文件名是 cpus）。
# 按组路径缓存，避免每个进程都读一遍。
function cgof(pid,   _g, _l, _f, _v, _i) {
    _g = ""
    while ((getline _l < ("/proc/" pid "/cpuset")) > 0) { _g = _l; break }
    close("/proc/" pid "/cpuset")
    sub(/[\r\n]+$/, "", _g)
    if (_g == "" || _g == "/") return ""
    if (_g in CG) return CG[_g]
    _v = ""
    for (_i = 1; _i <= 2; _i++) {
        _f = CGROOT _g (_i == 1 ? "/cpus" : "/cpuset.cpus")
        _l = ""
        while ((getline _l < _f) > 0) break
        close(_f)
        sub(/[\r\n]+$/, "", _l)
        if (_l != "") { _v = _l; break }
    }
    CG[_g] = _v
    return _v
}
{
    pid = $1; o = $2; m = $3; h = $4; ht = $5; hr = $6; cm = $7; uni = $8; tl = $9
    if (pid == "") next
    base = listof(cgof(pid))          # 预算；空 = 没有 cgroup 限制

    # ---- 快路径：全线程同目标 ----
    if (uni == "1") {
        if (m == "") next
        eff = base == "" ? lom(m) : inter(lom(m), base)
        if (eff == "") next
        em = maskof(eff)
        if (em != maskof(listof(affof("/proc/" pid "/status")))) printf "taskset -a -p %s %s\n", em, pid
        next
    }

    # ---- 慢路径：主线程 / 重线程 / comm 分到了不同核 ----
    # 先做一次「在当前 cgroup 预算下根本无事可做」的廉价判定：
    #   典型场景是应用在后台组（预算 0-3），而模板要求 4-9 / 8-9 等大核
    #   → 主线程目标 与 所有特例线程目标 都落在预算之外或就等于整个预算，
    #     此时整进程本来就该是「整个预算」，与现状一致 → 跳过整轮逐线程扫描。
    #   （不做这个判定的话，300 线程的应用每轮要读 600 个 /proc 文件。）
    eo = base == "" ? lom(o) : inter(lom(o), base)
    em = base == "" ? listof(m) : inter(listof(m), base)
    if (em == "" && tl != "") {
        bad = 0
        if (cm != "") {
            nc = split(cm, cps, ",")
            for (k = 1; k <= nc; k++) {
                if (cps[k] == "") continue
                at = index(cps[k], "@"); if (at < 1) continue
                ce = base == "" ? lom(substr(cps[k], at+1)) : inter(lom(substr(cps[k], at+1)), base)
                if (ce != "" && ce != eo) { bad = 1; break }
            }
        }
        if (!bad) {
            cur = maskof(listof(affof("/proc/" pid "/status")))
            if (cur == maskof(eo)) next
        }
    }

    nmis = 0; ntot = 0; tgt = ""
    n = split(tl, tids, " ")
    for (i = 1; i <= n; i++) {
        tid = tids[i]; if (tid == "") continue
        ntot++
        c = ""; getline c < ("/proc/" pid "/task/" tid "/comm"); close("/proc/" pid "/task/" tid "/comm")
        sub(/[\r\n]+$/, "", c)
        w = o
        if (tid == pid) w = m
        if (c != "" && hr != "" && matchsub(c, hr)) w = h
        if (c != "" && ht != "" && matchsub(c, ht)) w = m
        if (cm != "" && c != "") {
            ng = split(cm, pairs, ",")
            for (k = 1; k <= ng; k++) {
                if (pairs[k] == "") continue
                at = index(pairs[k], "@"); if (at < 1) continue
                tn = substr(pairs[k], 1, at-1); tm = substr(pairs[k], at+1)
                if (tn != "" && matchsub(c, tn)) { w = tm; break }
            }
        }
        if (w == "") w = o
        # 目标 ∩ cgroup 预算；交集为空说明想要的大核不在预算里 → 这个线程不动
        eff = base == "" ? lom(w) : inter(lom(w), base)
        # ⚠ 必须「掩码 vs 掩码」比较（want/eff 与 /proc 里读到的都是表达式→都转掩码）
        we = eff == "" ? "" : maskof(eff)
        cur = maskof(listof(affof("/proc/" pid "/task/" tid "/status")))
        if (we != "" && cur != we) nmis++
        tgt = tgt " " tid ":" we ":" cur
    }
    if (ntot == 0) next

    # 大面积不一致（应用刚起来 / 刚切前后台）→ 先整进程批量，再补差异
    if (nmis > 8 && o != "" && m != "") {
        eo = base == "" ? listof(o) : inter(listof(o), base)
        emm = base == "" ? listof(m) : inter(listof(m), base)
        if (eo != "") printf "taskset -a -p %s %s\n", maskof(eo), pid
        if (emm != "") printf "taskset -p %s %s\n", maskof(emm), pid
        eoM = eo == "" ? "" : maskof(eo)
        n = split(tgt, tg, " ")
        for (i = 1; i <= n; i++) {
            if (tg[i] == "") continue
            split(tg[i], q, ":")
            if (q[2] == "" || q[2] == eoM) continue
            printf "taskset -p %s %s\n", q[2], q[1]
        }
    } else {
        n = split(tgt, tg, " ")
        for (i = 1; i <= n; i++) {
            if (tg[i] == "") continue
            split(tg[i], q, ":")
            if (q[2] == "" || q[3] == q[2]) continue
            printf "taskset -p %s %s\n", q[2], q[1]
        }
    }
}
function matchsub(s, n) { return index(s, n) > 0 }
' "$TIDS" > "$CMDS" 2>/dev/null

# 6) 执行（只有真的需要改的命令才会在这里）
if [ -s "$CMDS" ]; then
    sh "$CMDS" >/dev/null 2>&1
fi
fi   # end of 5b

# 7) 落缓存：本轮核对过的（KEEP 里未过期的 + TODO 里本轮的）记下来，
#    下一轮同 pid + 同规格 + 同 cgroup 就直接跳过，不再重扫线程。
{ cat "$KEEP" 2>/dev/null; cat "$TODO" 2>/dev/null; } > "$APL.new" 2>/dev/null
mv -f "$APL.new" "$APL" 2>/dev/null
exit 0
