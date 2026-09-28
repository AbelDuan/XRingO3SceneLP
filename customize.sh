SKIPUNZIP=0
ui_print "- SceneO3LP：玄戒O3 Scene 调度方案（O1 官方移植）"
ui_print "- 仅灌配置，调度全由 Scene 下发"

# ⚠ KSU 安装环境里 MODDIR/MODPATH 都不可靠；customize.sh 的 cwd 就是模块解压目录
MD="$(pwd)"
[ -f "$MD/push.sh" ] || MD="${MODPATH:-$MODDIR}"
[ -f "$MD/push.sh" ] || MD="/data/adb/modules_update/SceneO3LP"
ui_print "- 模块目录: $MD"

ui_print "- 设置权限..."
chmod 0755 "$MD/push.sh" "$MD/service.sh" "$MD/action.sh" 2>/dev/null
chmod 0755 "$MD/Config/powercfg.sh" 2>/dev/null
chmod 0644 "$MD/Config/"*.json "$MD/module.prop" 2>/dev/null

if [ -d /data/data/com.omarea.vtools/files ]; then
    ui_print "- 检测到 Scene，立即推送配置..."
    MODDIR="$MD" sh "$MD/push.sh" install || ui_print "! 推送失败，可稍后在模块卡片点「执行」重试"
else
    ui_print "- Scene 未安装/未启动过，跳过推送（装好后点模块「执行」）"
fi
ui_print "- 完成（本模块无需重启）"
