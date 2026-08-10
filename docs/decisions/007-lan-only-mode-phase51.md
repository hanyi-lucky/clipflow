# 007 · LAN-only 独立模式正式化（Phase 2.5-5.1）

- 日期：2026-08-10
- 档位/组合：完整（2 explorer 并行 → architect → coder → tester → reviewer → 1 轮整改 → retest → fix-reviewer）

## 背景
- 实验性 `lanOnlyMode`（文本路径）已在真机验证零服务器写入；5.1 将其正式化：设置页开关、三型内容（文本/图片/≤15MiB 文件）全走 LAN、真实降级状态。
- 6GB 是阿里云 ECS 月度流量额度（LAN 的动机），不作为容量功能加入计划。

## 决策
1. `lanOnlyMode` 由 static 改为实例字段 + `SettingsProvider` 持久化（`lan_only_mode` key），不变式 **lanOnly ⇒ lanAcceleration**（级联只在设置页）。
2. 三型上传在 Provider 层加 `if (_lanOnlyMode)` 分支走 LAN（复用 `pushOperation` 三型 + `_onOperationSucceeded` 补账；文件先 `importEncryptedFile` 再 push）；>15MiB 走 Cloud；握手票据仍走服务端。
3. 新增 `SyncStatus.localOnly` + `LanSyncManager.hasVerifiedPeers`（真实握手态）；durable-local 语义：无 peer 也保留本地内容 + 首页横幅「内容仅在本地、未同步到其他设备」；**5.1 不做跨会话补发**（维持 outbox TTL 30s/3 次，跨分钟收敛归 5.2 durable cursor）。
4. 启动先恢复持久化历史再合并服务器历史（`_restorePersistedHistoryIfEmpty`），`cleanupOrphans` 不删 LAN-only artifact（reviewer 高置信缺陷整改）。

## 后果
- 同 Wi-Fi 下三型内容零服务器流量（服务器 DB 零内容写入）；对端离线内容保留本地并明确提示；开关切换不丢内容。
- 删除/恢复仍 Cloud-only（5.2 承接）；离线 >30s 不补发历史；Windows 无 LAN 插件时走降级路径。
- 红线零触碰：Cloud/加密/userId/tokens/lan_protocol/lan_transport/原生插件/服务端 0 改动。
- 全量 `flutter test` 473/473；`flutter analyze` 0 error；真机重启链路未验证（交付标注）。
