## v16.8 —— 把设备当前运行态固化为模块基线

按用户要求：抓取设备上的 Scene 配置与模块数据，与仓库逐文件比对后固化。

### 比对结论（先说好消息）

**Scene 侧 9 个方案配置文件与仓库二进制完全一致**（profile.json / manifest.json / _Apps.json /
_Games.json / _Camera.json / _ELP.json / powercfg.sh / description.txt / threads_games.json）。

唯一不同的是 `threads.json` —— 它是运行时生成物，由 `SYNC_SKIP` 保护，本就不该同步。

> 所以「刷模块会丢配置」这个担心是不成立的；你的 WebUI 分配也存在
> `STATE_DIR=/data/adb/SceneO3Tuner`（独立于模块目录，`uninstall.sh` 都不删它）。

### 真正需要固化的，是你通过 Scene UI 改过的三项

| 文件 | 设备现状 | 原方案包 | 处置 |
|---|---|---|---|
| `fas.conf` | `fas_engine=fas` | `feas\|fas\|fas_lite` | **固化** |
| `refresh_rate.conf` | `enable=0` | `enable=1` | **固化** |
| `env.conf` | `gpu_lock=1` | `gpu_lock=0` | **不固化**（见下） |

前两项此前**只存在于设备 Scene 侧** —— 刷模块时会被方案包覆盖掉，所以必须固化进包。

### 顺带纠正我自己的一处固化错误

`gpu_lock` 我一度也固化成了 `1`，但它在 O3 上**根本没有执行体**：

> 反汇编实证（2026-09-17）：`gpu_lock` 全 dex 只有 1 处引用，就是表单项定义；
> 它唯一的消费点是 Scene 把 `features/env.conf` 逐行拼成 `export <key>=<val>` 前缀、
> 再 `sh powercfg.sh` 执行 —— **真正干活的必须是 `powercfg.sh`，
> 而本模块的 `powercfg.sh` 自 v10 起完全不读 `$gpu_lock`**。

所以 `customize.sh` 里本就有 awk 逻辑强制写成 `0`，方案包现也回退为 `0`。
**你在 Scene 里拨到 1 不会产生任何影响**（既不会更快也不会更省）。

### 新增：分配数据作为新装种子

- `Config/app_assign.tsv`（58 条 APP→档位）
- `Config/game_assign.tsv`（王者/金铲铲 → performance）
- `customize.sh` 补了 app 分配的种子逻辑

⚠ 两者都**只在文件缺失时落地**，已装设备（含你现在的）**不会被覆盖**。

### 附：验证命令

```sh
# 方案包是否真的同步到了 Scene 侧
su -c 'cd /data/data/com.omarea.vtools/files/features && grep -E "^gpu_lock|^enable|^fas_engine|^limiter_" *.conf'
```

自检：`lint` ✓ / `camera` ✓ / `sync_skip` 27-0 / `pending` 28-0 / `selfheal` 22-0；产物 79 文件、0 CRLF。
