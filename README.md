# XRingO3SceneLP · 玄戒 O3 调度工具箱

> 面向 **小米玄戒 O3（`xring_o3_asic`，10 核 4+4+2）** 的 KernelSU 模块，
> 用来给 [Scene](https://github.com/omarea/Scene)（`com.omarea.vtools`）**补上它在本机没做到的两件事**：
> 线程绑核的**真正落地**，以及相机频率区间的**不塌缩**。
>
> 顺带把调频权限**交还**给 Scene —— 模块只做 Scene 做不到的部分。

[![Platform](https://img.shields.io/badge/platform-xring__o3__asic-blue)]()
[![Framework](https://img.shields.io/badge/framework-KernelSU%20%2F%20SukiSU-green)]()
[![Version](https://img.shields.io/badge/version-16.0-orange)]()
[![License](https://img.shields.io/badge/license-MIT-lightgrey)]()

---

## 目录

- [1. 这个模块解决什么问题](#1-这个模块解决什么问题)
- [2. 功能清单](#2-功能清单)
- [3. 实现原理（读懂这一章就懂整个模块）](#3-实现原理读懂这一章就懂整个模块)
  - [3.1 线程绑核为什么必须自己做](#31-线程绑核为什么必须自己做)
  - [3.2 cgroup 预算是硬上限（最关键的一条）](#32-cgroup-预算是硬上限最关键的一条)
  - [3.3 目标怎么解析：三级优先级](#33-目标怎么解析三级优先级)
  - [3.4 频率：模块不写，交回 Scene](#34-频率模块不写交回-scene)
  - [3.5 相机频率守护：三层根因](#35-相机频率守护三层根因)
- [4. 目录结构](#4-目录结构)
- [5. WebUI](#5-webui)
  - [5.1 游戏页的「FAS 调速器 → 设为 xres」](#游戏页的fas-调速器--设为-xresv15)
  - [5.2 应用页只显示「有前台界面」的应用](#应用页只显示有前台界面的应用v16)
- [6. 安装](#6-安装)
- [7. ⚠️ 需要注意的东西](#7-️-需要注意的东西)
- [8. 常见问题](#8-常见问题)
- [9. 调参与排障](#9-调参与排障)
- [10. 版本历史](#10-版本历史)
- [11. 已知限制与未验证项](#11-已知限制与未验证项)
- [12. 许可与致谢](#12-许可与致谢)

---

## 1. 这个模块解决什么问题

在玄戒 O3 上装 Scene，会遇到两件事 Scene 自己做不了：

### 问题一：Scene 不执行 `threads.json`

Scene 里有「单应用核心分配」，它会写出一份 `threads.json`。但在本机实测：

> 把 `com.tencent.mm` 设成「轻量·省电 (0-3)」→ 写 `threads.json`
> （`app_cpuset` 与 `cpuset/comm` 两种形状都试过）→ 重启 `scene-daemon` → 冷启动微信
> → **60 秒内主线程与工作线程的 `Cpus_allowed_list` 仍然是 `0-9`**。

用户看到的「先跑 `4-9`、过一阵才变 `0-3`」其实是 **Scene 自己对「前台/后台」的默认策略**，
不是我们规则的延迟生效。

→ **所以线程绑核由本模块自己做**。

### 问题二：相机一开就锁频

现象（用户原话）：**「打开相机瞬间频率会上升，但是会马上回落并严重限频。」**

实测三簇频率：

```text
启动前  cpu0=1939200/1939200  cpu4=1968000/1968000  cpu8=2044800/2044800
启动后  cpu0=417792/417792    cpu4=556800/556800    cpu8=1113600/1113600   ← min == max，区间塌缩
退相机  cpu0=417792/1785600   cpu4=556800/1804800   cpu8=1113600/2198400   ← 1 秒内恢复
```

`min == max == cpuinfo_min_freq` —— CPU 被**钉死在最低档**。详见 [§3.5](#35-相机频率守护三层根因)。

---

## 2. 功能清单

| 功能 | 实现位置 | 说明 |
|---|---|---|
| **线程绑核（核心）** | `Scripts/…/enforce_threads.sh` + `pin_cgroup.sh` | **v12 起改为 cgroup 分组落核**：整进程写进 `/dev/cpuset/SceneO3Tuner/<pkg>/{c0-3,c4-7}`，**新线程自动继承**，不必轮询追；幂等重跑 39ms（逐线程 `taskset` 要 226~244ms，只能当回退路径） |
| **三级目标解析** | `lib/util.sh` | 游戏名单 → Scene 模式映射 → 手动模板 |
| **档位（v10+）** | `lib/util.sh` `seed_app_templates()` | 档位与模式同名：**省电 / 均衡 / 性能 / 系统接管**（4 档，`fast` = 不绑核）；**默认不预设任何分配** |
| **从 Scene 导入档位** | `lib/util.sh` `import_scene_assign()` | 一次性导入，之后不再实时跟随（避免 Scene 一改就把你的分配冲掉） |
| **调度配置传递 / 备份 / 恢复** | `Scripts/…/profile_sync.sh` | 灌配置进 Scene、存档、回滚；推送前后字节级保存 `manifest.json` |
| **升级即覆盖（v15）** | `customize.sh` + `lib/util.sh` `SYNC_SKIP` | 升级时**直接覆盖** `profile.json`/`powercfg.sh`/`features/*.conf` 等模块设计文件，只保留 `threads*.json`（应用/游戏的线程表）；覆盖前自动备份 |
| **装完不用重启（v15.1 / v16.1 / v16.2）** | `customize.sh` | KSU 把更新放到 `modules_update/` 等重启合并时，安装脚本**自己就地合并**并将内容立即可用；并清掉 `disable` 标记（KSU 的启用状态就是 `/data/adb/modules/<id>/disable`）。⚠ **`update` 标记是 installer.sh 在 `. customize.sh` 返回之后才写的**，所以脚本里删它没用 —— v16.2 改成**落一个独立脚本 + `setsid` 后台拉起**，等 `update` 标记出现后再把它合并进 active、删标记、`rm -rf modules_update`、重拉 `ksud services`（全程不重启）。装完自动 `ksud services` 把守护拉起来 |
| **Scene · FAS 调速器一键设 xres（v15）** | `webui.sh fasxres` + 游戏页按钮 | Scene 的 FAS 调速器候选是它 APK 硬编码的，机器上选不到 `xres` → 直接写 `features/fas.conf` 的三个 `governor_*`，然后重启 scene-daemon |
| **应用页只显示有前台界面的应用（v16）** | `webui.sh launchables` + `manualApps()` | 按 `MAIN/LAUNCHER` 取「启动器能点开」的包（本机 487 → 169），避免把没有界面的系统服务也拉进来绑核；已配过档位的包仍显示；标题行有「含无界面」开关 |
| **调度守护** | `Scripts/…/guard.sh` | 目录权限、配置可写性、threads 重建、落核 |
| **WebUI** | `webroot/index.html` | 单文件，KernelSU 桥接，5 个页签 |
| **音量键操作菜单** | `action.sh` | 不装 WebUI 也能切换方案 / 修复配置 |
| **方案包 ×4** | `Config/4+4+2/O3/` | `sweet_eco` / `sweet_bal` / `sweet_perf` / **`sweet_hq`**（v16.3 新增 · 王者荣耀 / 金铲铲满画质专用） |
| **动态模块描述** | `lib/util.sh` `update_module_desc()` | 管理器里直接显示当前启用状态 |

> ⚠️ **v7.0 时代的两个相机条目已删除**（下表保留只是为了对照历史）：
> 「相机频率守护 `camera_freq_guard.sh`」与「相机档位看护」在 **v7 之后被移除** ——
> 新结构下（频率交回 Scene、`_Camera.json` 用 `["@limiter","NONE"]` 豁免）
> 守护读不到 `@cpu_freq` 会退回兜底表，**每次开相机反而写 3 个频率节点**，与设计矛盾。
> 现在的相机策略见 [§3.5](#35-相机频率守护三层根因)（已改写）与更新日志。

---

## 3. 实现原理（读懂这一章就懂整个模块）

### 3.1 线程绑核为什么必须自己做

见 [§1 问题一](#1-这个模块解决什么问题)。模块的做法是**不用 `threads.json` 驱动执行** ——
它照样生成 `threads.json`（让 Scene 侧数据自洽），但真正下发的是自己的落核器。

### 3.2 cgroup 预算是硬上限（最关键的一条）

本机是 **cgroup v1 cpuset**（挂载在 `/dev/cpuset`，`cpuset_v2_mode`）。
每个应用被放进一个组，**组里的 CPU 掩码就是它的硬预算**：

```text
/dev/cpuset/background       cpus = 0-3
/dev/cpuset/foreground       cpus = 0-9
/dev/cpuset/top-app          cpus = 0-9
/dev/cpuset/top-app/0-5      ← Scene 就是靠建这种子组做「应用核心分配」
```

`sched_setaffinity` **只能在预算之内收窄**。对 `background` 组里的进程
`taskset -p f0`（`4-7`）会直接返回 `EINVAL`（实测）。

所以 `enforce_threads.sh` 把目标核与当前组的预算**取交集**：

| 当前组 | 预算 | 行为 |
|---|---|---|
| `foreground` / `top-app` | `0-9` | 模板**完整生效**（这才是交互时真正需要的） |
| `background` | `0-3` | 系统本身已把整个应用限在 `0-3`，交集与现状一致 → **一条命令都不发** |

> 这也解释了「为什么后台应用看不到绑核变化」—— 那是设计，不是故障。

### 3.3 目标怎么解析：三级优先级

```text
① Scene 游戏名单里的包
      → 游戏页手动分配的模板
      （名单唯一权威来源 = Scene 的 games.xml 里 value="true" 的项，
        不能只看 game_assign.tsv 有没有这个包 —— 曾出现历史脏数据
        把几百个普通应用塞进去，会让整条映射失效）

② 在 Scene 里单独设过模式的包
      → 「模式同步线程」开关开启时，按模式自动映射：
            省电 powersave   → light  （轻量·省电）
            均衡 balance     → smooth （流畅日常）
            性能 performance → perf   （高性能）
            极速 fast        → 不覆盖（保留手动模板）
            igoned 等        → 不接管
        开关关闭时 → 回落 ③

③ 其余包
      → 应用页手动分配的模板
```

#### ⚠️ 「极速 → 不覆盖」≠「删除」

`MODE2TPL_fast` 是**空串**。v6.0 之前 `enforce_threads.sh` 的 awk 里写着：

```awk
if (t == "") { delete pick[p]; continue }   # ← 错：把包整个删掉
```

结果是：**凡在 Scene 里被设成 `fast` 的包，哪怕你在 WebUI 里手动给它套了模板，
也会被从目标表里彻底抹掉** —— 界面照常显示「已套高性能」，实际一条 `taskset` 都没发。

实测受害者：`com.android.camera`、`me.weishu.kernelsu`、`com.miui.backup`、
`com.miui.packageinstaller`、`com.android.updater`、`org.swiftapps.swiftbackup`、
`com.xiaomi.aicr`、`io.timepod.updater`。

**这就是「Scene 限制了对相机的调度」的真相。**

修法：空映射时 `continue`（保留手动模板，回落 ③），与前端 `effTpl()` 语义对齐。

> **一般化教训：前后端对同一个映射表的空值语义必须一致**，
> 否则同一份数据两边算出不同结果。v4.9 只修了前端，后端漏了，于是 bug 又多活了一个版本。

### 3.4 频率：模块不写，交回 Scene

**本模块不写任何频率节点。** 频率由 Scene 自己的模式 preset
（`profile.json` 里 `<mode>_active` / `<mode>_inactive` 的 `@cpu_freq`）下发 ——
那是 Scene 的正规通道，天然支持「按应用 / 按前后台」区分。

#### 本机频率旋钮的实测粘性

| 旋钮 | 粘得住 | 备注 |
|---|---|---|
| `cpuN/qos/max_freq` | ✅ | 唯一可靠的硬上限 |
| `cpuN/qos/min_freq` | ✅ | **抬下限 = 常驻功耗主因**（平台不改写它） |
| `scaling_max_freq` | ❌ | 写 `1968000` → 2s 后回 `556800` |
| `scaling_min_freq` | ❌ | 写了立刻打回 |
| `xres/*` | ✅ | 只调积极性，不能设硬上限 |
| **Scene 自己** | ❌ | **完全不写频率**（默认 `balance`→`performance` + 重启 daemon，20s 后一个值都没变） |

模块里保留 `apply_freq.sh`，但它已经**退化成一个幂等的「遗留 QoS 清理器」**：
只把 v2 时代留下的上下限还原成「不限频」，值本来就对就一个字节都不写。

> 保留而不是删掉的原因：`guard.sh` 与 WebUI 仍在调它，将来若要恢复模块限频，
> 把 v2 那段写回去即可。

#### `@cpu_freq` 的正确签名是 **4 参数**

```json
["@cpu_freq", "cpu0", "912000", "3148800"]
   宏名        cpu簇   min      max
```

**v6.3 及更早写成了 5 参数**（错）：

```json
["@cpu_freq", "policy0", "min", "417792"]     ← 错：多了 "min" 字段，且用了 policy0
```

Scene 解析这种错误格式时，会**把最后一个参数直接写进 `scaling_max_freq`**。
`strace` 实锤：`write(46, "417792", 6)`，而 `fd46 = policy0/scaling_max_freq`。

#### 写入顺序固定「先 min 后 max」

反过来 `max` 会被当时的 `min` 钳住（实测）：

| 实验 | 操作 | 结果 |
|---|---|---|
| C | **先写 min（低位）再写 max（高位）** | `min=417792 max=2899200` **保住** ✅ |
| C' | 先写 max（`min` 在高位） | `min=2899200 max=2899200` **塌缩** ❌ |

### 3.5 相机频率守护：三层根因

> ⚠️ **本节描述的是 v7.0 时代的做法（`camera_freq_guard.sh`），该脚本已在 v10+ 删除**，
> 只作为「当时为什么那样做」的记录保留。**当前做法**见
> [§10 版本历史 v10/v11/v14 行](#10-版本历史)：相机在 `_Camera.json` 里固定走
> `@preset fast_active` + `["@limiter","NONE"]`（豁免辅助调速器），模块不再写任何 CPU 频率，
> 也不再常驻看护。

#### 第一层：`@cpu_freq` 签名写错（模块自己带的 bug）

见 [§3.4](#34-频率模块不写交回-scene)。三个方案包的 `_Camera.json` **都带这个错误**，
所以换方案包也修不好。

#### 第二层：`@cpu_freq` 只落实 `max`，不落实 `min`

即便改成正确签名，实测 `scaling_min_freq` 仍会被压回该簇最低档：

```text
写 min=912000  →  立即读回 672000  →  2 秒后 417792
```

全进程扫描确认：**只有 `scene-daemon` 持有 `scaling_min_freq` 的写 fd**（3 个）。

#### 第三层：`xres` 让 `max` 跟随 `min` 塌缩

`min` 处于最低档时，`xres` governor 重算 policy，把 `max` 压到同值：

```text
cpu_frequency_limits: min=417792 max=417792  cpu_id=0
  => cpufreq_set_policy
  => handle_update          ← freq_qos work 回调
```

#### ★ 第四层（v7.0 才找到）：**模块自己也在破坏相机频率**

`guard.sh` 原本在**每次亮/息屏切换**时无条件跑 `apply_freq.sh`，
而它把 QoS 上限清成 `cpuinfo_max_freq`。

**问题在于 `cpuinfo_max_freq` 会跟着 thermal 限频 + 光感实时变化**：

| 场景 | `cpuinfo_max_freq` | 清成它意味着 |
|---|---|---|
| 白天（常温） | `3148800` | 上界 = 硬件最高，无害 |
| 夜间相机 / 强光下 | `1190400` | **上界被砍到 1/3，相机区间直接废掉** |

于是「开关屏幕」这个**和相机毫无关系**的动作，会把相机正在用的频率区间直接掀掉。

> 这也解释了为什么这个现象**有时重启后好一阵、有时一开相机就犯** ——
> 取决于触发那一刻 `cpuinfo_max_freq` 是多少。

**修法**：QoS 是**跨重启持久化**的，遗留值只在「模块刚升级 / 改过档位」时才存在，
不是每次亮息屏都会有 → 改成 **「只清一次」**（标记 `$STATE_DIR/qos_cleared`）：

```sh
if [ "$on" != "$ON_PREV" ]; then
    if [ ! -f "$QOS_CLEARED" ]; then       # $STATE_DIR/qos_cleared
        sh "$MODDIR/Scripts/4+4+2/O3/apply_freq.sh" >/dev/null 2>&1
        touch "$QOS_CLEARED"
    fi
    ON_PREV="$on"; FG_SIG=""
fi
```

> **一般化教训**：任何「还原 / 清残留」动作，先确认写入的目标值是不是一个**会漂移的量**。
> `cpuinfo_max_freq` / `cpuinfo_min_freq` / `scaling_available_frequencies` 末项**都会漂**；
> 只有从 `qos/*_freq` 或配置里读回来的才是稳定真源。

#### 修复：治本 + 兜底

**① 方案包修正（治本）** —— 三个 `_Camera.json` 全部重写：

```json
"state": {
  "active": [
    ["@cpu_freq", "cpu0", "912000",   "3148800"],
    ["@cpu_freq", "cpu4", "1142400",  "3686400"],
    ["@cpu_freq", "cpu8", "2044800",  "4358400"],
    ["/sys/devices/system/cpu/cpu0/cpufreq/scaling_min_freq", "912000"],
    ["/sys/devices/system/cpu/cpu4/cpufreq/scaling_min_freq", "1142400"],
    ["/sys/devices/system/cpu/cpu8/cpufreq/scaling_min_freq", "2044800"],
    ["/sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq", "3148800"],
    ["/sys/devices/system/cpu/cpu4/cpufreq/scaling_max_freq", "3686400"],
    ["/sys/devices/system/cpu/cpu8/cpufreq/scaling_max_freq", "4358400"]
  ]
}
```

- `@cpu_freq` 用**正确签名**（设上限）
- **追加裸 sysfs 路径**显式写 `scaling_min_freq` / `scaling_max_freq`
  （写法与 `_Games.json` 里 `target_loads` 的裸路径同源）
- **顺序固定：先 min 后 max**

**② 看护放进 `guard.sh`，不另开常驻进程**

`guard.sh` 的 WORK 分支**只在前台切换时**进入 —— 也就是「**进入相机的这一刻**」天然命中；
其余时间（包括整个相机期间）一次都不跑。**常驻轮询没有存在的必要。**

「是谁写坏的」判据 = **跑一次幂等的 `apply_freq.sh`，看它动不动手**：

| 结果 | 含义 | 动作 |
|---|---|---|
| 一个字节都没写 | 上界已是硬件最高 → 写它的是 **Scene** 自己（Scene 写的策略上界比硬件最高低） | **不覆盖**（守「交回 Scene」约定） |
| 写了 | 上界是**模块自己**留下的 | 写回相机档位 |

**③ `camera_freq_guard.sh` 降为兜底，并做功耗治理**

| | v1 | v2 |
|---|---|---|
| 间隔 | 1s | **2s** |
| 息屏 | 睡 10 轮（10s） | 睡 40 轮（80s） |
| **亮屏稳态 fork** | 每轮 `dumpsys`+`grep`+`sed` ≈ **3 个** | **0 个**（只内建 `read` 读 6 个节点） |
| 「谁在写」判定 | 每轮 | 判一次后缓存 |
| 判定为 Scene 接管后 | 仍每轮 fork 重判 | 直接睡，值对上自动解锁 |
| 写入策略 | 每轮单遍 | 一次校正内连写 3 遍（覆盖 ~2s 回写窗口）+ 5 轮冷静期 |

> **本机 fork 一个子进程要 10~40ms**，是这类守护功耗的唯一大头
> （`/proc` 下 1 万+ 线程，fork/exec 被放大 ~10 倍）。
> 所以目标是**把 fork 压到 0**。

**④ 档位现读，不写死**

三个方案包的相机档位**不一样**：

| 方案 | L min/max | M min/max | P min/max |
|---|---|---|---|
| `sweet_bal` | `912000 / 3148800` | `1142400 / 3686400` | `2044800 / 4358400` |
| `sweet_perf` | `912000 / 3148800` | `1142400 / 3686400` | `2044800 / 4358400` |
| `sweet_eco` | **`672000 / 2246400`** | **`835200 / 2294400`** | **`1497600 / 2860800`** |

所以守护**必须现读设备上正在用的 `_Camera.json`**（`camera_freq_load()`）——
写死就等于「用 eco 时把频率拉到 bal 的档位」，比不修还糟。
读不全就回退到 `sweet_bal`（最保守的一档），**绝不猜**。

#### 已排除的嫌疑（全部实证否定）

| 嫌疑 | 实测 |
|---|---|
| 温度 | 42~53 °C，trip 点全 ≥70 °C ❌ |
| `mi_thermald` | `cooling_device{0,1,2,5,7}/cur_state` **全 0** ❌ |
| IPA | `ipa_*_level_limit` 全开放，压 `ipa` 仍塌缩 ❌ |
| `perfflinger` | `qos` 区间正常，压 `qos` 无效 ❌ |
| `xres/pl` | `pl=0` 仍锁死 ❌ |
| `special_cpu_limit` | 写 1 无变化 ❌ |
| 节点权限 | `-rw-rw-r--` 可写，`rc=0` ❌ |

> ⚠️ **不推荐**写 `cpu_nolimit_temp=100000` 绕过温度限制 —— 会解除温度保护，**有硬件风险**。

---

## 4. 目录结构

```text
XRingO3SceneLP/
├── module.prop                          模块清单（id / version / action）
├── customize.sh                         安装逻辑（首次灌配置，之后继承）
├── service.sh                           开机：目录修复 → 生成线程分配 → 起守护
├── action.sh                            管理器「操作」按钮（音量键菜单）
├── uninstall.sh                         卸载清理
├── README.md
├── webroot/
│   └── index.html                       WebUI 单文件（约 127 KB）
├── lib/
│   └── util.sh                          公共库（1600+ 行）
│                                        路径常量 / 日志 / Scene pref / 频率预设缓存 /
│                                        档位 helper / 规则生成 / 可写性修复
├── Scripts/4+4+2/O3/
│   ├── webui.sh                         后端命令分发（前端唯一入口）
│   ├── enforce_threads.sh               ★ 线程落核器（模块核心）
│   ├── guard.sh                         ★ 调度守护 + 相机档位看护
│   ├── camera_freq_guard.sh             ★ 相机频率兜底守护
│   ├── apply_freq.sh                    幂等的遗留 QoS 清理器
│   ├── profile_sync.sh                  调度配置 传递 / 备份 / 恢复
│   └── set_scheme.sh                    方案应用
└── Config/
    ├── game_templates.tsv               游戏线程模板库
    ├── game_assign.tsv                  游戏 → 模板 分配
    ├── webui_model.seed.json            WebUI 种子数据
    └── 4+4+2/O3/
        ├── switch.sh                    Scene「自定义命令」入口
        ├── sweet_eco/                   省电方案包
        ├── sweet_bal/                   均衡方案包
        ├── sweet_perf/                  性能方案包
        └── sweet_hq/                    满画质游戏方案包（v16.3 · 王者/金铲铲）
            ├── manifest.json            配置身份（author + version）
            ├── profile.json             ★ 主配置（模式 preset，含 @cpu_freq）
            ├── _Apps.json / _Games.json / _Camera.json / _ELP.json
            ├── description.txt          方案说明（显示在音量键菜单里）
            ├── powercfg.sh              平台 sysfs 调优脚本
            ├── threads.json / threads_games.json
            └── features/
                ├── cpuset.conf / env.conf / fas.conf
                ├── limiter.conf / refresh_rate.conf
```

### 运行时数据目录

| 路径 | 内容 |
|---|---|
| `/data/adb/SceneO3Tuner/webui/app_templates.tsv` | 应用线程模板库（可直编） |
| `/data/adb/SceneO3Tuner/webui/app_assign.tsv` | 应用 → 模板 分配 |
| `/data/adb/SceneO3Tuner/webui/game_templates.tsv` | 游戏线程模板库 |
| `/data/adb/SceneO3Tuner/webui/game_assign.tsv` | 游戏 → 模板 分配 |
| `/data/adb/SceneO3Tuner/webui/settings.conf` | `mode_sync=0|1`、`debug=0|1` |
| `/data/adb/SceneO3Tuner/sceneo3.log` | 模块日志 |
| `/data/adb/SceneO3Tuner/active_scheme` | 当前方案 |
| `/data/adb/SceneO3Tuner/qos_cleared` | QoS 残留「只清一次」标记 |
| `/data/adb/SceneO3Tuner/camera_freq_guard.off` | 存在则禁用相机守护 |
| `/data/adb/SceneO3Tuner/backups/` | 调度配置备份（自动保留最近 3 份） |

### 后端命令一览

`sh Scripts/4+4+2/O3/webui.sh <cmd>`

```text
status                      模块状态（含 VER / SCENE_ID / SCENE_SOURCE / PROFILE_OK …）
mode / modeset              读 / 改当前模式
apps / apptpl / games       应用与游戏列表、模板
appmodes                    读 Scene 的模式表（A_=生效模式 / OWN_=显式设过）
syncmode / applymodes       按 Scene 模式同步线程分配
enforce / enforcep <pkg…>   落核（全量 / 定向）
freqapply / freqrestore     调 apply_freq.sh
profilepush / profilebackup / profilerestore / profilelist
live / scheme / log <n>
b64len / b64 / wbegin / wappend / wcommit     通用文件通道
```

---

## 5. WebUI

5 个页签：**概览 / 模式 / 应用 / 游戏 / 日志**。

| 板块 | 内容 |
|---|---|
| **概览** | 功能状态、调度配置（传递 / 备份 / 恢复）、配置身份 |
| **模式** | 4 档模式的**频率阶梯**（进/退前台各一组，读写 Scene 的真实 preset）、「频率跟随模式」开关 |
| **应用** | 模板卡（省电 / 均衡 / 性能 / 系统接管）、筛选、逐应用分配；**默认只显示有前台界面的应用**，标题行可切「含无界面」 |
| **游戏** | 同应用页，数据源是 Scene 的游戏名单；**顶部多一张「Scene · FAS 调速器」卡 + 「设为 xres」按钮** |
| **日志** | 查看 / 关闭模块日志 |

### 游戏页的「FAS 调速器 → 设为 xres」（v15）

Scene 的「FAS 调速器」下拉候选是**它 APK 里硬编码的**（非联发科 = `{performance, conservative,
sugov_ext}` ∩ 内核 + `auto`）—— 本机支持的 `xres` **根本选不到**。但 `features/fas.conf` 里的
`governor_little/middle/prime` 是自由的（Scene 不校验写入值），所以这个按钮直接写文件：

```
读现三值 → awk 改写（缺键补上）→ 写完自检（行数不能变少 + 三条 governor_ 必须在）
        → 写回并修权限 → 重启 scene-daemon → 回显「已设为 x…（原 y…）」
```

### 应用页只显示「有前台界面」的应用（v16）

`pm list packages` 那 480+ 个包里有一大半是**没有界面的系统服务/组件**，给它们绑核既没意义、
还可能把系统服务限制坏。所以启动时跑一次

```sh
cmd package query-activities --brief -a android.intent.action.MAIN -c android.intent.category.LAUNCHER
```

取「启动器能点开」的包（本机 **487 → 169**），应用页默认只列这些：

- **已配过档位的包照常显示**（否则老分配会变成「看不见但还在生效」，撤不掉）
- 拉不到清单（老系统没有 `query-activities`）→ **不筛选**，宁可多显示也不让列表变空
- 标题行右侧「**含无界面**」开关可临时显示全部，并在标题处提示「已隐藏 N 个无界面」

### 开关

| 开关 | 位置 | 默认 | 作用 |
|---|---|---|---|
| **自动切换**（模式同步线程） | 应用页顶部 | 关 | Scene 里单独设过模式的 app 自动按模式绑核 |
| **记录模块日志** | 日志页 | 关 | 守护写不写 `sceneo3.log` |
| 线程模板的具体数值 | 模式页 | — | 你改的就是生效值 |

> **频率同步没有开关，因为模块不写频率** —— 频率完全由 Scene 下发（[§3.4](#34-频率模块不写交回-scene)）。

### 交互约定

- 模板卡标题旁的 **ⓘ** → 展开该卡说明；标题行的 ⓘ → 展开全部
- 应用/游戏行内的两个标签**可点**：点「Scene ××」改该应用在 Scene 的模式，
  点「模板」改线程模板
- 单应用操作走**乐观更新**：先改本地状态 + 增量刷列表，再后台写盘（**不弹遮罩、不整页重绘**）

---

## 6. 安装

### 前置条件

- **机型**：玄戒 O3（`xring_o3_asic`），10 核 **4+4+2** 拓扑
- **环境**：HyperOS + **KernelSU / SukiSU**（需要 root 上下文常驻守护）
- **Scene**：需先装好 `com.omarea.vtools` 并**至少启动一次**

> 安装脚本会读 `/sys/devices/system/cpu/cpufreq/*/related_cpus` 判断拓扑。
> 不是 `4+4+2` / `4+4+1` 会给出警告，**但不会阻止安装**（不保证生效）。

### 步骤

1. 管理器（KernelSU / SukiSU）→ 模块 → **从本地安装** `SceneO3Tuner-v16.6-20260918.zip`
2. **装完即生效，不用重启** —— 安装脚本收尾会自己 `ksud services` 把守护拉起来
3. 模块 → **「打开」** 进入 WebUI

> **不需要重启**（v15.1 起）。KSU 有时会把新版本先放到 `/data/adb/modules_update/<id>/`
> 等你重启后再合并；本项目在 `customize.sh` 收尾**自己就地合并**并拉起服务，v16.2 进一步用一个**异步自愈脚本**等 KSU 写出 `update` 标记后再把它合并进 active 目录、删掉 `update`、`rm -rf modules_update` 并重拉服务。
> 如果你的设备是「临时越狱 root」（重启即掉 root），这条尤其重要。

### 四个方案怎么选（v16.3 起）

按音量键菜单（或 `switch.sh`）循环切换，当前方案存在 `/data/adb/SceneO3Tuner/active_scheme`：

| 方案 | 中文名 | 什么时候用 |
|---|---|---|
| `sweet_eco` | 极致能效 | 要续航、不在乎峰值帧率 |
| `sweet_bal` | 日常均衡 | **默认档**；不确定就用它，也是安全回退档 |
| `sweet_perf` | 性能甜点 | 放开我方限制 + 抬高下限换持续性能 |
| `sweet_hq` | 满画质游戏 | **王者荣耀 / 金铲铲 这类「帧率被游戏上限锁死」的 Unity 游戏、开高画质时** |

> `sweet_hq` 的非游戏部分与 `sweet_bal` **逐字节相同**，所以两档之间一点即可 A/B，
> 差异全部来自游戏态调优。
>
> ⚠ 用 `sweet_hq` 时，**这两款游戏在 Scene 里要设为「性能模式」** ——
> 本方案只改了性能模式这一档，设成均衡 / 省电不会生效。
>
> 判定是否该保留：同场景（同图、≥5 分钟）跑两轮，
> **5% Low ≥ 115 且平均功耗下降** → 保留；否则切回 `sweet_bal`。
> 预期省电 0.2~0.3W（5%~8%）。
>
> ⚠ **测试时电量请保持在 30% 以上**：电量 ≤5% 时系统会下线大核并压低中核频率
> （实测从 `119.5 fps` 掉到 `98.3 fps`，而当时温度才 54℃，不是热降频），
> 这段数据拿去和正常电量对比是不可比的。

### 低电量（≤5%）为什么会掉帧

实测 767 秒的全程（电量 10% → 4%）显示，掉帧是**断崖式**而非渐进的：

| | 大核在线（电量 6~10%） | 大核离线（电量 4~5%） |
|---|---|---|
| 平均帧率 | **119.48** | **98.26** |
| 5% Low | 117.0 | 89.0 |
| 平均功耗 | 4.147 W | 3.681 W |
| 中核频率 / 负载 | 1364777 / 54.9% | 1107270 / **63.5%** |
| CPU 温度 | 54.1℃ | 54.0℃ |

系统在电量 ≤5% 时把 `cpu8/cpu9` 下线，任务全压回中核，
中核负载从 54.9% 涨到 63.5%、频率反被压到 1107MHz。
**这笔账系统算亏了：省 0.467W，代价是 −21.2 fps**（能效 28.5 vs 28.1 fps/W，几乎持平）。

但这是电池保护策略，强行保活大核有掉电关机风险 ——
对临时 root 设备尤其不划算，因此本模块**不做对抗**，只在此说明。

### ⚠️ 升级会覆盖什么（v15 起）

| 处理 | 文件 | 理由 |
|---|---|---|
| **覆盖** | `profile.json`、`manifest.json`、`description.txt`、`powercfg.sh`、`_Camera.json`、`_Apps.json`、`_Games.json`、`_ELP.json`、`features/*.conf` | 都是**模块的设计**（频率 preset、调速器、limiter、相机豁免…），引擎改了就得跟着走 |
| **保留** | `threads.json`、`threads_games.json` | 应用 / 游戏的线程档位表；**真值**在模块状态目录的 `app_assign.tsv` / `game_assign.tsv`，模块里那两份只是打包当天的旧快照，拿去覆盖等于倒退 |

- 清单只有**一处**定义：`lib/util.sh` 的 `SYNC_SKIP`（`sync_scheme` 与同步后自检都认它）。置空即恢复「全量覆盖」。
- 覆盖前自动备份到 `/data/adb/SceneO3Tuner/backup/upgrade-<时间戳>/`；覆盖后**重启 scene-daemon**
  （`features/*.conf` 里的键它只在启动时读一次）。
- ⚠ `_Apps.json` / `_Games.json` 名字像「应用 / 游戏配置」，**其实是模块的设计**（分组的 模式 → preset /
  频率映射），而且 `_Games.json` 在三个方案包里各不相同（跟着 `fas.freq` 走）→ 必须跟方案一起换代。
- 想**主动全量重灌**（Scene 重置 / 丢配置 / 手工改坏了）：WebUI 概览页 → **「传递调度」**
  —— 它刻意**不设** `SYNC_SKIP`，属显式修复动作，会先自动备份。

---

## 7. ⚠️ 需要注意的东西

这一章是踩过的坑，**照做能省掉几小时**。

### 7.1 守护必须由 KSU 上下文启动

在 `adb shell` 里用 `nohup` / `setsid` 起的进程，**shell 退出时会被杀掉**（实测）。
只有 `ksud services` 或开机流程起的能常驻。

### 7.2 不要用 `am force-stop` 停 Scene

`force-stop` 会**连带掉无障碍服务 → Scene 直接失效**
（它靠 `com.omarea.vtools.AccessibilitySceneMode` 感知前台）。

**正确做法**：只 `pkill -f scene-daemon` —— 它是后台调度进程，
**4~8 秒内 Scene 会自动拉起并重读配置**，不碰 Scene 本身。

### 7.3 `while read` 会静默丢掉「没有结尾换行」的最后一行

```sh
# ✗ 错：EOF 处最后一行被静默丢弃
while IFS= read -r line; do ... done < file

# ✅ 对
while IFS= read -r line || [ -n "$line" ]; do ... done < file
```

实测复现：`app_assign.tsv` 最后一行是 `com.xiaomi.ugd smooth`，**尾字节是 `h`（无换行）**
→ 后端拿不到这一行 → 前端永远显示「未分配」。

模块内**所有**读配置文件的 `while read` 都用 `|| [ -n "$line" ]` 保护；
`webui.sh` 写入时也会**自动补结尾换行**。

### 7.4 `set -- $LIST` + `shift` 遍历会死循环写第一簇

```sh
# ✗ 错：每次 set -- 都重置游标 → 只扫到第一簇，并把它重复写 N 遍
set -- $FREQ_ALL
while [ "$i" -lt "$WRITE_TRIES" ]; do
    while [ $# -ge 3 ]; do fix_cluster "$1" "$2" "$3"; shift 3; done
    set -- $FREQ_ALL        # ← 这里把游标打回去了
    i=$((i+1))
done
```

**症状**：只有 `cpu0` 的 min/max 被写，`cpu4`/`cpu8` 原封不动；**日志却报「写入 N 个节点」**。

**修法**：外层重试循环里**逐簇显式展开**，或用 `for` 遍历一个不含 `set --` 的列表。

### 7.5 `_Camera.json` 是「路径一行、值在下一行」

```json
"/sys/devices/system/cpu/cpu0/cpufreq/scaling_min_freq",
"912000"
```

→ 解析**必须用两行滑动窗口**（`__pend` 记住上一行路径，本行当值），
**不能在同一行里找值**。第一版写成 `val="${line##*,}"` 直接全部解析失败。

### 7.6 本机 `printf` 不是内建

`/system/bin/printf` 是**外部命令**。在循环里逐行 `printf` 等于**每行 fork 一次**
（72 行就要 1 秒，还会打断 `read` 缓冲）→ **必须攒好再一次写**。

同理，热路径上：用 `read -r v < "$f"` 而不是 `cat "$f"`；用 shell 内建的
`[ ]` / `case` 而不是 `grep` / `awk` / `sed`。

### 7.7 别用 `chattr +i` 锁 Scene 的配置

会让 Scene **自己存不下配置** —— 点小齿轮改特性、切模式都会 `ENOTSUP` 失败，
现象就是「**改了没反应**」。

模块现在会主动**清掉历史残留的 chattr 标志**（`repair_scene_writable`）。

### 7.8 Scene 需要你在它的 UI 里被「显式选中」一次

Scene 用 `shared_prefs/global.xml` 的两个键决定「启用哪套配置」：

| 键 | 可用值 | 说明 |
|---|---|---|
| `scene_profile_source` | **`SOURCE_SCENE_ONLINE`** ★ | 唯一「显示对 + 能启用」的值 |
| | `SOURCE_SCENE_CUSTOM` | 能启用，但界面显示成「自定义」 |
| | `SOURCE_OUTSIDE` | 界面显示我们的身份却判为无效、`dynamic_control` 被按回 `false` ❌ |
| `dynamic_control` | `true` | 「性能调节」总开关；`false` 时 Scene **完全不下发调度** |

**正确操作**：Scene →「调节」页 → 点配置行（可能显示「未知」）→ 选「**自定义**」。

> ⚠️ 选「自定义」时 Scene 会把它自己的 `profile.json` 重置成 451B、
> `manifest.json` 写成 195B（`9.0 Customized`）。**选完请用 WebUI 的「传递调度」灌回我们的配置。**

### 7.9 `dynamic_control` 是 boolean，不能用字符串正则读

值在 `value="..."` 属性里。用字符串式正则读会**永远读成空**，误报「性能调节未打开」。
模块为此单独实现了 `scene_bool_get`。

### 7.10 被 `overflow: hidden` 祖先包住的 `position: absolute` 会被静默裁切

WebUI 开发时的坑：模板说明面板原本 `position:absolute; top:41px`，
而卡片有 `overflow:hidden` → 内容一多就被**静默裁掉**。

**修法**：改成内联流式块（`max-height:40vh; overflow-y:auto`），由卡片撑高。

### 7.11 同一节点上的多个 `addEventListener('click')` 之间 `stopPropagation()` 无效

它**只拦后代 → 祖先的冒泡**。

新增 `data-act` 名字时，**务必检查所有依赖 `data-act` 白名单的全局监听器** ——
曾出现「标题 ⓘ 点了没反应」：全局「点空白处收起」的监听器白名单里没有新名字，
于是刚展开就被同一个 click 事件的**下一个监听器**全收起了。

### 7.12 `lib/util.sh` 的 `MODDIR` 有回退

```sh
[ -f "${MODDIR}/module.prop" ] || MODDIR="/data/adb/modules/SceneO3Tuner"
```

**做离线测试时**：沙盒目录里**必须放一个 `module.prop` 占位**，
否则 `MODDIR` 会被打回 Android 路径，基线目录全部找不到。

同理，Windows / Git Bash 下的原生 Python **打不开 `/tmp/xxx` 这类 POSIX 路径**，
离线测试请用**相对 CWD** 的沙盒路径。

### 7.13 让子进程收尾，别让它变僵尸

`service.sh` 里每个 `nohup sh … &` 都要有对应的 `pkill -f "<pattern>"` 前置清理
（`uninstall.sh` 里也有）。守护脚本互相之间**用 `pgrep -f` 精确匹配到具体路径**
（如 `O3/guard\.sh`），否则会误杀同名脚本。

---

## 8. 常见问题

**Q：为什么后台应用看不到绑核变化？**
A：`background` 组的预算就是 `0-3`，系统已经把整个应用限住了；交集与现状一致，
所以不下发命令。这是设计，不是故障（[§3.2](#32-cgroup-预算是硬上限最关键的一条)）。

**Q：改了模板/分配，多久生效？**
A：前台切换的那一刻（下一个 5 秒 tick 内），或最多 60 秒兜底；
也可点右上角刷新按钮，或在应用页点保存后立即生效。

**Q：Scene 里切模式，线程会跟着变吗？**
A：只有开了「模式同步线程」开关才会
（省电→轻量 / 均衡→流畅 / 性能→高性能 / **极速→不覆盖，保留你手动套的模板**）。

**Q：频率会跟着模式变吗？**
A：会 —— **由 Scene 自己下发**。本模块不写频率节点（[§3.4](#34-频率模块不写交回-scene)）。

**Q：`threads.json` 还被写吗？**
A：写，但只为让 Scene 侧的数据自洽 —— **Scene 不会执行它**。
真正生效的是本模块的落核器。

**Q：相机还是锁频怎么办？**

> 先说结论：**现在（v14+）相机不再靠模块看护**，而是由 `_Camera.json` 固定走
> `["@preset","fast_active"]` + `["@limiter","NONE"]`（豁免 Scene 的辅助调速器）。
> 那个 `camera_freq_guard.sh` 已降级为**手动应急工具**，默认不开。

按顺序检查：

1. 辅助调速器开关（真凶）：`cat /data/data/com.omarea.vtools/files/features/limiter.conf`
   → `limiters_in_apps` / `limiters_in_games` 应为 `1`；相机靠自身 `@limiter NONE` 豁免，
   所以**开关关掉反而说明豁免链不完整**。
2. 设备上的 `_Camera.json` 是否**全模式 × 全状态**都指向
   `[["@preset","fast_active"],["@preset","limiter_on"],["@limiter","NONE"]]`
   —— ⚠ `@limiter NONE` **必须排在 `@preset` 之后**（预设内部自带 `limiter_on` + `@limiter p3`，顺序反了会被覆盖）。
3. 用 `pl_max_freq` 当**「哪个 preset 生效」的指纹**：
   `fast_active` = `2745600/3148800/3955200`，`fast_inactive` = `2860800/3148800/3648000`。
   ```sh
   for c in 0 4 8; do echo cpu$c=$(cat /sys/devices/system/cpu/cpu$c/cpufreq/xres/pl_max_freq); done
   ```
4. 兜底：WebUI 概览页 →「传递调度」重灌配置（`_Camera.json` 每次安装都会被强制替换）。

**Q：`camera_freq_guard.sh` 还要用吗？怎么开关？**
A：默认**不开**。它只在「相机前台但频率区间塌缩」时写回档位，是最老的一层兜底，v14 之后
正常情况下用不到。要用的话：

```sh
touch /data/adb/SceneO3Tuner/camera_freq_guard.on    # 启用
rm -f /data/adb/SceneO3Tuner/camera_freq_guard.on    # 停用
ksud services                                        # 让 service.sh 重新判定
```

> ⚠ 别用 `pkill -f camera_freq_guard` 了事 —— 那是上面 `service.sh` 自己做的事，
> 而且**不能**用 `pkill -f scene-daemon`（那条命令的 `-f` 会匹配到你自己的 shell，等于自杀）。
> 停 Scene 的 daemon 永远用 `pidof scene-daemon` + `kill <pid>`，它 4~8 秒会自己拉起。

**Q：怎么恢复出厂频率？**
A：音量键菜单选「恢复出厂频率」，或 `sh Scripts/4+4+2/O3/set_scheme.sh restore`。

**Q：管理器里模块是灰的 / 启用了又变回去 / 重启也没用？**
A：KSU 的「启用 / 禁用」在磁盘上就是**一个标记文件**：

```sh
/data/adb/modules/SceneO3Tuner/disable     # 存在 = 模块被禁用（管理器里显示灰色）
/data/adb/modules/SceneO3Tuner/remove      # 存在 = 标记为「重启后卸载」
/data/adb/modules/SceneO3Tuner/update      # 存在 = 标记为「重启后合并更新」
```

常见触发：① 管理器里误关；② **KSU 判定开机失败进入「安全模式」**（会把所有模块一起禁用，
典型症状就是「一觉醒来模块全灰了」）；③ 曾经卡在 `modules_update` 待迁移状态。

> **⚠ 灰的是「开关」+ 连「执行 / 打开」按钮都没有**（v16.2 重点修的局）：
> 这是 **`update` 标记** 在作怪，和 `disable` 不是一回事 ——
> ① 管理器里 `update` 文件存在时，**顶部开关会变灰且拨不动**（`ExpressiveSwitch` 被禁用）；
> ② 同时 KSU 读取的是 `modules/<id>/`，而更新内容还在 `modules_update/<id>/`，
> active 目录里可能**只有 `module.prop`**，没有 `webroot/` 和 `action.sh`
> → 管理器据此**根本不渲染「执行 / 打开」两个按钮**（不是灰，是压根不显示）。
> 关键坑：**`update` 是 installer.sh 在 `. customize.sh` 返回「之后」才写的**，
> 所以在安装脚本里 `rm -f update` 一定失败（v16.1 的失手点）。v16.2 改成
> **落一个独立自愈脚本 + `setsid` 后台拉起**，等 `update` 出现后把它合并进 active、
> 删标记、`rm -rf modules_update`、重拉 `ksud services` —— **全程不重启**。
>
> **v16.2.2 再加第三路：访问即自愈。** 后台进程在真机上可能被系统回收，所以
> `webui.sh` / `action.sh` 的**顶部**都会先跑一次同一个 `selfheal_pending_update`
> —— 也就是说：**你只要打开一次 WebUI（或按一次音量键触发「执行」），
> 就会顺手把待更新态合并掉**，不再依赖后台进程活着。
>
> 顺带一提，同一个原因的另一个症状是 **WebUI 首页版本号一直是旧的**：
> 首页的版本号是**运行时实时读** `modules/<id>/module.prop` 得来的（不是写死在页面里），
> 所以「版本号没变」＝ KSU 真正服务的那个目录还是旧文件 —— 处理办法和上面完全一样。

按这个顺序处理：

1. 管理器里把开关**拨回来**（能拨动就等于删掉了 `disable`）；
2. 拨不动就用带 root 的文件管理器（MT 管理器）删掉上面那个 `disable` 文件；
3. **让守护起来（不用重启）**：终端里 `su -c /data/adb/ksu/bin/ksud services`；
   > 被禁用的那一次开机里 `service.sh` 根本没执行过，所以这一步不能省 —— 否则模块「启用」了但守护是死的。
4. 如果是 **`update` 卡死（开关灰 + 没按钮）**：直接 `su -c` 跑下面这句，等几秒刷新管理器即可，**不用重启**：
   ```sh
   su -c "cp -af /data/adb/modules_update/SceneO3Tuner/. /data/adb/modules/SceneO3Tuner/ && rm -f /data/adb/modules/SceneO3Tuner/update /data/adb/modules/SceneO3Tuner/remove && rm -rf /data/adb/modules_update/SceneO3Tuner && /data/adb/ksu/bin/ksud services"
   ```
   （用 MT 管理器手动做等价操作也行：把 `modules_update/SceneO3Tuner/` 整个覆盖进 `modules/SceneO3Tuner/`，删掉 `update`/`remove`，删掉 `modules_update/SceneO3Tuner/`。）
5. 兜底：**重装本模块**（v16.2.2 起三路自愈：安装时就地合并 → 后台 `fix_pending.sh` 轮询 →
   **访问 WebUI / 按音量键即自愈**，并都会补跑 `ksud services`）。

> ✅ 放心清：本模块**没有 `post-fs-data.sh`**，只有 late_start 阶段的 `service.sh`，
> 不挂载 `/system`、不影响开机流程 —— 重新启用它**不可能**导致开不了机。
>
> ⚠️ 顺带提醒：如果你的设备是**临时越狱 root**（重启即掉 root），遇到这种情况**千万不要靠重启去试**，
> 按上面 1→4（或 5）处理即可。

---

## 9. 调参与排障

### 环境变量

| 变量 | 默认 | 说明 |
|---|---|---|
| `GUARD_INTERVAL` | `5` | 调度守护间隔（秒） |
| `CAM_FREQ_INTERVAL` | `2` | 相机兜底守护间隔（秒） |

在 `service.sh` 里通过环境变量传入，例如：
`GUARD_INTERVAL=3 CAM_FREQ_INTERVAL=2 sh service.sh`

### 常用排障命令

```sh
# 看守护在不在（⚠ pgrep -f 会把自己也算进去，加 [.] 规避）
pgrep -f "O3/guard[.]sh"

# 看三簇当前频率
for c in 0 4 8; do
  echo "cpu$c: $(cat /sys/devices/system/cpu/cpu$c/cpufreq/scaling_min_freq)/$(cat /sys/devices/system/cpu/cpu$c/cpufreq/scaling_max_freq)"
done

# ★ 看「哪个 preset 生效」的指纹（比 scaling_max_freq 更硬）
for c in 0 4 8; do echo cpu$c pl=$(cat /sys/devices/system/cpu/cpu$c/cpufreq/xres/pl_max_freq); done

# ★ 看落核（v12+ 是 cgroup 分组，不是逐线程 taskset）
P=$(pidof com.tencent.mm); cat /proc/$P/cpuset
ls /dev/cpuset/SceneO3Tuner/ 2>/dev/null

# QoS 上下限（老节点的遗留值，只作参考）
for c in 0 4 8; do
  echo "cpu$c qos: $(cat /sys/devices/system/cpu/cpu$c/qos/min_freq)/$(cat /sys/devices/system/cpu/cpu$c/qos/max_freq)"
done

# 谁在写频率（需要 root + strace）—— 定位辅助调速器时用的就是这条
strace -f -e trace=write -p "$(pidof scene-daemon)" 2>&1 | grep -i freq

# 模块状态 / 日志
sh /data/adb/modules/SceneO3Tuner/Scripts/4+4+2/O3/webui.sh status
sh /data/adb/modules/SceneO3Tuner/Scripts/4+4+2/O3/webui.sh audit
tail -50 /data/adb/SceneO3Tuner/sceneo3.log

# 后端命令可以直接在 shell 里试（WebUI 走的是同一套）
W=/data/adb/modules/SceneO3Tuner/Scripts/4+4+2/O3/webui.sh
sh $W launchables          # 列出「启动器能点开」的包（应用页过滤用的就是它）
sh $W conf fas             # 读 Scene 的 FAS 调速器三值
sh $W fasxres              # 一键设成 xres/xres/xres（写完自检 + 重启 scene-daemon）
```

> ⚠ 停 Scene 的 daemon 永远用 `pidof scene-daemon` + `kill <pid>`，**不要** `pkill -f scene-daemon`
> —— `-f` 会连你自己的 shell 一起匹配，等于自杀。daemon 被 kill 后 4~8 秒会自己拉起。

### 离线自检

仓库里带一套**完全离线**的自检套件（在 `tools/` 下，**不需要设备**），改完代码按顺序跑：

```bash
python tools/lint_module.py          # 模块结构自检
python tools/test_camera_guard.py    # 相机档位逻辑
bash   tools/test_sync_skip.sh       # 升级覆盖语义
python tools/build_module.py         # 打 zip + tgz（内部再跑一次 lint）
```

| 命令 | 覆盖什么 | 规模 |
|---|---|---|
| `tools/lint_module.py` | `webui.sh` 函数不重复 / 分发表引用的命令都有实现 / `sh -n` 语法 / 页签与视图函数一一对应 / `data-act` 全覆盖 / 前端调的后端命令都存在 / `index.html` 无预览注入 | 8 组 |
| `tools/test_camera_guard.py` | 相机档位逻辑（见下） | 6 组 |
| `tools/test_sync_skip.sh` | **升级覆盖语义**（§6）：拿真实方案目录在沙盒里跑真 `sync_scheme`，逐文件断言「谁被覆盖 / 谁被保留」+ `verify_synced` 是否认这份清单 | 27 断言 |
| `tools/build_module.py` | 产出 `dist/SceneO3Tuner-v<版本>-<日期>.zip`（包根直接是 `module.prop`，不套一层目录） | — |

> ⚠ `test_sync_skip.sh` 是**唯一**能验证「升级时保留 `threads*.json`」的地方 ——
> 这条语义是**静默生效**的，写错了在设备上只表现为「某些文件莫名回退」，很难发现。
> 它在**两种布局**下都能跑：开发树（模块在 `module/SceneO3Tuner/`）与本仓库（模块 = 仓库根）。

`test_camera_guard.py` 覆盖（v7.0 时代逻辑，脚本已删但断言仍保留）：

- 写入顺序必须「**先 min 后 max**」
- 三簇**全覆盖**（专门断言 `set -- $LIST` + `shift` 的写法不出现 —— 这个 bug 真出现过）
- 三个方案包的解析结果（含 `sweet_eco` 的档位差异）
- 回退档位的**保守性**（回退值 = `sweet_bal`，不比任一方案更激进）
- 在**假 sysfs 上真跑**一遍 `camera_band_fix`（含 `min==max==最低档` 的**塌缩态恢复**）

---

## 10. 版本历史

| 版本 | 主要内容 |
|---|---|
| **v16.6** | ★ **按用户要求移除「配置完整性」与「一键还原数据」** —— 概览页的「配置完整性」分组（注错文件清单 + 「检测配置」按钮）和「一键还原数据」按钮、前端 `ACTIONS.audit`/`fixall`、`Api.audit`/`fixall`、`parseAudit()`、开机自动审计 `loadAudit()`，以及后端的 `webui.sh: audit|fixall` 两个子命令与整个 `integrity.sh` 脚本全部删除；`test_webui.mjs` 里对应的 mock 换成**防回归断言**（断言这三样都不再出现）。⚠ 顺带修正一条此前的误判：`game_templates.tsv` 里 `heaviest_thread` 为空是**刻意设计**（主线程靠「tid == pid」自动识别后绑 `heaviest_cores`），不是配置缺口。产物体积：`index.html` 136239 → 131712 B，zip 内文件 79 → 78 |

| **v16.5** | ★ **配置键审计：揪出 9 个「Scene 根本不读」的编造键** —— 起因是 `fas.conf` 里那两个"目标功耗窗口"（`adj_min_power=6.0` / `adj_max_power=9.0`）与实测游戏功耗（3.8W）严重不符，于是把 Scene 的 APK 拉下来逐键核对，结果它们**在 `classes.dex` 和 `resources.arsc` 里都不存在**。顺藤摸瓜审计了模块推送的全部 5 个 `features/*.conf`，**14 个键里 9 个是编的**：① `fas.conf` 的 6 个 `adj_*`（功耗窗口 / 电池温度窗口 / SoC 温度窗口）全删 —— Scene 的 FAS **没有"目标功耗窗口(W)"这个功能**，功耗是靠 `target_fps_offset`（帧率微调‰）+ `margin_offset`（余量 MHz）+ 温度感知 + `fast_down_always` 间接控制的；② `limiter.conf` 的 `limiters_in_apps` / `limiters_in_games` / `stat_method` 改名成真实键 `limiter_apps` / `limiter_games` / `limiter_jiffies` —— **此前"改它就能开关辅助调速器"的说法是无效操作**，辅助调速器一直由 Scene 自己的 UI 设置在控制；③ `cpuset.conf` 的 5 个键也全部查无此键，但真实键名未确认，按"不猜"原则只加警告不动值。另附**键名验证法**（grep 两处字节 + 区分配置键与图表字段名） |

| **v16.4** | ★ **用第二份实测校正 `sweet_hq`，并修掉一处「改了但没生效」的配置** —— 第二份报告（同款游戏，`767s`、电量从 `10%` 一路测到 `4%`）带来两个结论：① **中核上限 `1651200→1468800`**：这次先按 `cpu_loads` 把中核负载分桶、再在桶内比频率（排除「高频出现在团战」的选择偏差），控制变量后帧率全程 119~120 纹丝不动，功耗却从 3.58W 单调涨到 4.59W，能效 33.5→25.9 fps/W，`1550MHz` 以上纯浪费；② **补 v16.3 的漏**：v16.3 只改了 `_Games.json` 的 `@cpu_freq`，`profile.json` 里中核上限还留在 `3148800`（会被硬件 clamp 到 ≈1.8GHz）——**实测无法区分这两套配置谁在游戏态生效**，所以现在两处同步改成同一个值，中核上限才真正落地。另：查清了低电量（≤5%）掉帧的根因 —— 系统把 cpu8/cpu9 下线、负载全压回中核，省 `0.467W` 却损失 `21.2 fps`（不是热降频，当时才 54℃）；因属电池保护策略且本机为临时 root，本版**不强行对抗**，只在方案说明里写清 |

| **v16.3** | ★ **新增 `sweet_hq`（满画质游戏）方案** —— 基于 Scene 实测报告（王者荣耀 v11.4.1.36 · 满画质 120fps · 453s）做的「砍过量供给」调优：报告显示帧率全程贴 120 上限（avg 119.63 / 5% Low 118），而功耗 2.86W→4.86W 帧率纹丝不动 ⇒ SoC 在过供给。改动（仅性能模式 · 游戏态）：大核下限 `1497600→1113600`（大核只承担 1.7% 计算量、90.3% 采样负载 <5%）、大核 boost `2371200/2044800→1651200/1497600`、中核 boost `1651200→1296000`、三簇上限收到实测峰值（L 1939200 / M 1651200 / P 2044800）。**中核下限 835200 与 target_loads 刻意不动**（UnityMain 主线程 84.6%，835MHz 是维持 120fps 的临界）。非游戏部分与 `sweet_bal` 逐字节相同 → 音量键菜单一点即可 A/B。⚠ 前提：游戏在 Scene 里要设为「性能模式」 |
| **v16.2.2** | ★ **「待重启生效」加第三路自愈 + 检测配置不再只会说「缺失」**：① `update` 待更新态此前只靠安装脚本的后台进程兜底，真机上会被系统回收 → 新增 **「访问即自愈」**：`webui.sh` / `action.sh` **顶部**都调同一个 `selfheal_pending_update`（`lib/util.sh`），**打开一次 WebUI 或按一次音量键就会顺手把待更新态合并掉**，不再依赖后台进程活着；② 自愈加 **版本守门**（`versionCode` 更高才合并，绝不把旧版本回盖），`ksufix` 从「只删标记」升级为**真合并**；③ **「检测配置」加了目录级前置检查**：11 项全报「缺失」时，现在会直接写明成因 —— `★目录不存在 ← 路径/挂载问题` / `★目录不可读 ← 权限或 SELinux` / `目录可读但确实无此文件 ← 被删除或从未写入`，并输出 `DIR_SCENE` / `DIR_WEBUI` 路径自检行，一眼分清是**检测/路径问题**还是**文件真不在**；④ 回归测试：`test_selfheal.py` 22 断言 + `test_pending_selfheal.py` 扩到 4 场景 28 断言（新增「暂存版本 ≤ 当前 → 只清孤儿标记、不回盖」） ⚠️ 其中「检测配置」功能已于 **v16.6 按用户要求移除**（脚本 `integrity.sh` 一并删除） |
| **v16.2.1** | ★ **修「刷入后 Web UI 还显示旧版本号」**：v16.2 只改了 `module.prop` 的版本号、**漏跑了 `gen_webui.py`**，打包脚本也不调它，导致打进 zip 的 `webroot/index.html` 是上一次遗留的 16.1 构建（版本角标 + 前端代码都是旧的）。v16.2.1 把 `gen_webui.py` 调进 `pack_module.py` 的打包流程，成为硬步骤（重建失败即中止打包），从此版本号与前端必定同步。功能代码与 v16.2 一致 |
| **v16.2** | ★ **修「开关是灰的 + 没有执行 / 打开按钮」**：读 KernelSU 源码定位到这是 **`update` 待更新标记**（不是 v16.1 的 `disable`）—— 安装器在 `. customize.sh` 返回**之后**才写 `update`，脚本里删它必失败；且 `update` 存在时 active 目录可能只剩 `module.prop`（缺 `webroot/`/`action.sh`），导致按钮**根本不渲染**。修正：安装脚本就地合并 + 清 `disable`/`remove`，再落一个独立自愈脚本 `setsid` 后台拉起，等 `update` 出现后合并进 active、删标记、`rm -rf modules_update`、重拉 `ksud services`（不重启）。新增 `test_pending_selfheal.py`（22 断言）覆盖该路径 |
| **v16.1** | ★ **修「模块在 KernelSU 里是灰的 / 启用不了」**：安装脚本现在会主动清掉 `/data/adb/modules/<id>/disable`（KSU 的启用状态就是这个标记文件）——在此之前，KSU 若是**原地安装**，重装模块也**清不掉禁用标记**，用户会以为重装都没用（甚至去重启手机）。同时在「刚从禁用态恢复」时补一次 `ksud services`，让守护不必重启就起来 |
| **v16.0** | ★ **应用页默认只显示有前台界面的应用**（`cmd package query-activities` 取启动器可见包，487→169），避免把无界面的系统服务拉进来绑核；已配档位的包仍显示 + 可切「含无界面」 |
| v15.1 | ★ **装完不用重启**：KSU 走到 `modules_update/` 待迁移时，`customize.sh` 收尾**自己就地合并**（本机 root 不允许重启）；顺带修 `powercfg.sh` 里 `/dev` 挂载后备目录随机名导致每次跑堆一个垃圾目录 |
| v15.0 | ★ **升级即覆盖**：升级时直接覆盖 `profile.json`/`powercfg.sh`/`features/*.conf` 等，只保留 `threads*.json`（应用/游戏线程表），覆盖前自动备份 + 覆盖后重启 daemon + 收掉旧版遗留的 GPU 温控 bind-mount；游戏页新增「FAS 调速器 → 设为 xres」按钮 |
| v14.0 | ★ FAS 调速器统一为 **xres**（`governor_*`，与「CPU 控制」页和 preset 三处一致）；反汇编证实 **FAS 候选是硬编码的**（本机只有 `auto/performance/conservative`）；**辅助调速器默认开启**（相机经 `_Camera.json` 的 `@limiter NONE` 豁免） |
| v13.0 | 修应用页「线程档位」点不动（`data-act` 处理函数引用了已删函数）；`pickSheet` 取消哨兵改 `__cancel__`（NUL 会被 HTML 换成 U+FFFD） |
| v12.0 | ★ **落核改 cgroup 分组**（新线程自动继承）；删「不接管」伪卡、极速档改名「系统接管」；相机频率偏低定位到「Scene 日用 app 辅助调速器」 |
| v11.0 | 清空所有内置默认线程分配；**相机固定「系统接管」且 UI 禁改**；给 `*_inactive` preset 补 `pl_max_freq` |
| v10.0 | ★ **档位与模式同名**、一次性从 Scene 导入、彻底去 GPU（`gpu_lock=0`）；删 `mode_sync` 那一整套实时推导 |
| v9.0 | 线程改回模块自己落核（Scene 核心分配的组级预算会把各档位压平） |
| v8.0 | 「零守护」尝试（失败，详见 §3.2 的预算压平结论） |
| **v7.0** | ★ 相机守护功耗治理：QoS 只清一次、看护并入 `guard.sh`、兜底守护 **0-fork 稳态**、档位现读现用；新增离线自检 |
| v6.4 | 修正三个方案包的 `_Camera.json`（4 参数签名 + 裸 sysfs + 先 min 后 max）；新增 `camera_freq_guard.sh` |
| v6.3 | 相机频率取证；模板卡 ⓘ 紧跟名称、说明面板不再被裁 |
| v6.2 | 概览页瘦身；模板区交互统一（标题行 = ⓘ + 右侧小按钮） |
| v6.1 | **CPU 调频交回 Scene**；新增配置完整性审计 + 一键还原 |
| v6.0 | 修掉「极速把包从线程管理里删掉」+ 频率下限策略；模板改名；WebUI 文案精简 |
| v4.6 | ★ 定位 Scene「无法启用」的真机制（`global.xml` 两个键） |
| v4.2 | 调度配置 传递 / 备份 / 恢复 |
| v3.x | WebUI 迭代；`threads.json` 生成；`enforce_threads.sh` 性能重写（上万 fork → 固定 5 次） |
| v1~v2 | 线程绑核 MVP；早期用 `qos/*_freq` 限频（v6.1 已交回 Scene） |

### 从 v7.0 到 v16.0 期间修正的几条**关键认知**（都推翻了当时的写法）

1. **「模块不写频率 + 相机守护」→ 相机守护整套删除**。真根因是 Scene 的
   「日用 app 辅助调速器」每秒多次写 `scaling_max_freq`（strace 8 次/秒），把前台压到 417~912MHz；
   正解是在 `_Camera.json` 里对相机用 `["@limiter","NONE"]` 豁免。
2. **逐线程 `taskset` → cgroup 分组**。关键收益不是快，而是**新线程自动继承创建者的 cgroup**。
3. **「实时跟随 Scene 模式」→ 一次性导入**。实时推导会被 Scene 的任何一次改动冲掉。
4. **FAS 调速器候选读不到内核**（硬编码），写 `fas.conf` 反而有效。
5. **升级不能「继承」，要直接覆盖**：否则模块改了什么永远送不到设备上
   （实测：Scene 侧 `powercfg.sh` 停在旧版好几天没人发现）。

---

## 11. 已知限制与未验证项

### 已知限制

- **只适配玄戒 O3（4+4+2）**。其他拓扑（如 6+2 八核）的 `Config/` 需要重做 ——
  历史上从 6+2 第三方配置包整包移植过来的 `_Camera.json` 就出过问题：
  值虽然合法，但它们是 `min`，会把 L 簇顶到 `2390400`，而该簇「80% 能效上限」才 `1353600`
  → 4 个小核全程满速空烧。
- **依赖 Scene**。Scene 的配置结构变化（`global.xml` 键名、`profile.json` 格式）
  会让模块失效。模块自己带的方案包是**跟随特定 Scene 9 版本**做的。
- **守护需要 root 常驻上下文**，KernelSU / SukiSU 之外的环境（纯 Magisk 未验证）。

### 未验证项（诚实标注）

- ⚠️ **Scene 的 `call` 数组是否接受裸 sysfs 路径** —— 只在 `_Games.json` 里见过
  `target_loads` 的裸路径先例，`_Camera.json` 里这么用**尚未在设备上证实生效**。
  如果无效，兜底守护仍能盖住（看到值不对就写回）。
- ⚠️ **守护 2s 间隔 + 连写 3 遍是否足够压住回写** —— 此前实测写 `min` 后约 2s 会被打回。
- ⚠️ **v7.0 的 QoS「只清一次」在跨版本升级场景的表现** —— 逻辑上成立
  （遗留值只在升级/改档位时出现），但如果将来有别的写入方，需要重新评估。

> 欢迎在这三项上反馈实测结果。

---

## 12. 许可与致谢

### 许可

本项目以 **MIT License** 发布。详见 [LICENSE](LICENSE)。

### 致谢

- [**Scene**](https://github.com/omarea/Scene)（`com.omarea.vtools`）——
  本模块的设计完全围绕 Scene 展开，`profile.json` / `threads.json` / `features/*.conf`
  的结构与语义都源自它。没有 Scene 就没有这个模块。
- [**KernelSU**](https://github.com/tiann/KernelSU) / SukiSU ——
  模块框架与 WebUI 桥接。
- [**ponytail**](https://github.com/dietrichgebert/ponytail) ——
  v7.0 的功耗治理是在它的「偷懒优先 / 先问这东西需要存在吗」原则下做的，
  正是那条原则让我发现**常驻轮询根本没必要存在**。

### 免责声明

改 CPU 频率、绑核、动 Scene 的配置，**都属于会影响设备稳定性与散热的行为**。
本模块按「如实标注、不猜、不覆盖别人的写入」设计，但**请自行评估风险**。

特别地：**不要**为了解锁频率去写 `cpu_nolimit_temp` —— 那会解除温度保护。

---

<div align="center">

**XRingO3SceneLP** · 为玄戒 O3 补上 Scene 缺失的那两块

</div>
