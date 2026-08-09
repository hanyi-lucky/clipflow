# 006 · 局域网优先同步 Phase 2.3：LAN 可靠性/ACK/诊断/重下熔断

- 日期：2026-08-10
- 档位/组合：完整（2 explorer 并行 → architect → coder → tester → reviewer + 1 整改轮）

## 背景
- Phase 2.2 已实现 LAN 文件交付；Phase 2.3 补齐可靠性（push 无 ACK 对端不可知）、诊断可见性（计数此前为零埋点）、坏 artifact 反复重下问题（每次轮询都重下 Cloud）。

## 决策
1. **fileAck 帧 + 能力协商**：hello 增加可忽略字段 `acks:1`（版本仍 1、原生插件零改动），fileAck（`{v,type,historyId,status}`）只在新↔新会话交换，旧 peer 永不收到 ack（堵住旧 initiator 误读断链缺口）；发送侧 per(peer,historyId) 待确认表，重试**绕过 `_knownHistoryIds` 发送侧去重**；initiator 用 per-session reader slot 读串行化（fetchLatest 遇 busy 跳过不排队，避免 300ms 超时杀死文件 ack-wait）。
2. **持久化 LAN outbox**：独立 store + 独立目录 `clipflow_lan_outbox/<userId>/<peerId>/`（不与云 outbox 冲突）；put 在 push 前（crash-safe）、ACK remove、give-up 删除、重启恢复（缺 artifact 丢弃）；账户切换清理、LAN 开关关闭保留；只装云 durable 已提交操作防双发，Cloud 权威兜底。
3. **诊断计数**：新增 `lan_diagnostics.dart`（8 类 roadmap 计数 + fallbackReason 10 分类 + ackSent/ackReceived），LanSyncManager 持有并注入三层；Provider 暴露 getter；设置页新增「诊断（局域网）」调试区（含手动清零）；`_resetState` 清内存态不删持久化 outbox。
4. **重下熔断**：`FileDownloadBreaker` per-historyId 3 次坏 artifact → 60s 冷却 + half-open 探针；成功/手动重试/取消/行被取代/切账户五重 reset；只在 `_processFileDownload` 入口拦截，不碰 `markAsReceived` 成功顺序。
5. **整改**：默认构造分支三处补 `_diagnostics` 注入（原 5/9 计数生产恒 0）+ 组合测试实证默认构造路径下计数可增长。

## 后果
- 服务端、`lan_protocol` 编解码核心、双端原生插件零改动；AES-256-GCM/PBKDF2/userId 派生/tokens/无外键零 diff。
- 验收通过：flutter test 458/458、analyze 0 error、server smoke 27/27、终审（含整改轮）DONE。
- 遗留/前置（Phase 2.4）：真实双实例/真机 fileAck 端到端实证、macOS 双实例实证、生产部署 `LAN_TICKET_SECRET`、Android 真机后台生命周期；ack 迟到帧断会话自愈竞态为已接受边界。
