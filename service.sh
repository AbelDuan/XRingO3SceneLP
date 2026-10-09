#!/system/bin/sh
# ============================================================
#  开机自启（玄戒O3 · Abel 调度工具箱 · 两模块版）
#   两块职责：
#     ① CPU 频率 —— 交给 Scene。模块只保证 Scene 能读到配置
#        （目录可进入、配置可写），并执行方案包内的 powercfg.sh
#        （平台 sysfs 调优：core_ctl / sched_boost 等）。
#     ② 线程核心分配 —— 完全交给艇长的 aether-optext。
#        本脚本仅按 aether.on 拉起 / 停掉它，不做任何原生落核。
#   分工清晰：频率 = Scene 下发，线程 = 艇长引擎。
# ============================================================
MODDIR="${0%/*}"
export MODDIR
. "$MODDIR/lib/util.sh"

# 等 /data 就绪
until [ -d "/data/data" ] || [ -d "/data/user/0" ]; do sleep 5; done
mkdir -p "$STATE_DIR" "$TMPD" 2>/dev/null

# 等 Scene 装好
n=0
while [ $n -lt 24 ]; do
    [ -n "$(get_package_uid "$SCENE_PKG")" ] && break
    sleep 5; n=$((n+1))
done

log "⚡ 玄戒O3 调度工具箱 service 启动"

# 0) 目录可进入 + 清除历史残留的 chattr 锁
#    频率交给 Scene，必须保证它的数据目录可进入、配置可写，
#    否则 Scene 卡在 splash、小齿轮改不动。
ensure_scene_dir_perm
r=$(repair_scene_writable)
log "· 配置可写性: $r"

SCHEME=$(active_scheme)
[ -z "$SCHEME" ] && SCHEME="sweet_bal"

# 1) 平台调优脚本（sysfs 节点，与方案包内 powercfg.sh 同源）
PC="${MODDIR}/Config/4+4+2/O3/${SCHEME}/powercfg.sh"
if [ -f "$PC" ]; then
    sh "$PC" >> "$LOG_FILE" 2>&1
    log "· powercfg.sh 已执行（方案 $SCHEME）"
fi

# 2) 线程核心分配 —— 艇长引擎（默认开启）
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

# 2.5) 调度守护 guard.sh —— 长期维持 Scene 启用开关（见 guard.sh 主循环 ①）
#      do_push 负责「首次启用」；guard 负责 Scene 任意一次（重新）启动后 ≤5s 自愈
#      （Scene 每次启动都会把 global.xml 的启用标志冲掉，见 profile_sync.sh 注释）。
#      用 nohup 后台拉起，service.sh 退出后仍存活（与 aether_ctl 引擎后台化同路）。
GUARD_SH="$MODDIR/Scripts/4+4+2/O3/guard.sh"
if [ -f "$GUARD_SH" ]; then
    nohup sh "$GUARD_SH" </dev/null >> "$LOG_FILE" 2>&1 &
    log "· 调度守护已拉起（guard.sh pid $!）"
fi

# 3) 模块卡片描述 = 当前功能启用状态
update_module_desc >/dev/null 2>&1

exit 0
