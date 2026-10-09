#!/system/bin/sh
# ============================================================
#  卸载（v18 · 模块自有）：停守护、把线程从 cgroup 组释放、
#  并把 CPU 频率上限恢复成硬件上限（放开 QoS 上下限）
# ============================================================
MODDIR="${0%/*}"
. "$MODDIR/lib/util.sh"

uninstall_module() {
    until [ -d "/data/data" ]; do sleep 5; done
    pkill -f "O3/guard\.sh" 2>/dev/null
    pkill -f "O3/camera_freq_guard\.sh" 2>/dev/null
    # 顺手清掉旧版遗留的锁定标记（机制已废除）
    rm -f "${STATE_DIR}/unlocked" "${STATE_DIR}/locked" "${STATE_DIR}/qos_cleared" "${STATE_DIR}/src.mark" 2>/dev/null

    # v18：不再触碰 Scene 目录（配置本就由模块自持）。

    # 先把线程从我们的 cgroup 组树里放出来（否则组会残留到下次开机）
    if [ -x "$MODDIR/Scripts/4+4+2/O3/pin_cgroup.sh" ]; then
        sh "$MODDIR/Scripts/4+4+2/O3/pin_cgroup.sh" --unbind-all >/dev/null 2>&1
    fi

    # 频率约束恢复出厂（放开 QoS 上下限）
    restore_stock_freq
}

uninstall_module >/dev/null 2>&1

echo "✅ 已停止调度守护；线程已释放；CPU 频率上限已恢复（不限频）"
echo "（模块目录会在重启后由管理器清理）"
