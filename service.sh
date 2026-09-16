#!/system/bin/sh
# ============================================================
#  开机自启（v3）
#    · 确保 Scene 数据目录可进入、配置可写
#    · 按 Scene 的「应用→模式」表生成线程分配
#    · 跑平台调优脚本（sysfs，与方案包内 powercfg.sh 同源）
#    · 启动配置守护
#
#  ⚠ 不再「把模块里的配置覆盖进 Scene」（v2 会做，于是每次开机都把用户在 Scene
#    里做的调整冲掉）。现在 Scene 侧是唯一真源，模块只负责线程分配与调优脚本。
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

log "⚡ SceneO3Tuner service 启动 (v3)"

# 0) 目录可进入 + 清除历史残留的 chattr 锁
#    必须在最前面：目录缺 x 会让 Scene 卡在启动 splash；
#    配置被锁则 Scene 自己存不下任何设置（小齿轮改不动、切模式不生效）。
ensure_scene_dir_perm
r=$(repair_scene_writable)
log "· 配置可写性: $r"

SCHEME=$(active_scheme)
[ -z "$SCHEME" ] && SCHEME="sweet_bal"

# 1) 平台调优脚本（sysfs 节点）
PC="${MODDIR}/Config/4+4+2/O3/${SCHEME}/powercfg.sh"
if [ -f "$PC" ]; then
    sh "$PC" >> "$LOG_FILE" 2>&1
    log "· powercfg.sh 已执行"
fi

# 2) 按 Scene 的「应用→模式」表生成线程分配
if [ -f "$SCENE_POWERCFG" ]; then
    out=$(gen_threads_from_scene 2>&1)
    log "· 线程分配: $out"
    echo "$(md5of "$SCENE_POWERCFG")/$(md5of "$SCENE_GAMES_XML")/$(md5of "$GAME_ASSIGN_FILE")/$(md5of "$GAME_TPL_FILE")/$(md5of "$APP_ASSIGN_FILE")/$(md5of "$APP_TPL_FILE")" > "${STATE_DIR}/scene.hash"
else
    log "· 未发现 Scene 的模式表，跳过线程分配生成"
fi

# 3) 启动守护
pkill -f "O3/guard\.sh" 2>/dev/null
sleep 1
# 间隔 5s：守护每轮都会「按模板落核」（enforce_threads.sh），
# 间隔越小，「应用刚打开就绑好核」越快；脚本内部一致即跳过，开销可忽略。
nohup sh "$MODDIR/Scripts/4+4+2/O3/guard.sh" "${GUARD_INTERVAL:-5}" >> "$LOG_FILE" 2>&1 &
log "· guard 已启动 (pid $!，间隔 ${GUARD_INTERVAL:-5}s)"

# 3.1) 相机频率守护
#  Scene 的 _Camera.json 在本机有 @cpu_freq 签名错误 + @cpu_freq 只落实 max 两个问题，
#  导致相机态 min==max==最低档（区间塌缩、频率钉死）。
#  另外 guard.sh 每次亮/息屏切换会跑 apply_freq.sh，把 QoS 上限清成
#  cpuinfo_max_freq —— 而它会随 thermal + 光感变化，等于把相机正在用的区间掀掉。
#
#  v7 两道修复（详见 camera_freq_guard.sh 头部）：
#    · guard.sh 只在进相机那一刻看护（常驻轮询没必要）
#    · camera_freq_guard.sh 降为兜底，间隔 2s 且**亮屏稳态 0 子进程**
#  可用 $STATE_DIR/camera_freq_guard.off 关闭。
if [ -f "$STATE_DIR/camera_freq_guard.off" ]; then
    log "· 相机频率守护：已被关闭标志禁用"
else
    pkill -f "O3/camera_freq_guard\.sh" 2>/dev/null
    sleep 1
    nohup sh "$MODDIR/Scripts/4+4+2/O3/camera_freq_guard.sh" "${CAM_FREQ_INTERVAL:-2}" >> "$LOG_FILE" 2>&1 &
    log "· 相机频率守护已启动 (pid $!，间隔 ${CAM_FREQ_INTERVAL:-2}s)"
fi

# 4) 模块卡片描述 = 当前功能启用状态
update_module_desc >/dev/null 2>&1

# 兼容：reference 风格 Scripts/<arch>/<soc>/extra/*.sh 批量执行
for f in "$MODDIR/Scripts/4+4+2/O3/extra"/*.sh; do
    [ -f "$f" ] || continue
    nohup sh "$f" >> "$LOG_FILE" 2>&1 &
done

exit 0
