#!/system/bin/sh
# ============================================================
#  开机自启（v9 · 模块接管线程落核）
#    · 确保 Scene 数据目录可进入、配置可写
#    · 按模板重建线程分配 → 写进 Scene 的 files/threads.json
#    · 跑平台调优脚本（sysfs，与方案包内 powercfg.sh 同源）
#    · 启动 guard.sh（逐线程落核）
#
#  v8→v9 的回调原因（2026-09-17 实测，设备 lhasa）：
#    v8 曾把线程落核交给 Scene 的「核心分配」（它确实会读 threads.json 的
#    app_cpuset 并写 /dev/cpuset/top-app/{main,render,other}/cpus），但——
#      · 它的 @cpuset 预算由 **Scene 全局模式** 决定，不是单应用模式；
#      · 它写子组时会**自己裁到预算内**（省电预算 0-3 → main 也只能 0-3）；
#    ⇒ 窄预算把所有档位压平成同一核位，per-app 差异消失，实测体验差。
#    故 v9 关闭 Scene 核心分配（见 Config/*/features/cpuset.conf 的 in_apps/in_games=0），
#    改回本模块 enforce_threads.sh 逐线程落核 —— 可精确到 UnityMain / RenderThread / comm。
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

# 2) 档位表迁移（v10 同名 + v11 清空默认分配 + v12 显示名 + v13 fast→4-9；幂等）
migrate_templates_v10
migrate_templates_v11
migrate_templates_v12
migrate_templates_v13
# v14：四档语义重定义 —— 极速 = 0-7 基线 + 高负载线程上探 4-9；均衡显示名 → 流畅
migrate_templates_v14

# 3) 按模板重建线程分配 → 写进 Scene 的 files/threads.json
if [ -f "$SCENE_POWERCFG" ]; then
    out=$(gen_threads_from_scene 2>&1)
    log "· 线程分配: $out"
    echo "$(md5of "$SCENE_POWERCFG")/$(md5of "$SCENE_GAMES_XML")/$(md5of "$GAME_ASSIGN_FILE")/$(md5of "$GAME_TPL_FILE")/$(md5of "$APP_ASSIGN_FILE")/$(md5of "$APP_TPL_FILE")" > "${STATE_DIR}/scene.hash"
else
    log "· 未发现 Scene 的模式表，跳过线程分配生成"
fi

# 4) 启动调度守护 —— v9：模块重新接管线程落核
#    背景（2026-09-17 实测）：Scene「核心分配」的 @cpuset 预算由 **全局模式** 决定，
#    且 Scene 写子组时会**自己裁到预算内**。窄预算会把所有档位压平成同一核位
#    （省电 0-3 时连「性能」档也只剩 0-3），per-app 差异消失 —— 实测体验差。
#    故 v9 关闭 Scene 的核心分配，改回本模块 enforce_threads.sh 逐线程落核
#    （per-thread sched_setaffinity，可精确到 UnityMain / RenderThread / comm）。
pkill -f "O3/guard\.sh" 2>/dev/null
sleep 1
# 间隔 5s：守护每轮按模板落核（幂等，值一致时一条命令都不发，开销可忽略）
# 开机先收一次系统 cpuset 组（禁止 8-9，见 bigcore_guard.sh 头部）
sh "$MODDIR/Scripts/4+4+2/O3/bigcore_guard.sh" quiet >/dev/null 2>&1

nohup sh "$MODDIR/Scripts/4+4+2/O3/guard.sh" "${GUARD_INTERVAL:-5}" >> "$LOG_FILE" 2>&1 &
log "· guard 已启动 (pid $!，间隔 ${GUARD_INTERVAL:-5}s)"

# 4.1) 相机频率守护作为**可选兜底**（v9 默认不开）
#    Scene 侧 _Camera.json 已改为 modes 结构（跟随模式，含 min+max 配对），
#    正常情况不再需要它。若实测发现相机频率仍塌缩，删除下面这个判断即可启用。
if [ -f "$STATE_DIR/camera_freq_guard.on" ]; then
    pkill -f "O3/camera_freq_guard\.sh" 2>/dev/null
    sleep 1
    nohup sh "$MODDIR/Scripts/4+4+2/O3/camera_freq_guard.sh" "${CAM_FREQ_INTERVAL:-2}" >> "$LOG_FILE" 2>&1 &
    log "· 相机频率守护已启动（$STATE_DIR/camera_freq_guard.on 存在）"
else
    log "· 相机频率守护：未启用（如需启用：touch $STATE_DIR/camera_freq_guard.on）"
fi

# 4) 模块卡片描述 = 当前功能启用状态
update_module_desc >/dev/null 2>&1

# 兼容：reference 风格 Scripts/<arch>/<soc>/extra/*.sh 批量执行
for f in "$MODDIR/Scripts/4+4+2/O3/extra"/*.sh; do
    [ -f "$f" ] || continue
    nohup sh "$f" >> "$LOG_FILE" 2>&1 &
done

exit 0
