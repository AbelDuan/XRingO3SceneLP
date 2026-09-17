#!/system/bin/sh
# ============================================================
#  KernelSU 动作按钮 —— 音量键切换调度方案
#    音量+ = 看下一个方案（连 description.txt 一起预览）
#    音量− = 确认使用
#    25 秒无操作自动退出
#
#  ⚠ 早期版本这里还有「锁定 / 解锁配置」菜单。锁定机制（chattr +i）已于
#    2026-09-15 **彻底废除**：它会让 Scene 自己存不下配置 —— 在 Scene 里点
#    小齿轮改特性、切全局/单应用模式时写 features/*.conf 会 ENOTSUP，
#    现象就是「改了没反应」。本机型云端也没有对应配置，没有防替换的必要。
#    菜单项一并删除，免得留一个「怎么点都是已解锁」的死选项。
# ============================================================
MODDIR="${0%/*}"
export MODDIR
. "$MODDIR/lib/util.sh"

# ---------- 访问即自愈：合并 KSU 待更新副本（免重启）----------
#  按下一次音量键（action.sh 由 KSU 管理器在「执行」按钮触发）也会走这里，
#  顺手把 modules_update 合并进正在服务的 modules/<id>，清标记、拉服务。
#  只在新版本暂存副本存在时才动作，否则零开销。
selfheal_pending_update

# ---------- 按键监听 ----------
sub_key() {    # $1=超时  输出 next / ok / overtime
    local limit="$1" start now gap res
    start=$(date +%s)
    while :; do
        now=$(date +%s); gap=$((now - start))
        [ $gap -ge "$limit" ] && { echo "overtime"; return; }
        res=$(timeout 0.15 getevent -lqc 1 2>/dev/null | while read -r m; do
                case "$m" in
                  *VOLUMEUP*DOWN*)   echo next;   break ;;
                  *VOLUMEDOWN*DOWN*) echo ok;     break ;;
                esac
              done)
        [ -n "$res" ] && { echo "$res"; return; }
        sleep 0.05
    done
}

status_line() {
    local s; s=$(active_scheme); [ -z "$s" ] && s="(未设置)"
    echo "方案: $(scheme_name_cn "$s")"
    if pgrep -f "O3/guard\.sh" >/dev/null 2>&1; then
        echo "守护: 运行中"
    else
        echo "守护: 未运行"
    fi
}

scheme_label() {
    if [ "$1" = "__restore__" ]; then echo "恢复出厂频率"; return; fi
    scheme_name_cn "$1"
}

# ---------- 方案循环选择 ----------
LIST="sweet_eco sweet_bal sweet_perf __restore__"
set -- $LIST
TOTAL=$#
IDX=0
LAST=-1
CUR=""

while :; do
    if [ "$IDX" -ne "$LAST" ]; then
        LAST=$IDX
        CUR=$(echo "$LIST" | cut -d' ' -f$((IDX + 1)))
        clear 2>/dev/null
        echo "┌──────────────────────────────────┐"
        echo "│  切换方案（共 $TOTAL 档）"
        echo "├──────────────────────────────────┤"
        echo "│ 当前: [$(scheme_label "$CUR")]"
        echo "├──────────────────────────────────┤"
        DESC="${MODDIR}/Config/4+4+2/O3/${CUR}/description.txt"
        if [ -f "$DESC" ]; then echo; cat "$DESC"; fi
        echo
        echo "──────────────────────────────────"
        echo "音量+ = 看下一个   音量− = 确认使用"
    fi

    K=$(sub_key 25)
    case "$K" in
      next)   IDX=$((IDX + 1)); [ $IDX -ge $TOTAL ] && IDX=0 ;;
      ok)
        echo
        echo "✅ 已选定: $(scheme_label "$CUR")"
        if [ "$CUR" = "__restore__" ]; then
            sh "$MODDIR/Scripts/4+4+2/O3/set_scheme.sh" restore
            echo
            echo "已放开频率上下限，Scene 恢复自主管理。"
        else
            sh "$MODDIR/Scripts/4+4+2/O3/set_scheme.sh" "$CUR"
            echo
            echo "提示: 切换后 Scene 会重读配置，首次切档可能有 1~2 秒过渡。"
        fi
        exit 0 ;;
      cancel|overtime)
        echo; echo "⏰ 超时，未改动"; exit 0 ;;
    esac
    sleep 0.15
done
