# Phase 2.5 最终方案（LAN-only 独立模式正式化 + 后续里程碑）

> 状态：已对齐拆分（5.1 优先）｜2026-08-10
> 前置：Phase 2.1–2.4 全部完成（含真机双向纯 LAN 内容交付实证、服务器零写入验证）。
> 背景：6GB 指阿里云 ECS 月度流量额度（LAN 同步的动机，非容量功能）——本计划不含任何 6GB 容量/流量观测交付项。

## 里程碑拆分（执行顺序）

### 5.1 LAN-only 独立模式正式化（⭐ 第一优先）
把实验性 `lanOnlyMode` 升级为正式功能，用户可在设置页开关，同一 Wi-Fi 下内容零服务器流量。

**范围**
1. **设置页开关**：新增「仅局域网同步（实验）」开关，默认关；开启时提示实验性说明（对端离线不保证送达）。
2. **三类内容全覆盖**：文本（已有）→ 图片 → 文件（≤15MiB），上传/下载完全走 LAN、跳过云端内容读写；握手票据仍走服务端。
3. **降级策略**：无 verified peer / 会话断开时——内容**保留本地** + **明确 UI 提示「内容仅在本地、未同步到其他设备」**（不静默丢内容）；可选复用 2.3 LAN outbox 做「对端恢复后补发」；开关关闭恢复 Cloud 权威。
4. **删除/恢复语义 + durable cursor：不纳入 5.1（拆到 5.2）**——5.1 只保证「新内容双向 LAN 交付」；删除/置顶/恢复的跨设备收敛与历史语义统一归 5.2，避免 5.1 范围过大。
5. **多设备收敛（限定）**：同一账户多设备在 LAN 内互相同步（peer 去重、不回推、无回声）——仅覆盖「同一时刻在线」的收敛；离线期间的历史/删除收敛归 5.2。
6. **状态与诊断**：真实连接状态（不模拟"connected"）；复用诊断计数。

**验收标准**
- 设置页开关开启/关闭生效，持久化；关闭后 Cloud 行为与未开一致（回归锚点）。
- 文本/图片/文件（≤15MiB）双向 LAN 交付，服务器 DB 零内容写入；>15MiB 仍走 Cloud。
- 对端离线/断会话：不丢内容（本地保留）、有 UI 提示、可自动恢复。
- LAN-only ↔ Cloud 开关切换（含有未发送内容时）不丢内容。
- `flutter test` 全量 + `analyze` 0 error；真机回归（Mac+Android）。

**档位**：完整（explorer 并行 → architect → coder → tester → reviewer）。

### 5.2 durable cursor + tombstone（删除/恢复持久化收敛，roadmap 既定目标）
**目标**：服务端新增 durable operation log / 单调 cursor / tombstone，替代当前 30 秒 `deletedIds/restoredEntries` 窗口；离线设备可重放删除/恢复；之后才允许删除/恢复经 LAN 分发（默认 Cloud-only 兜底）。

**范围**
1. 服务端 additive：新表（`sync_operations`/`sync_tombstones`，**不加 FOREIGN KEY**）+ `/api/sync/*` 路由（commit 幂等：同 operationId 返回同结果、冲突 payload 拒绝）。
2. 客户端 `SyncOperationKind` 扩展 `delete`/`restore`（当前只有 text/image/file）；删除/恢复生成稳定 operationId 走统一 outbox。
3. 用 durable cursor 替代客户端对 30 秒窗口的依赖；历史/删除/恢复的 LAN 与 Cloud 语义统一。
4. 旧 API/旧客户端不受影响（能力探测后新客户端才用新协议）。

**验收标准**
- 离线 >30s 的设备仍能收敛删除/恢复（不复活、不丢失）。
- 同 operationId 重复提交只产生 1 条 history；LAN/Cloud 乱序不重复写。
- 服务端 smoke test 全绿；`flutter test` 全量 + `analyze` 0 error。

**档位**：完整（触数据库结构红线）。

### 5.3 OSS 直传（大文件不经服务器中转）—— 已确认实施，独立 RFC
- **目标**：文件字节不经过 ECS，省 ECS 公共流量与磁盘；尤其非 LAN 场景的大文件。
- **机制**：服务端签发预签名 URL/STS 临时凭证 → 客户端直传/直下 OSS（仍是客户端加密后的密文）→ 服务端只存历史元数据与 OSS key。
- **注**：OSS 已确认实施（2026-08-10）——作为独立 RFC 推进，不阻塞 5.1/5.2；引入新存储服务与计费需在 RFC 中定成本模型。
- **红线/复杂度**：孤儿对象扫描回收、删除/恢复生命周期与 history 联动、预签名时效与密钥管理、双读验证后切单写、OSS 单独计费的成本模型评估。
- 档位：完整（触加密/存储架构红线）；不阻塞 5.1/5.2。




### 附加待办（独立，可插队）
- **LAN 会话稳定性优化**：迟到帧竞态导致的周期断开（不阻塞交付，但产生反复握手）→ 减少重连噪声。
- **Windows LAN 支持**：参考 macOS/Android 补 Windows 原生 mDNS（WinRT Dnssd）+ TLS + 注册 `generated_plugin_registrant.cc`。

## 关键约束（贯穿全部）
- 不删改 CloudBaseService/CloudRepository/服务端 API（只 additive）；不改 userId 派生/AES/PBKDF2/tokens/无外键。
- LAN-only 不混入云端历史语义（roadmap 既定）；切换开关不得丢数据。
- LAN 报文禁 userId/密码/token/K_lan/salt/证书指纹/文件名明文（已实现，保持）。
- 每里程碑走管线并落盘报告 + 决策留档（docs/decisions/）。
