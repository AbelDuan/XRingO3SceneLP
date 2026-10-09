#!/system/bin/sh
# ============================================================
#  卸载（v18 · 模块自有）：停守护、把线程从 cgroup 组释放、
#  并把 CPU 频率上限恢复成硬件上限（放开 QoS 上下限）
# ============================================================
MODDIR="${0%/*}"
. "$MODDIR/lib/util.sh"

uninstall_module() {
    until [ -d "/data/data" ]; do sleep 5; done
    # ★ 先杀光所有常驻进程（含线程引擎与事件落核器），避免它们仍持有模块目录 /
    #   其下脚本文件 → KSU 卸载时 umount/rm EBUSY，进而管理器卡死闪退。
    pkill -f "O3/guard\.sh" 2>/dev/null
    pkill -f "O3/camera_freq_guard\.sh" 2>/dev/null
    pkill -f "O3/aether/aether-optext" 2>/dev/null
    pkill -f "O3/pinwatch" 2>/dev/null
    pkill -f "O3/pinwatch\.sh" 2>/dev/null
    sleep 1
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

# 切到模块目录之外再执行，确保本脚本自身（CWD=模块目录）不会因下面删除操作
# 而持有目录 → 卸载流程能干净释放。
cd / || cd /data
uninstall_module >/dev/null 2>&1

echo "✅ 已停止调度守护；线程已释放；CPU 频率上限已恢复（不限频）"
echo "（模块目录会在重启后由管理器清理）"
