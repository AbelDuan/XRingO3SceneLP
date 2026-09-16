#!/system/bin/sh
# ============================================================
#  KernelSU 动作按钮：锁定 / 解锁 / 切换方案
#    音量上 / 音量下 两键操作，30 秒无操作自动退出
# ============================================================
MODDIR="${0%/*}"
export MODDIR
. "$MODDIR/lib/util.sh"

# ---------- 按键监听 ----------
key_wait() {   # $1=超时秒数  输出 run_lock / run_unlock / run_scheme / overtime
    local limit="$1" start now gap res
    start=$(date +%s)
    while :; do
        now=$(date +%s); gap=$((now - start))
        [ $gap -ge "$limit" ] && { echo "overtime"; return; }
        res=$(timeout 0.15 getevent -lqc 1 2>/dev/null | while read -r m; do
                case "$m" in
                  *VOLUMEUP*DOWN*)   echo run_lock; break ;;
                  *VOLUMEDOWN*DOWN*) echo run_unlock; break ;;
                esac
              done)
        [ -n "$res" ] && { echo "$res"; return; }
        sleep 0.05
    done
}

sub_key() {    # $1=超时  输出 next / ok / cancel / overtime
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
    if is_unlocked; then echo "状态: 🔓 已解锁（可手动调整）"
    else echo "状态: 🔒 已锁定（防 Scene/云同步替换）"; fi
    echo "方案: $s"
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

clear 2>/dev/null
echo "┌──────────────────────────────────┐"
echo "│  玄戒O3 · Abel 调度工具箱    │"
echo "├──────────────────────────────────┤"
status_line
echo "├──────────────────────────────────┤"
echo "│  音量+  → 🔒 锁定配置            │"
echo "│  音量−  → 解锁 / 切换方案        │"
echo "│                                  │"
echo "│  30 秒无操作自动退出             │"
echo "└──────────────────────────────────┘"

SEL=$(key_wait 30)

if [ "$SEL" = "run_lock" ]; then
    echo
    sh "$MODDIR/Scripts/4+4+2/O3/set_scheme.sh" lock
    echo
    echo "✅ 已锁定。若需手动调整，请用「音量−」先解锁。"
    exit 0
fi

if [ "$SEL" = "overtime" ]; then
    echo; echo "⏰ 超时退出"; exit 0
fi

# ---------- 子菜单 ----------
while :; do
    clear 2>/dev/null
    echo "┌──────────────────────────────────┐"
    echo "│  解锁 / 切换方案                 │"
    echo "├──────────────────────────────────┤"
    status_line
    echo "├──────────────────────────────────┤"
    echo "│  音量+  → 🔓 解锁配置            │"
    echo "│  音量−  → 🔄 切换方案            │"
    echo "│                                  │"
    echo "│  20 秒无操作自动退出             │"
    echo "└──────────────────────────────────┘"

    S2=$(key_wait 20)
    case "$S2" in
      overtime) echo; echo "⏰ 超时退出"; exit 0 ;;
      run_lock)
        echo
        sh "$MODDIR/Scripts/4+4+2/O3/set_scheme.sh" unlock
        echo
        echo "✅ 已解锁：Scene 可自由改写配置，守护已暂停回锁。"
        echo "   调整完请回到这里按「音量+」重新锁定。"
        exit 0 ;;
      run_unlock) break ;;
    esac
done

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
        # 取第 IDX+1 个
        CUR=$(echo "$LIST" | cut -d' ' -f$((IDX + 1)))
        clear 2>/dev/null
        echo "┌──────────────────────────────────┐"
        echo "│  切换方案（共 $TOTAL 档）             │"
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
            echo "已放开频率上下限并解除锁定，Scene 恢复自主管理。"
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
