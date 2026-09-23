#!/system/bin/sh
# ============================================================
#  KernelSU 动作按钮 —— 一键「同步配置」（= WebUI 同名按钮）
#    点一下：把 Scene 里「单独设过模式」的应用一次性同步进 app_assign.tsv ——
#    Scene 有 → 覆盖并打 scene 来源标记；带标记而 Scene 已无 → 删（回跟随系统）；
#    手工行永远保留。stdout 由 KSU 直接显示，所以输出必须是给人看的短中文结果。
#
#  ⚠ 历史（2026-09-23 替换）：这里曾是「音量键切换调度方案」的交互菜单
#    （音量+ 选档 / 音量− 确认 / 25 秒超时），外加 方案/守护 状态行。
#    它与新语义互斥 —— KSU 按钮要求**无头跑完**，不可能等人按键；而选方案
#    在 WebUI 里本来就有等价入口（webui.sh scheme/restore）。属无关旧功能，
#    整体替换，状态行是那个菜单的门面，一并移除。
#    保留的是下面的 selfheal_pending_update：它是「访问即自愈」三个触发点之一
#    （见 lib/util.sh 该函数头注：② webui.sh / action.sh 顶部），
#    删掉会少一条免重启恢复路径，与本次改动无关，不能顺手丢。
#
#  代码路径：与 WebUI「同步配置」按钮同源 —— webui.sh cmd_importscene 的核心
#    就是 lib/util.sh 的 import_scene_apply。这里**直接调它**而不经过
#    `sh webui.sh importscene`：webui.sh 把 STATE_DIR/TMPD 写死在 /data 下
#    （不可被环境变量覆写），沙盒测试没法隔离，还会在测试里去 mkdir 真机路径；
#    而同步语义（含 scene 标记剪枝）只存在于 import_scene_apply 一处，
#    直调 = 同一条代码路径，零重实现。
#    按钮不复制 cmd_importscene 的「重建 threads.json + 立即落核」两步：
#    守护本来每轮就做（guard.sh → gen_threads_from_scene + enforce_threads.sh），
#    同步落盘后几秒内自动跟上，不需要在这里抄一遍。
#
#  退出码：0 = 同步成功（或 Scene 没有单独设置、未改动也算成功）；
#          非 0 = 失败（读不到 powercfg.xml / 导入本身报错），KSU 会显示失败。
# ============================================================
MODDIR="${0%/*}"
export MODDIR
. "$MODDIR/lib/util.sh"

# ---------- 访问即自愈：合并 KSU 待更新副本（免重启）----------
#  按一次动作按钮（KSU 管理器触发）也走这里，顺手把 modules_update 合并进
#  正在服务的 modules/<id>，清标记、拉服务。只在新版本暂存副本存在时才动作。
selfheal_pending_update

# ---------- 前置检查：读不到 Scene 的模式表必须报错退出 ----------
#  import_scene_apply 对「读不到 powercfg.xml」是刻意宽容的（返回 0 + 提示、
#  一行不删，防止把整表误剪光）—— 但按钮要的是一次明确的同步：拿不到源表
#  就是失败，必须非零退出让 KSU 显示失败，而不是「显示成功却什么都没同步」。
[ -f "$SCENE_POWERCFG" ] || {
    echo "❌ 同步失败：读不到 Scene 的 powercfg.xml"
    echo "   （${SCENE_POWERCFG} —— Scene 未安装/未获授权，或路径变更）"
    exit 1
}

# ---------- 核心：与 WebUI 按钮同一代码路径 ----------
r=$(import_scene_apply app)
if [ $? -ne 0 ]; then
    echo "❌ 同步失败：$r"
    exit 1
fi
# r 形如「OK 已从 Scene 导入 N 条档位（…）（移除 R 条 Scene 已不再单独设置的 → …）」
# —— 条数与剪枝条数都在这一行里，KSU 面板直接展示给人。
echo "✅ $r"
exit 0
