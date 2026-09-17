#!/system/bin/sh
# ============================================================
#  Scene「自定义命令」入口 —— 在 Scene 里点一下即可切换方案
#    · 不带参数：切到下一档（极致能效 → 日常均衡 → 性能甜点 → 满画质游戏 → 回到第一档）
#    · 带参数：switch.sh sweet_eco|sweet_bal|sweet_perf|sweet_hq
#  说明：Scene 的自定义命令不方便按键交互，所以做成「点一次切一档」。
#
#  ⚠ 早期版本还支持 switch.sh lock / unlock。锁定机制已废除（见 action.sh
#    头部说明），入口一并删除 —— 留着只会让人以为配置会被云端替换。
# ============================================================
MODDIR="/data/adb/modules/SceneO3Tuner"
. "$MODDIR/lib/util.sh"

LIST="sweet_eco sweet_bal sweet_perf sweet_hq"
ARG="$1"

label() { scheme_name_cn "$1"; }

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
echo "再点一次 = 切到下一档"
echo "════════════════════════════════"
