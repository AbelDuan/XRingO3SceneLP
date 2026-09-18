## v16.6 —— 移除「配置完整性」与「一键还原数据」

按用户要求移除这两个功能。

### 移除了什么

| 层 | 内容 |
|---|---|
| 前端 | 概览页「配置完整性」分组（注错文件清单表格 + 「检测配置」按钮）、「一键还原数据」按钮；<br>`ACTIONS.audit` / `ACTIONS.fixall`、`Api.audit()` / `Api.fixall()`、`parseAudit()`、<br>`S.auditBad` / `S.auditAt`、开机自动审计 `loadAudit()` |
| 后端 | `webui.sh` 的 `audit)` / `fixall)` 子命令 + 用法说明行；<br>`Scripts/4+4+2/O3/integrity.sh` 整个文件（11724 B） |
| 测试 | `test_webui.mjs` 的 `audit` / `fixall` mock 换成**防回归断言** |

防回归断言（3 条）：概览页不再出现该分组、不再有那两个按钮、**不再向后端发这两个请求**。

### ⚠ 差点删错的一处

`lib/util.sh` 里的 `seed_app_templates` / `seed_game_templates`，注释写明是
**为了 integrity.sh 才从 webui.sh 迁过来的** —— 但它们同时还被：

```
customize.sh:136-137   安装时种子
webui.sh:586,623       另两个子命令
```

调用，所以**必须保留**，只更新了注释里的历史说明。

> 教训：删脚本前要 `grep` 它用到的**每个函数**，而不是只看「谁调用了这个脚本」。

### 顺带修正一条此前的误判

之前把 `game_templates.tsv` 里 `performance` 档 `heaviest_thread` 为空，
解读成「配置漏了、UnityMain 从没上过大核」。**实际是刻意设计** ——
`seed_game_templates()` 的注释原文：

> `heaviest_thread → 留空（主线程由 tid==pid 自动识别；填角色名是无效值）`

主线程靠「tid == pid」识别后绑到 `heaviest_cores`（`{p1_core}` = 4-7）。
所以「UnityMain 在中核、大核只干 1.1%」是**设计使然**，不是配置缺口。
（至于这个策略是否最优仍需 A/B，但性质完全不同。）

### 产物

`index.html`：136239 → **131712 B**；zip 内文件：79 → **78**（少的就是 `integrity.sh`）。

自检：jsdom **203-0**（含 3 条新断言）/ `lint` ✓ / `camera` ✓ /
`sync_skip` 27-0 / `pending` 28-0 / `selfheal` 22-0；**0 CRLF**。
