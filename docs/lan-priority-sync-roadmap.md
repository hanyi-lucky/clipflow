# ClipFlow 局域网优先同步改造交接记录

> 最后更新：2026-08-09（Asia/Shanghai）
> 当前状态：Phase 1 实现已提交，但测试整改未完成；不要部署到生产。

## 当前 Git 状态

- 分支：`codex/lan-priority-sync`
- 基线备份提交：`6e0393b chore: backup before LAN priority sync`
- Phase 1 实现提交：
  - `4f33c0b feat: add durable sync operation model`
  - `d6f5134 feat: persist sync operations in a user-scoped outbox`
  - `fcf2150 feat: add cloud transport and stable upload preparation`
  - `493f7a1 feat: add durable sync coordinator drain`
  - `436f402 feat: route app sync through coordinator`
- 当前工作树：干净。

## 已完成的 Phase 1 内容

本阶段没有实现真实局域网网络，也没有修改服务端 API，目标是先把云端路径稳定地放入可替换的协调层，为后续 LAN Transport 留出边界。

1. 新增 `SyncOperation` 模型和稳定 `operationId`。
2. 新增按 `userId` 隔离的文件系统 outbox，manifest 原子写入，支持 pending/sending/retryable/dead 状态。
3. 新增 `SyncTransport`、`CloudSyncTransport`。
4. 新增 `SyncCoordinator`，实现 single-flight、有限退避、去重和同一 operationId 重试。
5. Provider 与 ClipboardMonitor 的上传/下载入口改由同一个 Coordinator 处理。
6. 文本下载使用服务端 `history_id`，旧数据没有该字段时保留 UUID fallback。
7. 账户切换时停止同步并清理旧账户 outbox/artifact。
8. 保留 AES-256-GCM、PBKDF2 100000 次、userId 派生、SQLite tokens、无 FOREIGN KEY 和旧 Cloud API。

## 明确尚未实现

- mDNS 设备发现；
- TCP/Noise/TLS 局域网握手；
- LAN 文本/图片/文件传输；
- Android 原生局域网网络服务；
- OSS 直传；
- LAN-only 模式；
- 删除/恢复的 durable cursor/tombstone 改造；
- 6GB 流量指标和成本观测。

## 当前验证结果

### 已通过

- `bash server/smoke-test.sh`：`SMOKE TEST PASSED`。
- `git diff --check HEAD~5..HEAD`：通过。
- `flutter analyze` 在允许 SDK 缓存写入后能完成分析；当前没有 error，但有 warning/info，退出码仍为 1。

### 未通过 / 待整改

`flutter test` 当前失败，结束时为 `+315 -8`。主要症状：

1. Provider/文件/图片测试中出现：
   `MissingPluginException(No implementation found for method getApplicationSupportDirectory on channel plugins.flutter.io/path_provider)`。
   新增 Provider 初始化时会触发 outbox drain，而测试环境没有注册 `path_provider` mock/plugin。
2. `test/services/sync_coordinator_test.dart` 中 retry/pending 相关断言失败，需确认是 Coordinator drain 时序、测试异步写法还是 outbox 状态预期问题。
3. 多个文件上传测试因 outbox drain 失败而超时或连锁失败。

当前没有完成 Flutter 全量测试验收，因此本阶段不能宣称完成，也不能部署。

## 下次继续顺序

### 1. Debugger 根因分析

任务文件：
`/Users/hanyi/clipflow/.codex/pipeline/lan-priority-v1-debugger-task.md`

需要确认：

- 生产代码是否应提供可注入的 `OutboxStore`/路径解析 seam；
- 测试是否应注册 path_provider mock；
- retry 测试是否错误使用了同步 `expect` 检查 Future；
- `drainOnce()` 在失败后是否应该保留 retryable manifest；
- Provider 初始化是否应避免在没有平台存储能力时吞掉或反复打印错误。

### 2. Coder 修复

只修复上述测试和真实生命周期问题，不扩大到 LAN socket。每个逻辑单元独立提交。

### 3. 独立 Tester

必须重新运行：

```bash
flutter analyze
flutter test
flutter test test/services/sync_coordinator_test.dart
flutter test test/services/sync_operation_test.dart
flutter test test/repositories/local_outbox_store_test.dart
flutter test test/services/cloud_sync_transport_test.dart
flutter test test/services/sync_service_download_test.dart
flutter test test/services/clipboard_monitor_coordinator_test.dart
bash server/smoke-test.sh
```

### 4. Reviewer

确认：

- 旧 Cloud API 和鉴权没有变化；
- Provider/Monitor 没有重复发送；
- outbox 不保存明文、密码、派生 key 或 token；
- 账户切换不会发送旧账户待处理操作；
- `history_id` 修复覆盖有字段和无字段两条路径；
- 所有测试通过后，才进入 Phase 2。

## Phase 2 预定范围

Phase 2 才开始真实 LAN 文本/图片加速，顺序如下：

1. 引入 `LanTransport` 接口，但先不改变 CloudTransport。
2. mDNS 只广播服务类型、随机实例、协议版本、能力和临时公钥指纹，不广播密码、userId、Bearer token 或 AES 主密钥。
3. TCP 连接必须双向挑战认证，设备级凭据可撤销，不能只使用账户派生密钥。
4. 第一版优先做 Cloud-backed LAN acceleration；LAN-only 是独立模式，不混入云端历史语义。
5. 先支持文本和图片，文件与 Android 原生服务另行评估。
6. 使用 operationId、ACK、cursor/version 和 outbox，禁止 LAN/Cloud 各自创建一条历史。

## 重要约束

- 不删除或重构现有 CloudBaseService/CloudRepository/服务端 API。
- 不修改 AES-256-GCM、PBKDF2、userId 派生算法、SQLite tokens、无 FOREIGN KEY 约束。
- 不在 Phase 2 前引入 OSS。
- 不把“mDNS 发现成功”当成认证成功。
- 不把 Bearer token 放入局域网广播或传输协议。
- 不在真实 LAN 协议和 Android 后台策略未验证前承诺 6GB 目标。
