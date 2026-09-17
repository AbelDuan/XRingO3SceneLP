#!/system/bin/sh
# ============================================================
#  integrity.sh —— 配置完整性 / 正确性审计 + 一键还原
# ------------------------------------------------------------
#  两个子命令：
#
#   audit   只读审计。逐项核对「Scene 侧配置 + 模块侧数据」是否与基线一致，
#           输出机器可读的 K=V 行，前端渲染成「注错文件清单」（只列有问题的）。
#           校验维度：
#             · 文件是否存在（缺失）
#             · md5 是否被外部改动（被改）
#             · JSON / shell 语法是否还能解析（损坏）
#             · 身份键是否还是我们的（manifest 的 name/version，被 Scene 顶替）
#             · 频率 preset 是否齐全（@cpu_freq ≥ 24）
#
#   restore 一键还原。把**当前 scheme** 的内置基线重新灌进 Scene，等价于
#           「传递调度」，但语义更直接：数据坏了 → 一键还原到模块基线。
#
#  用法
#     integrity.sh audit
#     integrity.sh restore [scheme]
# ============================================================
MODDIR="${MODDIR:-/data/adb/modules/SceneO3Tuner}"
. "$MODDIR/lib/util.sh"

CFG_ROOT="${MODDIR}/Config/4+4+2/O3"

# ------------------------------------------------------------
#  基线：Scene files/ 下「必须存在且内容由我们决定」的文件
# ------------------------------------------------------------
#  格式: <文件名>|<中文名>|<校验方式>
#    md5  = 必须与方案目录里的那份逐字节一致（被改 / 缺失都报错）
#    json = 存在 + 可解析（Scene 运行时会重写，内容不比对 md5）
#    soft = 存在即可（Scene 自己维护的内容，只查有没有）
BASELINE_MD5="profile.json|Scene 调度主配置
manifest.json|Scene 配置身份
_Apps.json|应用模式配置
_Games.json|游戏模式配置
_Camera.json|相机调度配置
_ELP.json|能效等级配置
powercfg.sh|平台调优脚本"

BASELINE_JSON="_Apps.json|应用模式配置
_Games.json|游戏模式配置
_Camera.json|相机调度配置
_ELP.json|能效等级配置"
# profile.json / manifest.json 也必须是合法 JSON
BASELINE_JSON="${BASELINE_JSON}
profile.json|Scene 调度主配置
manifest.json|Scene 配置身份"

# 模块自己维护的数据（Scene 不碰，必须与我们内存里的基线一致）
MOD_FILES="app_assign.tsv|应用线程分配
app_templates.tsv|应用线程档位表
game_assign.tsv|游戏线程分配
game_templates.tsv|游戏线程档位表"

json_ok() {
    local f="$1"
    [ -s "$f" ] || return 1
    # 三种解析器任一可用即可；都没有就退回「首尾字符」粗检，避免误报
    if command -v jq >/dev/null 2>&1; then
        jq -e . "$f" >/dev/null 2>&1
        return $?
    fi
    if command -v python3 >/dev/null 2>&1; then
        python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$f" >/dev/null 2>&1
        return $?
    fi
    if command -v python >/dev/null 2>&1; then
        python -c 'import json,sys; json.load(open(sys.argv[1]))' "$f" >/dev/null 2>&1
        return $?
    fi
    # 粗检：首字符必须是 { 或 [，末字符必须是对应的闭合符
    local first last
    first=$(head -c 1 "$f" 2>/dev/null)
    last=$(tail -c 1 "$f" 2>/dev/null)
    case "$first" in
      '{') [ "$last" = "}" ] && return 0 || return 1 ;;
      '[') [ "$last" = "]" ] && return 0 || return 1 ;;
      *)   return 1 ;;
    esac
}

md5of_f() { [ -f "$1" ] && md5of "$1" || echo ""; }

# 「缺失」的成因判别 —— 目录级前置检查
# 为什么需要：11 项全报「缺失」时，光看清单分不清是
#   ① 文件真被删了（Scene 身份校验会删我们那 7 个）
#   ② 路径/挂载写错（整个目录都不在）
#   ③ 权限 / SELinux 读不到目录
# 这三种的处置完全不同，所以把成因直接写进 BAD 行的 detail 字段
# （前端 app.js 会把这个字段渲染到清单第 4 列，无需改前端）。
# 注意：只用 test 内建，不 fork —— 本机单次 fork/exec ≈ 20~30ms，11 项会很痛。
miss_why() {   # $1=所在目录  $2=文件名
    local d="$1"
    if [ ! -d "$d" ]; then
        echo "★目录不存在：$d ← 路径/挂载问题，不是文件被删"
        return
    fi
    if [ ! -r "$d" ] || [ ! -x "$d" ]; then
        echo "★目录不可读/不可进入：$d ← 权限或 SELinux 问题"
        return
    fi
    echo "目录可读（$d）但确实无此文件 ← 被删除或从未写入"
}

# ============================================================
#  审计
# ============================================================
do_audit() {
    local scheme; scheme=$(active_scheme); [ -z "$scheme" ] && scheme="sweet_bal"
    local src="${CFG_ROOT}/${scheme}"

    echo "SCHEME=${scheme}"
    echo "SRC_OK=$([ -d "$src" ] && echo 1 || echo 0)"
    # 路径自检（终端里跑 audit 时能直接看到审计到底在读哪儿）
    echo "DIR_SCENE=${SCENE_DIR}|$([ -d "$SCENE_DIR" ] && echo 存在 || echo 不存在)|$([ -r "$SCENE_DIR" ] && [ -x "$SCENE_DIR" ] && echo 可读 || echo 不可读)"
    echo "DIR_WEBUI=${WEBUI_DIR}|$([ -d "$WEBUI_DIR" ] && echo 存在 || echo 不存在)|$([ -r "$WEBUI_DIR" ] && [ -x "$WEBUI_DIR" ] && echo 可读 || echo 不可读)"

    local bad=0 checked=0 line fname cn md5want md5now d

    # ---- 1) Scene 侧：md5 必须与基线一致 ----
    BAD_SEEN=""      # 已报过异常的文件名（每行一个），用于后面去重
    local IFS='
'
    for line in $BASELINE_MD5; do
        fname="${line%%|*}"; cn="${line#*|}"
        checked=$((checked+1))
        md5want=$(md5of_f "${src}/${fname}")
        md5now=$(md5of_f "${SCENE_DIR}/${fname}")
        if [ ! -f "${SCENE_DIR}/${fname}" ]; then
            echo "BAD=${fname}|${cn}|缺失|$(miss_why "$SCENE_DIR" "$fname")"
            bad=$((bad+1)); BAD_SEEN="${BAD_SEEN}${fname}
"
        elif [ -n "$md5want" ] && [ "$md5now" != "$md5want" ]; then
            echo "BAD=${fname}|${cn}|被改|与模块基线不一致（可能被 Scene 或其他模块改写）"
            bad=$((bad+1)); BAD_SEEN="${BAD_SEEN}${fname}
"
        fi
    done

    # ---- 2) Scene 侧：JSON 必须还能解析 ----
    #   ⚠ 一个文件可能既「被改」又「损坏」（内容变了 + 语法也坏了）。
    #     对用户来说「损坏」是更严重、更该先修的结论，所以若该文件已在第 1 轮
    #     报过「被改」，这里就不再重复报一次 —— 清单里一个文件只出现一次。
    for line in $BASELINE_JSON; do
        fname="${line%%|*}"; cn="${line#*|}"
        [ -f "${SCENE_DIR}/${fname}" ] || continue   # 缺失已在上一轮报过
        if ! json_ok "${SCENE_DIR}/${fname}"; then
            if [ -n "$BAD_SEEN" ] && printf '%s\n' "$BAD_SEEN" | grep -qx "$fname"; then
                continue
            fi
            echo "BAD=${fname}|${cn}|损坏|JSON 解析失败（文件被写坏）"
            bad=$((bad+1))
        fi
    done

    # ---- 3) 身份键：manifest 必须还是我们的 ----
    local mf="${SCENE_DIR}/manifest.json" ma mv
    if [ -f "$mf" ]; then
        ma=$(sed -n 's/.*"author"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$mf" 2>/dev/null | head -1)
        mv=$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$mf" 2>/dev/null | head -1)
        if [ -z "$ma" ] || [ -z "$mv" ]; then
            echo "BAD=manifest.json|Scene 配置身份|损坏|读不到 author/version（Scene 会判定调度未安装）"
            bad=$((bad+1))
        fi
    fi

    # ---- 4) 频率 preset 条数 ----
    local np; np=$(grep -c '@cpu_freq' "${SCENE_DIR}/profile.json" 2>/dev/null)
    np="${np:-0}"
    echo "PRESET_N=${np}"
    if [ "$np" -lt 24 ] && [ -f "${SCENE_DIR}/profile.json" ]; then
        echo "BAD=profile.json|Scene 调度主配置|缺频率|@cpu_freq 只有 ${np} 条（应 ≥24）"
        bad=$((bad+1))
    fi

    # ---- 5) Scene 偏好里的两个关键开关 ----
    local ssrc dyn
    ssrc=$(scene_source_get); dyn=$(scene_dyn_get)
    echo "SCENE_SOURCE=${ssrc}"
    echo "SCENE_DYN=${dyn}"
    [ "$ssrc" = "$SCENE_SOURCE_WANT" ] || echo "BAD=global.xml|Scene 配置来源|未启用|scene_profile_source=${ssrc:-空}（应为 ${SCENE_SOURCE_WANT}）"
    [ "$dyn" = "true" ] || echo "BAD=global.xml|Scene 性能调节|未开启|dynamic_control=${dyn:-空}（应为 true）"

    # ---- 6) 模块侧数据表 ----
    for line in $MOD_FILES; do
        fname="${line%%|*}"; cn="${line#*|}"
        checked=$((checked+1))
        if [ ! -f "${WEBUI_DIR}/${fname}" ]; then
            echo "BAD=${fname}|${cn}|缺失|$(miss_why "$WEBUI_DIR" "$fname")"
            bad=$((bad+1))
        fi
    done

    # ---- 7) threads.json 规则数 ----
    local nr; nr=$(grep -c '"friendly"' "${SCENE_DIR}/threads.json" 2>/dev/null)
    echo "THREADS_RULES=${nr:-0}"

    echo "CHECKED=${checked}"
    echo "BAD_N=${bad}"
    [ "$bad" = "0" ] && echo "OK 全部 ${checked} 项配置与基线一致" || echo "WARN 发现 ${bad} 项异常"
    return 0
}

# ============================================================
#  一键还原
# ============================================================
#  复用 profile_sync.sh 的 push 路径 —— 那是唯一经过设备验证的写入链路
#  （force-stop → 灌文件 → 置来源 → 校验 → 重启 → 复核 md5）。
do_restore() {
    local scheme="$1"
    [ -z "$scheme" ] && scheme=$(active_scheme)
    [ -z "$scheme" ] && scheme="sweet_bal"

    echo "▶ 一键还原：把 ${scheme} 的内置基线重新灌进 Scene"
    sh "$MODDIR/Scripts/4+4+2/O3/profile_sync.sh" push "$scheme"
    local rc=$?

    # push 只还原 Scene 侧；模块侧的数据表用内置生成器补齐缺失项
    #   ⚠ 模板表没有 Config 种子文件（由 seed_*_templates 就地生成），
    #     所以要「先删掉空/坏的，再让生成器重建」，不能 cp 一个不存在的源。
    local f
    for f in app_templates.tsv game_templates.tsv; do
        if [ ! -s "${WEBUI_DIR}/${f}" ]; then
            rm -f "${WEBUI_DIR}/${f}" 2>/dev/null
            case "$f" in
              app_templates.tsv)  seed_app_templates ;;
              game_templates.tsv) seed_game_templates ;;
            esac
            [ -s "${WEBUI_DIR}/${f}" ] && echo "· 已重建模块数据表 ${f}"
        fi
        chmod 0666 "${WEBUI_DIR}/${f}" 2>/dev/null
    done

    # 线程分配表为空 = 用户没配过，不算损坏，但补个空文件避免读取出错
    for f in app_assign.tsv game_assign.tsv; do
        [ -f "${WEBUI_DIR}/${f}" ] || : > "${WEBUI_DIR}/${f}" 2>/dev/null
        chmod 0666 "${WEBUI_DIR}/${f}" 2>/dev/null
    done

    # 档位表迁移 v10（档位与模式同名 + 核位重写）。
    # ⚠ 先删幂等标记：这是「一键还原」，语义上就是要**强制重写**档位表回模块基线
    #   （前端没有编辑档位核位的入口，所以重写不会冲掉用户的自定义）。
    rm -f "$TPL_V10_MARK" "$TPL_V11_MARK" "$TPL_V12_MARK" 2>/dev/null
    migrate_templates_v10
    migrate_templates_v11
    migrate_templates_v12

    # 重建线程分配（Scene 配置刚变过）
    local out; out=$(gen_threads_from_scene 2>&1)
    echo "· $out"

    if [ "$rc" = "0" ]; then
        echo "OK 一键还原完成"
    else
        echo "ERR 还原过程中有问题（见上方输出）"
    fi
    return $rc
}

# ============================================================
case "$1" in
  audit)   do_audit ;;
  restore) shift; do_restore "$1" ;;
  *)
    echo "用法: integrity.sh audit | restore [scheme]"
    exit 1
    ;;
esac
