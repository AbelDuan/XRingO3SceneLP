#!/system/bin/sh
# ============================================================
#  安装脚本（KernelSU / Magisk 通用）  v3
# ------------------------------------------------------------
#  设计原则（2026-09-17 起）：**首次全灌，升级按清单覆盖，只保留「应用 / 游戏」配置**。
#    · 首次安装（Scene 里没有 profile.json）→ 内置完整调度配置全量灌进 Scene，
#      按 Scene 的 uid 修属主/权限，并逐个校验关键文件是否真的落盘。
#    · 非首次安装 → **直接覆盖** profile.json / manifest.json / description.txt /
#      powercfg.sh / _Camera.json / _Apps.json / _Games.json / _ELP.json / features/*.conf；
#      **保留** threads.json / threads_games.json —— 应用 / 游戏的线程档位表
#      （真值在模块状态目录的 app_assign.tsv，模块里那两份是打包当天的旧快照，
#        拿它覆盖等于把设备上最新的分配倒退回去）。
#      清单 = `lib/util.sh` 的 SYNC_SKIP，改一处即可。
#      覆盖前自动备份到 $STATE_DIR/backup/upgrade-<时间戳>/，可回滚。
#      ⚠ 早先是「继承、绝不覆盖」，代价是**模块改了什么都送不到设备上** ——
#        实测：Scene 侧 powercfg.sh 停在 v9 版（还在写 GPU 节点）好几天没人发现。
#    · 不再 chattr 加锁（实测会让 Scene 自己存不下配置）。
#    · 想**连被保留的那几个也重灌**（比如 Scene 重置/丢配置后），用 WebUI 概览页的
#      「传递调度」—— 它刻意不设 SYNC_SKIP，属显式全量修复动作；
#      「备份调度」「恢复备份」用于存档与回滚。
# ============================================================
SKIPUNZIP=0

MODID=SceneO3Tuner
FINAL_PATH="/data/adb/modules/${MODID}"
STATE_DIR="/data/adb/SceneO3Tuner"

. "$MODPATH/lib/util.sh"
MODDIR="$MODPATH"
export MODDIR

# ---------- 设备校验：必须是玄戒 O3 (4+4+2) ----------
ARCH_RAW=$(wc -w /sys/devices/system/cpu/cpufreq/*/related_cpus 2>/dev/null \
    | sed -E 's/^[[:space:]]+//g;/total/d;s/(^[0-9]+)([[:space:]].*)/\1/g' \
    | sed ':a;$!N;s/\n/+/g;ta;s/+$//g')
MACHINE=$(cat /sys/devices/soc0/machine 2>/dev/null)
[ -z "$MACHINE" ] && MACHINE=$(getprop ro.board.platform)

ui_print " "
ui_print "====================================="
ui_print "  玄戒O3 · Abel 调度工具箱"
ui_print "====================================="
ui_print "- 核心配置: ${ARCH_RAW:-未知}"
ui_print "- 平台标识: ${MACHINE:-未知}"

case "$ARCH_RAW" in
  4+4+2|4+4+1) : ;;
  *) ui_print "⚠ 未识别到 4+4+2 三簇拓扑（实际 ${ARCH_RAW}）"
     ui_print "  本模块仅适配玄戒 O3(10核 4+4+2)，继续安装但不保证生效" ;;
esac

SCENE_UID=$(get_package_uid "$SCENE_PKG")
if [ -z "$SCENE_UID" ]; then
    ui_print "⚠ 未检测到 Scene(com.omarea.vtools)，请先安装并至少启动一次"
else
    ui_print "- Scene UID: ${SCENE_UID} ✅"
fi

# ---------- 权限 ----------
set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm_recursive "$MODPATH/Scripts" 0 2000 0755 0755
set_perm_recursive "$MODPATH/Config"  0 2000 0755 0644
set_perm "$MODPATH/action.sh" 0 0 0755
set_perm "$MODPATH/service.sh" 0 0 0755
set_perm "$MODPATH/uninstall.sh" 0 0 0755
chmod 0755 "$MODPATH/Config/4+4+2/O3"/*/*.sh 2>/dev/null

# ---------- 旧版目录：保留、不删 ----------
#  这里早先是一句 `[ "$MODPATH" != "$FINAL_PATH" ] && rm -rf "$FINAL_PATH"`，
#  想法是「让 KSU 以为没装过、别走重启迁移」。实测两点都不成立：
#    ① KSU 的 installer.sh 在**跑本脚本之前**就已经把 MODPATH 指到
#       /data/adb/modules_update/<id> 了，删 active 目录改变不了它的路径判定，纯白删；
#    ② 删掉之后只要后面任何一步失败，模块目录就只剩一个 module.prop ——
#       用户在管理器里看到的就是「卡片在、但内容全无、执行/打开按钮都不见了」。
#  现在保留旧目录，靠后面的 `cp -af` 逐个覆盖（多出来的旧文件留着无害）。

# ---------- ★ 清除「模块被禁用 / 待迁移」标记 ----------
#
#  KSU 的「启用/禁用」在磁盘上就是 `/data/adb/modules/<id>/disable` 这一个标记文件。
#  管理器里看到「模块是灰的、开关打不开、重启也没用」，就是它还在。
#
#  什么时候会被打上：
#    ① 在管理器里手动关掉（或误触）；
#    ② **KSU 判定本次开机失败 → 进入「安全模式」，会把所有已加载模块一起禁用**；
#    ③ 从 modules_update「待迁移」状态掉 root 后残留 —— 本机 2026-09-17 就是这么来的
#       （模块目录只剩 module.prop，内容全在 modules_update 里，重装又走了待迁移路径）。
#
#  ⚠ 为什么必须由安装脚本主动清：
#    用户唯一的自救动作就是「重装模块」。如果安装脚本不清这个标记，
#    重装完**模块仍然是灰的** —— 用户会以为重装都没用，然后去重启手机（本机重启=掉 root）。
#    ⚠ 但这里只能清 disable / remove。`update` 这个标记**必须由文件末尾的「安装后自愈」
#      异步清** —— KSU 的 installer.sh 是在本脚本**返回之后**才 mktouch 出 update 的，
#      在这个脚本里删它，删完立刻又被建一个（v16.1 就是这么白忙一场的）。
#
#  ⚠ 安全性：本模块**没有 post-fs-data.sh**，只有 late_start 的 service.sh，
#    不参与、也不可能影响开机流程 → 清掉禁用标记绝不会引入「开不了机」的风险。
_cleared=""
for _mk in disable update remove; do
    if [ -f "${FINAL_PATH}/${_mk}" ]; then
        rm -f "${FINAL_PATH}/${_mk}" 2>/dev/null && _cleared="${_cleared} ${_mk}"
    fi
done
[ -n "$_cleared" ] && ui_print "- 已清除标记:${_cleared}（模块恢复为启用态，无需重启）"

mkdir -p "$STATE_DIR" "${STATE_DIR}/webui"

# ---------- 初始化状态 ----------
if [ ! -f "${STATE_DIR}/active_scheme" ]; then
    echo "sweet_bal" > "${STATE_DIR}/active_scheme"
    ui_print "- 默认方案: 日常均衡 (sweet_bal)"
else
    ui_print "- 保留原方案: $(cat ${STATE_DIR}/active_scheme 2>/dev/null)"
fi

# ⚠ 不再写 locked / unlocked 标记 —— 锁定机制已废除，留着只会误导。
#    若从旧版升级，顺手清掉它们。
rm -f "${STATE_DIR}/locked" "${STATE_DIR}/unlocked" 2>/dev/null

# ---------- WebUI 种子 ----------
chmod 0755 "$MODPATH/Scripts/4+4+2/O3/webui.sh" 2>/dev/null

# 1) 页面模型（内置模板 + 应用归类 + 游戏规则）
if [ ! -f "${STATE_DIR}/webui/model.json" ] && [ -f "$MODPATH/Config/webui_model.seed.json" ]; then
    cp -f "$MODPATH/Config/webui_model.seed.json" "${STATE_DIR}/webui/model.json"
    chmod 0666 "${STATE_DIR}/webui/model.json" 2>/dev/null
    ui_print "- WebUI 模型已初始化"
fi

# 2) 线程档位表（app_templates.tsv / game_templates.tsv）
#
#    ⚠ 这两个表由 lib/util.sh 的 seed_app_templates() / seed_game_templates()
#      **唯一维护**。早期版本在 Config/ 下另存了一份种子文件，两份内容会各自
#      漂移 —— v9 就出现过「包内是新的、设备上是旧的」而没人发现。那个种子
#      文件已删除，这里直接调函数。
#    ⚠ 两个 seed 函数都有「文件已存在则直接返回」的保护，不会覆盖你改过的档位表。
seed_app_templates
seed_game_templates
_rdy=""
for _t in app_templates.tsv game_templates.tsv; do
    if [ -f "${STATE_DIR}/webui/$_t" ]; then
        chmod 0666 "${STATE_DIR}/webui/$_t" 2>/dev/null
        _rdy="$_rdy $_t"
    fi
done
[ -n "$_rdy" ] && ui_print "- 线程档位表已就绪：${_rdy# }"

if [ -f "$MODPATH/Config/game_assign.tsv" ]; then
    # ⚠ **游戏默认不套任何档位**，让用户自己在「游戏」页勾选套用。
    #   所以这里只在缺失时落一个「只有表头」的种子，绝不预置分配。
    if [ ! -f "${STATE_DIR}/webui/game_assign.tsv" ]; then
        cp -f "$MODPATH/Config/game_assign.tsv" "${STATE_DIR}/webui/game_assign.tsv"
        ui_print "- 游戏档位分配：默认留空（由你在 WebUI 里勾选套用）"
    else
        # 升级路径：清掉指向「已不存在的档位 id」的僵尸条目
        # （档位 id 在各版本间变过：tpl_moba/tpl_unity → unity/default → powersave/balance/…）
        _ga="${STATE_DIR}/webui/game_assign.tsv"
        _gt="${STATE_DIR}/webui/game_templates.tsv"
        if [ -s "$_gt" ]; then
            cp -f "$_ga" "${TMPD}/ga.old" 2>/dev/null
            awk -F'\t' -v TPL="$_gt" '
              BEGIN { while ((getline l < TPL) > 0) { if (l == "" || l ~ /^#/) continue; n=split(l,a,"\t"); if (n>=2) ok[a[1]]=1 } close(TPL) }
              /^#/ { print; next }
              NF>=2 && $2 != "" && ($2 in ok) { print; next }
              NF>=2 { dropped++ }
              END { if (dropped) print "# 已清除 " dropped " 条无效分配（模板已不存在）" > "/dev/stderr" }
            ' "${TMPD}/ga.old" > "$_ga" 2>/dev/null
            chmod 0666 "$_ga" 2>/dev/null
        fi
    fi
    chmod 0666 "${STATE_DIR}/webui/game_assign.tsv" 2>/dev/null
fi

# ---------- 把模块内置的全部配置文件同步进 Scene（替换原文件 + 修正确权限）----------
# 用户要求：模块自带一份完整配置，装完就是「可用状态」，不用再去 Scene 里手配。
#   · 源 = Config/4+4+2/O3/<当前方案>/   （profile.json / _Apps.json / _Games.json /
#     _Camera.json / _ELP.json / powercfg.sh / manifest.json / description.txt /
#     threads.json / threads_games.json / features/*.conf）
#   · 目标 = Scene 自己的数据目录 $SCENE_DIR（以及 features/ 子目录）
#   · sync_scheme 内部会：替换 inode 写入（个别 inode 拒写）→ 按 Scene 的 uid 修属主/权限
#     → 跑 verify_synced 自检（md5 逐个比对，防串档）
if [ -d "$SCENE_DIR" ]; then
    # a) 目录可进入 + 清掉历史残留的 chattr 锁（否则 Scene 自己存不下设置）
    ensure_scene_dir_perm
    r=$(repair_scene_writable)
    ui_print "- 配置可写性: $r"

    # b) 首次安装判定 → 灌默认配置；非首次 → 继承，绝不覆盖
    #
    #    ⚠ 为什么必须区分：
    #      profile.json 里存着用户在 Scene 里调过的 8 组频率预设。早期版本每次
    #      装模块都全量覆盖一遍，等于把用户的调校冲掉 —— 这就是「继承」要解决的问题。
    #
    #    ⚠ 为什么首次判定看 profile.json：
    #      Scene 按 manifest.json 的 name/version + files/profileInstalled 校验调度是否已安装，
    #      标识一变（比如方案名从 LP 改称 Abel）它就会**删掉** profile.json / manifest.json /
    #      _Apps.json / _Games.json / _Camera.json / _ELP.json 并清空 objects/、features/。
    #      所以「profile.json 不在」正是需要灌配置的信号，用它当判据最准。
    SCHEME_INST=$(cat "$ACTIVE_FILE" 2>/dev/null)
    [ -z "$SCHEME_INST" ] && SCHEME_INST="sweet_bal"
    SRC_INST="$MODPATH/Config/4+4+2/O3/$SCHEME_INST"

    if [ -f "${SCENE_DIR}/profile.json" ]; then
        # ── 升级路径（2026-09-17 语义变更）：**按清单直接覆盖** ──
        #
        #  旧语义是「继承，绝不覆盖 profile.json 等」，理由是那里面有用户在 Scene 里
        #  调过的参数。代价是**模块改了什么基本送不到设备上** —— 实测踩到：
        #  Scene 侧的 powercfg.sh 一直停在 v9 版（还在写 devfreq_gpu_limit / boost_enable），
        #  而模块源码里那段早就删了；两边不一致了好几天，直到手动比对 md5 才发现。
        #
        #  新语义（用户 2026-09-17 明确要求）：**除「应用 / 游戏」类配置外，一律直接覆盖**。
        #   · 覆盖：profile.json / manifest.json / description.txt / powercfg.sh /
        #           _Camera.json / _ELP.json / features/*.conf
        #   · 保留：_Apps.json / _Games.json / threads.json / threads_games.json
        #           —— 清单在 `lib/util.sh` 的 SYNC_SKIP，改一处即可。
        #  覆盖前先把将被覆盖的文件备份到 $STATE_DIR/backup/upgrade-<时间戳>/（可回滚）。
        #  （_Camera.json 仍属「覆盖」，所以原先「相机配置强制替换」这条已自动包含在内。）
        ui_print "- 检测到已有调度配置 → 升级：按清单直接覆盖（应用/游戏配置除外）"

        # 1) 备份将被覆盖的文件（只备份真实存在的，别造空文件）
        _bk="${STATE_DIR}/backup/upgrade-$(date +%Y%m%d_%H%M%S)"
        mkdir -p "${_bk}/features" 2>/dev/null
        _bn=0
        for _f in profile.json manifest.json description.txt powercfg.sh _Camera.json _ELP.json; do
            if [ -f "${SCENE_DIR}/${_f}" ] && cp -f "${SCENE_DIR}/${_f}" "${_bk}/" 2>/dev/null; then
                _bn=$((_bn+1))
            fi
        done
        for _f in cpuset.conf env.conf fas.conf limiter.conf refresh_rate.conf; do
            if [ -f "${SCENE_DIR}/features/${_f}" ] && cp -f "${SCENE_DIR}/features/${_f}" "${_bk}/features/" 2>/dev/null; then
                _bn=$((_bn+1))
            fi
        done
        [ "$_bn" -gt 0 ] && ui_print "- 已备份被覆盖的 ${_bn} 个文件 → ${_bk}"

        # 2) 覆盖。保留清单 = lib/util.sh 的 SYNC_SKIP（默认只留「应用 / 游戏」的线程表）
        if [ -d "$SRC_INST" ]; then
            cnt=$(sync_scheme "$SRC_INST" 2>&1 | tail -1)
            case "$cnt" in
              ''|*[!0-9]*)
                ui_print "- ⚠ 配置覆盖异常：$cnt"
                ui_print "  可在 WebUI 概览页点「传递调度」重试" ;;
              *)
                ui_print "- 已覆盖内置配置 ${cnt} 个文件（方案 $SCHEME_INST）"
                _miss=""
                for _f in profile.json manifest.json _Camera.json powercfg.sh; do
                    [ -f "${SRC_INST}/${_f}" ] || continue
                    [ -f "${SCENE_DIR}/${_f}" ] || _miss="$_miss $_f"
                done
                if [ -n "$_miss" ]; then
                    ui_print "- ⚠ 以下文件未落盘：$_miss"
                else
                    ui_print "- ✅ 关键文件已覆盖并校验"
                fi
                ui_print "- 保留未动（应用/游戏线程配置）：${SYNC_SKIP:-无}"
                ;;
            esac
        else
            ui_print "- ⚠ 内置方案目录缺失：$SRC_INST"
        fi

        # 3) 让 scene-daemon 重读刚写下去的 features/*.conf
        #    ⚠ 这几个键是 daemon 启动时读一次缓存的（实测改完不重启不生效）。
        #      它被 kill 后由 Scene 自身在 4~8 秒内拉起，不影响 Scene 界面与无障碍服务。
        if pgrep -f scene-daemon >/dev/null 2>&1; then
            restart_scene_daemon >/dev/null 2>&1 && ui_print "- scene-daemon 已重启（将重读新的 features 配置）"
        fi
    else
        ui_print "- 未检测到调度配置（首次安装 / 或 Scene 重置过）→ 传递内置默认配置"
        if [ -d "$SRC_INST" ]; then
            cnt=$(sync_scheme "$SRC_INST" 2>&1 | tail -1)
            case "$cnt" in
              ''|*[!0-9]*)
                ui_print "- ⚠ 配置传递异常：$cnt"
                ui_print "  可在 WebUI 概览页点「传递调度」重试" ;;
              *)
                ui_print "- 已传递内置配置 ${cnt} 个文件 → Scene（方案 $SCHEME_INST）"
                # 逐个确认关键文件真的落盘（verify_synced 对「不存在」是 skip，
                # 所以这里显式再查一遍，避免"没写进去却报成功"）
                _miss=""
                for _f in profile.json manifest.json _Apps.json _Games.json _Camera.json _ELP.json powercfg.sh; do
                    [ -f "${SRC_INST}/${_f}" ] || continue
                    [ -f "${SCENE_DIR}/${_f}" ] || _miss="$_miss $_f"
                done
                if [ -n "$_miss" ]; then
                    ui_print "- ⚠ 以下文件未落盘：$_miss"
                    ui_print "  可在 WebUI 概览页点「传递调度」重试"
                else
                    ui_print "- ✅ 配置校验通过（关键文件齐全）"
                fi
                ;;
            esac
        else
            ui_print "- ⚠ 内置方案目录缺失：$SRC_INST"
        fi
    fi

    # c) 确保 Scene 的「核心分配」是**关**的（只动 use_presets / in_apps / in_games）
    #
    #    ⚠ 这里曾经写反过（$2=1，把三个开关强行打开），与模块默认配置里的
    #      `in_apps=0 / in_games=0` 直接矛盾 —— 症状是「包里的默认配置是关的，
    #      装完到设备上却是开的」。v10 修正为统一置 0。
    #
    #    为什么必须关：Scene 的核心分配会读我们写的 threads.json，但它写
    #    /dev/cpuset/top-app/{main,render,other}/cpus 时**按 Scene 全局模式的
    #    @cpuset 预算自己裁一刀** —— 「省电」这类窄预算会把所有档位压平成同一核位，
    #    per-app 差异全部消失（用户实测反馈「效果很差」）。
    #    线程交给模块的 enforce_threads.sh 逐线程落核，才能精确到 UnityMain /
    #    RenderThread / 任意 comm 名字。
    _cf="${SCENE_DIR}/features/cpuset.conf"
    if [ -f "$_cf" ]; then
        _tmp="${TMPD}/cpuset.inst"
        cp -f "$_cf" "$_tmp" 2>/dev/null
        awk -F= -v OFS='=' '
            /^use_presets=/ { $2=0; u=1 }
            /^in_apps=/     { $2=0; i=1 }
            /^in_games=/    { $2=0; g=1 }
            { print }
            END { if(!u) print "use_presets=0"; if(!i) print "in_apps=0"; if(!g) print "in_games=0" }
        ' "$_tmp" > "${_tmp}.2" 2>/dev/null && mv -f "${_tmp}.2" "$_tmp"
        write_replace "$_tmp" "$_cf" && perm_file "$_cf"
        rm -f "$_tmp" "${_tmp}.2" 2>/dev/null
        ui_print "- 已关闭 Scene 核心分配（线程由模块逐线程落核）"
    fi

    # d) 确保 GPU 完全交回系统（features/env.conf 的 gpu_lock=0）
    #
    #    ⚠ 与 c 步对称：**继承路径不会覆盖 features/**，所以老版本升级上来的设备
    #      会保留旧的 gpu_lock=1（= 禁止系统 GPU Boost），与 v10「模块完全不碰 GPU」
    #      的约定不符。
    #
    #    ── 2026-09-17 定论：Scene 的「禁止GPU Boost」在 O3 上无执行体 ──
    #    反汇编 classes.dex 实证：字符串 `gpu_lock` 全 dex 只有 **1 处**引用，就是
    #    `com.omarea.scene_mode.d$b$a$a` 的表单项定义（default / path / type=boolean）。
    #    它唯一的消费点是 `com.omarea.scene_mode.f.q()`：把 features/env.conf 逐行拼成
    #    `export <key>=<val>` 前缀，再 `sh <powercfg.sh> <arg>` 执行
    #    ⇒ **真正干活的必须是 powercfg.sh，Scene 自己一个字节都不写。**
    #    O3 没有云端 LP/HP/EP 方案（`schedule_unsupported`，SoC 表里没有 O3）→ 没有官方
    #    powercfg.sh；设备上那份是本模块的，而 v10 起它完全不读 `$gpu_lock`
    #    ⇒ 开关在 O3 上不产生任何内核写入（strace -f 跟 daemon 启动 + 12s 稳态，
    #      对 /sys 的 GPU 节点零访问）。
    #
    #    内核侧也顺带钉死了：O3 的 boost 旋钮**真实有效** —— 把 gpufreq_core 钉在
    #    119370000（`dynamic/user_freq` + `user_valid=1`）后写 `boost_enable=1`，
    #    cur_freq 立刻被抬到 576000000（hispeed 档，target 仍是 119MHz），写回 0 即落回。
    #    但 **O3 从不打开它**：powercfg.sh 日志 3775 行（9/14 起、跨 2 次开机）里
    #    boost_enable 一条写入记录都没有；空载 / screencap 压 GPU / 相机预览三场景实测
    #    全程为 0（同批确认 O3 没有 `launcher_boost_enabled` 节点，所以环境配置页的
    #    另一个开关「启动器加速」同样空转）。
    #    ⇒ **没有可禁止的对象** → 按约定取「关闭」：gpu_lock=0，模块不碰 GPU 节点。
    #      （若将来要让这个开关真正可控：在 powercfg.sh 里读 `$gpu_lock`，=1 时写
    #        `boost_enable=0` 即可 —— 但那需要把 powercfg.sh 重新同步进 Scene。）
    _ef="${SCENE_DIR}/features/env.conf"
    if [ -f "$_ef" ]; then
        _tmp="${TMPD}/env.inst"
        cp -f "$_ef" "$_tmp" 2>/dev/null
        awk -F= -v OFS='=' '
            /^gpu_lock=/ { $2=0; g=1 }
            { print }
            END { if(!g) print "gpu_lock=0" }
        ' "$_tmp" > "${_tmp}.2" 2>/dev/null && mv -f "${_tmp}.2" "$_tmp"
        write_replace "$_tmp" "$_ef" && perm_file "$_ef"
        rm -f "$_tmp" "${_tmp}.2" 2>/dev/null
        ui_print "- GPU 交回系统（gpu_lock=0；该开关在 O3 上无执行体，O3 本身也不 boost GPU）"
    fi

    # e) 按 O3 实测结论修正「调速器」与「辅助调速器」
    #
    #    ⚠ 2026-09-17 起 features/*.conf 已经被 b 步**整体覆盖**过了，这几条现在是
    #      「兜底修正」：防的是 b 步失败、或用户装的包比这一步旧、或有人手改过 features/。
    #      仍然是「不改就会踩坑」的键，保留。
    #
    #    ── fas.conf 的 governor_little/middle/prime ──
    #      Scene 文案：「FAS/FEAS 工作期间，小/中/大核使用的调速器」。
    #      O3 三簇实际只有 xres / conservative / powersave / performance / schedutil
    #      —— **没有 walt**（那是 8E 等平台的值）。
    #      这里统一写成 **xres**，与「CPU 控制」页默认值、以及 profile.json 各模式
    #      preset 的 scaling_governor 三处一致。
    #      （Scene 的 FAS 候选是硬编码的，O3 上只有 auto/performance/conservative；
    #        详见 Config/4+4+2/O3/*/features/fas.conf 的注释。Scene 不校验写入值。）
    #
    #    ── limiter.conf 的 limiters_in_apps / limiters_in_games ──
    #      按用户要求默认**开启**（=1）：功耗最低，代价是 1 秒内的突发负载响应变慢。
    #      相机已在 _Camera.json 里用 ["@limiter","NONE"] 单独豁免。
    _ff="${SCENE_DIR}/features/fas.conf"
    if [ -f "$_ff" ]; then
        _tmp="${TMPD}/fas.inst"
        cp -f "$_ff" "$_tmp" 2>/dev/null
        awk -F= -v OFS='=' '
            /^governor_little=/ { $2="xres"; a=1 }
            /^governor_middle=/ { $2="xres"; b=1 }
            /^governor_prime=/  { $2="xres"; c=1 }
            { print }
            END {
                if(!a) print "governor_little=xres"
                if(!b) print "governor_middle=xres"
                if(!c) print "governor_prime=xres"
            }
        ' "$_tmp" > "${_tmp}.2" 2>/dev/null && mv -f "${_tmp}.2" "$_tmp"
        write_replace "$_tmp" "$_ff" && perm_file "$_ff"
        rm -f "$_tmp" "${_tmp}.2" 2>/dev/null
        ui_print "- 调速器已统一为 O3 支持的 xres（与 CPU 控制页一致）"
    fi

    _lf="${SCENE_DIR}/features/limiter.conf"
    if [ -f "$_lf" ]; then
        _tmp="${TMPD}/limiter.inst"
        cp -f "$_lf" "$_tmp" 2>/dev/null
        awk -F= -v OFS='=' '
            /^limiters_in_apps=/  { $2=1; a=1 }
            /^limiters_in_games=/ { $2=1; g=1 }
            { print }
            END {
                if(!a) print "limiters_in_apps=1"
                if(!g) print "limiters_in_games=1"
            }
        ' "$_tmp" > "${_tmp}.2" 2>/dev/null && mv -f "${_tmp}.2" "$_tmp"
        write_replace "$_tmp" "$_lf" && perm_file "$_lf"
        rm -f "$_tmp" "${_tmp}.2" 2>/dev/null
        ui_print "- 辅助调速器已开启（应用 + 游戏；相机单独豁免）"
    fi

    # f) 收掉旧版 powercfg.sh 留下的 GPU 温控屏蔽残留
    #
    #    v9 及以前的 powercfg.sh 里有 `hide_value $T/devfreq_gpu_limit 0` —— 用
    #    bind-mount 把一个写着 0 的普通文件盖在「温控给 GPU 的限频节点」上，
    #    于是温控 HAL 的限频写入全被这个文件吃掉，**GPU 的温控限频形同虚设**。
    #    v10 起模块把这一行删了（GPU 完全交回系统，含温控），但**已经挂上的 bind-mount
    #    不会自己消失**（新脚本不再碰它 → 连 umount 都不会发生）。
    #    所以这里显式收掉；下次开机后自然也不会再有。
    #
    #    ⚠ 只收 devfreq_gpu_limit 这一个：temp_state / market_download_limit 至今仍是
    #      模块主动屏蔽的对象（v14 的 powercfg.sh 还在 hide），不能动。
    _gl="/sys/devices/virtual/thermal/thermal_message/devfreq_gpu_limit"
    if grep -q "thermal_message/devfreq_gpu_limit" /proc/mounts 2>/dev/null; then
        if umount "$_gl" 2>/dev/null; then
            ui_print "- 已解除遗留的 GPU 温控屏蔽（旧版 powercfg.sh 留下的 bind-mount）"
        else
            ui_print "- ⚠ GPU 温控屏蔽残留未解除（重启后即消失）"
        fi
    fi

    # d) 按 Scene 的「应用→模式」表生成线程分配
    ui_print "- $(gen_threads_from_scene 2>&1 | tail -1)"
    echo "$(md5of "$SCENE_POWERCFG")/$(md5of "$SCENE_GAMES_XML")" > "${STATE_DIR}/scene.hash"
    # 落一个「输入已处理」标记：守护用 mtime（-nt）判断要不要重建线程分配，
    # 有这个标记装完就不会再多跑一轮无意义的重建。
    touch "${STATE_DIR}/scene.mark" 2>/dev/null
else
    ui_print "⚠ Scene 尚未启动过，配置将在首次开机由 service.sh 处理"
fi

# ---------- 自我保护：把 KSU 的「待重启生效」就地做掉（本机不能重启）----------
#
#  ⚠⚠ 本机是**临时越狱 root**，重启会掉 root（用户铁律，2026-09-17）。
#     而 KSU 更新一个「已存在」的模块时走的是「暂存 + 待重启」这套：
#        · 新内容解到 /data/adb/modules_update/<id>/
#        · 在 /data/adb/modules/<id>/ 里留一个空的 `update` 标记
#        · 真正的合并只发生在**开机**时（ksud handle_updated_modules 把
#          modules_update/<id> 整个改名覆盖 modules/<id>）
#     在这台机器上等于：
#        · 模块目录可能只剩 module.prop（Config/Scripts/webroot 全没了）
#        · 管理器里「开关变灰、点不动」（update=1）且「执行 / 打开(WebUI)」两个按钮
#          直接不渲染（active 目录里没有 action.sh、没有 webroot/）
#        · WebUI 打不开、守护脚本找不到文件（正在跑的进程引用的是已删除的 inode）
#
#  ⚠ 时序（2026-09-17 逐行读 KernelSU 源码确认，别再靠猜）：
#      installer.sh 在 `. customize.sh` **返回之后**才执行下面三行：
#          mktouch $NVBASE/modules/$MODID/update          ← 无条件创建，晚整整一步
#          rm -rf  $NVBASE/modules/$MODID/{remove,disable}
#          cp -af  $MODPATH/module.prop $NVBASE/modules/$MODID/module.prop
#      ⇒ 「在自定义脚本里删 update 标记」**原理上就不可能成功**：
#        脚本里删掉的那个，installer 紧接着又建一个。（v16.1 的失手点就在这。）
#
#  ⇒ 因此分两步：
#      (1) 这里先把内容 `cp -af` 覆盖进 active 目录 —— 立刻可用，不依赖后面那步；
#      (2) 文件末尾再拉起一个**脱离安装进程**的自愈脚本，等 installer.sh 把
#          update 标记写出来之后，由它删标记 + 收拾 modules_update + 重拉服务。
#
#  判据：MODPATH（KSU 解压出来的位置）不等于 FINAL_PATH 就说明走了待迁移路径。
_migrated=""
if [ -n "$MODPATH" ] && [ "$MODPATH" != "$FINAL_PATH" ] && [ -f "${MODPATH}/module.prop" ]; then
    mkdir -p "$FINAL_PATH"
    cp -af "$MODPATH"/. "$FINAL_PATH"/ 2>/dev/null
    # 合并成功的判据：三个「缺了就废」的东西都在
    if [ -f "${FINAL_PATH}/module.prop" ] && [ -f "${FINAL_PATH}/service.sh" ] \
       && [ -f "${FINAL_PATH}/webroot/index.html" ] && [ -f "${FINAL_PATH}/lib/util.sh" ]; then
        # 这一步对「adb push 部署」这条路径有用（那条路径没有 installer.sh 补标记）；
        # zip 安装时 installer.sh 稍后还会重建 update —— 交给末尾的自愈收掉。
        rm -f "${FINAL_PATH}/update" "${FINAL_PATH}/remove" 2>/dev/null
        set_perm_recursive "$FINAL_PATH" 0 0 0755 0644
        set_perm_recursive "$FINAL_PATH/Scripts" 0 2000 0755 0755
        set_perm_recursive "$FINAL_PATH/Config"  0 2000 0755 0644
        chmod 0755 "$FINAL_PATH"/Config/4+4+2/O3/*/*.sh 2>/dev/null
        # ⚠ 这里**不要** rm -rf modules_update/<id>：installer.sh 紧接着还要
        #   `cp -af $MODPATH/module.prop $NVBASE/modules/$MODID/module.prop`，
        #   提前删掉 MODPATH 会让它报错。清理由末尾的自愈脚本在安装进程结束后做。
        _migrated=1
        ui_print "- 已就地合并到 $FINAL_PATH（本机不重启，跳过 KSU 待迁移状态）"
    else
        ui_print "- ⚠ 就地合并未完成（$FINAL_PATH 缺关键文件）—— 请勿重启，见末尾「安装后自愈」日志"
    fi
fi

# ---------- 让守护用上新脚本（不重启）----------
#  守护是按文件路径跑的（/data/adb/modules/<id>/Scripts/...），合并完路径就恢复了；
#  已在跑的旧进程会在下一轮自然读回新文件，这里只补一次「确保在跑」。
#
#  ⚠ 两种情况都要拉一次：
#    · $_migrated —— 刚从 modules_update 就地合并过来，路径换了；
#    · $_cleared  —— 刚清掉 disable，模块从「被禁用」变回启用态，
#                    上一个 boot 的 service.sh 根本没跑过，不补这一次守护就是死的。
if { [ -n "$_migrated" ] || [ -n "$_cleared" ]; } \
   && [ -x "$FINAL_PATH/service.sh" ] && command -v ksud >/dev/null 2>&1; then
    ksud services >/dev/null 2>&1 && ui_print "- 已让 ksud 重新拉起模块服务（无需重启）"
fi

# ---------- 把切换脚本放进 Scene「自定义命令」----------
CC_DIR="${SCENE_DIR}/custom-command"
if [ -d "$SCENE_DIR" ]; then
    mkdir -p "$CC_DIR"
    cp -af "$MODPATH/Config/4+4+2/O3/switch.sh" "${CC_DIR}/O3调度·切换方案.sh"
    [ -n "$SCENE_UID" ] && chown "${SCENE_UID}:${SCENE_UID}" "${CC_DIR}/O3调度·切换方案.sh"
    chmod 0777 "${CC_DIR}/O3调度·切换方案.sh"
    ui_print "- 已注入 Scene 自定义命令：O3调度·切换方案.sh"
fi

# ---------- ★ 安装后自愈：改写 KSU 的「待重启生效」状态 ----------
#
#  为什么必须异步：见上面「自我保护」的时序 —— `update` 标记是 installer.sh
#  在本脚本返回**之后**才 mktouch 出来的，脚本里没有任何办法阻止它。
#
#  做法：落一个独立脚本 → setsid/nohup 脱离安装进程后台跑 → 它轮询等 update 标记
#        出现（最多 90s），再把 modules_update/<id> 合并进 modules/<id>、删标记、
#        重拉服务。这样 zip 安装也能**免重启**直接生效。
#
#  ⚠ 安全边界：只有「关键文件校验通过」才删 modules_update，校验不过就原样保留那份
#     完整副本，绝不制造「两边都不全」的局面。失败会写日志，不会静默。
SELFHEAL="${STATE_DIR}/fix_pending.sh"
mkdir -p "$STATE_DIR"
cat > "$SELFHEAL" <<'SHEOF'
#!/system/bin/sh
# 由 customize.sh 在安装收尾时拉起（后台）。
# 用途：本机禁止重启，靠这一步跳过 KernelSU 的「待重启生效」——
#   把 /data/adb/modules_update/<id> 合并进 /data/adb/modules/<id>，
#   删掉 active 目录里的 update 标记，再让 ksud 重拉一次模块服务。
# 日志：/data/adb/SceneO3Tuner/fix_pending.log
ID=SceneO3Tuner
UPD="/data/adb/modules_update/$ID"
FIN="/data/adb/modules/$ID"
LOG="/data/adb/SceneO3Tuner/fix_pending.log"

now() { date '+%F %T' 2>/dev/null || echo '?'; }

# ksud：优先全路径（init 起的进程 PATH 很窄），再退回 PATH 查找
KSUD=""
for c in /data/adb/ksu/bin/ksud /data/adb/ksud; do
    [ -x "$c" ] && { KSUD="$c"; break; }
done
[ -z "$KSUD" ] && KSUD=$(command -v ksud 2>/dev/null)

i=0
while [ "$i" -lt 90 ]; do
    if [ -e "$FIN/update" ]; then
        [ -d "$UPD" ] && cp -af "$UPD"/. "$FIN"/ 2>/dev/null
        if [ -f "$FIN/module.prop" ] && [ -f "$FIN/service.sh" ] \
           && [ -f "$FIN/webroot/index.html" ] && [ -f "$FIN/lib/util.sh" ]; then
            rm -f "$FIN/update" "$FIN/remove" 2>/dev/null
            # zip 里的脚本被 installer 统一设成 0644，这里把该可执行的补回来
            chmod 0755 "$FIN/service.sh" "$FIN/action.sh" "$FIN/uninstall.sh" 2>/dev/null
            chmod 0755 "$FIN"/Scripts/*/*/*.sh "$FIN"/Config/*/*/*.sh \
                       "$FIN"/Config/*/*/*/*.sh 2>/dev/null
            chmod 0644 "$FIN/module.prop" "$FIN/webroot/index.html" "$FIN/lib/util.sh" 2>/dev/null
            # 留 3s 让 installer.sh 把剩下的收尾动作跑完（它还要 cp module.prop），
            # 再清掉暂存目录 —— 等价于「重启后 handle_updated_modules 的结果」。
            sleep 3
            [ -d "$UPD" ] && rm -rf "$UPD" 2>/dev/null
            echo "$(now) OK 已合并、已清 update 标记（免重启生效）" >> "$LOG"
            [ -n "$KSUD" ] && "$KSUD" services >/dev/null 2>&1
            exit 0
        fi
        echo "$(now) FAIL 校验不通过（$FIN 缺关键文件）—— 保留 modules_update 副本，未做任何删除" >> "$LOG"
        exit 1
    fi
    i=$((i + 1))
    sleep 1
done
echo "$(now) SKIP 等待 90s 未出现 update 标记（可能不是 KSU zip 安装路径，无需处理）" >> "$LOG"
exit 2
SHEOF
chmod 0755 "$SELFHEAL"

# 脱离安装进程独立运行：安装器一退出，父进程可能连子孙一起收走
if command -v setsid >/dev/null 2>&1; then
    setsid "$SELFHEAL" </dev/null >/dev/null 2>&1 &
    ui_print "- 已启动安装后自愈（setsid 后台，免重启生效）"
elif command -v nohup >/dev/null 2>&1; then
    nohup "$SELFHEAL" </dev/null >/dev/null 2>&1 &
    ui_print "- 已启动安装后自愈（nohup 后台，免重启生效）"
else
    "$SELFHEAL" </dev/null >/dev/null 2>&1 &
    ui_print "- 已启动安装后自愈（后台，免重启生效）"
fi
ui_print "- 约 10 秒后下拉刷新管理器：开关不再灰，出现「执行 / 打开」"
ui_print "  （日志：/data/adb/SceneO3Tuner/fix_pending.log）"

ui_print " "
ui_print "✅ 安装完成"
ui_print "ℹ 分工：线程档位 = 本模块 cgroup 分组落核（WebUI「应用 / 游戏」页）"
ui_print "         CPU 频率 = Scene 按模式下发（WebUI「模式」页图形化编辑）"
ui_print "👉 模块 WebUI = 概览 / 模式 / 应用 / 游戏 / 日志"
ui_print "👉 配置不加锁：Scene 内所有设置（含小齿轮里的特性）都可自由调整"
ui_print "👉 Scene 的「核心分配」保持关闭 —— 它的组级预算会把各档位压平成同一个核位"
ui_print "👉 辅助调速器（应用 + 游戏）保持开启 —— 相机已在 _Camera.json 里单独豁免"
ui_print "👉 FAS 调速器统一为 O3 支持的 xres（与「CPU 控制」页、各模式 preset 三处一致）"
ui_print "   详见 Config/.../features/{fas,limiter}.conf 的注释"
ui_print " "
ui_print "ℹ 模块 Config 里的文件是备份副本，需要时可从 WebUI 显式施加"
