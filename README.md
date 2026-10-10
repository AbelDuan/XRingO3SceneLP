![Platform](https://img.shields.io/badge/platform-Android%2010%2B-3ddc84?logo=android&logoColor=white)
![Framework](https://img.shields.io/badge/framework-KernelSU-6aa84f)
![SoC](https://img.shields.io/badge/SoC-XRing%20O3%20(lhasa)%20%2F%204%2B4%2B2-ff9800)
![Version](https://img.shields.io/badge/version-18.3.7-blue)
![License](https://img.shields.io/badge/license-MIT-lightgrey)

# O3CPUSet · 玄戒 O3 调度工具箱（线程模块）

> 面向小米 18 Fold（2608BPX34C / lhasa，XRing O3，4 小 + 4 中 + 2 超大核）的 KernelSU 调度模块。
> 让普通应用真正用上「小核 + 中核」，把超大核留给游戏与前台高优任务。

---

## 1. 这个模块解决什么问题

玄戒 O3 是 `0-3 小核 / 4-7 中核 / 8-9 超大核` 的 4+4+2 拓扑。
出厂调度下，大量普通应用（桌面、系统 UI、小部件）要么被塞进中核挤成一团，
要么小核 0-3 长期空转 —— **小核浪费、中核过载、超大核被非游戏进程顺手占用**。

本模块用静态规则（`threads.json` + `apprules.tsv`）把线程精确绑到合适的核族：

- 普通应用 / 桌面 → **小核 + 中核（0-7）**，小核不再空转
- 游戏 / 用户显式放行 → 可用 **超大核（8-9）**
- 系统关键进程（system_server 等） → 框架默认 0-9（全核，设计如此，非 bug）

---

## 2. 功能清单

- **线程落核引擎 AppOpt**（JZzz v14 原生二进制）：按 `o3lim.conf` 把每个线程绑到指定 cpuset 组，2 秒一轮保活。
- **配置生成 o3lim.sh**：继承 `threads.json` 默认规则 + 已装应用自动补「流畅档」+ 8-9 闸门（非游戏不给超大核）。
- **调度守护 guard.sh**：前台识别 + 频率兜底 + 落核引擎保活；引擎掉线自动拉起。
- **多档方案**：`sweet_bal` / `sweet_eco` / `sweet_hq` / `sweet_perf`（Config/4+4+2/O3/）。
- **频率 QoS**：按模式下发小/中/大核 min/max。
- **WebUI**：`webroot/index.html`，可视化开关与调参。

---

## 3. 实现原理

### 3.1 为什么自己做落核
系统调度器对「同应用内不同线程」的区分能力弱。本模块在 `cpuset` 层按线程名（comm）
精确分组，绕开内核调度器的粗粒度，保证桌面主线程 / binder / RenderThread 都落小+中核。

### 3.2 约束（cgroup 预算）
- 核族固定：`0-3` 小 / `4-7` 中 / `8-9` 超大。
- AppOpt 读的是 `o3lim.conf`（由 `o3lim.sh gen` 生成），不是原始 `threads.json`。

### 3.3 解析策略（多来源优先级）
`threads.json`（包级静态规则） > `apprules.tsv`（应用分类） > 8-9 闸门（非游戏拦超大核） > `o3lim.user.conf`（用户自定义，放行 8-9）。

### 3.4 交回 / 让位机制
系统组（top-app / foreground）保持 0-9，不被冻结；超大核由游戏 / 用户放行独占，普通应用让位。

### 3.5 根因排查链
| 现象 | 判据 | 根因层 |
|---|---|---|
| 桌面仍在中核 4-7 | `cat /proc/<pid>/cgroup` 显示 `/AppOpt/4-7` | 规则里 `0-3,4-7` 被 AppOpt 截断成末段 |
| 手机卡顿 / 发热 | `pgrep -f 'AppOpt -c' \| wc -l` 远大于 1 | 守护重复拉起 AppOpt 泄漏 |
| 脚本开机不执行 | `sh -n service.sh` 报错 / `bad interpreter` | 提交含 CRLF |

---

## 4. 目录结构

```
O3CPUSet/
├── module.prop                 # 模块元数据（version 单一事实源）
├── service.sh                  # 开机自启（gen 配置 → 拉 AppOpt → 拉 guard）
├── customize.sh                # 安装时 set_perm 修权限 + 展开模板
├── action.sh / uninstall.sh
├── lib/util.sh                 # 公共函数
├── Config/4+4+2/O3/            # 各档方案（powercfg / threads.json / 游戏表）
├── Scripts/4+4+2/O3/
│   ├── o3lim.sh                # 配置生成
│   ├── AppOpt                  # 落核引擎（JZzz v14 二进制）
│   ├── guard.sh                # 调度守护（保活 AppOpt）
│   ├── aether/                 # ⚠️ 已弃用，保留向后兼容（见 §7.1）
│   └── ...
└── webroot/index.html          # WebUI
```

---

## 5. WebUI

模块自带 WebUI（`webroot/index.html`），KernelSU 管理器内点模块卡片即可打开，
读写 `/data/adb/O3CPUSet/o3lim.user.conf` 与方案切换。

---

## 6. 安装

1. 设备已装 KernelSU / 兼容框架，Android 10+。
2. 下载 Release 里的 `O3CPUSet_vX.Y.Z.zip`。
3. KSU 管理器 → 模块 → 本地安装 → 选 zip → 重启设备。
4. 重启后：`pgrep -f 'AppOpt -c'` 应有 1 个进程，`com.miui.home` 线程在 `/AppOpt/0-7`。

---

## 7. ⚠️ 需要注意的东西（踩过的坑）

### 7.1 `0-3,4-7` 这种逗号多段核位 AppOpt 不支持

现象：规则写成 `0-3,4-7`（想表达小核+中核），结果线程只落 `4-7`（中核），小核 0-3 空转。
根因：AppOpt / JZzz v14 只取逗号分隔的**最后一段**， `0-3,4-7` → 截断为 `4-7`。
正确做法：用单段 `0-7` 表达「小核 + 中核」。本模块已在 `o3lim.sh` 生成配置后自动
`sed 's/0-3[ ,]*4-7/0-7/g'` 归一，模板里也直接用 `{e_core},{p_core}` 占位符展开成 `0-7`。

```bash
# 验证本机没有残留的逗号断点规则
grep -c '0-3,4-7' /data/adb/O3CPUSet/o3lim.conf   # 应为 0
```

### 7.2 守护脚本 pgrep 必须用 basename 匹配，否则 AppOpt 进程泄漏

现象：设备上 `pgrep -f 'AppOpt -c' | wc -l` 堆到 30+，手机卡顿发热。
根因：AppOpt 运行期 cmdline 只有 basename（`AppOpt -c ...`），用完整路径
`pgrep -f "/data/adb/.../AppOpt"` 永远匹配不到 → 每轮误判「引擎不在」→ 重复拉起。
正确做法：看护段用 `pgrep -f 'AppOpt -c'`（片段匹配 basename）。

```bash
# 健康态：引擎应恒为 1 个
pgrep -f 'AppOpt -c' | wc -l   # 期望 1
```

### 7.3 CRLF 行尾会让设备上脚本直接废

现象：`bad interpreter: No such file or directory` 或 `syntax error: unexpected 'then'`。
根因：Windows 提交的 shell 脚本带 `\r`，`/system/bin/sh` 零容忍。
正确做法：仓库 `.gitattributes` 设 `* text eol=lf`，且 local `core.autocrlf=false`。

### 7.4 系统进程 allowed=0-9 不是 bug

现象：`grep Cpus_allowed_list` 看到大量线程 `0-9`。
根因：模块设计就是 system_server / 小米系统服务走全核（框架预期），普通应用限 0-7。
`/dev/cpuset/AppOpt/8-9` 组 task 数为 0 即说明没有普通应用被放进超大核。

---

## 8. 常见问题

- **Q：重启后没生效？** A：确认 `service.sh` 拉起了 AppOpt（1 个）与 guard（1 个）。
- **Q：想让某应用用超大核？** A：在 `o3lim.user.conf` 加该包放行 8-9。
- **Q：aether 目录干嘛的？** A：旧引擎，已弃用，保留仅向后兼容，不参与落核。

---

## 9. 调参与排障

```bash
# 看某应用落核
for p in $(pidof com.miui.home); do
  for t in /proc/$p/task/*; do grep -i cpuset /proc/$p/cgroup 2>/dev/null|head -1; done
done | sort | uniq -c

# 全系统核位分布
grep -h ^Cpus_allowed_list /proc/[0-9]*/task/*/status | awk '{print $2}' | sort | uniq -c

# 引擎健康度
echo "AppOpt=$(pgrep -f 'AppOpt -c' | wc -l) guard=$(pgrep -f guard.sh | wc -l)"

# 手动重启模块
pkill -9 -f guard.sh; pkill -9 -f 'AppOpt -c'; rm -f /data/adb/O3CPUSet/guard.pid
sh /data/adb/modules/O3CPUSet/service.sh
```

---

## 10. 版本历史

- **18.3.7** (2026-10-11)：修复 AppOpt 看护 `pgrep` 匹配（basename 片段），消除 30+ 进程泄漏；
  桌面 / 普通应用 comm 规则 `0-3,4-7` → `0-7` 归一（小核+中核真正生效）。
- 早期版本：o3lim 落核框架切换、aether 引擎弃用、多档方案。

---

## 11. 已知限制与未验证项

- **aether 目录保留但未使用**：落核已完全切到 AppOpt，aether 仅向后兼容。
- **超大核系统进程 0-9**：设计行为，未在「彻底限制系统进程超大核」方向验证（可能影响流畅度）。
- **其它 4+4+2 机型**：仅 18 Fold (lhasa) 实测，其他 XRing O3 机型未逐一验证。
- **WebUI 完整功能**：未逐项点测，仅确认文件存在与脚本可加载。

---

## 12. 许可与致谢

MIT License © 2026 Abel Duan。
落核引擎 AppOpt 基于 JZzz v14 实现；调度框架 o3lim。
