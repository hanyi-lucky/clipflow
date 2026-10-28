# ClipFlow 优化路线图（已审查）

> 状态：**已审查；大方向、阶段顺序与分阶段验收已确认。具体批次开工前仍需满足本文门槛。**
> 制定依据：2026-10-27 三路只读审计（同步可靠性、性能资源、服务端运维与产品体验）+ 2026-10-28 工程治理基线。
> 计划性质：大方向已确认，具体范围、顺序、验收门槛可在阶段开始前调整；任何扩项都要说明理由并留痕。
>
> 执行原则：先正确性，后韧性，再效率，最后体验与工程优化。阶段之间不得并行抢跑；同一阶段内部按小批次独立验收。

## 1. 总路线

| 阶段 | 主题 | 目标 | 当前状态 |
|---|---|---|---|
| Phase 0 | 治理基线 | 阻止状态、agent 和专题文档继续漂移；让 AI 指引入口保持轻量 | 已完成（待提交） |
| Phase 1 | 同步正确性 | 删除/恢复、离线重放、Windows 持久化和 LAN-only 不复活、不丢失 | 1A 完成（已知 ADS 限制）；1B/1C 未开始 |
| Phase 2 | 数据与运维韧性 | 服务端可备份、可恢复、可验证，发布可追溯 | 未开始 |
| Phase 3 | 网络与资源效率 | 降低空闲流量、峰值内存和磁盘无界增长 | 未开始 |
| Phase 4 | 体验与工程治理 | 提高错误可见性，补齐 CI、诊断和依赖维护 | 未开始 |

暂缓：OSS 生产启用、v2.0 功能、大规模架构重构、离线解锁、自研静态分析器。见第 8 节。

## 2. Phase 0：治理基线

### 目标

1. 明确 `PROGRESS.md` 是唯一当前状态入口。
2. `AGENTS.md` 收敛为“路由表 + 硬约束”，专题正文进入独立文档。
3. `.codex/agents/*.toml` 与 `.claude/agents/*.md` 双容器入库并校验。
4. pre-commit 检查同一提交快照，避免治理文件“工作树通过、暂存区失败”。
5. 不继续扩展自研解析器或小型静态分析工具。

### 已完成内容

- 工程决策原则已写入 `AGENTS.md`。
- 架构、数据流、加密、LAN、数据库移到 `docs/architecture.md`。
- 子代理管线细则移到 `docs/pipeline-workflow.md`。
- 服务器运维移到 `docs/server-operations.md`。
- 决策记录增加索引：`docs/decisions/README.md`。
- `AGENTS.md` 从 491 行 / 34,990 bytes 降至约 267 行 / 13.9KB。
- 体积只作为审查参考，不作为硬性行数门禁。

### 收尾结果

- 当前事实冲突已清理，专题文档无高置信重复事实源。
- 独立 reviewer 复验通过：暂存快照、工作树检查、agent 负向门禁均通过。
- 治理改动已与图标、`analysis_options.yaml`、`pubspec.lock` 等无关改动分开暂存。
- Phase 0 成本摘要已写入 `.codex/pipeline/summary.md`。
- 尚未执行 git commit；提交由用户确认。

### 退出条件

- `bash scripts/check-agent-docs.sh --strict` 通过。
- `bash -n scripts/check-agent-docs.sh .githooks/pre-commit`、`git diff --check` 通过。
- 6 组 agent 正文一致且均在暂存区。
- `AGENTS.md` 的关键硬约束、档位、强制底限和路由入口无缺失。
- 专题正文只有一份事实源，没有复制成第二份规则。
- 独立 reviewer 无高置信阻断问题。

## 3. Phase 1：同步正确性

### 目标

保证删除、恢复、离线重放、Windows 持久化和 LAN-only 本地提交不会产生：

- 已删除条目复活；
- 已恢复条目再次被旧删除意图覆盖；
- cursor 已推进但 history 尚未落盘；
- Windows 无法写入或读取 outbox；
- LAN manager 不可用时本地内容没有 durable 落盘。

### 3.1 Phase 1A：Windows outbox 文件名兼容

**问题**

逻辑 operationId 使用 `del:<entryId>` / `rest:<entryId>`，但 `LocalOutboxStore` 直接把它作为文件名。冒号在 Windows 是保留字符，可能导致写入失败、ADS 或无法重新加载。

**实施结果（2026-10-28，SHA cdc785d + 验收文档 d27a9ee）**

- canonical 文件名已改为 `v2-<sha256>.json`，临时文件唯一化，直接 rename 替换；
- 路径身份统一走 URI key，修复 Windows 混合分隔符误判；
- 旧 UUID / 通用旧文件名可迁移；旧 `del:`/`rest:` 若已落成 ADS，Dart 目录枚举无法恢复，已记录为明确残余风险；
- 本机与 Windows 专项测试、coordinator 测试和 Windows release 构建通过。
- 结论：新 canonical 路径在 Windows 已验收；旧冒号 ADS 不恢复，作为已知残余风险记录。Phase 1A 关闭。

**范围**

- 保持线上 `del:` / `rest:` operationId 格式不变。
- 存储层使用 SHA-256 或 URL-safe Base64 生成安全文件名。
- 文件名规则必须带版本前缀（例如 `v2-<hash>.json`），避免算法升级不可识别。
- 旧 `del:<id>.json` / `rest:<id>.json` 按“双读 → 原子迁移 → 再删除旧文件”处理；迁移失败时保留旧文件，不能丢操作。
- `remove` 同时兼容新文件名与旧文件名；只删除对应 operationId 的 manifest，不误删其他操作。
- 覆盖 text、image、file、delete、restore 全类型。

**不做**

- 不改服务端 operationId 解析。
- 不改同步状态机。
- 不改加密格式。

**验收**

- Windows 真机执行 `put → restart → loadActive → remove`。
- 目录中不出现非法文件名或 ADS。
- 旧 `del:`/`rest:` manifest 在升级后能加载、迁移、删除，且不重复入队。
- 迁移中途中断后重启仍至少保留一份可恢复记录，不产生重复 active op。
- 删除/恢复离线重试不丢失。
- operationId 在协议层仍保持原格式。

### 3.2 Phase 1B：删除/恢复状态收敛

**问题**

当前至少有三类状态来源：current clipboard、durable op log、客户端 `deletedEntryIds`/时间窗口。它们没有统一版本语义，可能导致删除复活、恢复后再删除结果错误，或 cursor 先于 history 落盘。

**范围**

- 定义 current、operations、tombstone 的统一状态优先级。
- 明确唯一权威：新路径以服务端 op `seq` + 持久化 cursor 为准；`deletedEntryIds` 仅作旧 API/op 保留期之外的兼容兜底，不扩展成第二套版本状态。
- 保留 `seq`，按 entryId 折叠最终状态或按序应用。
- current 行若被同批 op 判为 deleted，不得重新写入剪贴板/历史。
- `hasMore` 先排空再合并 current。
- `deletedEntryIds` 不得覆盖较新的 restore；其清理必须服从 cursor/op 状态，不能自行裁决最终状态。
- 由 architect 定义 history JSON 与 SharedPreferences cursor 两个独立持久化位置的 journal/可重放顺序；“同一 checkpoint”必须落成具体故障窗口与恢复步骤，不能只写概念。
- refresh、LAN push、周期 tick 共用同一个串行拉取/应用边界。

**必须先行**

本批次触及同步去重和持久化核心，必须先由 architect 冻结状态机，再进入 coder。不能直接边写边改。

**前置门槛**

- 在改同步应用路径前，确认生产数据库与文件密文存在一致、可验证的备份，并写明失败回滚路径。
- Phase 2 再完成自动化、异机保留和 RPO/RTO；本门槛只保证“首次高风险改动可以恢复”。

**验收**

- `delete → restore → delete` 最终删除。
- `restore → delete → restore` 最终恢复。
- 等待超过 30 秒结果不变。
- current 与 delete 同 ID 时不复活。
- 删除应用后、history flush 前崩溃，重启不复活。
- refresh 与 LAN push 并发时历史/cursor 一致。
- 预置 250 条 op 时能安全排空或停在安全页边界，current 不抢跑。

### 3.3 Phase 1C：LAN-only durable 本地语义

**问题**

LAN-only 上传在 LAN manager 不存在时直接返回 null；本地历史/artifact 是否落盘仍依赖 LAN 初始化。

产品语义已由决策 007 确定：无 peer 时保留本地内容，**不做跨会话补发**。本阶段不重开该决策。

**范围**

- 先生成密文并完成本地 durable commit，再 best-effort 推送 LAN。
- 本机恢复成功后直接应用权威行，不等待下一轮游标。
- 维持“仅在线会话保证”；不得静默扩大为跨会话 durable replay。
- UI 必须明确说明对端离线时的限制。

**待用户决策**

无。若未来要改变跨会话补发语义，必须新开决策并更新 decision 007，不能在 Phase 1C 内顺带修改。

**验收**

- manager 为 null/启动失败时，文本/图片/文件仍进入本地历史和缓存。
- 本机恢复立即重新出现。
- 在线会话内 peer 收到且不重复；离线 peer 不承诺补发，UI 明示限制并有测试。

### Phase 1 红线

- 不改 AES-256-GCM、PBKDF2 100000 次或 `[2字节 IV 长度][IV][密文+tag]` 格式。
- 不改 userId 派生。
- Token 继续存 SQLite。
- 新表仍不得加 FOREIGN KEY。
- LAN 报文不得携带 userId、token、密码、salt、证书指纹或明文文件名。

## 4. Phase 2：数据与运维韧性

### 目标

从“功能可用”提升到“故障后可恢复、发布可证明”。服务端恢复单元不是单个数据库，而是 SQLite WAL + 文件密文目录 + TLS 证书/私钥 + systemd/反代配置。

### 候选范围

- SQLite 在线备份 + 文件密文快照 + TLS/配置备份。
- 异机加密保存与保留策略（每日/每周/每月）。
- 一次性真实恢复演练。
- liveness/readiness 分离：readiness 只判断能否接流量（DB 查询、文件目录可写、磁盘余量、schema 版本）；备份年龄归入独立 health/degraded 告警，不直接导致服务不可用。
- 显式 schema migration；只忽略明确的“列已存在”，其他失败拒绝启动。
- 未捕获异常退出，SIGTERM 优雅停机。
- smoke 测试独立目录/端口，避免误删本地数据库。
- 部署绑定 commit/版本，改为可靠 restart，并验证运行版本。

### 退出条件

- 空机恢复后 `PRAGMA integrity_check` 为 `ok`。
- 数据库记录数、文件密文、TLS 指纹一致。
- 抽样条目可由客户端解密。
- RPO ≤ 24h、RTO ≤ 30min，并至少完成一次恢复演练。
- readiness 在 DB/磁盘/目录异常时返回非成功；备份过期进入 degraded 状态与告警。

### 暂不包含

- 离线解锁；触及认证红线，单独立项。
- 多机高可用、集群化。
- OSS 生产启用。

## 5. Phase 3：网络与资源效率

### 目标

在正确性稳定后，降低空闲网络、峰值内存和磁盘增长。先测量后优化。

### 候选范围

- `/clipboard` 增加轻量版本/ETag 探测，避免每 500ms 下载完整当前密文。
- 设备心跳与内容轮询分离，避免无变化时重复 UPDATE。
- 消除文本/图片一次操作重复 `POST /clipboard`。
- `hasMore` 在单次同步预算内排空。
- 备份导出/导入流式化、临时文件 + 原子 rename。
- 桌面剪贴板读取增加 single-flight，避免慢读取重叠。
- 文件下载进度与历史数据分离，进度更新限频。
- outbox、图片缓存、临时目录统一容量/生命周期预算。

### 开工前先记录基线

- 同一 5MiB 当前图片、同一网络、静置 10 分钟：记录请求数、完整响应字节、心跳 UPDATE 次数。
- 64KiB 人造流下载：记录整页 build 次数。
- 50MiB 文件与 1GiB 备份：记录峰值内存采样方式与上限。
- 离线和反复失败：记录 App Support 目录大小。

基线必须先落盘，再冻结优化指标。

### 必测指标

- 固定 5MiB 当前图片静置 10 分钟：请求数、响应字节、心跳 UPDATE 次数。
- 64KiB 人造流：文件下载期间整页 build 次数。
- 50MiB 文件与 1GiB 备份的峰值内存。
- 离线和反复失败后 App Support 目录大小。

### 退出条件

- 完整内容下载的**响应字节**在不变化时下降 ≥95%，请求数同时下降；以同一负载改前基线为对照。
- 1GiB 备份峰值内存不随总大小线性增长，或有明确产品上限。
- 文件下载不再按 chunk 触发全树重建。
- 缓存目录可回到明确预算内，不误删 active 数据。

## 6. Phase 4：体验与工程治理

### 候选范围

- 垃圾箱区分 loading / error / empty / list；网络失败不能再表现为空垃圾箱。
- 恢复结果区分“已同步”和“已排队待同步”，失败不显示成功。
- 首页显示可读同步状态和重试入口，不只依赖 8×8 圆点。
- LAN-only 降级横幅增加重新发现/查看诊断动作。
- 脱敏诊断摘要：版本、最后同步时间、服务器/LAN 状态、缓存占用、最近错误。
- CI 覆盖治理、三端构建、关键回归和容量门禁。
- 依赖升级分批进行，pointycastle 单独验证加密兼容向量。
- 文档漂移与失效路径清理。

## 7. 阶段依赖与顺序

```text
Phase 0 收尾
    ↓
Phase 1A Windows outbox
    ↓
Phase 1B 状态收敛（先 architect 冻结设计）
    ↓
Phase 1C LAN-only 语义（产品决策后实施）
    ↓
Phase 2 备份/恢复/部署/health
    ↓
Phase 3 网络与资源效率
    ↓
Phase 4 体验/CI/依赖
```

规则：

- 任何阶段如果发现红线或跨 3+ 文件，按 §2.2 升级完整档。
- 阶段之间不得并行启动写代码。
- 同一阶段内每个小批次独立 tester/reviewer，不以“总计划完成”替代单项验收。

## 8. 暂缓事项与理由

| 事项 | 决定 | 理由 |
|---|---|---|
| OSS 生产启用 | 暂缓 | 当前量级未到流量/磁盘阈值；保持 compat 模式 |
| v2.0 分类/标签/快捷键 | 暂缓 | 同步正确性和灾备未稳定前不增加状态 |
| `ClipboardProvider` 大规模拆分 | 暂缓 | 需先冻结依赖方向和状态边界，避免移动代码制造新状态 |
| 服务端 `index.js` 大重构 | 暂缓 | 先做显式 migration、readiness 和恢复；不以重构代替韧性 |
| 离线解锁 | 单独决策 | 触及 token/认证红线，必须 architect + reviewer |
| 自研架构解析器 | 不做 | 治理成本高于收益；严格静态分析用成熟工具或人工审查 |
| 大规模依赖升级 | 暂缓 | 先有 CI 和三端回归门禁；pointycastle 必须独立验证 |

## 9. 已确认与仍需单独决策的事项

已确认：

1. 接受本路线作为后续大方向基线。
2. Phase 1A 只做“存储文件名安全化 + 迁移/删除兼容”，不顺手改状态机。
3. LAN-only 维持决策 007：仅在线会话保证，不做跨会话补发。
4. Phase 3 必须先记录基线，再冻结具体优化项。

仍需单独决策：

1. Phase 2 的备份是否允许使用异机加密存储。
2. 可接受的 RPO/RTO 目标。
3. 是否接受“备份过期只降级告警、不阻断服务”的 health 策略。

## 10. 变更控制

后续允许调整，但必须满足：

- 调整顺序：说明阻塞原因和依赖关系。
- 扩大范围：说明用户价值、风险、档位升级和验收变化。
- 缩小范围：说明剩余风险，不得把未完成项静默移出计划。
- 新增专题正文：放到专题文档，`AGENTS.md` 只保留入口。
- 每次阶段完成：更新本文件的“当前状态”和 `PROGRESS.md`。

## 审查记录（2026-10-28）

> 以下保留审查时的原始发现，便于追溯。各项整改状态见文末“审查整改结果”；已整改项不再代表当前正文缺陷。

**结论：路线顺序和分阶段验收方式可作为讨论基础；完成以下高优先级修订前，不建议启动 Phase 1B/1C。** 本次审查对照了 `AGENTS.md`、`PROGRESS.md`、`docs/architecture.md`、决策 007/008，以及当前 outbox 与同步应用代码；未运行测试。

### 高优先级

1. **Phase 1C 重开了决策 007 已确定的 LAN-only 产品语义。** 决策 007 已规定：无 peer 时保留本地内容、跨会话不补发；Phase 1C 却再次询问是否承诺 peer 上线后补发。当前 `_lanOnlyUploadText`、`_lanOnlyUploadImage` 和文件路径在 LAN manager 不存在时会直接返回，说明仍有“manager 不可用时是否能完成本地 durable commit”的实现缺口，但这不等于补发承诺尚未决定。建议将 Phase 1C 限定为修复本地持久化，并引用决策 007；若要改变跨会话语义，应明确标为重开决策并更新该决策记录。

2. **Phase 1B 尚未明确唯一权威状态，可能把 `deletedEntryIds` 扩成第二套版本状态。** 决策 008 已将服务端 `sync_operations`/`sync_tombstones` 与持久化 cursor 作为删除/恢复收敛路径，并把 `deletedEntryIds` 留作旧 API 或操作日志保留期之外的兜底。计划提出给 `deletedEntryIds` 增加版本/seq 语义，却没有说明它如何服从 durable cursor 和操作日志，存在重复维护删除状态的风险，也与 `AGENTS.md` 的单一状态所有者原则冲突。建议先写清优先级：新路径以 op seq/cursor 为准，`deletedEntryIds` 仅作有边界的兼容兜底，且不得覆盖较新的操作。另需由 architect 说明 history JSON 与 SharedPreferences cursor 这两个独立持久化位置如何通过 journal 或可重放顺序处理崩溃窗口；“同一 checkpoint”目前不是可直接验收的实现定义。

3. **备份恢复门槛排在高风险同步状态改动之后。** Phase 1B 会改变删除/恢复应用及 cursor 推进语义，但完整备份与恢复演练目前排在 Phase 2。建议在 Phase 1B 开始前增加最小恢复前置条件：确认当前数据库和密文文件有一致、可验证的备份，并说明失败回滚路径；Phase 2 再完成自动化、异机保留和 RPO/RTO 目标。这样不会把首次恢复能力验证推迟到状态机改动之后。

### 中优先级

4. **Phase 1A 的旧 outbox 文件迁移和删除路径没有定义完整。** `LocalOutboxStore` 当前以原始 `operationId.json` 写入并按同一路径删除；将文件名改为 hash 后，计划只写了“兼容读取旧 manifest”，没有规定旧路径如何迁移、`remove` 如何找到旧记录，以及迁移中断时如何避免重复或孤儿项。建议明确新文件名版本/算法、旧新格式双读与原子迁移策略，并把旧 `del:`/`rest:` 记录经过重启后可加载、删除且不重复列入验收。

5. **Phase 2 把备份年龄异常直接列为 readiness 失败条件，可能把服务主动判为不可用。** 备份陈旧是重要运维告警，但不必然代表 API 当前无法服务；单实例环境中将它绑定 readiness，可能在数据库仍健康时造成整体不可用。建议把“服务可接流量”和“备份状态降级/告警”分开，除非另有明确的故障策略要求备份过期时拒绝服务。

6. **Phase 3 的量化退出条件还缺少基线和计量口径。** “完整内容下载下降 ≥95%”需明确按请求数、响应字节还是两者计量，并以同一负载下的改前数据作比较；“1GiB 备份峰值内存不随总大小线性增长，或有明确产品上限”也需定义采样方式、上限及触顶后的用户行为。建议在该阶段开工前先记录基线，再冻结指标。

7. **Phase 0 的“没有第二事实源”退出条件尚未满足。** 当前 `PROGRESS.md` 的服务器信息仍写有“经 Cloudflare Tunnel”，与 `AGENTS.md` 及 `docs/server-operations.md` 中“直连 IP、自签证书固定，Tunnel 已废弃”冲突。建议在 Phase 0 验收前把该未标注为历史的当前事实改正或明确标为历史，并据此复核其他专题文档；同时，“大方向已确认”与第 9 节“是否接受本路线”应统一为一种状态表述。

### 建议的开工顺序调整

- Phase 0：先清掉当前事实冲突并完成治理验收。
- Phase 1A：冻结旧 outbox 迁移与删除兼容规则后实施。
- Phase 1B：先定权威状态和崩溃恢复方案，并通过最小备份/恢复前置门槛，再改同步应用路径。
- Phase 1C：按决策 007 修复本地 durable commit；只有用户明确重开补发语义时才扩大范围。
- Phase 2：继续完成完整备份自动化、异机保留、健康状态和发布恢复能力。

## 审查整改结果（2026-10-28）

| 审查项 | 处理结果 | 落点 |
|---|---|---|
| 1C 重开决策 007 | 已关闭该决策点；维持“仅在线会话保证、不做跨会话补发” | §3.3、§9 |
| 1B 权威状态不清 | 已明确 op `seq` + cursor 为权威，`deletedEntryIds` 仅兼容兜底 | §3.2 |
| 高风险改动前无恢复能力 | 已增加 Phase 1B 最小备份/回滚前置门槛；完整自动化仍在 Phase 2 | §3.2、§4 |
| 1A 迁移/删除规则不完整 | 已补充版本化文件名、旧新双读、原子迁移、双路径删除和中断验收 | §3.1 |
| 备份年龄误绑 readiness | 已改为独立 health/degraded 告警，不阻断接流量 | §4 |
| Phase 3 指标缺基线口径 | 已增加开工前基线采集，明确以响应字节和请求数同时对比 | §5 |
| Phase 0 仍有事实冲突 | 已修正 `PROGRESS.md` 当前服务器信息，并标注旧 Tunnel 段落为历史 | `PROGRESS.md` |

### 下一步执行顺序

1. **Phase 0 收尾**：复核本文与专题文档无新冲突；跑治理检查；独立终审；只提交治理相关文件。
2. **Phase 1A**：先冻结文件名版本和迁移状态机，再实施；完成 Windows 真机验收。
3. **Phase 1B**：先确认最小可恢复备份和回滚路径，再由 architect 冻结状态机。
4. **Phase 1C**：按决策 007 修复本地 durable commit，不扩大补发语义。

在上述门槛满足前，不启动对应业务代码修改。
