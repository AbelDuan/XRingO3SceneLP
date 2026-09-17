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
    # 顺手清掉旧版遗留的锁定标记（机制已废除，见 action.sh 头部说明）
    rm -f "${STATE_DIR}/unlocked" "${STATE_DIR}/locked" 2>/dev/null

    uid=$(get_package_uid "$SCENE_PKG")
    unlock_tree "$SCENE_DIR"
    for f in "${SCENE_DIR}"/*.json "${SCENE_DIR}"/*.sh "${SCENE_DIR}"/features/*.conf; do
        [ -e "$f" ] && unlock_file "$f"
    done
    [ -n "$uid" ] && chown -R "${uid}:${uid}" "$SCENE_DIR" 2>/dev/null

    # 清掉注入的自定义命令
    rm -f "${SCENE_DIR}/custom-command/O3调度·切换方案.sh" 2>/dev/null

    # v12：先把线程从我们的 cgroup 组树里放出来（否则组会残留到下次开机）
    #   ⚠ 不释放就删组是删不掉的（还有线程占用），所以必须走 unbind-all
    if [ -x "$MODDIR/Scripts/4+4+2/O3/pin_cgroup.sh" ]; then
        sh "$MODDIR/Scripts/4+4+2/O3/pin_cgroup.sh" --unbind-all >/dev/null 2>&1
    fi

    # 频率约束恢复出厂（放开 QoS 上下限）
    restore_stock_freq
}

uninstall_module >/dev/null 2>&1
[ -d "$SCENE_DIR" ] && uninstall_module >/dev/null 2>&1

echo "✅ 已停止调度守护；配置交还 Scene；CPU 频率上限已恢复（不限频）"
echo "Scene 现在可以正常改写自己的配置了。"
echo "（模块目录会在重启后由管理器清理）"
