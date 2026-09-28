# SceneO3LP · 玄戒O3 Scene 调度方案（O1 官方 HP 移植）

KernelSU 模块。**无 WebUI**——只把写死的调度配置灌进 Scene（`com.omarea.vtools`），
调度全部由 Scene 引擎下发（governor xres + limiter 辅助调速器）。

- 数值蓝本：**v17.1 四方案**（`sweet_eco/bal/perf/hq`，玄戒 O3 能耗/能效对照实验校准）
- 结构蓝本：`helloklf/scheduler-n1` `1.0/hp/o1_asic`（O1 官方 schema 同族，Scene N1 实战验证）
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
| manifest.version | `HP(Developer Test)` | `HP`（**纯短词**——v17.1 实战验证 Scene 调节页只认短词命名） |

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
4. Scene 会自动重读（daemon 被 kill 后 4~8s 自动拉起）

## 验证

```sh
# profile/manifest md5 与模块源一致、两开关正确
su -c 'MODDIR=/data/adb/modules/SceneO3LP sh /data/adb/modules/SceneO3LP/push.sh verify'
# xres 参数是否被 Scene 下发（示例：中核 hispeed）
su -c 'cat /sys/devices/system/cpu/cpu4/cpufreq/xres/hispeed_freq'
```

Scene 调节页应显示：`Scene` + `🌍 Version: LP`（author=SCENE9、version=LP 纯短词）。

## 文件结构

```
├── module.prop / service.sh（开机推送）/ action.sh（按钮）/ customize.sh / uninstall.sh
├── push.sh              配置推送（灌文件+global.xml 两键+重启 daemon+md5 校验）
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
