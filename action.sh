#!/system/bin/sh
# ============================================================
#  KernelSU 动作按钮 —— 一键「同步配置」
#    点一下：① CPU 频率方案 + 启用开关 同步到 Scene（profile_sync.sh push）
#            ② 线程分配（艇长 Aether）按当前开关重新部署并启动
#    输出必须是给人看的短中文，KSU 面板直接展示。
#
#  与 WebUI 顶部「同步到 Scene」按钮同源语义：频率 → Scene（含启用）；
#  线程 → Aether。
#  保留顶部的 selfheal_pending_update：它是「访问即自愈」三个触发点之一
#  （见 lib/util.sh 该函数头注），删掉会少一条免重启恢复路径。
# ============================================================
MODDIR="${0%/*}"
export MODDIR
. "$MODDIR/lib/util.sh"

# ---------- 访问即自愈：合并 KSU 待更新副本（免重启）----------
selfheal_pending_update

echo "⏳ 正在同步配置…"

# ---------- ① CPU 频率 → Scene（含启用开关）----------
#  ⚠ 关键：必须用 profile_sync.sh push —— 它除了把方案文件灌进 Scene，
#    还会把 scene_profile_source 设为 SOURCE_SCENE_ONLINE、dynamic_control 设为
#    true，并杀掉 Scene 主进程让其重读 global.xml。只调 set_scheme.sh 只会拷文件、
#    不设置启用开关，结果就是「Scene 打开还是自定义模式、无法启用」。
sh "$MODDIR/Scripts/4+4+2/O3/profile_sync.sh" push >/dev/null 2>&1
if [ "$(scene_source_get)" = "$SCENE_SOURCE_WANT" ] && [ "$(scene_dyn_get)" = "true" ]; then
  echo "✅ 频率方案已下发 Scene 并已启用（来源=$(scene_source_get)）"
else
  echo "⚠ 频率已下发，但启用开关未就绪：来源=$(scene_source_get) 性能调节=$(scene_dyn_get)"
fi

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
