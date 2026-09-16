#!/system/bin/sh
# ============================================================
#  安装脚本（KernelSU / Magisk 通用）  v3
# ------------------------------------------------------------
#  设计原则（2026-09-16 起）：**首次灌配置，之后继承**。
#    · 首次安装（Scene 里没有 profile.json）→ 把模块内置的完整调度配置灌进 Scene，
#      按 Scene 的 uid 修正属主/权限，并逐个校验关键文件是否真的落盘。
#    · 非首次安装 → **继承**已有配置，绝不覆盖 profile.json（那里面是用户在 Scene
#      里调过的 8 组频率预设，覆盖了等于把调校冲掉）。只做目录权限与开关的维护。
#    · 不再 chattr 加锁（实测会让 Scene 自己存不下配置）。
#    · 想主动把内置配置灌回去（比如 Scene 重置/丢配置后），用 WebUI 概览页的
#      「传递调度」；「备份调度」「恢复备份」用于存档与回滚。
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

# ---------- 先移除旧版（避免 KSU 走重启迁移）----------
if [ -d "$FINAL_PATH" ] && [ "$MODPATH" != "$FINAL_PATH" ]; then
    rm -rf "$FINAL_PATH" 2>/dev/null
fi
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

# 2) 游戏线程模板与分配（TSV；核号用 {e_core}/{hp_core} 等语义占位符，
#    生成时按实际拓扑展开并按在线核裁剪）
if [ -f "$MODPATH/Config/game_templates.tsv" ]; then
    # 只在缺失时落种子 —— 否则每次升级都会把用户改过的模板冲掉
    if [ ! -f "${STATE_DIR}/webui/game_templates.tsv" ]; then
        cp -f "$MODPATH/Config/game_templates.tsv" "${STATE_DIR}/webui/game_templates.tsv"
        ui_print "- 游戏线程模板已初始化（5 套）"
    fi
    chmod 0666 "${STATE_DIR}/webui/game_templates.tsv" 2>/dev/null
fi
if [ -f "$MODPATH/Config/game_assign.tsv" ]; then
    # ⚠ 用户要求：**游戏默认不套任何线程模板**，让用户自己在「游戏」页勾选套用。
    #   所以这里只在缺失时落一个「只有表头」的种子，绝不预置分配。
    if [ ! -f "${STATE_DIR}/webui/game_assign.tsv" ]; then
        cp -f "$MODPATH/Config/game_assign.tsv" "${STATE_DIR}/webui/game_assign.tsv"
        ui_print "- 游戏线程分配：默认留空（不套模板，由你在 WebUI 里勾选套用）"
    else
        # 升级路径：清掉指向「已不存在的模板 id」的僵尸条目
        # （老版本种子用过 tpl_moba / tpl_unity，现在模板 id 是 unity/default 之类）
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
        ui_print "- 检测到已有调度配置 → 继承，不覆盖你在 Scene 里的调校"
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

    # c) 校正核心分配必需开关（只动 use_presets / in_apps / in_games 三个键）
    _cf="${SCENE_DIR}/features/cpuset.conf"
    if [ -f "$_cf" ]; then
        _tmp="${TMPD}/cpuset.inst"
        cp -f "$_cf" "$_tmp" 2>/dev/null
        awk -F= -v OFS='=' '
            /^use_presets=/ { $2=1; u=1 }
            /^in_apps=/     { $2=1; i=1 }
            /^in_games=/    { $2=1; g=1 }
            { print }
            END { if(!u) print "use_presets=1"; if(!i) print "in_apps=1"; if(!g) print "in_games=1" }
        ' "$_tmp" > "${_tmp}.2" 2>/dev/null && mv -f "${_tmp}.2" "$_tmp"
        write_replace "$_tmp" "$_cf" && perm_file "$_cf"
        rm -f "$_tmp" "${_tmp}.2" 2>/dev/null
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

# ---------- 把切换脚本放进 Scene「自定义命令」----------
CC_DIR="${SCENE_DIR}/custom-command"
if [ -d "$SCENE_DIR" ]; then
    mkdir -p "$CC_DIR"
    cp -af "$MODPATH/Config/4+4+2/O3/switch.sh" "${CC_DIR}/O3调度·切换方案.sh"
    [ -n "$SCENE_UID" ] && chown "${SCENE_UID}:${SCENE_UID}" "${CC_DIR}/O3调度·切换方案.sh"
    chmod 0777 "${CC_DIR}/O3调度·切换方案.sh"
    ui_print "- 已注入 Scene 自定义命令：O3调度·切换方案.sh"
fi

ui_print " "
ui_print "✅ 安装完成"
ui_print "👉 在 Scene 里切全局模式 / 改单个应用的模式，核心分配会自动跟随"
ui_print "👉 模块 WebUI = 概览 / 模式 / 应用 / 游戏 / 日志"
ui_print "👉 配置不再加锁，Scene 内所有设置（含小齿轮里的特性）都可自由调整"
ui_print " "
ui_print "ℹ 模块 Config 里的文件是备份副本，需要时可从 WebUI 显式施加"
