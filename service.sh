#!/system/bin/sh
# ============================================================
#  开机自启（玄戒O3 · Abel 调度工具箱 · v18 模块自有版）
#   三块职责（v18 起全部由本模块自持，不再依赖 Scene）：
#     ① CPU 频率 —— 模块 PM QoS 接管：service 启动时按全局模式下发频率；
#        守护每轮兜底 + 前台应用按 app 模式覆盖。
#     ② 平台调优 —— 执行方案包内 powercfg.sh（core_ctl / sched_boost 等 sysfs）。
#     ③ 线程核心分配 —— 艇长 aether-optext 引擎（默认开启）。
#   分工清晰：频率 = 模块 QoS，线程 = 艇长引擎，调度器 = powercfg。
# ============================================================
MODDIR="${0%/*}"
export MODDIR
. "$MODDIR/lib/util.sh"

# ★ 关键：先把 CWD 切到模块目录之外（/），再拉任何守护。
#   守护与 aether-optext 会反复 exec sh "$MODDIR/.../*.sh" 子进程，这些子进程
#   继承 CWD。若 CWD 停在模块目录，常驻进程会一直持有该目录的 fd →
#   KSU「禁用/卸载」时要 umount/rm 模块目录会 EBUSY、管理线程卡死，
#   表现为 KSU 闪退、模块无法禁用/卸载。切走后卸载路径才能干净释放。
cd / || cd /data

# 等 /data 就绪
until [ -d "/data/data" ] || [ -d "/data/user/0" ]; do sleep 5; done
mkdir -p "$STATE_DIR" "$TMPD" 2>/dev/null

log "⚡ 玄戒O3 调度工具箱 service 启动（v18 模块自有）"

SCHEME=$(active_scheme)
[ -z "$SCHEME" ] && SCHEME="sweet_bal"

# 1) 频率接管：按当前全局模式下发 PM QoS（O3 上唯一被强制执行的频率旋钮）
current_mode_read 2>/dev/null
sh "$MODDIR/Scripts/4+4+2/O3/apply_freq.sh" --mode "${CUR_MODE:-balance}" >> "$LOG_FILE" 2>&1
log "· 频率已按模式[${CUR_MODE:-balance}]下发（QoS）"

# 2) 平台调优脚本（sysfs 节点，与方案包内 powercfg.sh 同源）
PC="${MODDIR}/Config/4+4+2/O3/${SCHEME}/powercfg.sh"
if [ -f "$PC" ]; then
    sh "$PC" >> "$LOG_FILE" 2>&1
    log "· powercfg.sh 已执行（方案 $SCHEME）"
fi

# 3) 线程核心分配 —— 艇长引擎（默认开启）
#    aether_ctl.sh 内部自行判 aether.on / 二进制是否存在：
#      · 未启用 → 跳过；
#      · 二进制缺失 / 内核不支持 eBPF → aether-optext 自身静默退出，不影响其余功能。
AETHER_CTL="$MODDIR/Scripts/4+4+2/O3/aether/aether_ctl.sh"
if [ -f "$AETHER_CTL" ]; then
    # 首次/升级：确保拓扑展开配置已落地（幂等）
    sh "$AETHER_CTL" deploy >/dev/null 2>&1
    out=$(sh "$AETHER_CTL" start 2>&1)
    log "· 艇长线程引擎: $out"
else
    log "· 未找到 aether_ctl.sh，跳过线程引擎"
fi

# 4) 调度守护 guard.sh —— 每轮兜底频率 + 线程分配 + 大核限制
#   （CWD 已在文件顶部切到 /，守护与子进程均不持有模块目录，见顶部注释）
GUARD_SH="$MODDIR/Scripts/4+4+2/O3/guard.sh"
if [ -f "$GUARD_SH" ]; then
    nohup sh "$GUARD_SH" </dev/null >> "$LOG_FILE" 2>&1 &
    log "· 调度守护已拉起（guard.sh pid $!）"
fi

# 5) 模块卡片描述 = 当前功能启用状态
update_module_desc >/dev/null 2>&1

exit 0
