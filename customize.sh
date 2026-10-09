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

# ---------- 艇长线程引擎（Aether）：部署二进制 + 展开拓扑配置 ----------
ui_print " "
ui_print "---------- 线程引擎（艇长 Aether）----------"
chmod 0755 "$MODPATH/Scripts/4+4+2/O3/aether/aether_ctl.sh" 2>/dev/null
chmod 0755 "$MODPATH/Scripts/4+4+2/O3/aether/aether-optext" 2>/dev/null
# 默认开启艇长线程引擎（用户要求：线程核心分配直接用艇长的方案）
if [ ! -f "${STATE_DIR}/aether.on" ]; then
    touch "${STATE_DIR}/aether.on" 2>/dev/null
    ui_print "- 默认启用艇长线程引擎"
else
    ui_print "- 保留原设置：艇长线程引擎 $([ -f "${STATE_DIR}/aether.on" ] && echo 开 || echo 关)"
fi
# 按本机拓扑把语义占位符展开 → /sdcard/Android/Aether/threads.json
if sh "$MODPATH/Scripts/4+4+2/O3/aether/aether_ctl.sh" deploy 2>&1; then
    ui_print "- 艇长线程配置已按本机拓扑部署"
else
    ui_print "- ⚠ 艇长线程配置部署失败（见上方原因）"
fi

# ---------- v18：模块自有初始化（不再与 Scene 交互）----------
#  频率 / 调度器 / 线程全部由本模块定义。安装时只做几件模块自己的事：
#    · 选默认全局模式（由当前方案推导，写 active_mode）并下发 QoS 频率；
#    · 把方案包内的 powercfg.sh 落地执行（平台 sysfs 调优）；
#    · 线程分配已由 aether_ctl.sh deploy 结束，这里仅提示。
SCHEME_INST=$(cat "$ACTIVE_FILE" 2>/dev/null)
[ -z "$SCHEME_INST" ] && SCHEME_INST="sweet_bal"
case "$SCHEME_INST" in
  sweet_eco)  _mode=powersave ;;
  sweet_bal)  _mode=balance ;;
  sweet_hq)   _mode=performance ;;
  sweet_perf) _mode=fast ;;
  *)          _mode=balance ;;
esac
mkdir -p "$STATE_DIR" 2>/dev/null
echo "$_mode" > "$ACTIVE_MODE_FILE" 2>/dev/null
ui_print "- 默认全局模式[${_mode}]已写入（active_mode）"

# 频率接管：按默认模式下发 PM QoS（O3 上唯一被强制执行的频率旋钮）
if sh "$MODPATH/Scripts/4+4+2/O3/apply_freq.sh" --mode "$_mode" 2>&1; then
    ui_print "- 频率已按模式[${_mode}]下发（PM QoS）"
else
    ui_print "- ⚠ 频率下发返回异常（详见模块日志）"
fi

# 平台调优：执行方案包内 powercfg.sh（core_ctl / sched_boost 等 sysfs）
_PC="$MODPATH/Config/4+4+2/O3/$SCHEME_INST/powercfg.sh"
if [ -f "$_PC" ]; then
    sh "$_PC" >/dev/null 2>&1
    ui_print "- powercfg.sh 已执行（方案 $SCHEME_INST）"
fi

# 线程分配已交由艇长引擎（Aether）处理
ui_print "- 线程分配：已交由艇长引擎（Aether）处理"

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
#
# 触发：installer.sh 在本脚本返回之后才 mktouch update 标记，所以这里轮询等
#   update 标记出现；同时只要 modules_update/<id> 带 module.prop 也视为可合并
#   （双触发，避免「只等 update 标记、后台进程中途被回收」导致漏合并）。
#   版本守门：仅当「暂存 versionCode > 当前服务 versionCode」才合并，绝不把旧/同版本回盖。
#
# ⚠ 即便这一步因后台进程被回收而没兜住，还有 webui.sh / action.sh 顶部的
#   「访问即自愈」（用户一开 WebUI 或按一次音量键即触发合并）作为兜底。
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

vcode(){ grep '^versionCode=' "$1" 2>/dev/null | head -1 | cut -d= -f2 | tr -d '\r'; }

i=0
while [ "$i" -lt 45 ]; do
    _trigger=0
    [ -e "$FIN/update" ] && _trigger=1
    [ -d "$UPD" ] && [ -f "$UPD/module.prop" ] && _trigger=1
    if [ "$_trigger" -eq 1 ]; then
        vc_u=$(vcode "$UPD/module.prop"); [ -z "$vc_u" ] && vc_u=0
        vc_m=$(vcode "$FIN/module.prop"); [ -z "$vc_m" ] && vc_m=0
        if [ "$vc_u" -gt "$vc_m" ] 2>/dev/null; then
            [ -d "$UPD" ] && cp -af "$UPD"/. "$FIN"/ 2>/dev/null
            if [ -f "$FIN/module.prop" ] && [ -f "$FIN/service.sh" ] \
               && [ -f "$FIN/webroot/index.html" ] && [ -f "$FIN/lib/util.sh" ]; then
                rm -f "$FIN/update" "$FIN/remove" 2>/dev/null
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
        # 暂存版本不高于当前：只清孤儿 update 标记（修开关灰），不动内容
        [ -e "$FIN/update" ] && rm -f "$FIN/update" 2>/dev/null
        echo "$(now) SKIP 暂存版本不高于当前，已清孤儿 update 标记" >> "$LOG"
        exit 0
    fi
    i=$((i + 1))
    sleep 1
done
echo "$(now) SKIP 等待 45s 未出现更新标记 / 暂存副本（可能不是 KSU zip 安装路径，无需处理）" >> "$LOG"
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
ui_print "ℹ 玄戒O3 调度工具箱（v18 · 模块自有，不依赖 Scene）= 三块"
ui_print "   ① CPU 频率 —— 模块 PM QoS 接管（全局 + 按 app 模式）"
ui_print "   ② 线程分配 —— 艇长(Aether)引擎，WebUI 可开关与自定义"
ui_print "   ③ 调度器   —— 方案 powercfg.sh（平台 sysfs 调优）"
ui_print "👉 模块 WebUI = 频率 / 线程 / 调度 三大块"
ui_print "👉 线程引擎默认开启（艇长的方案）；如需关闭在 WebUI「线程」页翻开关"
ui_print "👉 全局模式在 WebUI「模式」页切换；应用/游戏档位在「应用/游戏」页设置"
ui_print " "
ui_print "ℹ 频率完全由本模块下发（Scene 在玄戒O3 上不适配，已不再依赖）"
