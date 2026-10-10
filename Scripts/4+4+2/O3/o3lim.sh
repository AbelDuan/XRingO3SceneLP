#!/system/bin/sh
# ============================================================
#  o3lim.sh —— 线程模块「配置生成器」（落核已交由 AppOpt 二进制）
# ------------------------------------------------------------
#  职责（唯一）：生成 AppOpt 要读的配置文件 o3lim.conf（JZzz v14 规则格式）
#      [包名glob]{[线程名glob]}=核位
#  不再做任何 shell 落核（apply_proc/apply_rules/polltick 已全部移除）——
#  落核由 AppOpt -c <配置> -s 2 负责（原生二进制，2 秒一轮）。
#
#  规则策略（用户确认）：
#    · 游戏（gamelist / 游戏引擎线程名）→ 可上 8-9
#    · none 不接管 → 不给任何规则，交系统调度
#    · 其他普通程序 → 不给 8-9（默认流畅档 0-3,4-7）
#    · 未配置/新安装应用 → 自动补默认流畅档（只写 conf，不写 apprules → WebUI 显示未配置）
#    · 系统服务/无界面后台 → 不在纳管名单，不生成规则
# ============================================================
MODDIR="${MODDIR:-/data/adb/modules/O3CPUSet}"
STATE_DIR="${STATE_DIR:-/data/adb/O3CPUSet}"
CP="/dev/cpuset"
THREADS="/sdcard/Android/Aether/threads.json"
CONF="$STATE_DIR/o3lim.conf"
UCONF="$STATE_DIR/o3lim.user.conf"
GAMELIST="/sdcard/Android/Aether/gamelist"
ALLOW="$STATE_DIR/o3lim.allow"
MANAGE="$STATE_DIR/.o3lim.manage"
LOG="$STATE_DIR/o3lim.log"
DEF_MASK="0-7"

log_quiet() { echo "$(date +%H:%M:%S) $*" >> "$LOG" 2>/dev/null; }

# 游戏引擎专属线程名（放行 8-9 判据；不含 RenderThread/*.ui/*.raster 等通用名）
game_thread() {
  case "$1" in
    *Unity*|*unity*|GLThread*|*GameThread|*Unreal*|*Vulkan*|*Main*) return 0 ;;
    *) return 1 ;;
  esac
}

# ---------- 放行判据（独立：gamelist + none + 用户自定义）----------
build_allow() {
  : > "$ALLOW"
  [ -f "$GAMELIST" ] && grep -v '^[[:space:]]*$' "$GAMELIST" 2>/dev/null >> "$ALLOW"
  if [ -f "$STATE_DIR/apprules.tsv" ]; then
    awk -F'\t' 'NF>=2 && $2 ~ /[89]/{print $1}' "$STATE_DIR/apprules.tsv" >> "$ALLOW" 2>/dev/null
  fi
  if [ -f "$UCONF" ]; then
    sed -n 's/^{\?\([^{=]*\)[{=].*/\1/p' "$UCONF" 2>/dev/null | grep -v '^#' >> "$ALLOW"
  fi
  grep -v '^$' "$ALLOW" 2>/dev/null | sort -u > "${ALLOW}.t"
  mv "${ALLOW}.t" "$ALLOW" 2>/dev/null
}
is_allowed() { [ -s "$ALLOW" ] && grep -qx "$1" "$ALLOW" 2>/dev/null; }

# ---------- 纳管名单：只管「有界面的应用」 ----------
build_manage_list() {
  : > "$MANAGE"
  [ -f "$STATE_DIR/webui/pkg_labels.tsv" ] && cut -f1 "$STATE_DIR/webui/pkg_labels.tsv" 2>/dev/null >> "$MANAGE"
  [ -f "$STATE_DIR/webui/app_freq.tsv" ]  && cut -f1 "$STATE_DIR/webui/app_freq.tsv"  2>/dev/null >> "$MANAGE"
  [ -f "$STATE_DIR/apprules.tsv" ]        && cut -f1 "$STATE_DIR/apprules.tsv"        2>/dev/null >> "$MANAGE"
  [ -f "$CONF" ] && sed -n 's/^{\?\([^{=]*\)[{=].*/\1/p' "$CONF" 2>/dev/null >> "$MANAGE"
  [ -f "$UCONF" ] && sed -n 's/^{\?\([^{=]*\)[{=].*/\1/p' "$UCONF" 2>/dev/null >> "$MANAGE"
  grep -v '^$' "$MANAGE" 2>/dev/null | sort -u > "${MANAGE}.t"
  mv "${MANAGE}.t" "$MANAGE" 2>/dev/null
}

# ============================================================
#  gen：生成 AppOpt 配置
# ============================================================
cmd_gen() {
  local line pkg mask g p tmp nones nn pk skip n

  : > "$CONF"
  {
    echo "# o3lim 默认配置（自动生成；自定义请写 o3lim.user.conf）"
    echo "# 格式：[包名glob]{[线程名glob]}=核位    核位：0-3 小核 / 4-7 中核 / 8-9 超大核"
    echo ""
  } >> "$CONF"

  # ① threads.json 的 other + comm 规则
  awk '
  function trimq(s){ if (match(s,/"[^"]*"/)) return substr(s, RSTART+1, RLENGTH-2); return ""; }
  /"packages"[ \t]*:[ \t]*\[/ { in_pk=1; npkg=0; next }
  in_pk && /^[ \t]*\]/ { in_pk=0; next }
  in_pk { q=trimq($0); if(q!="") pkg[npkg++]=q; next }
  /"other"[ \t]*:[ \t]*"/ { v=$0; sub(/^[^:]*:[ \t]*/,"",v); om=trimq(v)
    if (om != "" && om != "other") for(i=0;i<npkg;i++) print pkg[i] "\tOTHER\t" om; om=""; next }
  /"comm"[ \t]*:[ \t]*\{/ { in_comm=1; next }
  in_comm && /^[ \t]*\}/ { in_comm=0; next }
  in_comm && /"[0-9][0-9,-]*"[ \t]*:[ \t]*\[/ { cm=trimq($0); in_arr=1; next }
  in_arr && /^[ \t]*\]/ { in_arr=0; next }
  in_arr { q=trimq($0); if(q!="") for(i=0;i<npkg;i++) print pkg[i] "\tCOMM\t" cm "\t" q; next }
  /^[ \t]*\}/ { npkg=0 }
  ' "$THREADS" 2>/dev/null | sort -u | while IFS='	' read -r p kind m t; do
    [ -z "$p" ] && continue
    if [ "$kind" = "COMM" ]; then echo "${p}{${t}}=${m}" >> "$CONF"
    else echo "${p}=${m}" >> "$CONF"; fi
  done

  # ② apprules.tsv：模块应用列表全量（含微信小程序 appbrand*、支付宝小程序等）
  if [ -f "$STATE_DIR/apprules.tsv" ]; then
    awk -F'\t' -v OFS='=' 'NF>=2 && $2 ~ /^[0-9]/ {print $1, $2}' "$STATE_DIR/apprules.tsv" 2>/dev/null >> "$CONF"
  fi

  sort -u "$CONF" -o "$CONF" 2>/dev/null

  # ②.5 归一「小核+中核」逗号格式：AppOpt/JZzz v14 不支持 0-3,4-7，只取末段 4-7 → 小核废。
  #      统一收敛为 0-7（小核+中核，AppOpt 原生支持，配置=现场）。
  sed -i -E 's/0-3[ ,]+4-7/0-7/g' "$CONF" 2>/dev/null

  # ③ 闸门：非放行应用的 8-9 → 收敛 0-7
  build_allow
  tmp="${CONF}.tmp"; : > "$tmp"
  while IFS= read -r line; do
    case "$line" in ''|\#*) echo "$line" >> "$tmp"; continue ;; esac
    pkg="${line%%[\{=]*}"; mask="${line##*=}"
    case "$mask" in
      *8*|*9*)
        if is_allowed "$pkg"; then echo "$line" >> "$tmp"; continue; fi
        g=""
        case "$line" in *\{*\}=*) g="${line#*\{}"; g="${g%%\}*}" ;; esac
        if [ -n "$g" ] && game_thread "$g"; then
          echo "$line" >> "$tmp"
        else
          log_quiet "gen 闸门: $pkg 非游戏/none，${mask} → 收敛 0-7"
          echo "${line%%=*}=0-7" >> "$tmp"
        fi ;;
      *) echo "$line" >> "$tmp" ;;
    esac
  done < "$CONF"
  mv "$tmp" "$CONF" 2>/dev/null

  # ④ 补默认流畅档（AppOpt 只处理有规则的进程，无运行时兜底）
  #    只写 conf；不写 apprules.tsv → WebUI 显示「未配置」
  pm list packages -3 2>/dev/null | cut -d: -f2 | while IFS= read -r p; do
    [ -z "$p" ] && continue
    grep -qF -- "${p}=" "$CONF" 2>/dev/null && continue
    is_allowed "$p" && continue
    echo "${p}=${DEF_MASK}" >> "$CONF"
  done
  build_allow
  build_manage_list
  while IFS= read -r p; do
    [ -z "$p" ] && continue
    grep -qF -- "${p}=" "$CONF" 2>/dev/null && continue
    is_allowed "$p" && continue
    echo "${p}=${DEF_MASK}" >> "$CONF"
  done < "$MANAGE"

  # ⑤ 剔除 none（不接管）应用的所有规则 → 交系统调度
  nones=$(awk -F'\t' 'NF>=2 && $2 ~ /[89]/{print $1}' "$STATE_DIR/apprules.tsv" 2>/dev/null)
  if [ -n "$nones" ]; then
    nn="${CONF}.none"; : > "$nn"
    while IFS= read -r line; do
      case "$line" in ''|\#*) echo "$line" >> "$nn"; continue ;; esac
      pk="${line%%[\{=]*}"; skip=0
      for n in $nones; do
        if [ "$pk" = "$n" ]; then skip=1; break; fi
      done
      [ "$skip" = "1" ] && continue
      echo "$line" >> "$nn"
    done < "$CONF"
    mv "$nn" "$CONF" 2>/dev/null
    log_quiet "gen: 已剔除 none 应用规则（交系统调度）: $nones"
  fi

  echo "OK 生成 $CONF（$(grep -c '=' "$CONF" 2>/dev/null) 条）"
}

# ---------- boot：只生成配置（落核交 AppOpt）----------
cmd_boot() {
  [ -s "$CONF" ] || cmd_gen
  build_allow
  build_manage_list
  log_quiet "boot: 配置就绪，落核交 AppOpt"
  echo "OK boot: 配置 $(grep -c '=' "$CONF" 2>/dev/null) 条，落核由 AppOpt 负责"
}

# ---------- restore：停 AppOpt + 清理其 cpuset ----------
cmd_restore() {
  pkill -f AppOpt 2>/dev/null
  local g t
  for g in "$CP/AppOpt"/*/; do
    g="${g%/}"
    [ -r "$g/tasks" ] && while read -r t; do
      [ -n "$t" ] && echo "$t" > "$CP/top-app/tasks" 2>/dev/null
    done < "$g/tasks"
  done
  rm -rf "$CP/AppOpt" 2>/dev/null
  rm -rf "$CP/o3lim" 2>/dev/null
  echo "OK restore: AppOpt 已停，其 cpuset 组已清理"
}

cmd_status() {
  echo "=== 配置 ==="
  echo "  规则: $(grep -c '=' "$CONF" 2>/dev/null)  放行: $(wc -l < "$ALLOW" 2>/dev/null)  纳管: $(wc -l < "$MANAGE" 2>/dev/null)"
  echo "=== AppOpt ==="
  if pgrep -f AppOpt >/dev/null 2>&1; then echo "  运行中"; else echo "  未运行"; fi
  echo "=== AppOpt 组 ==="
  for g in "$CP/AppOpt"/*/; do g="${g%/}"; [ -f "$g/cpus" ] && echo "  $(basename $g) cpus=[$(cat $g/cpus 2>/dev/null)] tasks=$(wc -l < $g/tasks 2>/dev/null)"; done
  echo "=== 日志尾 ==="; tail -5 "$LOG" 2>/dev/null
}

case "$1" in
  gen)     cmd_gen ;;
  boot)    cmd_boot ;;
  restore) cmd_restore ;;
  status)  cmd_status ;;
  *) echo "usage: o3lim.sh gen|boot|restore|status" ;;
esac
