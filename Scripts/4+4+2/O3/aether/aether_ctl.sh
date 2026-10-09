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
merge_overrides() {
  local ovr_file="${TMPD}/aether_ovr.txt"
  awk -F'\t' -v n="$(grep -c . "$OVR" 2>/dev/null || echo 0)" '
    BEGIN{ i=0 }
    NF>=2 {
       i++
       rule="    {\n      \"friendly\": \"自定义·" $1 "\",\n      \"packages\": [\"" $1 "\"],\n      \"cpuset\": { \"other\": \"" $2 "\", \"comm\": \"" $2 "\" }\n    }"
       if (i < n) printf ",\n  %s,\n", rule
       else       printf ",\n  %s\n", rule
    }
  ' "$OVR" > "$ovr_file" 2>/dev/null
  # 把覆盖规则插到 rules 数组闭合符（^  ]$）之前
  awk 'FNR==NR{o=o $0 "\n"; next} /^  \]$/ && !d{printf "%s", o; d=1} {print}' "$ovr_file" "$BASE" > "$CFG" 2>/dev/null
  [ -s "$CFG" ] || cp -f "$BASE" "$CFG" 2>/dev/null
  chmod 0666 "$CFG" 2>/dev/null; chown 0:0 "$CFG" 2>/dev/null
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

# ---------- set：为未分配的应用自定义线程核位 ----------
cmd_set() {
  local pkg="$1" cluster="$2"
  [ -z "$pkg" ] && { echo "ERR 用法: set <包名> <核位>"; return 1; }
  case "$pkg" in */*|*'<'*|*'>'*|*'"'*|*' '*|*\`*) echo "ERR 包名含非法字符"; return 1 ;; esac
  case "$cluster" in
    0-3|4-7|8-9|0-7|4-9) ;;
    *) echo "ERR 非法核位: $cluster（可用 0-3 小核 / 4-7 中核 / 8-9 大核 / 0-7 / 4-9）"; return 1 ;;
  esac
  mkdir -p "$STATE_DIR"
  [ -f "$OVR" ] && awk -F'\t' -v p="$pkg" '$1!=p' "$OVR" > "${OVR}.tmp" 2>/dev/null && mv -f "${OVR}.tmp" "$OVR" 2>/dev/null
  printf '%s\t%s\n' "$pkg" "$cluster" >> "$OVR"
  chmod 0666 "$OVR" 2>/dev/null; chown 0:0 "$OVR" 2>/dev/null
  cmd_deploy
  echo "OK 已为 ${pkg} 设置线程分配：${cluster}（其余仍由艇长自动分配）"
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

# ---------- setbatch：批量设置核位（仅一次 deploy）----------
#   入参：多行 pkg<TAB>cluster；cluster=auto 表示移除该包自定义。
#   用于 WebUI「勾选应用 → 套用模板」的批量通道，避免 N 次 cmd_deploy。
cmd_setbatch() {
  local tmp="${TMPD}/aether_batch.tsv" keep=0 drop=0 bad=0
  : > "$tmp"
  while IFS= read -r line || [ -n "$line" ]; do
    [ -z "$line" ] && continue
    pkg=$(printf '%s' "$line" | cut -f1)
    cl=$(printf '%s' "$line" | cut -f2-)
    [ -z "$pkg" ] && { bad=$((bad+1)); continue; }
    case "$pkg" in */*|*'<'*|*'>'*|*'"'*|*' '*|*\`*) bad=$((bad+1)); continue ;; esac
    case "$cl" in
      0-3|4-7|8-9|0-7|4-9) keep=$((keep+1)) ;;
      auto|"")               drop=$((drop+1)) ;;
      *)                     bad=$((bad+1)); continue ;;
    esac
    printf '%s\t%s\n' "$pkg" "$cl" >> "$tmp"
  done
  [ -s "$tmp" ] || { rm -f "$tmp"; echo "ERR 没有有效的包=核位 输入"; return 1; }
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
  echo "OK 批量设置完成：应用 ${keep} 个模板、移除 ${drop} 个自定义、忽略 ${bad} 个非法"
}

# ---------- 启停 ----------
cmd_start() {
  [ -f "$ONF" ] || { echo "SKIP aether 未启用（$ONF 不存在）"; return 0; }
  [ -x "$BIN" ] || { echo "ERR 二进制缺失或不可执行: $BIN"; return 1; }
  [ -f "$CFG" ] || cmd_deploy >/dev/null 2>&1
  pkill -f "aether-optext" 2>/dev/null; sleep 1
  nohup "$BIN" -c "$CFG" -s >> "$LOG" 2>&1 &
  echo "OK 已启动 aether-optext (pid $!)"
}

cmd_stop() {
  pkill -f "aether-optext" 2>/dev/null
  sleep 1
  pgrep -f "aether-optext" >/dev/null 2>&1 && echo "WARN 仍有进程残留" || echo "OK 已停止"
}

cmd_restart() { cmd_stop >/dev/null 2>&1; cmd_start; }

cmd_ison() { [ -f "$ONF" ] && echo on || echo off; }

cmd_status() {
  echo "ON=$(cmd_ison)"
  if pgrep -f "aether-optext" >/dev/null 2>&1; then
    echo "RUNNING=1"; echo "PID=$(pgrep -f 'aether-optext' | tr '\n' ',' | sed 's/,$//')"
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
