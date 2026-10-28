# AGENTS.md

> **本文件是 clipflow 唯一的 AI 指引入口：路由表 + 硬约束。**
> Claude Code 经 `CLAUDE.md` 的 `@AGENTS.md` 导入；Codex / Cursor / OpenCode 直接读取。
> 共享规则只在本文件编辑；专题事实放入下方专题文档，不在这里复制。

## 进度与文档入口

| 想知道什么 | 去哪里 |
|---|---|
| 当前状态、已完成功能、技术债 | `PROGRESS.md`（**唯一当前状态快照**） |
| 版本计划与历史 | `docs/version-roadmap.md`（计划/历史） |
| Phase 2.5 里程碑 | `docs/phase25-final-plan.md`（计划/历史） |
| LAN 同步交接与已知限制 | `docs/lan-priority-sync-roadmap.md`（历史交接） |
| 架构、数据流、加密、LAN、数据库 | `docs/architecture.md` |
| 优化路线、阶段边界与待决策项 | `docs/optimization-roadmap.md`（已审查） |
| 为什么这样设计 | `docs/decisions/` |
| 子代理管线细则 | `docs/pipeline-workflow.md` |
| 服务器运维 | `docs/server-operations.md` |
| 每轮成本台账 | `.codex/pipeline/summary.md` |
| 历史管线产物 | `archive/`（gitignored，仅本机） |

开工顺序：

1. 读 `PROGRESS.md`，再读与任务对应的 roadmap。
2. 核对代码和本次实际测试结果，不凭记忆假设现状。
3. 涉及架构或不可逆约束时，读 `docs/architecture.md` 与相关 decisions。
4. 任务完成后按 §6.6 追加成本摘要；里程碑级结论回写 `PROGRESS.md`。

事实优先级：

- 当前实现：本次实际检查到的代码与测试结果。
- 功能/技术债状态：`PROGRESS.md`；其中带日期的历史段落只代表当时。
- 是否允许某做法：`CLAUDE.md` 硬红线、本文件 §2.2、`docs/decisions/`。
- roadmap：只提供计划与历史，不代表当前状态。
- 代码与决策冲突时报告漂移，不能把现状自动解释成新标准。

## 1. 核心原则

- **成本随任务规模自适应**：保留探索→设计→实现→独立验收骨架，但按任务增减阶段。
- **标准/完整档必须使用真实子代理**：禁止主代理在同一会话内模拟开发、测试和验收。
- **阶段之间串行**：唯一例外是只读 explorer 探索可并行。
- **写代码与验收串行**：一次只启动一个写代码或验收子代理。
- 子代理中间推理和原始报告不进入用户聊天框，只交回主代理汇总。
- 主代理负责路由、编排和档位判断，不代替子代理执行完整分析流程。

### 1.1 工程决策原则

- **探索事实优先于记忆与假设**：先核对代码、进度、决策与约束；发现冲突时说明风险，由用户拍板。任何探索结论都不能绕过 CLAUDE 硬红线或 §2.2。
- **一个状态只有一个所有者**：current clipboard、history、outbox、cursor、tombstone、同步状态必须有明确归属，禁止多个模块维护近似状态。
- **新能力必须归属现有层**：找不到模块或扩展点时先设计边界，不得把新职责直接塞进 `ClipboardProvider`、`server/index.js` 或 UI。
- **行为变更与结构重构分离**：同一任务不同时做大规模移动代码和行为修改。
- **复杂度超限即暂停**：出现第二套同步/路由/状态、UI 直接装配安全敏感流程或跨层反向依赖时，返回「最小安全/推荐/彻底」三方案；档位仍由 §2.2 判断。
- **已定义边界优先低成本校验**：能稳定脚本化的边界进入 pre-commit 或 CI；未脚本化的边界不得宣称已受保护。
- **治理工具也受复杂度约束**：不要为门禁手写语言解析器或小型编译器；严格静态分析优先使用成熟工具。
- **代理必须提出反对意见**：方案会增加长期维护成本时，应明确说“不建议这样做”并解释依据；最终决定权归用户。

## 2. 任务路由

### 2.1 参考配方

| 配方 | 流程 | 适用 |
|---|---|---|
| 快速 | 主代理直做（TDD）→ 业务代码必选 tester；非代码可选 tester | 单文件/单模块轻功能、文案、配置、基础设施、根因已定位的小 bug |
| 标准 | explorer（可并行）→ coder → tester | 多模块/2 文件及以下/UI、普通 bug |
| 完整 | explorer（可并行）→ architect → coder → tester → reviewer | 加密/同步/架构/跨 3+ 文件/双端/三端平台 |

配方是默认起点。主代理可按任务增减阶段，例如 `debugger → coder → tester`，但不能绕过 §2.2。

### 2.2 强制底限

```
① 写了业务代码 → 必须有独立验证（tester 报告落盘）；禁止自写自验算完成
② 触红线（加密格式/密码派生/token 认证/数据库结构/同步去重/跨 3+ 文件/双端/三端平台）→ 必须有 architect + reviewer
③ 不满足底限 = 任务未完成：补阶段，或显式记录风险注记并获用户知晓
④ 基础设施/非代码 → 无强制，主代理直做
⑤ 触红线优先于档位：任何档位一旦触碰红线 → 升级完整档（architect + reviewer）
⑥ 本节优先级最高；全文其他表格与本节目冲突时以本节为准
```

### 2.3 初始判定

```
触红线？                                      → 完整（不申请）
明确小工程（单文件/单模块/文案/配置/基础设施）？ → 快速（不申请）
中等且方向明确？                               → 标准（不申请）
边界模糊 / 成本敏感？                          → 请示，附三档预期
```

### 2.4 动态升级

- 发现红线、跨 3+ 文件、设计风险、约束歧义或架构假设不成立 → 立即升级。
- 快速档开工先做 5 分钟侦察。
- 升级只补缺失阶段，不丢已完成工作。
- 成本摘要记录「初始档 → 升级档 → 原因」。

### 2.5 整改循环

1. tester/reviewer 不通过时，先取得根因；根因已知且附修复方向可免 debugger。
2. 根因 + 失败报告 + 整改清单合并交给 coder；快速档由主代理按根因修复。
3. 修复后重新进入本档位验收；含 reviewer 的档位必须重新终审。
4. 最多 3 轮。仍未通过则终止流程，向用户上报问题与迭代历史。

### 2.6 交付规范

用户交付只保留：核心改动、测试结论、验收结果、关键风险。

完整子代理报告只留在 `.codex/pipeline/`；成本摘要只写 `.codex/pipeline/summary.md`。用户主动索要时再单独提供。

### 2.7 任务预算

预期墙钟：快速约 10 分钟、标准约 30 分钟、完整约 60 分钟。

实际超过预期 ×2 时暂停请示，说明已完成、剩余工作、是否升级或人工介入；结论写入成本摘要。

## 3. 分场景触发

| 场景 | 处理 |
|---|---|
| 注释、文案、配置、文档 | 快速档，主代理直做 |
| 部署、网络、证书、真机安装 | 快速档，必要时 tester |
| 普通功能新增 / bug 修复 | 标准档；单模块轻功能或根因已定位的小 bug 可走快速档 |
| 架构重构、加密、同步机制 | 完整档；必要时追加 code review |

与 §2.1 不一致时，以 §2.1 + §2.2 为准。

## 4. 子代理

### 4.1 角色

| Agent | 职责 | 可写业务代码 |
|---|---|---|
| explorer | 代码探索、执行路径追踪 | ❌ |
| architect | 方案设计、架构决策 | ❌ |
| coder | TDD 实现 | ✅ |
| tester | 测试验证、完成声明验证 | ❌ |
| reviewer | 终审、置信度评分 | ❌ |
| debugger | 根因分析 | ❌ |

### 4.2 约束与校验

- explorer、architect、tester、reviewer、debugger 禁止用 Write/Edit 修改业务代码。
- 主代理收到子代理结果后交叉校验改动范围。
- 子代理工具调用可通过 Argus 插件审计。

### 4.3 调用

- `subagent_type` 使用对应角色名。
- 并发只允许只读 explorer；写代码与验收一次一个。
- spawn 只传任务文件路径、目标和验收标准；详细需求放任务文件。

## 5. 子代理规则边界

- 子代理只加载自身定义，不继承 `CLAUDE.md` 或本文件。
- 角色专属职责、约束和验收标准必须写入 `.claude/agents/*.md` 与 `.codex/agents/*.toml`。
- 两份容器正文必须一致；不能依赖主指引向子代理传递专属规则。

## 6. 主代理编排规范

违反本节视为编排事故。细则见 `docs/pipeline-workflow.md`。

1. 子代理交付物全部落盘 `.codex/pipeline/`，下一阶段直接读文件。
2. 默认文件投递；消息投递只在无法建任务文件时使用。
3. 每个阶段使用全新实例；已完结实例不 followup。中断、失败、超时一律重开。
4. 文件投递失败时重开一次；消息投递失败时改文件投递。同一方式最多重试一次。
5. 任务文件只写：输入路径、本阶段增量要求、输出路径；需求唯一源在任务文件。

`.codex/pipeline/` 由 Claude 与 Codex 共用；只有 `summary.md` 入库，其余产物和 `archive/` 仍 gitignored。归档前确认两侧都没有在途任务。

### 6.1 握手与交付

- 文件投递：子代理先读任务文件确认加载，再开工。
- 消息投递：先回复“收到任务，开始执行”。
- 子代理必须把交付物写到指定路径；主代理检查文件存在性和 git 改动范围。

### 6.2 决策留档

验收后，把 explorer/architect 的关键决策按「背景-决策-后果」写入 `docs/decisions/`。

### 6.3 产物治理

- 命名：`<里程碑>-<阶段>-<代理>.md`。
- 新阶段前归档上一阶段产物；保留最近一个里程碑全过程与历史摘要。

### 6.4 checkpoint

coder 每完成一个逻辑单元 commit 一次；中断后从最后一个 commit 续跑。

### 6.5 explorer 并行

按 server / client / 平台拆分只读 explorer；写代码阶段保持串行。

### 6.6 成本摘要

每轮追加一行到 `.codex/pipeline/summary.md`：

`档位/组合 | 代理数 | 墙钟 | 产物路径 | 结论 | model`

成本摘要不进用户交付。

### 6.7 审计

子代理报告不可由主代理删改；每任务记录阶段组合、理由和产物路径，供复盘与查证。

### 6.8 边界请示

| 档位 | 流程 | 预计时长 | 质量保障 | 适用 |
|---|---|---|---|---|
| 快速 | 直做 → 业务代码必选 tester | ~10 分钟 | 单测 + 独立验证 | 小改动 |
| 标准 | explorer → coder → tester | ~30 分钟 | 探索 + 独立测试 | 中等功能 |
| 完整 | explorer → architect → coder → tester → reviewer | ~60 分钟 | 全链路 + 终审 | 重大改动 |

## 构建、测试、检查

```bash
flutter test
bash server/smoke-test.sh
flutter analyze
```

- Flutter：`~/development/flutter/bin/flutter`；旧的 `/opt/homebrew/bin/flutter` 已不存在。
- `flutter analyze` 的 warning 和 info 也会导致 exit 1；error 必须为零。
- 当前测试数量与 analyze 条数以本次实际输出为准，不在本文件维护快照。

## 核心设计决策

以下是不可违反的硬约束。详细机制与后果见 `docs/architecture.md`、`CLAUDE.md` 硬红线和各 decisions。

- **密码即账户**：`userId = "user_" + SHA256("clipflow:$password").substring(0, 16)`；不得改派生算法，不得引入邮箱/用户名注册体系。
- **Token 持久化**：存 SQLite `tokens` 表，不可改回内存，不可删表；401 自动重新认证并重试。
- **无外键**：所有现有表和新建表都不得添加 FOREIGN KEY。
- **端到端加密**：AES-256-GCM（128-bit tag）+ PBKDF2-HMAC-SHA256（100000 次）；载荷格式 `[2字节 IV 长度][IV][密文+tag]` 的 base64。算法、参数和序列化不可改。
- **服务器只见密文**：内容必须在客户端加密后才上传。
- **LAN 密钥隔离**：`K_lan = HMAC-SHA256(账户密钥, "clipflow:lan-auth-v1")`，不得与内容密钥混用；不得在 LAN 广播/报文中携带 token、userId、密码、salt、证书指纹或明文文件名。
- **同步防回环**：`ignoreHashes`、文件在途签名守卫、时间戳+来源设备跳过检查不可删。
- **历史裁剪**：置顶条目不占名额永不裁剪；垃圾箱软删条目不参与裁剪。服务端与 `HistoryService._trim()` 必须一致。
- **三端样式一致**：UI 样式/布局层禁止 `Platform.isXXX` / `kIsWeb` 分支；功能层平台适配不受此限制，不要误删。
- **连接方式**：生产 API 为直连 IP + 自签证书指纹固定；域名与 Cloudflare Tunnel 已废弃，不要改回。
- **OSS 现实状态**：代码已实现，生产保持 compat 模式；启用阈值见 decisions 010。
- **技术栈**：Flutter + Provider；Node.js + Express + SQLite。

## 工具差异对照

| 项 | Codex | Claude Code |
|---|---|---|
| 子代理定义 | `.codex/agents/<name>.toml` 的 `developer_instructions` | `.claude/agents/<name>.md` 的 YAML frontmatter + 正文 |
| 子代理调用 | `run_in_background: false` 串行等待 | 同一消息多个 Agent = 并发；分多条消息 = 串行 |
| 主代理身份 | `/root` | Claude Code 主会话 |
| 指引入口 | 本文件 | `CLAUDE.md` 导入 + 末尾硬红线 |
| 技能清单 | 工具自动发现，不在文档维护 | 同左 |
| 管线目录 | `.codex/pipeline/` | 同左，共用 |

两份 agent 定义正文必须一致。改动一侧时同步另一侧。

## 项目治理护栏

1. `scripts/check-agent-docs.sh` 校验事实源、硬红线、关键章节和 agent 正文。
2. `.githooks/pre-commit` 用 `--staged --strict` 检查提交快照；治理文件暂存/工作树不一致或存在未跟踪残留时阻止提交。
3. 架构边界由 reviewer/主代理人工审查：不新增反向依赖、第二套同步路由或状态所有者；已知债务逐步减少。

```bash
bash scripts/check-agent-docs.sh --strict
bash scripts/check-agent-docs.sh --staged --strict
```

每台机器启用一次：`git config core.hooksPath .githooks`。

> `.codex/agents/*.toml` 与 `.claude/agents/*.md` 均入库并双向校验。hook 只在本机生效，其他 fork/CI 目前没有同等门禁。
