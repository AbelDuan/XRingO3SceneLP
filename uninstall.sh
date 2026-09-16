#!/system/bin/sh
# ============================================================
#  卸载：停守护、把配置交还给 Scene、并把 CPU 频率上限恢复成硬件上限
# ============================================================
MODDIR="${0%/*}"
. "$MODDIR/lib/util.sh"

uninstall_module() {
    until [ -d "/data/data" ]; do sleep 5; done
    pkill -f "O3/guard\.sh" 2>/dev/null
    pkill -f "O3/camera_freq_guard\.sh" 2>/dev/null
    rm -f "$UNLOCK_FILE"
    : > "${STATE_DIR}/unlocked"

    uid=$(get_package_uid "$SCENE_PKG")
    unlock_tree "$SCENE_DIR"
    for f in "${SCENE_DIR}"/*.json "${SCENE_DIR}"/*.sh "${SCENE_DIR}"/features/*.conf; do
        [ -e "$f" ] && unlock_file "$f"
    done
    [ -n "$uid" ] && chown -R "${uid}:${uid}" "$SCENE_DIR" 2>/dev/null

    # 清掉注入的自定义命令
    rm -f "${SCENE_DIR}/custom-command/O3调度·切换方案.sh" 2>/dev/null

    # 频率约束恢复出厂（放开 QoS 上下限）
    restore_stock_freq
}

uninstall_module >/dev/null 2>&1
[ -d "$SCENE_DIR" ] && uninstall_module >/dev/null 2>&1

echo "✅ 已停止调度守护；配置交还 Scene；CPU 频率上限已恢复（不限频）"
echo "Scene 现在可以正常改写自己的配置了。"
echo "（模块目录会在重启后由管理器清理）"
