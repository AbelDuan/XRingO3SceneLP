#!/system/bin/sh
# ============================================================
#  KernelSU 动作按钮 —— 一键「应用配置」（v18 · 模块自有）
#    点一下：① CPU 频率按当前全局模式下发到 PM QoS（不再交给 调度App）
#            ② 线程分配（艇长 Aether）按当前开关重新部署并启动
#    输出必须是给人看的短中文，KSU 面板直接展示。
#
#  v18 起与「调度App」彻底解耦：频率 / 调度器 / 线程全部由本模块定义。
#  保留顶部的 selfheal_pending_update：它是「访问即自愈」三个触发点之一
#  （见 lib/util.sh 该函数头注），删掉会少一条免重启恢复路径。
# ============================================================
MODDIR="${0%/*}"
export MODDIR
. "$MODDIR/lib/util.sh"

# ---------- 访问即自愈：合并 KSU 待更新副本（免重启）----------
selfheal_pending_update

echo "⏳ 正在应用配置（模块自有）…"

# ---------- ① CPU 频率 → 模块 PM QoS（按全局模式）----------
current_mode_read 2>/dev/null
sh "$MODDIR/Scripts/4+4+2/O3/apply_freq.sh" --mode "${CUR_MODE:-balance}" >/dev/null 2>&1
echo "✅ 频率已按模式[${CUR_MODE:-balance}]下发（PM QoS，模块自有）"

# ---------- ② 线程分配 → 艇长 Aether（仅在启用时）----------
AETHER_CTL="$MODDIR/Scripts/4+4+2/O3/aether/aether_ctl.sh"
if [ -f "$STATE_DIR/aether.on" ] && [ -x "$AETHER_CTL" ]; then
  sh "$AETHER_CTL" deploy >/dev/null 2>&1
  sh "$AETHER_CTL" restart 2>&1
  echo "✅ 线程引擎（Aether）已重载"
else
  echo "✅ 线程引擎未启用，已跳过"
fi
exit 0
