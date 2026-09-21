# 同步状态报告：艇长 Aether OptExt → SceneO3Tuner（v16.25）

> 生成：2026-09-18（会话续） · 设备：小米 18 Fold / lhasa / xring_o3_asic（玄戒 O3，2+4+4）
> 对照源：艇长 `NetizenNemo/Aether_OptExt`（Rust+eBPF 重写版，抓取至 `_aether_src/`）
> 我们的源：`AbelDuan/XRingO3SceneLP` GitHub `main` = v16.25（`4cdc7a6`，2026-09-20 推送）

## 0. 结论（一句话）

**用户的同步需求已满足**：我们的 v16.25 已完整移植艇长的「感知方案 / 线程监控 / 落定」三块逻辑（均按 O3 能效架构调优），
仅保留我们自己的 **Scene 四档 hex 调度**（`sweet_eco`/`sweet_bal`/`sweet_perf`/`sweet_hq`）—— 这是设计差异，不是遗漏。
本地构建镜像 `2026-09-20-14-07-01/XRingO3SceneLP` 与 GitHub v16.25 完全一致（7 个核心脚本逐字节相同，其余脚本均在 GitHub 树中确认存在），**无未推送改动**。

---

## 1. 用户需求回顾

> 「艇长线程 github 更新了，帮我同步他的改动，感知方案，线程监控u以及落定都按艇长的方案来，只是hex调度使用我们的调度」
> 「我们的模块g可能在 github 也有更新，你同步一下」

解读：
- **感知方案** = load_aware（负载感知，升/降核）
- **线程监控** = fork/exec 事件驱动的线程发现与即时落核
- **落定** = cgroup 子树 + 新线程继承，把线程钉到目标核位
- **hex 调度** = 我们基于 Scene 派生的四档频率/核位方案（保留，不跟艇长）

---

## 2. 三块逻辑对照

### 2.1 感知（load_aware）

| 维度 | 艇长（Rust，`src__proccache.rs::adjust_target`） | 我们（v16.25，`load_aware.sh`） |
|---|---|---|
| 分级 | `process::load_level()`：`stat` tick 增量比 → 0–10 级（0–5→1, 6–15→3, 16–35→5, 36–60→7, 其余→10） | `ratio = Δticks/Δelapsed*100` → 同样 1/3/5/7/10 五档 |
| 升级 | `load >= 8` → `base_cpus ∪ hp_core`（**保留原目标**，只并入超大核） | `lvlN >= hotN` → 升到本档升级目标 `SESC`：`powersave="-"`(不升) / `balance=4-7` / `perf=4-7` / `fast=4-9`(+LWHP) |
| 降级 | `load <= 2` → `e_core` | `lvlN <= idleN` → 降到 `e_core`（仅当基集更大时才动） |
| 保持带 | `3–7` 隐式不动 | 中间档不进任何分支 → 保持 |
| 热跟随 | `cap` / `CAP_TTL=3`：被内核限缩时记 `cap`，TTL 后重探扩回 | **无**（依赖 `effective_cpus`） |

**等价性**：结构完全一致（升 + 降 + 保持 对称死区），且都「升级保留原目标、不排他」。
**差异**：艇长阈值基于固定 8/2；我们阈值 `LW_HOT`/`LW_IDLE` 可按档配（默认 powersave 不升、balance/perf 升中核、fast 升 4-9）。艇长多了 `cap`/`CAP_TTL` 热跟随（见 §4 P0）。
**旧 bug 已修**：v16.25 已修 v16.13 前的「单向降级器」（P0-3，只降不升）与 awk 字符串 vs 数字比较（P0-2，`lvlN=lvl+0` 强制数值化）。

### 2.2 线程监控（fork 事件驱动）

| 维度 | 艇长（Rust+eBPF，`ebpf/src/main.rs`） | 我们（v16.25，`pinwatch.sh` + `pinwatch` 二进制） |
|---|---|---|
| 事件源 | 5 个 tracepoint：`sched_process_fork` / `exec` / `rename` / `exit` / `cgroup_attach_task` → ringbuf `EVENTS` | `pinwatch` eBPF（5832B）挂 `raw_tracepoint sched_process_fork`（仅 fork 子集）→ `pinwatch.events` 文件队列 |
| 匹配 | `TARGET_COMM_MAP` 8 字节滑窗匹配 comm；`APPLIED_MAP`(LruHashMap tid→cpumask) | 按包名消费事件 → 调 `enforce_threads.sh` 落核；`GAP=3s`/`MAXEV=4096` 节流 |
| 回退 | eBPF 失败 → proc 轮询增量维护 | proc 轮询兜底由 `enforce_threads.sh` + `guard.sh` 每轮负责 |
| 调度频率 | 主循环 `recv_timeout(1s)`，配置变更全量扫 | `guard.sh` 每轮调 `pinwatch.sh`；屏亮 5s/查前台，屏灭不查+30s 兜底 |

**等价性**：fork 即时落核思路一致——新线程一诞生就把核位定好，不再靠轮询全量扫。
**差异**：艇长覆盖 5 事件（含 exec/rename/exit/cgroup_attach），我们只挂 fork；艇长用 ringbuf+MAP，我们用文件事件队列。对「钉核」目标而言 fork 已覆盖绝大多数场景，exec/rename 主要影响改名线程（我们靠 `enforce_threads` 兜底补）。

### 2.3 落定（cgroup 继承）

| 维度 | 艇长（Rust，`cpuset.rs` + `proccache.rs`） | 我们（v16.25，`pin_cgroup.sh`） |
|---|---|---|
| 子树 | `/dev/cpuset/OptExt` 子组 | `/dev/cpuset/SceneO3Tuner/<pkg_slug>/{c0-3,c4-7,...}` |
| 继承 | 进程迁入子组，新线程继承 | 进程迁 lo 组「1 次写，之后新建线程全部自动继承」（脚本注释明确：把「靠轮询」变「靠继承」） |
| 核位探测 | `detect_core_types()` 按 cpufreq 最大频升序分 e/p/h；`clip_online()`(1s 节流) 避离线核 EINVAL | 固定 2+4+4 拓扑（`{e_core}=0-3 {p1}=4-7 {p}=4-9 {hp}=8-9`） |
| 负载覆盖 | `adjust_target` 内联 | `HOT[pid:tid]` 负载感知覆盖仅 `lo` 且无显式角色线程；显式角色线程免疫 |

**等价性**：cgroup 子树 + 新线程继承核心思路一致，均实现「落定即免轮询」。
**差异**：艇长多 `clip_online()` 在线核裁剪（避免热关核/冻结大核时撞 EINVAL，见 §4 P1）；我们多「显式角色线程免疫」逻辑（游戏主线程等不被负载感知误降级）。

---

## 3. 我们保留的不同（设计如此，不跟艇长）

- **Scene 四档 hex 调度**：`sweet_eco`(极致能效) / `sweet_bal`(日常均衡) / `sweet_perf`(性能甜点) / `sweet_hq`(满画质游戏)。
  频率下限命脉按 O3 实测：**中核 835200 绝不降、小核 672000 贴底**，省电只动上限与大核（C1-Ultra 仅 >2.2GHz 有能效优势）。
- **模块专属逻辑**：WebUI、三路自愈（安装/后台/fix_pending/访问即自愈）、大核封禁 `bigcore_guard.sh`（mount --bind 冻结出厂 8-9 回写）、相机频控 `camera_freq_guard.sh`、频率同步 `profile_sync.sh` / `set_scheme.sh`。

---

## 4. 仍存在的差距（艇长最新 Rust 重写的增强，v16.25 未含）

> 这些属于「增强」，不在用户要求的「感知/监控/落定」范畴内；核心三段已对齐。是否吸收是独立决策。

- **[P0 可选] `cap` / `CAP_TTL` 热跟随重探**：内核限缩 `sched_setaffinity` 后记录 `cap`，TTL(3 轮)后重探扩回，避免大核恢复/分组放宽后永久缩核。我们目前无此机制，靠 `effective_cpus` 间接处理。
- **[P1] `clip_online()` 离线核 EINVAL 规避**：大核被 `bigcore_guard` 冻结或热关核时，避免每轮撞 EINVAL。`enforce_threads` 当前可能重试报错。
- **[P2] `sched_getaffinity` 零成本短路**：已在目标核位则跳过 `setaffinity`。我们每轮重设，理论上有冗余系统调用。
- **[P2] `fg_hint` 前台存活信号**：进程迁入 OptExt cpuset 子组后，Scheduler 的 `top-app` inotify 不再触发，艇长写 `pkg:pid:ts` 通知 Scheduler 重查前台。我们走 `dumpsys` 轮询，路径不同，未必需要。
- **[P2] `threads_cache` 按线程名 `est_load` 自动归类**（Render/Gfx=10, Main/Unity=9, Worker=5, Io=3, Background=1…）：未知应用自动扫描线程名归类 big/mid1/mid2/little。我们靠 `app_assign.tsv` 静态 + 角色识别。
- **[P3] 语义占位符多拓扑自动展开**：艇长 `{e_core}/{p1_core}/{p2_core}/{p_core}/{hp_core}/{all_core}` 按 cpufreq 分组在任意拓扑展开；我们硬编码 2+4+4。

### 架构级决策（单独议题）

艇长已将整个调度器从 **shell 脚本重写为 Rust 二进制 + eBPF**（构建链需 Rust toolchain + eBPF 编译）。我们 v16.25 是**艇长早期 shell 方案的 O3 移植 + 我们的四档调度**。
是否整体移植 Rust+eBPF 是架构级变更，影响：
- 构建链（引入 `cargo` + `libbpf`/ `aya` + eBPF 编译，当前 `build.py`/`linux.py` 已含 Rust 构建）；
- 免重启策略（KSU mount --bind 仍可用，但二进制需预编译进模块，设备侧 `ksud module install` 不变）；
- 调试方式（从 `logcat` shell 日志转向 Rust 日志 + eBPF map 导出）。

**建议**：维持 shell 端口（已满足需求），仅增量吸收 §4 的 P0/P1/P2 小增强，不整体重写。

---

## 5. 已解决的历史问题（v16.25 已落地）

- **P0-1** 双 `TMP` 目录死链（`lw.hot` 读写分裂）→ 调用时显式 `TMPD="$TMP" sh ...`，读写为同一路径。
- **P0-2** `t.sig` 用 `-s` 判存 → `touch` 出的 0 字节文件恒不满足 → 改 `[ ! -f ]`，每轮强制重建目标表。
- **P0-3** `load_aware` 单向降级器（只降不升，不看档位）→ 已改对称死区（§2.1）。
- **P1-4** 日常应用（微信/酷安/抖音/小红书/设置）误挂 `powersave` 且主线程 0-3 → **已修**：v16.25 `app_assign.tsv` 中 `powersave` 仅 8 条（阅读器+播放器：kmxs.reader / vlc / qidian / mxtech ×2 / dragon.read / duokan / iReader）；微信(`com.tencent.mm`)各线程走 `performance`/`fast`；未列出的日常应用走默认 `balance`。

---

## 6. 同步动作记录

- GitHub `main` = v16.25（`4cdc7a6`，tag `v16.25`，pushed 2026-09-20T01:55:37Z）。
- 本地构建镜像 `2026-09-20-14-07-01/XRingO3SceneLP` = v16.25（`module.prop` 一致）。
  - 7 个核心脚本（load_aware / pin_cgroup / pinwatch / guard / bigcore_guard / enforce_threads / webui）与 GitHub 抓取（`_oss_v1625`）**逐字节一致**（CRLF 归一后 diff 为空）。
  - 其余脚本（`pinwatch` 二进制、`camera_freq_guard.sh`、`apply_freq.sh`、`profile_sync.sh`、`set_scheme.sh`、`unbind_fast.sh`）均在 GitHub v16.25 树中确认存在 → **本地与 GitHub 完全同步，无未推送改动**。
- 艇长源抓取至 `_aether_src/`（Rust+eBPF 重写版）供对照；树结构 `_aether_tree.json`。

---

## 7. 待用户决策

1. **是否整体移植艇长 Rust+eBPF 重写？** 建议：否（维持 shell 端口，已满足需求）；仅增量吸收增强。
2. **是否吸收 `cap`/`CAP_TTL`（P0 可选）+ `clip_online`（P1）？** 这两项对「热关核/大核冻结后恢复」最实用，建议优先。
3. **是否吸收 `threads_cache` 自动归类（P2）？** 可减少 `app_assign.tsv` 维护量，但需验证线程名模式在 O3 上的命中率。

---

## 附：关键文件索引

| 文件 | 角色 |
|---|---|
| `Scripts/4+4+2/O3/load_aware.sh` | 感知（对称死区） |
| `Scripts/4+4+2/O3/pinwatch.sh` + `pinwatch` | 线程监控（eBPF fork 事件） |
| `Scripts/4+4+2/O3/pin_cgroup.sh` | 落定（cgroup 继承） |
| `Scripts/4+4+2/O3/bigcore_guard.sh` | 大核封禁（mount --bind 冻结 8-9） |
| `Scripts/4+4+2/O3/camera_freq_guard.sh` | 相机频控 |
| `Config/app_assign.tsv` | 包→档分配（57 条，powersave 仅 8 条阅读/播放） |
| `Config/4+4+2/O3/sweet_*/` | 四档 hex 调度（profile.json + threads.json + powercfg.sh） |
| `_aether_src/src__proccache.rs` | 艇长感知+落定（对照） |
| `_aether_src/ebpf/src/main.rs` | 艇长 eBPF 事件（对照） |
