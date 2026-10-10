#!/system/bin/sh
# ============================================================
#  aether_ctl.sh —— 艇长(Aether)线程引擎：拓扑部署 + 启停 + 状态
# ------------------------------------------------------------
#  设计：线程核心分配完全交给艇长的 aether-optext（Rust 二进制）。
#    本脚本只负责：
#      1) deploy  —— 按设备 CPU 拓扑把语义占位符展开成真实核号，
#                    生成 /sdcard/Android/Aether/threads.json；
#      2) start/stop/restart —— 拉起 / 停掉 aether-optext；
#      3) status / ison —— 供 WebUI 读取；
#      4) feat / featlist —— 读写 features 里的扁平开关（图形界面用）。
#    二进制缺失或内核不支持 eBPF 时，aether-optext 自身会静默退出，
#    不影响模块其余功能；WebUI 据此如实上报。
# ============================================================
MODDIR="${MODDIR:-/data/adb/modules/SceneO3Tuner}"
# 二进制 / 模板 / 名单一律按脚本自身所在目录定位（安装期 $MODDIR 可能还不是最终路径）
SCRIPT_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
AETHER_DIR="${SCRIPT_DIR:-$MODDIR/Scripts/4+4+2/O3/aether}"
BIN="$AETHER_DIR/aether-optext"
TPL="$AETHER_DIR/threads.json"
GAME="$AETHER_DIR/gamelist"
TARGET="/sdcard/Android/Aether"
CFG="$TARGET/threads.json"
STATE_DIR="${STATE_DIR:-/data/adb/SceneO3Tuner}"
ONF="$STATE_DIR/aether.on"
LOG="$STATE_DIR/aether.log"
TMPD="${TMPD:-/data/local/tmp/_wui}"
# 艇长基准（首装时把设备现有配置或模板固化；之后所有部署都基于它，绝不直接回灌模板）
BASE="$STATE_DIR/threads_base.json"
# 用户自定义覆盖：每行 包名<TAB>核位（0-3/4-7/8-9/0-7/4-9）
OVR="$STATE_DIR/aether_overrides.tsv"
# 应用→核位映射（由 base 生成，WebUI 展示用）：包名<TAB>核位<TAB>艇长名
APPRULES="$STATE_DIR/apprules.tsv"
mkdir -p "$STATE_DIR" "$TMPD" 2>/dev/null

has(){ command -v "$1" >/dev/null 2>&1; }

# ★ 转义 pgrep/pkill -f 的正则元字符。
#   二进制路径里含 "4+4+2"，其中的「+」会被 pgrep -f 当成「前导字符量词」，
#   导致 pgrep -f ".../4+4+2/.../aether-optext" 永远匹配不到本模块进程 → RUNNING 误报 0、
#   pkill 也停不掉本模块引擎。这里把 [][\.*+?(){}|^$] 全部转义成字面量。
re_escape(){ printf '%s' "$1" | sed 's/[][\.*+?(){}|^$]/\\&/g'; }
# 取本模块二进制路径（已转义，可直接喂给 pgrep -f / pkill -f）
BIN_RE="$(re_escape "$BIN")"

# ---------- 拓扑检测（复用艇长 customize.sh 的 cpufreq 分组逻辑）----------
detect_topo() {
  eval "$(for policy in /sys/devices/system/cpu/cpufreq/policy[0-9]*; do
      [ -d "$policy" ] || continue
      freq=$(cat "$policy/cpuinfo_max_freq" 2>/dev/null)
      cpus=$(cat "$policy/related_cpus" 2>/dev/null)
      [ -z "$freq" ] || [ -z "$cpus" ] && continue
      echo "$freq:$cpus"
    done | sort -t: -k1,1n | awk -F: '
    function normalize(s,    out,n,parts,i,p,lo,hi,j) {
        n = split(s, parts, /[ ,]+/)
        out = ""
        for (i = 1; i <= n; i++) {
            p = parts[i]
            if (p == "") continue
            if (p ~ /-/) { split(p, r, /-/); lo = r[1]+0; hi = r[2]+0
                for (j = lo; j <= hi; j++) out = out (out==""?"":",") j }
            else out = out (out==""?"":",") p+0
        }
        return out
    }
    function compress(s,    n,a,i,j,t,out,start,prev,first) {
        n = split(s, a, /,/)
        for (i = 1; i <= n; i++) a[i] = a[i]+0
        for (i = 1; i <= n; i++) for (j = i+1; j <= n; j++)
            if (a[j] < a[i]) { t = a[i]; a[i] = a[j]; a[j] = t }
        if (n == 0) return ""
        out=""; start=a[1]; prev=a[1]; first=1
        for (i = 2; i <= n; i++) {
            if (a[i] == prev+1) { prev = a[i]; continue }
            out = out (first?"":",") (start==prev?start:start"-"prev)
            first=0; start=a[i]; prev=a[i]
        }
        out = out (first?"":",") (start==prev?start:start"-"prev)
        return out
    }
    $1 in freq { freq[$1] = freq[$1] "," $2; next }
    { freq[$1] = $2; order[++k] = $1 }
    END {
        n = k
        if (n == 0) { print "E_CORE= P1_CORE= P2_CORE= HP_CORE="; exit }
        e  = compress(normalize(freq[order[1]]))
        hp = compress(normalize(freq[order[n]]))
        p1 = (n >= 3) ? compress(normalize(freq[order[2]])) : ""
        p2 = (n >= 4) ? compress(normalize(freq[order[3]])) : ""
        if (hp == "") hp = e
        print "E_CORE=\"" e "\""
        print "P1_CORE=\"" p1 "\""
        print "P2_CORE=\"" p2 "\""
        print "HP_CORE=\"" hp "\""
    }')"

  ALL_CORE=$(cat /sys/devices/system/cpu/present 2>/dev/null)
  [ -z "$ALL_CORE" ] && ALL_CORE="$HP_CORE"
  if [ -n "$P1_CORE" ] && [ -n "$P2_CORE" ]; then
    P_CORE="${P1_CORE},${P2_CORE}"
  elif [ -n "$P1_CORE" ]; then
    P_CORE="$P1_CORE"
  else
    P_CORE="$P2_CORE"
  fi
}

# ---------- deploy：艇长基准 + 用户自定义 → 真机 threads.json ----------
cmd_deploy() {
  mkdir -p "$TARGET" "$STATE_DIR" "$TMPD" 2>/dev/null
  rm -f "${TARGET}/threads_cache" 2>/dev/null
  # gamelist：设备已有则保留（艇长/Aether 实时维护），仅首次缺失时播种
  if [ ! -s "${TARGET}/gamelist" ] && [ -f "$GAME" ]; then
    cp -f "$GAME" "${TARGET}/gamelist" 2>/dev/null
  fi
  # ① 固化「艇长基准」：首装时把设备现有配置（或模板）记成 base；之后所有部署都基于
  #    base + 用户自定义覆盖，绝不直接用模板回灌覆盖设备配置（保留艇长实时调校）。
  if [ ! -s "$BASE" ]; then
    if [ -s "$CFG" ]; then
      cp -f "$CFG" "$BASE" 2>/dev/null
      echo "OK 已记录艇长基准配置（首次捕获，rules=$(grep -c '\"friendly\"' "$BASE" 2>/dev/null)）"
    else
      if [ ! -f "$TPL" ]; then echo "ERR 找不到模板: $TPL"; return 1; fi
      detect_topo
      if grep -q '{[a-z_]*_core}' "$TPL" 2>/dev/null; then
        sed -e "s/{e_core}/$E_CORE/g"    -e "s/{p1_core}/$P1_CORE/g" \
            -e "s/{p2_core}/$P2_CORE/g"  -e "s/{p_core}/$P_CORE/g"  \
            -e "s/{hp_core}/$HP_CORE/g"  -e "s/{all_core}/$ALL_CORE/g" \
            "$TPL" > "$BASE" 2>/dev/null
        [ -s "$BASE" ] || { cp -f "$TPL" "$BASE" 2>/dev/null; }
      else
        cp -f "$TPL" "$BASE" 2>/dev/null
      fi
      chmod 0666 "$BASE" 2>/dev/null; chown 0:0 "$BASE" 2>/dev/null
      echo "OK 已按拓扑从模板生成基准配置（首装，e=$E_CORE p1=$P1_CORE p2=$P2_CORE hp=$HP_CORE all=$ALL_CORE）"
    fi
    chmod 0666 "$BASE" 2>/dev/null; chown 0:0 "$BASE" 2>/dev/null
  fi
  # ② 合并 base + 用户自定义覆盖 → 设备 CFG（Aether 真正读取的文件）
  merge_overrides
  # ③ 生成应用→核位映射（WebUI 图形展示用）
  gen_apprules
  echo "OK 已部署（艇长基准 $(grep -c '\"friendly\"' "$BASE" 2>/dev/null) 条 + 自定义 $(grep -c . "$OVR" 2>/dev/null || echo 0) 条 → CFG $(grep -c '\"friendly\"' "$CFG" 2>/dev/null) 条）"
}

# ---------- 合并：base + 自定义覆盖 → CFG ----------
#  ⚠ v18.2 重做：覆盖**不再是「整个应用压到某一簇」**（旧写法只发
#     {"other": X, "comm": X}，把 RenderThread/音频/加载线程全压到一起，
#     与艇长的「分进程负载」模型相反）。现在按**角色**展开成五层：
#       main_thread    主线程
#       heaviest_thread/cores  最重线程 → 大核
#       heavy_thread/cores     重线程   → 中核
#       comm{...}      按线程名路由（音频/IO → 小核；渲染/任务 → 中核）
#       other          其余
#    占位符（{e_core}/{p1_core}/{hp_core}…）在 deploy 时按真机拓扑展开。
merge_overrides() {
  detect_topo
  [ -s "$OVR" ] || { cp -f "$BASE" "$CFG" 2>/dev/null; chmod 0666 "$CFG" 2>/dev/null; return 0; }
  # 每个覆盖包生成一条完整的 rule（cpuset 由角色展开为五层）
  local full="${TMPD}/aether_ovr_full.txt"
  : > "$full"
  local i=0 pkg role
  while IFS='	' read -r pkg role || [ -n "$pkg" ]; do
    [ -z "$pkg" ] && continue
    [ "${pkg#\#}" != "$pkg" ] && continue
    role=$(printf '%s' "$role" | tr -d ' \r'); [ -z "$role" ] && role=balance
    i=$((i+1))
    [ $i -eq 1 ] || printf ',\n' >> "$full"
    {
      printf '    {\n'
      printf '      "friendly": "自定义·%s",\n' "$pkg"
      printf '      "packages": ["%s"],\n' "$pkg"
      printf '      "cpuset": '
      tpl_cpuset "$role"
      printf '\n    }'
    } >> "$full"
  done < "$OVR"
  # 插入点：**最后一行只含 `]`（可有前导空格）**——兼容两种格式：
  #   艇长 Config 模板结尾是「  ]」，设备/二进制规范化后是「]」。
  #   旧写法硬匹配 /^  \]$/ 在后者上永不命中（覆盖静默失效），这里改为
  #   「记住最后一个 ^[[:space:]]*]$ 的行号，在其前插入」。
  awk -v full="$full" '
    { lines[NR] = $0 }
    /^[[:space:]]*\][[:space:]]*$/ { last = NR }
    END {
      if (last == 0) { for (i = 1; i <= NR; i++) print lines[i]; exit }
      for (i = 1; i < last; i++) print lines[i]
      # 给已有规则补逗号，再接覆盖规则
      printf ",\n"
      while ((getline l < full) > 0) print l
      print lines[last]
    }
  ' "$BASE" > "$CFG" 2>/dev/null
  [ -s "$CFG" ] || cp -f "$BASE" "$CFG" 2>/dev/null
  chmod 0666 "$CFG" 2>/dev/null; chown 0:0 "$CFG" 2>/dev/null
}

# 角色 → 五层分进程 cpuset（JSON 片段，单行）。核位用真机拓扑展开。
tpl_cpuset() {
  local role="$1"
  local E="$E_CORE" P1="$P1_CORE" HP="$HP_CORE" ALL="$ALL_CORE"
  [ -z "$HP" ] && HP="${E}"
  [ -z "$P1" ] && P1="${E}"
  case "$role" in
    powersave)
      # 轻线程/主线程压小核，只给渲染线程留一条通向中核的窄出口
      printf '{"main_thread":"%s","heaviest_thread":"RenderThread","heaviest_cores":"%s","heavy_thread":"RenderThread","heavy_cores":"%s","comm":{"%s":["Audio","AudioTrack","FMOD","Http","Socket","Download","GC","Pool","TAsync"]},"other":"%s"}' \
        "$E" "$P1" "$P1" "$E" "$E" ;;
    balance)
      printf '{"main_thread":"%s","heaviest_thread":"RenderThread","heaviest_cores":"%s","heavy_thread":"RenderThread","heavy_cores":"%s","comm":{"%s":["Worker","Job","Async","Pool","Audio","AudioTrack","FMOD","Http","Socket","Download"]},"other":"%s"}' \
        "$P1" "$P1" "$P1" "$E" "$E" ;;
    performance)
      printf '{"main_thread":"%s","heaviest_thread":"RenderThread;2.raster;rt-launcher","heaviest_cores":"%s","heavy_thread":"RenderThread,2.raster,rt-launcher","heavy_cores":"%s","comm":{"%s":["Audio","AudioTrack","FMOD","Http","Socket","Download","GC","Pool","TAsync"],"%s":["RenderThread","Job.","Loading.","TaskGraph","NativeThread","Background"]},"other":"%s,%s"}' \
        "$P1" "$P1" "$P1" "$E" "$P1" "$E" "$P1" ;;
    fast)
      # 中低负载 0-7 由系统分配，高负载线程由 load_aware 上探 4-9
      printf '{"main_thread":"%s","heaviest_thread":"RenderThread;GameThread;UnityMain","heaviest_cores":"%s","heavy_thread":"RenderThread;RHIThread;UnityGfx","heavy_cores":"%s","comm":{"%s":["Audio","AudioTrack","FMOD","Http","Socket","Download","GC","Pool","TAsync"],"%s":["RenderThread","Job.","Loading.","TaskGraph","NativeThread","Background","RHIThread"]},"other":"%s"}' \
        "$P1" "$HP" "$P1" "$E" "$P1" "$E,$P1" ;;
    game)
      # 游戏：主线程/最重线程上大核，渲染与任务线程走中核，音频/IO 留小核
      printf '{"main_thread":"%s,%s","heaviest_thread":"UnityMain;GameThread;UEGameThread;Thread-;Main","heaviest_cores":"%s","heavy_thread":"UnityGfx;RHIThread;RenderThread","heavy_cores":"%s","comm":{"%s":["Audio","AudioTrack","FMOD","Http","Socket","Download","GC","Pool","TAsync"],"%s":["RenderThread","Job.","Loading.","TaskGraph","NativeThread","Background","RHIThread","UnityGfx"]},"other":"%s"}' \
        "$E" "$HP" "$HP" "$P1" "$E" "$P1" "$E" ;;
    *)
      printf '{"main_thread":"%s","other":"%s"}' "$E" "$E" ;;
  esac
}

# ---------- 由 base 生成 应用→核位 映射（艇长已定义的线程分配）----------
gen_apprules() {
  awk '
    /[ \t]*"friendly"[ \t]*:[ \t]*"/ { f=$0; gsub(/.*"friendly"[ \t]*:[ \t]*"/,"",f); gsub(/".*/,"",f); inr=1; pkgs=""; other=""; next }
    inr && /"packages"[ \t]*:[ \t]*\[/ { inpkg=1 }
    inr && inpkg {
       line=$0
       while (match(line, /"[a-zA-Z][a-zA-Z0-9._]*"/)) {
          p=substr(line,RSTART,RLENGTH); p=substr(p,2,length(p)-2)
          if (p ~ /\./) pkgs=(pkgs==""?p:pkgs SUBSEP p)
          line=substr(line,RSTART+RLENGTH)
       }
       if ($0 ~ /\]/) inpkg=0
       next
    }
    inr && /"other"[ \t]*:[ \t]*"/ { o=$0; gsub(/.*"other"[ \t]*:[ \t]*"/,"",o); gsub(/".*/,"",o); other=o; next }
    inr && /^[ \t]*\}/ { n=split(pkgs,arr,SUBSEP); for(i=1;i<=n;i++) print arr[i] "\t" other "\t" f; inr=0 }
  ' "$BASE" > "$APPRULES" 2>/dev/null
  chmod 0666 "$APPRULES" 2>/dev/null
}

# ---------- apps：列出本机有界面的应用 + 系统/第三方 + 艇长/自定义/未分配 ----------
#   ⚠ v18 优化：原版对每个包各跑一次 grep/awk（≈300+ 进程 → 卡顿）；
#      现改为「一次性读入 OVR/APPRULES 到内存表 + 单趟扫描清单」的纯 awk，
#      全程零 per-pkg fork，几百个应用也能秒出。
cmd_apps() {
  local lp="${TMPD}/launch.txt" sp="${TMPD}/sys.txt"
  cmd package query-activities --brief -a android.intent.action.MAIN -c android.intent.category.LAUNCHER 2>/dev/null \
    | sed -n 's#^[[:space:]]*\([^/][^/]*\)/.*#\1#p' | sort -u > "$lp"
  # ★ 兜底：launcher 查询无结果（某些 ROM / 权限下会返回空）时，退回 pm 全包清单，
  #   避免线程页「读不出有界面应用」。注意：$lp/$sp 必须是**纯包名**（与正常路径一致，
  #   awk 里据此判定系统/第三方），不要加 APP= 前缀。第三方(pm -3)进 $lp、系统(pm -s)进 $sp。
  if [ ! -s "$lp" ]; then
    pm list packages -3 2>/dev/null | sed 's/^package://' | sort -u > "$lp"
  fi
  pm list packages -s 2>/dev/null | sed 's/^package://' | sort -u > "$sp"
  # 四份输入各包一行哨兵（# 开头），保证空文件也能正确计数（mawk/toybox 没有 ARGIND）
  local ovrf="${TMPD}/ovr.txt" aprf="${TMPD}/apr.txt" spf="${TMPD}/sp.txt" lpf="${TMPD}/lp.txt"
  { echo '#'; [ -s "$OVR" ]      && cat "$OVR"; }      > "$ovrf" 2>/dev/null
  { echo '#'; [ -s "$APPRULES" ] && cat "$APPRULES"; } > "$aprf" 2>/dev/null
  { echo '#'; cat "$sp"; }                             > "$spf"  2>/dev/null
  { echo '#'; cat "$lp"; }                             > "$lpf"  2>/dev/null
  awk -F'\t' -v OFS='|' '
    /^#/ { fc++; next }                                # 每个文件的哨兵：文件序号 +1
    fc==1 { ovr[$1]=$2; next }                         # 文件1: OVR 自定义覆盖 pkg->cluster
    fc==2 { if (!($1 in ovr)) apa[$1]=$2 SUBSEP $3; next }  # 文件2: APPRULES pkg->cluster\friendly
    fc==3 { sys[$0]=1; next }                          # 文件3: 系统包清单
    {                                                 # 文件4: launcher 清单（主输出）
      p=$0
      if (p=="") next
      if (p ~ /[\/<>\" \x60]/) next
      s=(p in sys)?"1":"0"
      if (p in ovr)      { print "APP=" p, s, "1", "1", ovr[p], "自定义"; next }
      if (p in apa)      { split(apa[p], a, SUBSEP); print "APP=" p, s, "1", "0", a[1], a[2]; next }
      print "APP=" p, s, "0", "0", "", ""
    }
  ' "$ovrf" "$aprf" "$spf" "$lpf"
  rm -f "$ovrf" "$aprf" "$spf" "$lpf" 2>/dev/null
}

# ---------- set：为应用套用「角色档」（分进程五层策略）----------
cmd_set() {
  local pkg="$1" role="$2"
  [ -z "$pkg" ] && { echo "ERR 用法: set <包名> <角色档>"; return 1; }
  case "$pkg" in */*|*'<'*|*'>'*|*'"'*|*' '*|*\`*) echo "ERR 包名含非法字符"; return 1 ;; esac
  role=$(printf '%s' "$role" | tr -d ' \r')
  case "$role" in
    powersave|balance|performance|fast|game) ;;
    # 旧核位 → 等价角色
    0-3)       role=powersave ;;
    4-7|0-7)   role=performance ;;
    8-9|4-9)   role=fast ;;
    *) echo "ERR 非法角色档: $role（可用 powersave/balance/performance/fast/game）"; return 1 ;;
  esac
  mkdir -p "$STATE_DIR"
  [ -f "$OVR" ] && awk -F'\t' -v p="$pkg" '$1!=p' "$OVR" > "${OVR}.tmp" 2>/dev/null && mv -f "${OVR}.tmp" "$OVR" 2>/dev/null
  printf '%s\t%s\n' "$pkg" "$role" >> "$OVR"
  chmod 0666 "$OVR" 2>/dev/null; chown 0:0 "$OVR" 2>/dev/null
  cmd_deploy
  echo "OK 已为 ${pkg} 套用线程角色档：${role}（分进程下发，其余仍由艇长自动分配）"
}

# ---------- del：移除自定义，恢复由艇长自动分配 ----------
cmd_del() {
  local pkg="$1"
  [ -z "$pkg" ] && { echo "ERR 用法: del <包名>"; return 1; }
  [ -f "$OVR" ] || { echo "ERR 无自定义记录"; return 1; }
  awk -F'\t' -v p="$pkg" '$1!=p' "$OVR" > "${OVR}.tmp" 2>/dev/null && mv -f "${OVR}.tmp" "$OVR" 2>/dev/null
  chmod 0666 "$OVR" 2>/dev/null
  cmd_deploy
  echo "OK 已移除 ${pkg} 的自定义分配（恢复由艇长自动分配）"
}

# ---------- setbatch：批量套用「角色档」（仅一次 deploy）----------
#   入参：多行 pkg<TAB>role；role=auto 表示移除该包自定义。
#   role ∈ powersave|balance|performance|fast|game（分进程五层，不是单簇核位）。
#   兼容旧的裸核位（0-3/4-7/…）—— 映射到等价角色，避免老前端写入非法值。
cmd_setbatch() {
  local tmp="${TMPD}/aether_batch.tsv" keep=0 drop=0 bad=0
  : > "$tmp"
  while IFS= read -r line || [ -n "$line" ]; do
    [ -z "$line" ] && continue
    pkg=$(printf '%s' "$line" | cut -f1)
    cl=$(printf '%s' "$line" | cut -f2- | tr -d ' \r')
    [ -z "$pkg" ] && { bad=$((bad+1)); continue; }
    case "$pkg" in */*|*'<'*|*'>'*|*'"'*|*' '*|*\`*) bad=$((bad+1)); continue ;; esac
    case "$cl" in
      powersave|balance|performance|fast|game) keep=$((keep+1)) ;;
      # 旧核位 → 等价角色（老前端 / 历史数据兼容）
      0-3)                     cl=powersave;   keep=$((keep+1)) ;;
      4-7|0-7)                 cl=performance; keep=$((keep+1)) ;;
      8-9|4-9)                 cl=fast;        keep=$((keep+1)) ;;
      auto|"")                 drop=$((drop+1)) ;;
      *)                       bad=$((bad+1)); continue ;;
    esac
    printf '%s\t%s\n' "$pkg" "$cl" >> "$tmp"
  done
  [ -s "$tmp" ] || { rm -f "$tmp"; echo "ERR 没有有效的 包=角色 输入"; return 1; }
  mkdir -p "$STATE_DIR"
  # 用批处理表重建 OVR：旧 OVR 中未被本批「auto」命中的行先保留，再叠加 set 行
  local merged="${TMPD}/aether_ovr_merged.tsv"
  : > "$merged"
  [ -f "$OVR" ] && cp -f "$OVR" "$merged" 2>/dev/null
  # 移除本批涉及的所有包（无论 set 还是 auto），再追加 set 行
  awk -F'\t' -v bf="$tmp" 'BEGIN{ while ((getline l < bf) > 0) { split(l,a,"\t"); if(a[1]!="") rem[a[1]]=1 } }
    !($1 in rem) { print }' "$merged" > "${merged}.tmp" 2>/dev/null && mv -f "${merged}.tmp" "$merged" 2>/dev/null
  awk -F'\t' '$2!="auto"' "$tmp" >> "$merged" 2>/dev/null
  mv -f "$merged" "$OVR" 2>/dev/null
  chmod 0666 "$OVR" 2>/dev/null; chown 0:0 "$OVR" 2>/dev/null
  cmd_deploy
  echo "OK 批量套用完成：设置 ${keep} 个角色档、移除 ${drop} 个自定义、忽略 ${bad} 个非法"
}

# ---------- 启停 ----------
cmd_start() {
  [ -f "$ONF" ] || { echo "SKIP aether 未启用（$ONF 不存在）"; return 0; }
  [ -x "$BIN" ] || { echo "ERR 二进制缺失或不可执行: $BIN"; return 1; }
  [ -f "$CFG" ] || cmd_deploy >/dev/null 2>&1
  # 只停掉「本模块」的 aether-optext（按完整路径匹配，已 regex 转义），不要误杀同名兄弟模块
  pkill -f "$BIN_RE" 2>/dev/null; sleep 1
  # ★ 同配置抢占：设备若存在另一个同名 KSU 模块 aether-optext，它很可能也读着
  #   /sdcard/Android/Aether/threads.json —— 两份引擎抢同一份配置会互殴。
  #   本模块启用时，必须把「非本模块路径、但读同一份 -c CFG」的 aether-optext 也停掉，
  #   由本模块独占该配置。命中条件：cmdline 含本模块 CFG 路径且**不是**本模块二进制。
  for pid in $(pgrep -f "aether-optext -c $CFG" 2>/dev/null); do
    c=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)
    case "$c" in *"$BIN"*) continue ;; esac   # 本模块自己的，跳过
    kill "$pid" 2>/dev/null && echo "已让出同配置竞争引擎 pid $pid"
  done
  sleep 1
  # ★ 关键：常驻 native 进程必须**完全脱离**调用方的进程树与 stdio 管道。
  #   旧写法 `nohup $BIN ... &` 只是让 SIGHUP 不杀它，但它仍是 action 脚本的
  #   子进程、且**继承了 stdin（KSU action 的输出管道）**。KSU 的 action 运行器
  #   会一直读到 EOF 才返回，而常驻进程永不退出 → 管道写端不关闭 → 面板卡死、
  #   Manager 被系统杀掉（现象就是「划到 action 按钮 KSU 闪退」）。
  #   这里用 ( ... & ) 再 fork 一次把子进程过继给 init，并把三路 fd 全重定向
  #   （stdin→/dev/null，out/err→日志），彻底断开与 action 管道的连接。
  if command -v setsid >/dev/null 2>&1; then
    ( setsid "$BIN" -c "$CFG" -s </dev/null >> "$LOG" 2>&1 & )
  else
    ( "$BIN" -c "$CFG" -s </dev/null >> "$LOG" 2>&1 & )
  fi
  echo "OK 已启动 aether-optext（已脱离 action 进程树）"
}

cmd_stop() {
  pkill -f "$BIN_RE" 2>/dev/null
  sleep 1
  pgrep -f "$BIN_RE" >/dev/null 2>&1 && echo "WARN 仍有进程残留" || echo "OK 已停止"
}

cmd_restart() { cmd_stop >/dev/null 2>&1; cmd_start; }

cmd_ison() { [ -f "$ONF" ] && echo on || echo off; }

cmd_status() {
  echo "ON=$(cmd_ison)"
  # ⚠ 必须按本模块自己的二进制路径判定「是否运行中」：设备上存在另一个同名 KSU 模块
  #   aether-optext（/data/adb/modules/aether-optext/aether-optext），其进程 cmdline
  #   也含 aether-optext；且本模块路径含 "4+4+2"，「+」是正则元字符，pgrep -f 必须转义。
  #   用 BIN_RE（已转义完整路径）精确命中本模块进程，杜绝误判 / 漏判。
  local _p; _p=$(pgrep -f "$BIN_RE" 2>/dev/null | tr '\n' ',' | sed 's/,$//')
  if [ -n "$_p" ]; then
    echo "RUNNING=1"; echo "PID=$_p"
  else
    echo "RUNNING=0"; echo "PID="
  fi
  echo "CFG_BYTES=$(wc -c < "$CFG" 2>/dev/null | tr -d ' ')"
  echo "RULES=$(grep -c '\"friendly\"' "$CFG" 2>/dev/null)"
  echo "BIN_OK=$([ -x "$BIN" ] && echo 1 || echo 0)"
  echo "TOPO_E=$E_CORE"; echo "TOPO_P1=$P1_CORE"; echo "TOPO_P2=$P2_CORE"; echo "TOPO_HP=$HP_CORE"; echo "TOPO_ALL=$ALL_CORE"
}

# ---------- features 读写（扁平开关，图形界面用）----------
featget() {
  local k="$1"
  grep -oE "\"$k\"[[:space:]]*:[[:space:]]*[^,}]*" "$CFG" 2>/dev/null | head -1 \
    | sed -E "s/\"$k\"[[:space:]]*:[[:space:]]*//"
}
cmd_featlist() {
  for k in ebpf auto-for-none foreground load_aware render_guard min_cpus; do
    v=$(featget "$k")
    [ -n "$v" ] && echo "FEAT_${k}=${v}"
  done
}

# ---------- rules：把艇长配置结构化输出（供 WebUI 图形展示 / 自定义）----------
cmd_rules() {
  echo "RULES=$(grep -c '\"friendly\"' "$CFG" 2>/dev/null)"
  # 每条规则：friendly | other核位（按出现顺序一一对应，艇长模板每条恰一个）
  awk '
    /"friendly"/ { f=$0; gsub(/.*"friendly"[ \t]*:[ \t]*"/,"",f); gsub(/".*/,"",f); buf=f }
    /"other"/   { o=$0; gsub(/.*"other"[ \t]*:[ \t]*"/,"",o); gsub(/".*/,"",o);
                  printf "RULE=%s|%s\n", buf, o; buf="" }
  ' "$CFG" 2>/dev/null
}
cmd_feat() {
  local k="$1" v="$2"
  if [ -z "$v" ]; then featget "$k"; return; fi
  case "$k" in
    ebpf|auto-for-none|foreground|load_aware|render_guard)
      case "$v" in true|false) ;; *) echo "ERR 仅接受 true/false"; return 1 ;; esac ;;
    min_cpus) case "$v" in *[!0-9]*) echo "ERR min_cpus 必须为整数"; return 1 ;; esac ;;
    *) echo "ERR 未知特性: $k"; return 1 ;;
  esac
  if ! sed -i -E "s/(\"$k\"[[:space:]]*:[[:space:]]*)[^,}]*/\1$v/" "$CFG" 2>/dev/null; then
    echo "ERR 写入失败"; return 1
  fi
  echo "OK $k=$v（重启引擎后生效）"
}

case "$1" in
  deploy)   cmd_deploy ;;
  start)    cmd_start ;;
  stop)     cmd_stop ;;
  restart)  cmd_restart ;;
  status)   cmd_status ;;
  ison)     cmd_ison ;;
  topo)     detect_topo; echo "E=$E_CORE P1=$P1_CORE P2=$P2_CORE HP=$HP_CORE ALL=$ALL_CORE" ;;
  featlist) cmd_featlist ;;
  feat)     cmd_feat "$2" "$3" ;;
  rules)    cmd_rules ;;
  apps)     cmd_apps ;;
  set)      cmd_set "$2" "$3" ;;
  del)      cmd_del "$2" ;;
  setbatch) cmd_setbatch ;;
  *) echo "err: unknown command '$1'"; exit 1 ;;
esac
