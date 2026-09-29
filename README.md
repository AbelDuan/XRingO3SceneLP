# SceneO3LP · 玄戒O3 Scene 调度方案（O1 官方蓝本 LP 低耗移植）

## ⚠ v1.5 重大变更：改用「外部配置」通道（2026-09-29 实机定论）

**旧机制（v1.4）已失效**：本机 Scene（`N1 2026.09 Alpha7`，2026-09-27 安装）**不再接受
`scene_profile_source=SOURCE_SCENE_ONLINE`** —— 写入后会被 App **主动清除**（实测矩阵：
`BANANA` / `SOURCE_SCENE_CUSTOM` / `SOURCE_SCENE_LP` / `SCENE_HP` / `SCENE_EP` /
`SCENE_IMPORT` / `SCENE_ACTIVE` 全部保留，**唯独 `SOURCE_SCENE_ONLINE` 被清**）。
这就是调节页一直显示「未知 / 未选择」且「性能调节」打不开的真因；早期 `SceneO3Tuner`
（v16/v17 线）依赖的正是这个值，其经验来自 09-16 之前的 Scene 版本。

**现行通道 = 官方文档的「外部配置（第三方调度）对接」**：

| 项 | 值 |
|---|---|
| 脚本 | `/data/powercfg.sh`（非空即视为「已安装配置」；Scene 以 `sh /data/powercfg.sh <mode>` 调用） |
| 描述 | `/data/powercfg.json`（version/versionCode/author/features） |
| 来源 | `global.xml: scene_profile_source = SOURCE_OUTSIDE` |
| 开关 | `global.xml: dynamic_control = true`（「性能调节」总开关） |

判据：`outsideConfigInstalled()` 为真 → `modeConfigCompleted()` 直接返回 true →
「性能调节」可开启。实机验证：push 后 14 秒复核 `source=SOURCE_OUTSIDE dynamic=true`
（App 冷启动后不回滚），调节页配置位置显示 **「外部来源」**、开关为 **开启**，
Scene 启动时确实执行了 `sh /data/powercfg.sh init`（脚本日志
`/data/local/tmp/scene_o3_lp.log` 可查）。

**四档频率由脚本按 mode 下发**：`tools/gen_powercfg.py` 从 `Config/profile.json`
（sweet_eco 完整方案集）生成 `Config/powercfg.sh`，逐档实测结果：

| Scene 模式 | policy0 (小核) | policy4 (中核) | policy8 (大核) |
|---|---|---|---|
| powersave 省电 | 417792~912000 | 556800~1142400 | 1113600~2198400 |
| balance 流畅 | 417792~1353600 | 556800~1651200 | 1113600~2860800 |
| performance 性能 | 672000~1785600 | 835200~2131200 | 1497600~3398400 |
| fast 极速 | 1065600~2092800 | 1142400~2419200 | 2044800~3648000 |

**辅助限速器（Scene 的 `@limiter`）档级映射 —— 四档各自绑定**：

| 档位 | 频率上限（小/中/大核） | 限速器 |
|---|---|---|
| 省电 | **417792~1209600 / 556800~1651200 / 1113600~2553600**（下限=内核最低，上限抬高保流畅） | `@limiter p1` |
| 流畅 | **417792~1939200 / 556800~2419200 / 1113600~2371200**（下限=内核最低） | `@limiter p2` |
| 性能 | 2745600 / 3148800 / 3955200 | `@limiter p3` |
| 极速 | **3148800 / 3686400 / 4358400（三簇满频）** | **`@limiter NONE`（解绑，完全拉满）** |

- 限速器档级本体（p1/p2/p3/inactive/idle 的三簇 min/max/margins）在 `Config/profile.json`
  的 `features.limiter.limiters`，开关在 `Config/features/limiter.conf`（`limiter_apps=1` /
  `limiter_games=1`），两者都会随 push 灌入 Scene。
- ⚠ **在 `SOURCE_OUTSIDE`（外部配置通道）下，Scene 的特性/限速器 UI 不展示这套配置**，
  但 daemon 实际在读并生效——实测 12 秒采样：`p4` 上限在 2294400↔2419200、
  `p8` 在 2044800↔2371200 之间每秒多次变化（低值=限速器压，高值=该档上限）。
  「UI 不显示」是外部通道的显示差异，不是功能缺失。
- ⚠ 限速器会在 app 场景把上限动态压低；**极速档已 `@limiter NONE` 解绑**，选极速即满频。

**限速器档级（v1.6.4 起按 SceneLP 原版移植，取自 `sweet_perf` 校准值）**：

| 档级 | 小核 min~max | 中核 min~max | 大核 min~max | 备注 |
|---|---|---|---|---|
| p1 | 672000~1209600 | 835200~1651200 | 1113600~2553600 | 带 `core_ctl`；省电档绑定 |
| p2 | 912000~2092800 | 1142400~2544000 | 1497600~3523200 | 流畅档绑定 |
| p3 | 1065600~2745600 | 1142400~3148800 | 1497600~3955200 | 性能档绑定 |
| inactive | 417792~1497600 | 835200~1804800 | 1113600~2707200 | 带 `core_ctl` |
| idle | 417792~912000 | 835200~1296000 | 1113600~2198400 | 带 `core_ctl` |

- 另有 `_whitelist.json`（豁免档）：白名单应用执行 `@limiter NONE` + `@cpu_freqs_max` + `@cpuset`，
  即「白名单里的应用不受限速器压制」。
- **行为实测（2026-09-29 12:02，v1.6.4 刷入后）**：上限在 `1641600/1804800/2044800` 与
  `1939200/2419200/2371200`（流畅档上限）之间**每秒多次跳变** —— 即限速器持续读取当前频率
  并动态改写 `scaling_max_freq` 的上限，与设计一致。
- ⚠ 在 `SOURCE_OUTSIDE`（外部配置通道）下，Scene 的特性/限速器 **UI 不展示**这套配置，
  但 daemon 实际读取并生效（上面的采样即证据）。

**一个名字、一个下限（v1.6.3.4）**：

- **方案名 = `Abel`**：改的是 `Config/manifest.json` 的 `author`（Scene 用它作「配置身份」，
  push/action 状态行会打印 `配置身份 : Abel'LP`）。`action.sh` 已改为**实读 manifest**，不再写死。
  ⚠ `调节页/概览页` 上那个 **`外部来源`** 是 Scene 对 `SOURCE_OUTSIDE` 的**硬编码文案，配置改不了**
  （要改只能走已废弃的内部方案通道），能改的「配置名字」就是上面的方案身份。
- **三簇下限锁在内核最低**：四档 preset 的 `@cpu_freq min` 与**全部限速器档级**的 `cpus[].min`
  统一为 `417792 / 556800 / 1113600`；生成的外部脚本在每个档位写完后执行 `lock_min`
  （把三个 `scaling_min_freq` 置 `0444`），避免被动态抬升。
- **实测（v1.6.3.6，静置 20 秒逐秒采样）**：`p0/p4/p8` 下限 **20/20 全部** 为
  `417792 / 556800 / 1113600`，触摸 3 次后仍为内核最低。概览页读数
  `417~1641MHz / 556~1804MHz / 1113~2044MHz`。
- **RCA：下限为什么会被抬（2026-09-29）** —— 静置时下限周期性跳到 `1065600 / 1142400`：
  ① `kill scene-daemon` 后跳动立即停止 ⇒ 写入者是 **Scene 自身**（不是 thermal / perf 厂商侧）；
  ② `grep -rl 1065600 files/` ⇒ 命中 `profile.json` 与 `_Games.json`；
  ③ `profile.json` 里该值位于 **`performance_inactive` / `fast_inactive` 的 `@cpu_freq` 下限** ——
  上一轮只改了四档 **active** 预设的下限，**漏了 inactive（前后台切换时下发）与 `_Games.json`（游戏档）**。
  ⇒ 修复：四档 `_active` + 四档 `_inactive` + 全部限速器档级 + `_Games.json` 共 6 处的 `@cpu_freq min`
  统一为内核最低；生成脚本在每个档位写完后执行 `lock_min`（三簇 `scaling_min_freq` 置 `0444`）。
  **经验：Scene 的下限有 4 类写入点（档位 active / inactive、限速器档级、`_Games.json`、系统 boost），
  只改一处必漏。**

**官方切档入口（源码级实证，2026-09-29）** —— Scene 的档位应用链：
- **常驻通知 → 点击内容 → `ReceiverSceneMode` → `FloatPowercfgSelector`（悬浮档位选择器，五个按钮：
  省电 / 默认(均衡) / 游戏(性能) / 极速 / 忽略）→ `switchMode()` → `modeSwitcher.executePowercfgMode(selectedMode, packageName)`**
- 另有官方入口：`am start -n com.omarea.vtools/.activities.ActivityPowerModeTile`（QS 磁贴的启动器，
  它 internal 就是 `FloatPowercfgSelector(...).open(pkg)`）；
  `am broadcast -a com.omarea.scene_mode.ReceiverSceneMode --es packageName <包名>`（= 通知内容点击的同一条 intent）
- ⚠ 该选择器是 **`TYPE_APPLICATION_OVERLAY` + `NOT_FOCUSABLE`** 窗口：**uiautomator / input 自动化抓不到、
  点不到**（本机实测窗口 Requested 468×30、节点 dump 为空），但**人工可以正常弹出并切换四档**
  （用户 2026-09-29 实测确认）——所以「自动化测不出档位调用」≠「Scene 不调用」。
- ✅ **端到端实证（2026-09-29 11:37:48）**：用户在「通知 → 悬浮选择器」把当前应用
  （`top.funcun.dshfolk`）设为**极速**，同一秒脚本日志出现 `[fast]`，`powercfg.xml` 写入
  `top.funcun.dshfolk=fast`；随后离开选择器、前台应用变化，又出现 `[powersave]` 调用 ——
  证明 Scene 在 **应用切换 / 档位变更** 时都会执行 `sh /data/powercfg.sh <mode>`，
  **外部分发链路完整可用**（app-side `executePowercfgMode` → 我们的脚本）。
- `push.sh` 的 `apply_default_mode()` 仍保留作兜底：推送/开机时按 Scene 当前默认档
  （`powercfg.xml` 的 `"*"`）主动应用一次，保证装完即生效。

**与 Scene 官方最新 O1 调度（`helloklf/scheduler-n1` `1.0/hp/o1_asic`）对照**：
- 官方 `reset` 首项是 `["@xring_reset"]`（XRing 专用清理函数）——**装机版 Scene 无此函数**
  （dex/资源均无 `xring_reset`），照搬=空转，故不采用；待 Scene 更新后再评估。
- 官方用 `@cpu_freqs_max/@cpu_freqs_min` 函数式写法——本版 Scene 的字符串表里**不存在**
  这些函数名，未证实支持，故继续用实测有效的裸路径写入。
- 官方 `_whitelist.json`（豁免档）与我们的 `_ELP.json` 属同族自定义文件，保留现状。
- 官方外部配置通道（`powercfg.sh` + `powercfg.json`）与我们现行方案一致 ✅

**不再做、也不推的东西**：`threads.json` / `threads_games.json`（线程/核心分配 = 线程绑定）、
模块侧守护与落核脚本——按用户要求本模块只保留「频率配置 + 配送到 Scene」。

**⚠ 另一个被证伪的旧结论**：`files/profileInstalled` **不是** Scene 的方案安装标记，
而是 **AndroidX ProfileInstaller** 的基线 profile 标记（App 启动日志
`D/ProfileInstaller: Installing profile for com.omarea.vtools`）。v1.4 删它「逼 Scene 重装」
属误判，v1.5 已不再触碰。


KernelSU 模块。**无 WebUI**——只把写死的调度配置灌进 Scene（`com.omarea.vtools`），
调度全部由 Scene 引擎下发（governor xres + limiter 辅助调速器）。

- 数值蓝本：**v17.1 四方案**（`sweet_eco/bal/perf/hq`，玄戒 O3 能耗/能效对照实验校准）
- 结构蓝本：`helloklf/scheduler-n1` `1.0/o1_asic`（O1 官方 schema 同族，Scene N1 实战验证）
- 目标：Xiaomi 18 Fold（`lhasa` / `xring_o3_asic`「玄戒O3」），Scene N1 2026.09 Alpha7+
- 原则：**模块只传话，调度全靠 Scene**

## 四档频率（Scene 模式 ← v17.1 方案，直接采用能效校准值）

| Scene 模式 | 来源方案 | active 上限 [小核 L / 中核 M / 大核 P] |
|---|---|---|
| 省电 powersave | sweet_eco | 912000 / 1142400 / 2198400 |
| 流畅 balance | sweet_bal | 1939200 / 2419200 / 2371200 |
| 性能 performance | sweet_perf | 2745600 / 3148800 / 3955200 |
| 极速 fast | sweet_hq | 3148800 / 3686400 / **4358400（满频）** |

## 辅助调速器 = limiter（Limited），不是 FAS

Scene 的**场景化动态限频器**：随时根据当前频率设置新的频率上限。
- `manifest.features.limiter = true` 开启；运行时级 `p1/p2/p3/inactive/idle`
  （`profile.json → features.limiter.limiters`，每级三簇 max/min/margins）取自 **sweet_perf**
  —— p3 大核 3955200 不压制性能档；游戏时 `@limiter NONE` 自动关闭，不影响极速满频
- FAS 特性保持 `fas: true`（游戏帧率对齐），但 LP 档的频率兜底靠的是 limiter

## 与 v17.1/O1 蓝本的关系

- `@cpuset` 沿用 v17.1 实战写法（4 参数 `["0-3","0-3","0-9","0-9"]`）
- `@cpu_freq cpuN min max`、`xres` 直写行、`_ELP.json` 等均为 v17.1 实战验证过的同族 schema
- O1 蓝本仅提供结构参照（其频率是 O1 档位，不适用于 O3）；转换器
  `tools/o1_to_o3.py` 保留作溯源，**生成配置以 `tools/merge_v17.py`（四方案合并器）为准**

## 与蓝本的差异（移植规则）

| 项 | O1 官方 | O3 移植 |
|---|---|---|
| 簇 | 4 簇 cpu0/cpu2/cpu4/cpu8（2+2+4+2） | 3 簇 policy0(0-3)/policy4(4-7)/policy8(8-9) |
| 频率 | O1 档位表 | **比例映射**（f/maxO1 → ×maxO3）+ snap 到 O3 真实档位 |
| max 上限合成 | c0、c1 两小簇 | 小核取 c1（宽松侧）；min 下限取 c0（保守侧） |
| target_loads | 4 行 | 3 行（小核行取 c1，断点按比例换算） |
| cpuset | `0-1/0-3/2-7/2-9` | `0-3/0-7/0-9` 递进域 |
| perfmgr/migt/game_opt | 有 | **删**（O3 无节点，实测 2026-09-28） |
| powercfg.sh | 温控解绑+migt+core_ctl+joyose | 温控解绑+core_ctl+joyose（去 migt 段） |
| manifest.version | `HP(Developer Test)`（O1 原版） | `LP`（**纯短词**——v17.1 实战验证 Scene 调节页只认短词命名） |

O1 频率表原文见 `docs/o1_reference/xring_o1_notes.txt`；转换器 `tools/o1_to_o3.py` 可复现全部配置。

## LP 模式与辅助调速器（limiter）

Scene 低功耗档静态上限压得低，频率兜底由 **limiter（Limited，场景化动态限频器）** 负责：
随时根据当前频率设置新的频率上限。本方案已启用（`features.limiter=true` + 四级 limiters），
游戏时 `@limiter NONE` 自动关闭不做钳制。在 Scene 里保持「性能调节」开启即可。

## 刷入（不重启）

1. KSU 管理器 → 模块 → 从本地安装 `SceneO3LP-vX.Y.zip`（Release 里下载或 `python tools/build_zip.py` 打包）
2. ⚠ ksud 新装模块会放进 `modules_update/` 并打 `update` 标记（等重启生效）——**本机不能重启（临时 root）**，手动合并：
   ```sh
   su -c 'cp -af /data/adb/modules_update/SceneO3LP/. /data/adb/modules/SceneO3LP/
          rm -f /data/adb/modules/SceneO3LP/update
          chmod 0755 /data/adb/modules/SceneO3LP/{push.sh,service.sh,action.sh}'
   ```
3. 灌配置（任选其一）：
   - **KSU 模块卡片「执行」按钮**（action.sh：重灌 + 显示方案身份）
   - `su -c 'MODDIR=/data/adb/modules/SceneO3LP sh /data/adb/modules/SceneO3LP/push.sh manual'`
4. 模块会自动完成「清旧标记 + daemon 重读 + 拉起 Scene 重装」：`push.sh` 在灌完文件后**立刻删掉
   Scene 自维护的 `files/profileInstalled` 旧标记**（避免 Scene 因新旧标识不一致而删掉我们的配置），
   再 kill scene-daemon，并在非开机场景下 `am start` 把 Scene 拉前台触发重装。
   ⚠ **删掉后 Scene 需要 ~18 秒重建这个 24B 标记**，`push.sh` 已内置轮询等待；重建完成前
   调节页可能短暂显示「未选择 / 未知」，属正常过渡，打开 Scene 调节页等一会儿即可。

## 验证

```sh
# 重跑推送会打印 Scene 当前状态（身份/来源/性能调节/profileInstalled/是否缺文件）
su -c 'MODDIR=/data/adb/modules/SceneO3LP sh /data/adb/modules/SceneO3LP/push.sh manual'
# xres 参数是否被 Scene 下发（示例：中核 hispeed）
su -c 'cat /sys/devices/system/cpu/cpu4/cpufreq/xres/hispeed_freq'
```

Scene 调节页应显示：`Scene` + `Version: LP`（author=SCENE9 → 显示「Scene」，version 直接显示）。

### Scene 里仍显示「未知 / 未选择」时的排查顺序

「未知 / 未选择」= Scene 认为**没有选中任何已安装方案**，本质就是 `profileInstalled` 没匹配上。
启用链 = **manifest.json 身份 + global.xml 两键 + profileInstalled 重建**，缺一不可：

1. `files/manifest.json` 的 version 是否已是 `LP`（它就是 Scene 眼里「当前启用方案」的身份）
2. `global.xml` 两键：`scene_profile_source=SOURCE_SCENE_ONLINE`（唯一显示对+能启用的值）
   + `dynamic_control=true`（性能调节总开关）
3. **`files/profileInstalled` 是 Scene 自维护的 24B「已安装方案」标记**：
   - 它记录的标识要和 manifest 的 author/version 一致，Scene 才认；不一致会**直接删掉**我们的 profile.json/manifest.json（即「Scene 丢失配置」）
   - 所以 `push.sh` 升级时会先删掉它，让 Scene 当作"未安装"重新安装并重建 —— **重建要 ~18 秒**
   - 刚跑完脚本立刻看显示「未知」是正常的，等一会儿或打开 Scene 调节页即可变 LP
   - 手动排查：`rm -f /data/data/com.omarea.vtools/files/profileInstalled` 后打开 Scene 调节页
4. 若 6 个配置文件（profile/manifest/_Apps/_Games/_Camera/_ELP/powercfg）被 Scene 清掉 → `push.sh` 状态会报「缺失文件」，重跑脚本即可
5. 以上都正常还显示旧值 → 杀 Scene App 重开（UI 层缓存）
   ```sh
   su -c 'grep -o "scene_profile_source[^<]*<[^<]*" /data/data/com.omarea.vtools/shared_prefs/global.xml;
          cat /data/data/com.omarea.vtools/files/profileInstalled 2>/dev/null; echo;
          sed -n "s/.*\"version\"[^0-9]*\([0-9]*\).*/v=\1/p" /data/data/com.omarea.vtools/files/manifest.json'
   ```

## 文件结构

```
├── module.prop / service.sh（开机推送）/ action.sh（按钮）/ customize.sh / uninstall.sh
├── push.sh              配置推送（灌文件+global.xml 两键+删 profileInstalled+重启 daemon+轮询重建+状态报告）
├── Config/              写死的 O3 方案（profile/manifest/_apps/_games/_camera/_whitelist/powercfg/description）
├── tools/build_zip.py   一键打包（LF 规范化 + 755/644 权限位 + CRLF 终检）
├── tools/merge_v17.py   四方案合并器（★配置以它为准：eco/bal/perf/hq → Scene 四模式）
├── tools/o1_to_o3.py    O1→O3 比例转换器（溯源保留）
└── docs/o1_reference/   O1 官方原版（溯源对照）
```

## 已知注意点

- `ro.soc.model`（O3 上报 `O3`）≠ 方案目录名；本模块走**本地文件通道**
  （`scene_profile_source=SOURCE_SCENE_ONLINE` + `dynamic_control=true`），与在线方案识别无关
- `1.0/lp/` 官方**尚无 o1_asic** 目录（LP 待官方发布）；本方案的四模式（省电/流畅/性能/极速）
  已完整覆盖 LP 语义，FAS 链路见上节
- O3 的 `cpu_nolimit_temp` 保持默认 0 不写（O1 官方写 49500，O3 语义未验证，误写可能激活限流）
