#!/system/bin/sh
# ============================================================
#  Scene「自定义命令」入口 —— 在 Scene 里点一下即可切换方案
#    · 不带参数：循环切到下一档（甜点能效 → 日常均衡 → 性能甜点 → …）
#    · 带参数：switch.sh sweet_eco|sweet_bal|sweet_perf
#    · switch.sh lock / unlock
#  说明：Scene 的自定义命令不方便按键交互，所以这里做成「点一次切一档」。
# ============================================================
MODDIR="/data/adb/modules/SceneO3Tuner"
. "$MODDIR/lib/util.sh"

LIST="sweet_eco sweet_bal sweet_perf"
ARG="$1"

label() {
    case "$1" in
      lock)   echo "锁定" ;;
      unlock) echo "解锁" ;;
      *)      scheme_name_cn "$1" ;;
    esac
}

if [ "$ARG" = "lock" ] || [ "$ARG" = "unlock" ]; then
    sh "$MODDIR/Scripts/4+4+2/O3/set_scheme.sh" "$ARG"
    echo "[O3调度] $(label "$ARG") 完成"
    exit 0
fi

# 指定方案
case " $LIST " in
  *" $ARG "*) NEXT="$ARG" ;;
  *) NEXT="" ;;
esac

# 未指定 → 循环下一个
if [ -z "$NEXT" ]; then
    CUR=$(active_scheme)
    [ -z "$CUR" ] && CUR="sweet_perf"       # 首次点击从「极致能效」开始
    NEXT=""
    for s in $LIST; do
        if [ -n "$FIRST_AFTER" ]; then NEXT="$s"; break; fi
        [ "$s" = "$CUR" ] && FIRST_AFTER=1
    done
    [ -z "$NEXT" ] && NEXT=$(echo "$LIST" | cut -d' ' -f1)
fi

echo "════════════════════════════════"
echo "  Abel · 玄戒O3 调度"
echo "════════════════════════════════"
echo "当前方案: $(label "$(active_scheme)")"
echo "切换至  : $(label "$NEXT")"
echo "────────────────────────────────"

sh "$MODDIR/Scripts/4+4+2/O3/set_scheme.sh" "$NEXT"

echo "────────────────────────────────"
if is_unlocked; then
    echo "锁定状态: 🔓 已解锁"
else
    echo "锁定状态: 🔒 已锁定"
fi
echo "再点一次 = 切到下一档"
echo "════════════════════════════════"
