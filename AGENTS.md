# AGENTS.md

> **本文件是 clipflow 项目唯一的 AI 指引事实源。**
> Claude Code 经 `CLAUDE.md` 中的 `@AGENTS.md` 机械导入本文件；Codex / Cursor / OpenCode 等直接读本文件。
> 共享内容**只在本文件编辑**；工具专属差异一律写在末尾「工具差异对照」，不要散进正文。

本文件为 AI 编码代理在本仓库工作提供指引。

## 进度在哪（开工前先读）

进度与计划**不在本文件**，去下面这些地方找 —— 除标注外全部已入库，两个工具都读得到：

| 想知道什么 | 文件 |
|---|---|
| 做到哪了、已完成功能、技术债与时间节点 | `PROGRESS.md` |
| 版本计划、当前执行到哪个版本 | `docs/version-roadmap.md` |
| Phase 2.5 里程碑拆分与附加待办 | `docs/phase25-final-plan.md` |
| LAN 优先同步交接记录、**明确尚未实现**、已知问题 | `docs/lan-priority-sync-roadmap.md` |
| 架构与流程**为什么**是这样 | `docs/decisions/001–011` |
| 每轮任务的成本/轮次台账（§6.6 追加处） | `.codex/pipeline/summary.md` ✅ **已入库**，两个工具共用 |
| 归档的历史管线产物 | `archive/` ⚠️ gitignored，2.4 MiB，仅本机 |

> ⚠️ `docs/superpowers/plans/2026-08-01-history-search-implementation.md` 的复选框**全部未勾选**（43/43），但该功能**早已实现**（见 `lib/widgets/search_bar.dart`）——**不要把它当成待办清单**。
> 其它相关：`docs/manual-test-checklist-v1.5.md`（人工测试清单）、`docs/pipeline-optimization-proposal.md`（本文 §1–§6 管线规范的来源）、`SERVER_MAINTENANCE.md`（未入库）。

**开工前先读 `PROGRESS.md` + 对应的 roadmap**，不要凭记忆假设进度，也不要把"上次看到的"当成现状。
一轮任务做完：按 §6.6 往 `summary.md` 追加一行；有里程碑级结论时回写 `PROGRESS.md`。
测试与静态检查的**当前**数字以实际运行为准（`flutter test` / `flutter analyze`），文档里的数字是快照。

# Agent 专用管线工作流

## 1. 核心原则
- **成本随任务规模自适应**：骨架（探索→设计→实现→独立验收）保留，阶段选择由主代理在「强制底限」约束下自由组合（见 §2），不为所有任务套同一套流程。
- **标准/完整档**：禁止主代理在当前会话内分角色模拟开发/测试/验收，必须委派真实子代理实例执行；**阶段之间串行**（上一阶段验收完才开下一阶段），唯一例外是只读 explorer 探索可并行（见 §6.5、§4）。
- **快速档**：主代理可直接实现（TDD），但业务代码改动仍需独立验证（见 §2.2 强制底限①）。
- 子代理拥有完全独立的上下文，其内部工具调用、中间推理过程严禁输出到用户主聊天框，仅将最终结果返回给主代理，由主代理统一汇总交付。
- 主代理负责路由、编排与档位判断；不加载 Skill 定义、不执行分析流程（快速档直做除外）。
- **并行边界**：仅只读 explorer 探索可并行；写代码与验收阶段一次只启动一个子代理。

### 6 个专用 Agent
| Agent | 职责 | 方法论 | 可写代码 |
|-------|------|--------|---------|
| explorer | 代码探索、执行路径追踪 | code-explorer | ❌ |
| architect | 方案设计、架构决策 | code-architect | ❌ |
| coder | TDD 代码实现 | test-driven-development | ✅ |
| tester | 测试验证、完成声明验证 | verification-before-completion | ❌ |
| reviewer | 终审、置信度评分 | confidence-scoring | ❌ |
| debugger | 根因分析 | systematic-debugging | ❌ |

### 工具约束与校验
- explorer、architect、tester、reviewer、debugger 禁止使用 Write、Edit 工具修改业务代码，为指令级软约束；
- 主代理在收到子代理结果后，需交叉校验是否存在违规修改业务代码的操作；
- 所有子代理工具调用可通过 Argus 插件回溯审计。

## 2. 任务路由（自由组合 + 强制底限 + 动态升级）

### 2.1 参考配方（默认起点，非强制捆包）
主代理按任务选择配方，可在满足强制底限的前提下自由增减阶段（如纯 bug 用 `debugger→coder→tester`、只读验证用 `tester` 单独跑）。

| 配方 | 流程 | 适用 |
|------|------|------|
| 快速 | 主代理直做（TDD）→ **业务代码必选 tester**；纯基础设施/非代码可选 tester | 轻量改动；轻功能（单模块、不碰红线）；基础设施/运维；根因已定位的小 bug |
| 标准 | explorer(可并行) → coder → tester | 新功能（多模块 / 2 文件及以下 / UI）；普通 bug（根因不完全清晰） |
| 完整 | explorer(可并行) → architect → coder → tester → reviewer | 重大改动（加密/同步/架构/跨 3+ 文件/双端） |

### 2.2 强制底限（规则，主代理无权绕过）
```
① 写了业务代码 → 必须有独立验证（tester 报告落盘）；禁止「自写自验」算完成
② 触红线（加密格式/密码派生/token认证/数据库结构/同步去重/跨3+文件/双端/三端平台）→ 必须有 architect + reviewer
③ 不满足底限 = 任务未完成：必须补阶段，或显式记录风险注记并获用户知晓
④ 基础设施/非代码 → 无强制，主代理直做
⑤ 触红线优先于档位：任何档位（含快速档基础设施/非代码）一旦触碰红线 → 立即按②升级完整档（architect + reviewer）
⑥ **本节优先级最高**：全文任何表格、清单、配方与本节不一致时，一律以本节为准（并回过头修正该处）。
```

### 2.3 初始判定（猜错可升级）
```
任务输入
 ├─ 触红线？ → 完整（不申请）
 ├─ 明确小工程（单文件 / 单模块轻功能 / 文案 / 配置 / 文档 / 基础设施 / 根因已定位的小 bug）？ → 快速（不申请）
 ├─ 中等但方向明确？ → 标准（不申请）
 └─ 边界模糊 / 成本敏感 → 请示（附三档预期对比表，见 §6.8）
```

### 2.4 动态升级（档位可中途上调）
- 任一阶段发现触红线、跨 3+ 文件、设计风险、约束歧义、架构假设不成立 → **立即升级加阶段**（快速→标准/完整；标准→完整），不硬扛。
- 快速档开工先做 5 分钟侦察（读相关文件、找调用点），把误判前移。
- 升级不丢工作（coder 按逻辑单元 commit，见 §6.4）；只补缺失阶段。
- 升级留痕：成本摘要记录「初始档 → 升级档 → 原因」。

### 2.5 整改循环（最多 3 轮）
若 tester 或 reviewer 判定不通过：
1. 主代理派 debugger 做根因分析（**根因已知并附修复方向时可免 debugger，直接在整改清单留痕说明**）
2. 将根因分析（debugger 或整改清单已附）+ tester 失败报告 + reviewer 整改清单合并，传给 coder
3. coder 基于根因修复（不自由探索；**快速档无 coder，由主代理按根因直接修复**）
4. 重新进入本档位的验收阶段（含 reviewer 的档位一并送 reviewer；快速/标准档无 reviewer 则只重跑 tester）
5. **最多执行 3 轮整改**；若 3 轮仍未通过，则自动终止流程，向用户上报完整问题详情与历史迭代记录，由人工介入处理

### 2.6 交付规范
全部验收通过后，主代理统一汇总并交付给用户，内容必须精简：
- 仅保留：核心改动清单、测试结论、验收最终结果、关键风险提示
- 完整原始报告只留在落盘产物（`.codex/pipeline/`）中，**不进用户交付**；用户主动索要时再单独输出
- 禁止完整粘贴子代理的原始报告、调试日志到用户主聊天框
- 成本摘要只落盘审计（`.codex/pipeline/summary.md`，**Claude 与 Codex 共用**该目录），**不进入用户交付**；用户需要时单独提供

### 2.7 任务预算（终止条件）
- 开工时按 §6.8 三档预期估算墙钟（快速 ~10min / 标准 ~30min / 完整 ~60min）。
- 实际墙钟超过预期 ×2 时：**暂停并向用户请示**（附已完成进度、剩余工作量、是否升级档位/继续/人工介入），不硬扛。
- 升级档位优先；请示结论记录进成本摘要。

## 3. 分场景触发规则
| 场景 | 处理方式 |
|------|---------|
| 轻量改动（注释、文案、配置、文档） | 快速档：主代理直接处理 |
| 基础设施/运维（部署、网络、证书、真机安装） | 快速档：主代理直做，必要时 tester |
| 普通功能新增 / Bug 修复 | 标准档：explorer → coder → tester |
| 核心重大改动（架构重构、加密逻辑、同步机制） | 完整档：explorer → architect → coder → tester → reviewer，必要时 /code-review |

> 与 §2.1 参考配方不一致时，**以 §2.1 + §2.2 强制底限为准**：「单模块轻功能」「根因已定位的小 bug」属快速档，不因上表「普通功能新增 / Bug 修复」行而升到标准档。

## 4. 子代理调用方式
使用 Agent 工具，关键参数：
- `subagent_type`：分别指定 `explorer`、`architect`、`coder`、`tester`、`reviewer`、`debugger`
- 并发语义：**一次只启动一个子代理，唯一例外是只读 explorer 探索可并行**（见 §6.5）。用哪个参数、怎么触发并发，见末尾「工具差异对照」——本节不写工具参数。
- `prompt`：极简消息，只含文件路径 + 任务目标 + 验收标准，详见「6. 主代理编排规范」

## 5. 子代理规则边界
- 子代理仅加载自身 `.md` 文件内的系统提示，不继承项目 CLAUDE.md 的全局规则
- 所有子代理专属的职责、约束、校验标准必须全部写入各自的 **agent 定义文件**（本项目 6 个：explorer / architect / coder / tester / reviewer / debugger；两种工具的存放路径与容器格式见「工具差异对照」）
- 不得依赖 CLAUDE.md 向子代理传递专属规则

## 6. 主代理编排规范

以下规范约束主代理的子代理编排方式，违反任一条视为编排事故。

> `.codex/pipeline/` 是**本项目 Claude 与 Codex 共用的管线产物目录**。其中**只有 `summary.md` 入库**（轮次台账，两工具共享并进 git）；`pipeline/` 下的其它任务报告产物、`.codex/` 其余内容、`archive/` 仍被 gitignore。归档用 `scripts/archive-pipeline.sh`。按 `.codex/` 路径书写是因为脚本与既有产物都在该路径下，不代表只给 Codex 用。
> ⚠️ 归档脚本是**无差别整目录搬走**（`for f in "$PIPE"/*; do mv`）。若 Codex 侧有在途任务文件，Claude 跑归档会把它们一起搬走（反之亦然）——**归档前先确认另一侧没有正在进行的里程碑**。

1. **管道产物全部落盘**：每个子代理的交付物写入 `.codex/pipeline/` 下的文件；下一个子代理直接读文件，主代理不做二次转述。
2. **默认文件投递**：详细需求、约束、输出格式全部写进 `.codex/pipeline/` 的任务文件，spawn 消息只含文件路径 + 任务目标 + 验收标准。消息投递（无任务文件）仅作 fallback，此时详细需求直接写在消息里（见 §6.1）。
3. **每阶段全新实例**：子代理输出终态后即视为归档，绝不对已完结的代理 followup 补发任务；中断、失败、超时一律重开全新实例。
4. **失败即换投递机制**：子代理报告"没收到任务/输入不完整"时——若当前用的是消息投递（fallback），立即改为文件投递并重开全新实例；若已是文件投递，重开全新实例重试一次。同一投递方式最多重试一次，仍失败则停止并向**用户**上报，由人工介入处理。
5. **任务文件模板**：阶段任务文件只写三块——输入文件路径、本阶段增量要求、输出路径；需求唯一源在 `phaseX-task.md`，不复述。

### 6.1 握手与交付协议
- 文件投递场景：spawn 消息只含任务文件路径 + 目标 + 验收，子代理「先读文件确认已加载」后开工，不强制先回复「收到任务，开始执行」。
- 消息投递场景（无任务文件）：保留握手 `请先回复「收到任务，开始执行」再开始工作。`
- 子代理交付物必须写入任务文件指定输出路径，主代理只校验文件存在性与 git 改动范围，不转述内容。

### 6.2 决策留档
验收后，主代理把 explorer/architect 的关键决策以「背景-决策-后果」三行同步进 `docs/decisions/`（进 git）。

### 6.3 产物治理
- 任务/报告文件命名：`<里程碑>-<阶段>-<代理>.md`（阶段：explorer/architect/coder/tester/reviewer/debugger；里程碑如 `v16-switchaccount`），便于检索。
- 新阶段开工前，把上一阶段 `.codex/pipeline/` 过程文件归档到 `archive/<里程碑>/`（可用 `scripts/archive-pipeline.sh`）；保留最近 1 个里程碑全过程 + 历史摘要。

### 6.4 checkpoint
coder 任务书约定：**每完成一个逻辑单元 git commit 一次**（本工作树/feature 分支，不污染 main）；中断后从最后一次 commit 续跑。

### 6.5 explorer 并行
探索只读可并行：按 server / client / 平台拆分多个 explorer 同时跑，主代理汇总；写代码阶段保持串行。

### 6.6 成本摘要
每轮结束，主代理把一行成本摘要 `档位/组合 | 代理数 | 墙钟 | 产物路径 | 结论`（含 model）**追加落盘**到 `.codex/pipeline/summary.md`，供审计与复盘；**不进用户交付**，用户聊天框只给精简交付，复盘或索要时再展示。

### 6.7 审计
子代理报告全部落盘 `.codex/pipeline/`，主代理不可删改；主代理每任务记录「阶段组合 + 理由」，供复盘与用户查证（防偷工）。

### 6.8 边界请示
档位判断见 §2.3；边界模糊/成本敏感时向用户请示，附三档预期对比表：
| 档位 | 流程 | 预计时长 | 质量保障 | 适用 |
|------|------|---------|---------|------|
| 快速 | 直做 → **业务代码必选 tester**（非代码可选） | ~10 分钟 | 单测 + tester 独立验证 | 小改动 |
| 标准 | explorer → coder → tester | ~30 分钟 | 探索+独立测试 | 中等功能 |
| 完整 | explorer → architect → coder → tester → reviewer | ~60 分钟 | 全链路+终审 | 重大改动 |

---

## 构建、测试、检查

```bash
# 运行所有测试（无需服务器连接即可跑核心服务测试；2026-10-15 实测 537 个）
flutter test

# 服务器端 smoke 测试（自动本地起/停 server，56 个用例）
bash server/smoke-test.sh

# 静态检查（**warning 和 info 都会让 exit code 变 1**，二者任一非零即 exit 1，已用 --no-fatal-warnings / --no-fatal-infos 对照验证；只有 error 必须处理。
# 2026-10-15 基线：总计 102 条 = info 89 + warning 13 + error 0，exit code 1）
flutter analyze
```

**Flutter 安装路径：** `~/development/flutter/bin/flutter`（`~/.zshrc` 已把 `~/development/flutter/bin` 加入 PATH，正常直接 `flutter` 即可；命令找不到时用完整路径）。
⚠️ 旧文档写的 `/opt/homebrew/bin/flutter` **已不存在**（2026-10-15 系统降级恢复后实测），照旧路径执行会 `exit 127`。

## 架构

**跨平台剪切板同步工具，端到端加密。** Flutter 前端，Node.js + SQLite 自建服务器后端。支持 macOS、Android、Windows，iPad/iOS 通过快捷指令 + Web App 补充。

### 整体架构

```
Flutter App
    ├─ 云端同步：HTTPS 直连 IP + 自签证书指纹固定（pinned_client.dart）
    │       ↓ JSON over TLS
    │   Node.js Server (Express + SQLite，仅监听 127.0.0.1，本机 TLS 层持自签证书对外；域名/Tunnel 已废弃，决策 001)
    │       ↓ 阿里云 ECS (2核2G, 40GB SSD)
    ├─ LAN 优先同步：mDNS 发现 + 自签 TLS + A3 双向挑战握手，文本/图片/文件直传，云端兜底
    │       ↓ LanSyncManager/LanTransport/LanProtocol 等 8 个 lan_*.dart
    └─ 混合同步调度：SyncCoordinator + durable outbox（离线操作排队重放），LAN-only 独立模式
```

### 服务器地址

- **生产 API：** `https://121.196.222.122/api`（客户端直连 IP + 自签证书 DER SHA-256 指纹固定，见 `lib/services/pinned_client.dart`；域名+Cloudflare Tunnel 方案已废弃，因 SNI 拦截）
- **健康检查：** `https://121.196.222.122/api/ping`（服务器本机调试用 `http://127.0.0.1:3000/api/ping`）
- **SSH：** `ssh -i /Users/hanyi/Downloads/key241294.pem root@121.196.222.122`
- **服务管理：** `systemctl restart clipflow`
- **服务器代码路径：** `/opt/clipflow/index.js`（与仓库 `server/index.js` 同步部署）
- **数据库路径：** `/opt/clipflow/clipflow.db`（SQLite）

## 历史重大决策

记录项目演进过程中的关键选择，帮助理解"为什么是现在这样"。

### 后端三迁：Firebase → 腾讯云 → 阿里云自建

| 阶段 | 方案 | 迁移原因 |
|------|------|----------|
| v1.0 | Firebase | 初期快速验证，但国内需要梯子，用户无法使用 |
| v1.1 | 腾讯云开发 CloudBase | 国内直连，通过云函数 HTTP 端点访问数据库。但使用的是体验版，每月有资源点上限，而本项目的轮询机制会 24 小时与数据库互动，资源点很快耗尽 |
| v1.2+ | 阿里云 ECS 自建 | 买了一年服务器，无限次调用，完全自主可控，可直接 SSH 调试 |

**教训：** 有持续轮询需求的项目不适合按量计费或有资源上限的 BaaS 服务。自建服务器固定成本，无调用次数限制。

### 桌面端轮询 vs 系统原生 API

**决策：** macOS/Windows 使用 `Timer.periodic` 500ms 轮询 `Clipboard.getData()`，而非系统原生剪切板变更通知 API。

**原因：**
- Flutter 没有跨平台的剪切板变更通知 API
- 各平台原生 API 差异大（macOS 用 NSPasteboard observer，Windows 用 AddClipboardFormatListener）
- 500ms 轮询对剪切板场景完全够用，CPU 占用极低
- 实现简单，一个文件覆盖所有桌面平台

**例外：** Android 使用原生 `ClipboardManager.OnPrimaryClipChangedListener`（通过 MethodChannel），因为 Android 10+ 限制了后台剪切板访问，轮询方式不可靠。

### 端到端加密 vs 服务器端加密

**决策：** 所有数据在客户端加密后才上传，服务器只存储密文。

**原因：** 剪切板内容可能包含密码、token、私密信息等极度敏感数据。如果服务器被攻破，密文无法被解读。即使是我们自己运维的服务器，也不应该能看到用户数据。

### SQLite vs MongoDB/Redis

**决策：** 使用 SQLite 作为服务器数据库。

**原因：** 阿里云 ECS 是 2核2G 小机器，SQLite 零配置、零运维、单文件存储，对这个量级（个人工具，几台设备）绰绰有余。MongoDB/Redis 会额外占用几百 MB 内存，对小机器不友好。

---

## 核心设计决策（重要！）

以下是不可轻易更改的架构决策，修改前必须理解其原因。

### 1. 密码即账户（Password-as-Identity）

**机制：** userId = `user_` + `SHA256("clipflow:$password").substring(0, 16)`

- 相同密码 → 相同 userId → 共享数据
- 不同密码 → 不同 userId → 数据完全隔离
- 不存在传统的注册/登录/用户名系统

**为什么这样做：** 用户无需注册账号，输入密码即可跨设备同步。密码本身就是身份标识。

**⚠️ 不要做的事：**
- 不要实现邮箱/用户名注册系统
- 不要让用户创建独立的账户
- 不要修改 userId 的派生算法（会导致已有数据无法访问）

### 2. Token 持久化

**机制：** 服务器 token 存储在 SQLite `tokens` 表中（不是内存 Map），重启不丢失。

**为什么这样做：** 早期版本用内存 Map 存 token，服务器重启后所有客户端 token 失效，触发 FOREIGN KEY 错误。

**⚠️ 不要做的事：**
- 不要把 token 改回内存存储
- 不要删除 `tokens` 表
- 客户端收到 401 时会自动重新登录（`cloudbase_service.dart` 的 `_callApi`），不要手动处理

### 3. 数据库无外键约束

**机制：** 所有表（clipboard、history、devices、salt、tokens）都没有 FOREIGN KEY 约束。

**为什么这样做：** 早期有 FOREIGN KEY，当 token 失效导致 userId fallback 到不存在的 `'default'` 时，INSERT 操作报错且无法被客户端优雅处理。

**⚠️ 不要做的事：**
- 不要给现有表添加 FOREIGN KEY 约束
- 如果需要新建表，也不要加 FOREIGN KEY

### 4. 认证流程

```
用户输入密码
    ↓
SHA256("clipflow:$password") → userId
    ↓
POST /api/auth { userId } → 获取 token
    ↓
后续请求 Authorization: Bearer <token>
    ↓
token 失效(401) → 自动重新 POST /api/auth → 获取新 token → 重试
```

### 5. 前端跨平台样式一致性

**原则：三端（Android / macOS / Windows）使用完全相同的代码，不写平台分支，不做平台区分。**

**为什么这样做：** Flutter 的 `InputDecorationTheme` 等全局主题属性通过 `merge` 机制向子树传播，不同平台的渲染引擎对 `InputBorder.none` 的合成行为不一致，导致同一份代码在 Mac 上显示边框、Android 上正常。热重载也无法完全刷新主题继承。

**具体规则：**

1. **不在全局 `ThemeData` 中设置 `inputDecorationTheme` 的边框。** 需要边框的 TextField（如解锁密码框）在自己的 `InputDecoration` 中显式声明 `OutlineInputBorder`；不需要边框的 TextField（如搜索框）显式声明 `InputBorder.none` + `filled: false`
2. **UI 样式/布局层禁止 `Platform.isXXX` / `kIsWeb` 分支。** 同一份 Widget 树 = 同一份渲染结果。功能层的平台适配不受此限制（如 Android MethodChannel 剪切板监听、设备名称映射）
3. **自定义 Material 组件设 `surfaceTintColor: Colors.transparent`。** 防止 Material 3 默认 tint 在不同平台上的合成差异
4. **组件级颜色优先用 `ColorScheme` token**（`cs.surfaceContainerHighest`、`cs.onSurfaceVariant` 等）。应用级品牌色和固定设计值可硬编码（如 `Color(0xFF5B6CF0)`），但组件内部不得硬编码会被暗色模式影响的颜色
5. **样式修改后必须重启完整应用测试三端**，热重载不能可靠刷新主题继承

**新增 TextField 时的检查清单：**
- 是否显式声明了 `border`？（不声明会拿到 Flutter 默认 underline）
- 是否设置了 `filled`？（不设置会继承全局主题的 filled 值）
- 用 `grep -rn "TextField" lib/` 确认项目中所有 TextField 的边框样式是否统一

**⚠️ 不要做的事：**
- 不要在 `app.dart` 的 `inputDecorationTheme` 中设置 `border: OutlineInputBorder(...)` 然后期望子组件用 `InputBorder.none` 覆盖——Flutter 的 merge 在桌面端不可靠
- 不要为不同平台写不同的 Widget 树
- 不要新增未声明边框的 TextField——会拿到 Flutter 默认下划线，破坏三端一致性

## 数据流（复制 → 同步 → 粘贴）

```
[设备 A 复制内容]
    ↓ ClipboardMonitor 检测变化（桌面端 500ms 轮询，Android 原生监听）
    ↓ _onClipboardChanged() → 防抖 500ms → _uploadContent()
    ↓ SyncCoordinator 统一调度（single-flight/去重/退避）：
        文本/图片/文件 → AES-256-GCM 客户端加密 → outbox 持久化
        → 优先 LAN 推送（mDNS 对端在线时）→ 云端 API 兜底上传
    ↓
[其他设备通过 _startSyncLoop() 周期轮询 + durable cursor 增量拉取]
    ↓ SyncService.downloadLatestContent()：跳过自己的上传或过期数据 → 解密 → 返回
    ↓ ClipboardProvider 写入系统剪切板（先暂停监听器防止循环同步）
    ↓ 条目加入 HistoryService（按 historyLimit 截断，置顶不占名额）
    ↓ 删除/恢复操作经 durable outbox + sync_tombstones 多设备收敛
```

## 服务器 API

服务器通过 HTTP/HTTPS 接收 JSON 请求（`/api/auth` 有 IP+userId 双桶限流；`/api/crash` 可选认证+独立限流）；端点清单见 `server/index.js`。

## 加密

- `EncryptionService` 在 `lib/services/encryption_service.dart` — AES-256-GCM（128-bit tag；基于 pointycastle ^3.9.1，4.x 升级已列入计划）。密钥通过 PBKDF2-HMAC-SHA256 派生（`AppConstants.pbkdf2Iterations = 100000`，密钥 32 字节，IV 12 字节）。**`EncryptedData` 序列化为 `[2字节 IV 长度][IV][密文+tag]` 的整体 base64**（`toBytes()` / `fromBytes()`）——**注意那 2 字节长度前缀**，漏了会读出不兼容的数据。文件用 `FileProcessingService` 流式加解密（同一套密钥）。
- 主密码在 `UnlockScreen` 输入。Salt 存储在服务器数据库。所有设备使用相同密码即可派生相同密钥。
- **LAN 认证密钥隔离：** `K_lan = HMAC-SHA256(账户密钥, "clipflow:lan-auth-v1")`，与内容加密密钥用途隔离；LAN 传输经自签 TLS（证书指纹固定，区别于云端指纹）。

## LAN 同步子系统（Phase 2.1-2.4 / 5.1-5.2，详见 docs/decisions/003-009）

- 8 个服务：`lan_discovery_service`（mDNS 桥接+黑名单）、`lan_handshake_service`（A3 双向挑战+nonce 重放防护）、`lan_tls`（自签证书指纹固定）、`lan_protocol`（帧编解码）、`lan_transport`（TLS 会话+分块帧+逐帧超时）、`lan_sync_manager`（push/pull/待确认表）、`lan_network_channel`（平台 MethodChannel：macOS NSNetService / Android NsdManager / Windows Win32 DNS-SD）、`lan_diagnostics`（计数埋点）。
- 平台插件：macOS `LanNetworkPlugin.swift`、Android `LanNetworkPlugin.kt`、Windows `lan_network_plugin.cpp`（决策 009：Win32 DNS-SD，否决 WinRT）。
- 可靠性：LAN 专属 outbox（`clipflow_lan_outbox/`，原子写）、fileAck 确认帧、`FileDownloadBreaker` 重下熔断（3 次坏 artifact → 60s 冷却）、幂等会话替换。
- LAN-only 模式（决策 007）：三型内容路由 + 降级横幅 + 重启恢复，默认关。

## 剪切板监听

- `ClipboardMonitor` 在 `lib/services/clipboard_monitor.dart`
- **桌面端（macOS/Windows）：** `Timer.periodic` 每 500ms 轮询 `Clipboard.getData()`
- **Android：** 通过 `MethodChannel` (`clipflow/clipboard`) 与原生层通信。原生层使用 `ClipboardManager.OnPrimaryClipChangedListener` + Foreground Service 保活，检测到变化后调用 `syncClipboard` 传入剪切板内容（Android 10+ 限制后台读取剪切板，因此由原生层传递内容而非 Flutter 层主动读取）
- 提供 `pause()`/`resume()` 方法，在将接收到的数据写入剪切板时暂停监听以防止循环同步
- `ignoreHashes` 机制：从其他设备同步来的内容加入忽略列表，防止上传自己刚下载的内容
- 文件在途签名守卫（Phase 2.1 ⑧）：防止文件回写触发重复上传

## OSS 直传（Phase 5.3，决策 010：实现完成、生产暂缓）

- 无 OSS env 时服务器 presign 端点返回 503，客户端自动回退经 ECS relay——当前生产即此 compat 模式。
- 启用阈值：月非 LAN 流量逼近 6GB / 磁盘 >30GB。客户端 `oss_direct_client.dart` + 仓库层 direct/fallback 已就绪并有单测。

## 数据库模型

服务器使用 SQLite，表在启动时自动创建，**所有表无 FOREIGN KEY 约束**；建表语句见 `server/index.js`。

- `clipboard` 表仅保留每用户最新 1 条记录（上传时 DELETE + INSERT）
- `history` 表保留最近 100 条**非置顶活跃**条目（服务端自动清理；**置顶条目不占名额永不裁剪，垃圾箱软删条目不参与裁剪不占名额**——与客户端 `HistoryService._trim()` 语义对齐），支持软删除（`deleted_at`）和恢复（`restored_at`）
- `sync_operations` 7 天清理；`sync_tombstones` 快照 24h 清理；`tokens` 每小时清理超过 24 小时的过期 token；`crash_reports` 30 天清理；软删 history 超 24h 触发文件清理

## 同步去重

- 上传：明文 SHA256 与 `_lastUploadedHash` 比对 — 相同则跳过。
- 下载：时间戳比对 + 来源设备检查 — 跳过自己的上传和过期数据。

## 多选拼接

- `ClipboardProvider` 维护 `_isMergeMode`、`_selectedIds`（有序集合）、`_mergeSeparator`。
- `MergeBar` 组件显示实时拼接预览和分隔符下拉选择器（换行、逗号、分号、空格）。
- 复制拼接内容：用选定的分隔符将已选条目的内容拼接为一个字符串写入剪切板。

## 测试说明

537 个测试不依赖服务器（2026-10-15 实测 `flutter test` 537/537 全绿；加密、历史、同步、LAN 协议/传输/管理器、outbox、备份、i18n 护栏、Provider 集成等）。服务器行为用 `server/smoke-test.sh` 覆盖（本地自动起停 server，56 用例含 history 裁剪/token/限流/OSS compat 回归）。i18n 护栏：`hardcoded_chinese_test.dart` 阻止硬编码中文回流。

## 服务器部署

```bash
# 在阿里云服务器上
ssh -i /Users/hanyi/Downloads/key241294.pem root@121.196.222.122
cd /opt/clipflow
bash deploy.sh
```

---

## 工具差异对照（唯一允许分叉的地方）

本节是**各工具的参数适配层**。正文（§1–§6 与全部项目事实）对所有工具一视同仁；只有本节可以按工具不同。修改共享内容时，若某个行为在两个工具上实现方式不同，就把**语义**写进正文、把**参数**写进本表。

| 项 | Codex | Claude Code |
|---|---|---|
| 子代理定义 | `.codex/agents/<name>.toml` 的 `developer_instructions` 字段（TOML） | `.claude/agents/<name>.md` 的 YAML frontmatter（`name`/`description`）+ 正文 |
| 子代理调用 | `run_in_background: false` 串行等待 | Agent 工具**没有** `run_in_background`（2.1.300 schema 仅 `description`/`isolation`/`model`/`prompt`/`subagent_type`）。**同一条消息里发多个 Agent 调用 = 并发**；分多条消息逐个发 = 串行 |
| 主代理身份 | `/root` | Claude Code 主会话 |
| 指引入口 | 本文件（AGENTS.md） | `CLAUDE.md` 的 `@AGENTS.md` 导入 + 该文件末尾的硬红线 |
| 技能清单 | 由工具自发现，**不要在文档里维护手写清单**（必然腐烂） | 同左 |
| 管线产物目录 | `.codex/pipeline/` | `.codex/pipeline/`（**共用**，见 §6 blockquote 与归档警示） |

> **两份 agent 定义目前内容完全相同**（body 逐字节一致，只是容器格式不同）。改动任一侧时请同步另一侧，或择机改为由一份生成另一份。

---

## 单一事实源的护栏

本仓库**没有 CI、没有历史 git hook**，所以漂移只能靠自带护栏拦。两道：

**1. 结构校验脚本** `scripts/check-agent-docs.sh`

```bash
bash scripts/check-agent-docs.sh            # 结构性问题=失败；agent 正文漂移=仅警告
bash scripts/check-agent-docs.sh --strict   # 漂移也算失败
```

检查项：
1. `AGENTS.md` 必须被 git 追踪（事实源不入库 = 方案失效）
2. `CLAUDE.md` 必须有**独立成行**的 `@AGENTS.md`（整行精确匹配，防 `.bak` 等前缀变体绕过）
3. `CLAUDE.md` 的硬红线段必须存在且**含 >=8 条实质条目**（防只留标题的掏空）
4. `AGENTS.md` 关键章节齐全（防仍在 git 但内容被掏空）
5. `.claude/agents/*.md` 与 `.codex/agents/*.toml` 正文一致

**2. pre-commit hook** `.githooks/pre-commit`（用 `--strict` 调上面的脚本）

每台机器启用一次：

```bash
git config core.hooksPath .githooks
```

卸载 `git config --unset core.hooksPath`；单次跳过 `git commit --no-verify`。

> ⚠️ **已知边界**：`.codex/` 被 gitignore，所以 `.codex/agents/*.toml` 只在**跑过 Codex 的机器**上存在。
> 新克隆的机器上第 5 项会退化为 WARN 空转（脚本会明说"无法比对"），不是通过。
> 另外 hook 只在本仓库、本机器生效 —— 其他 fork / CI 上没有。
