# ClipFlow 全项目交付后综合审查提示词

> **用法：** 在 clipflow 仓库根目录新开一个 Claude Code 会话，输入
> 「读取 docs/project-review-prompt.md 并严格执行」，或直接粘贴下方分割线之后的全文。
> 执行方为新会话的主代理，全程只读，不修改任何代码。

---

# ClipFlow 全项目交付后综合审查

## 0. 任务性质与管线覆盖声明（先读这一段）

本任务是对已完成项目的**只读交付后审查**，不是开发任务。以下规则显式覆盖 CLAUDE.md「Agent 专用管线工作流」的路由表：

- **不使用** explorer → architect → coder → tester → reviewer / debugger 串行开发管线，不启动整改循环，不修复任何发现的问题（发现本身即交付物）
- 全程**只读**：你与所有子代理均不得使用 Edit/Write 修改任何项目文件，不得 git commit/push，不得 flutter build
- Phase 1 的五个审查子代理**在同一消息内并行启动**，不受 CLAUDE.md「仅串行委派」约束——五个维度相互独立且全部只读
- 本提示词已是完整规格：无需 brainstorming，无需进入计划模式，直接按 Phase 0 → 3 执行
- 子代理的中间过程与原始报告不进入用户主聊天框，仅最终综合报告交付用户（沿用 CLAUDE.md 交付规范）

## 1. 项目背景（一段话，给子代理传递用）

ClipFlow：跨平台剪切板同步工具（macOS / Android / Windows，iPad 走快捷指令 + Web App），端到端加密（客户端 AES-256-GCM + PBKDF2，服务器只存密文）。Flutter 客户端 + Node.js/Express + SQLite 自建服务器（阿里云 ECS，代码在本仓库 `server/` 下）。除云端同步外，代码库还包含 CLAUDE.md 描述不足的多个子系统：LAN 优先同步（`lib/services/` 下 8 个 `lan_*.dart`：发现、握手、自签 TLS、协议、同步管理器、诊断）、文件与图片剪切板（压缩、断点、下载熔断）、OSS 直传（phase25，当前 compat 模式，见 `docs/decisions/010`）。`lib/services/` 共约 29 个服务文件。

## 2. 铁律豁免清单（审查红线）

以下是**有意为之的架构决策**。不得将决策本身上报为问题（例如：不得建议改用系统原生剪切板通知 API、不得建议给表加外键、不得建议增加注册系统）。但你**必须**验证代码实现是否真正遵守——实现偏离决策属于高优先级问题。

来自 CLAUDE.md：

1. **密码即账户**：userId = `user_` + `SHA256("clipflow:$password")` 截前 16 位。无注册系统，同密码即同账户
2. **Token 持久化**：token 存 SQLite `tokens` 表，非内存；客户端 401 时自动重登重试
3. **全库无外键**：所有表无 FOREIGN KEY 约束，新建表也不得加
4. **剪切板监听双轨**：桌面端 500ms `Timer.periodic` 轮询；Android 用原生 `ClipboardManager.OnPrimaryClipChangedListener` + Foreground Service（MethodChannel 传入内容）
5. **端到端加密**：客户端加密后才上传，服务器只见密文；PBKDF2-HMAC-SHA256 10 万次迭代
6. **三端同构 UI**：不写平台分支 Widget 树；`inputDecorationTheme` 不设全局边框
7. **SQLite 选型**：单文件、零运维，适配 2核2G ECS

来自 `docs/decisions/`：**001–010 号决策文档全部视为铁律**（001 直连 IP + 自签证书指纹固定、003 LAN 优先协调器 + 成功回执、007 LAN-only 模式、008 持久化游标 + 墓碑、009 Windows win32-dnssd、010 OSS 直传暂缓转 compat 模式等）。Phase 0 需通读全部 10 份文档并汇总为「有意决策表」。

## 3. 执行工作流

### Phase 0 — 事实基线（串行，派 1 个 general-purpose 子代理）

产出一份**事实基线表**，作为 Phase 1 五个代理的共享输入（须原文传入每个代理的 prompt）：

1. 运行 `/opt/homebrew/bin/flutter test` 与 `/opt/homebrew/bin/flutter analyze`，记录完整结果。注意：analyze 的 info 级也会导致 exit code 1，**只有 error 级需要重点标注**，info 数量单独统计即可，不算失败
2. git 全量历史：`git log --oneline` 全量输出，并按主题归纳（云端同步 / 垃圾箱 / LAN phase2x / Phase 5.x / OSS / 加密 / 文档）
3. 声明清单：通读 `PROGRESS.md`、`README.md`、`docs/version-roadmap.md`、`docs/phase25-final-plan.md`、`docs/lan-priority-sync-roadmap.md`、`docs/decisions/README.md` 及 001–010 全部决策文档，提取所有「已声称完成」的功能与里程碑，**逐条编号**
4. 铁律基线：将第 2 节清单 + decisions 001–010 汇总为一张「有意决策表」
5. 规模盘点：`lib/` 与 `server/` 的文件数与行数；`test/` 目录实际覆盖的文件清单，与 `lib/services/` 全部服务文件对照，标出**无任何测试的服务**

### Phase 1 — 五维并行审查（同一消息并行启动 5 个 general-purpose 子代理，每个的 prompt 均注入：事实基线表全文 + 第 2 节铁律清单全文 + 对应维度清单 + 第 5 节证据规则，并显式声明「你只读，禁用 Edit/Write，不得修改任何文件」）

**A · 质量审计**
- flutter analyze 的 error 级条目逐条定性（真 bug / 误报 / 待确认）
- flutter test 失败逐条分析原因
- 测试盲区：基线表中标出无测试的服务，评估其中承担核心逻辑者（如 sync_coordinator、lan_sync_manager、file_*）的风险
- 错误处理：网络异常、JSON 解析、超时、空值边界是否被捕获或会让 UI 崩溃
- 并发与生命周期：Timer 的取消、Stream 的关闭、`ignoreHashes` 防循环机制、监听器 pause/resume 是否严格配对（漏 resume = 功能永久失效）
- 服务器保留策略的实现核对：clipboard 表仅留 1 条、history 留 100 条、token 24h 清理、垃圾箱 24h 自动清理——逐一找到实现代码并核对触发时机

**B · 安全审计**
- 加密实现：AES-256-GCM 的 IV 生成方式与唯一性保障（`encryption_service.dart`）；PBKDF2 迭代次数、salt 的存取路径与传输是否经认证；`EncryptedData` 打包格式（IV+密文 base64）的正确性
- 密钥生命周期：派生后的密钥在内存中驻留多久、是否有不必要的持久化/日志泄露
- 自签证书体系：decision 001 的证书指纹固定（pinning）实现强度；`lan_tls.dart` 的校验逻辑是否存在接受任意证书的路径
- 数据隔离：不同密码 → 不同 userId → 数据完全隔离，是否在 clipboard / history / devices / salt / tokens **每张表**都成立；userId 可否被伪造冒用
- 服务器（`server/index.js`）：SQL 是否全部参数化；各 API 输入校验；token 认证路径与 401 重登；无外键（铁律）前提下孤儿数据与跨用户数据的一致性风险
- 文件路径（`server/file_store.js`、`oss_stub.js`、phase25 presign 相关）：路径遍历、文件大小/类型限制、presign 的签名与过期
- LAN 通道上的数据是否同样端到端加密，还是仅 TLS 传输加密
- 全链路明文扫描：密文以外是否有任何明文内容落盘、落库或进入日志（含 crash_reporter）

**C · 交付验收**
- 将 Phase 0 的声明清单逐项与代码对照：git 提交中声称的 phase25 M4–M6（OSS 直传+presign+测试）、Phase 5.1/5.2（LAN-only、游标+墓碑）、decision 009（Windows win32-dnssd 插件）等，是否在代码中**真实存在且完整**（有实现、有调用方、有测试）
- `PROGRESS.md` 更新于 2026-08-06，但仓库此后仍有提交：列出所有**声明落后于实现**的项
- roadmap 中标记为搁置/暂缓的项（如 decision 010 OSS 转 compat 模式）与代码现状是否一致——搁置的代码是否被正确降级而非半启用
- `docs/manual-test-checklist-v1.5.md` 的检查项与现存 UI 页面/组件能否对上

**D · 文档与债盘点**
- CLAUDE.md 与实际代码的脱节：已知线索——CLAUDE.md **完全未提及 LAN 同步子系统**，而 `lib/services/` 有 8 个 `lan_*.dart`；完整核对 CLAUDE.md 每一节（架构图、服务列表、数据流、API 表）与代码现状的差异，输出**需补写/改写的章节清单**
- README / PROGRESS / AGENTS.md / WINDOWS_SETUP.md 的时效性
- `grep -rn "TODO\|FIXME\|HACK\|XXX" lib/ server/` 全量清单，逐条判断是否为活债
- 依赖债：pubspec 当前 pointycastle ^3.9.1、permission_handler ^11.3.1，均落后大版本（既有升级计划：pointycastle 3→4、permission_handler 11→13）；检查 `pubspec.lock` 实际锁定版本及其它落后版本
- `archive/`、`releases/`、`build/` 目录的角色，是否应进 `.gitignore`
- `analysis_options.yaml` 严格度是否与项目现状匹配

**E · 功能设计与三端统一性（两个子任务）**

*E1 功能设计质量*——以 PROGRESS.md 已完成功能为索引，逐个评判**设计本身**（不只找 bug，评判交互与边界设计）：
- 解锁与密码即账户流程（错误提示、首次输入与后续输入的一致性）
- 混合同步（全量加载 + 周期轮询 + 本地独有条目保护 + 服务器不可达降级）的衔接与状态一致性
- 垃圾箱闭环（软删/恢复/24h 清理/多设备同步）的交互完整性
- 多选拼接（有序选中、分隔符、预览）
- LAN 优先切换：云端/LAN/LAN-only 三态决策与失败回退（decision 003/007）——回退路径是否完整、用户能否感知当前通道
- 文件与图片剪切板（压缩、断点续传、下载熔断）
- Android 触发式同步三模式并存（通知栏/打开 App/轮询）的切换逻辑
- 设置项与同步循环的联动（改开关是否即时生效）
每个功能回答三问：交互闭环是否完整？边界状态（空/超时/并发/离线）是否有设计？失败路径用户能否感知？

*E2 三端统一性硬规则*——机械执行并输出违规清单：
- `grep -rn "Platform.is\|kIsWeb" lib/` 逐条判定：**UI 样式/布局层 = 违规；功能层（Android MethodChannel、设备名映射等）= 合规**
- 所有 `TextField` 是否显式声明 `border` 与 `filled`（缺省会拿 Flutter 默认下划线）
- 自定义 Material 组件是否设 `surfaceTintColor: Colors.transparent`
- 组件级颜色是否用 `ColorScheme` token 而非硬编码（品牌色 `Color(0xFF5B6CF0)` 属例外）
- 是否存在按平台分叉的 Widget 树

### Phase 2 — 交叉验证（串行，派 1 个只读子代理）

逐条复核 Phase 1 的全部发现：
1. 重新打开每条证据的 file:line，确认引用真实存在且摘录未断章取义
2. 推演失败场景是否**真实可达**（有具体触发路径），而非理论风险
3. 复核是否误伤第 2 节铁律豁免清单（把有意决策报成了问题）
4. 赋每条置信度：高 / 中 / 低
5. 证据不成立 → 删除；推理不成立 → 移入「待人工确认」栏并注明存疑点

### Phase 3 — 主代理汇总（自己完成，不再派代理）

按第 6 节格式输出最终综合报告，全文交付用户。

## 4. 验证边界

**允许**：Read / Grep / Glob；只读 git 命令（log / show / diff / blame）；`/opt/homebrew/bin/flutter test`；`/opt/homebrew/bin/flutter analyze`；ls / find / du / wc。

**禁止**：SSH 到 121.196.222.122 或触碰任何线上服务与数据库；flutter build / run；Edit / Write 修改任何项目文件；git commit / push / branch；安装或升级依赖。若依赖缺失导致 test 无法运行，如实记录并跳过该项，**不得自行修复**。

## 5. 证据规则（对所有子代理强制）

每条发现必须包含三要素：
1. **file:line 引用**（如 `lib/services/sync_service.dart:142`）
2. **关键代码摘录**（≤ 5 行）
3. **一句话失败场景**：什么输入/状态 → 什么错误结果

禁止无出处的推测与纯理论风险（如「PBKDF2 10 万次迭代偏弱」这类无对比基准的判断）。无法在代码中佐证的风险只能进「待人工确认」栏。

## 6. 最终报告格式（单一综合报告，按此结构输出）

1. **执行摘要**：整体健康度结论（一段话）+ 各维度一句话结论 + P0/P1/P2 数量统计
2. **问题清单**：按 P0（严重：数据丢失/安全破绽/核心功能失效）→ P1（重要：功能缺陷/明显设计问题）→ P2（改进项）排序；每条含：维度标签、file:line、失败场景、置信度
3. **交付验收核对表**：Phase 0 声明清单逐项 ✅ 已验证完成 / ❌ 声明与代码不符 / ⚠️ 部分完成，附证据
4. **三端统一性专项**：E2 各项硬规则的违规清单与合规确认
5. **技术债清单**：每条附建议处理时机（随下次功能 / 随 v1.3 依赖升级 / 专项处理）
6. **文档补写清单**：CLAUDE.md 及各文档需补写/改写的具体章节
7. **待人工确认栏**：证据不足或需线上环境才能验证的疑点
8. **已检查且无问题的领域**：明确列出查过且干净的领域（防止报告只报忧不报平安）
