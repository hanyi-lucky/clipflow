# ClipFlow 局域网优先同步改造交接记录

> 最后更新：2026-08-09（Asia/Shanghai）
> 当前状态：Phase 1（云端路径协调层 + 整改）已完成并全部验证通过；未部署到生产。

## 当前 Git 状态

- 分支：`codex/lan-priority-sync`
- 基线备份提交：`6e0393b chore: backup before LAN priority sync`
- Phase 1 实现提交：
  - `4f33c0b feat: add durable sync operation model`
  - `d6f5134 feat: persist sync operations in a user-scoped outbox`
  - `fcf2150 feat: add cloud transport and stable upload preparation`
  - `493f7a1 feat: add durable sync coordinator drain`
  - `436f402 feat: route app sync through coordinator`
- Phase 1 整改提交（测试修复 + 成功回执）：
  - `a461953 test: await async throws assertions in sync coordinator retry tests`
  - `596ab74 test: point outbox store fixtures at the real clipflow_outbox dir`
  - `b59c4da fix: inject OutboxStore into ClipboardProvider for deterministic file tests`
  - `4728991 fix: add durable success receipt so background drain backfills history`
  - `d3878de test: wait for image cache persistence and cover text/image receipts`
  - `4c7166b test: drop unused variables in image receipt test`
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
8. 整改：`ClipboardProvider` 增加 `OutboxStore? outbox` 注入；`SyncCoordinator` 新增成功回执 `onOperationSucceeded`（`markUploadSucceeded → remove → notify`，回调独立 try/catch），后台 drain/401 重放成功时也补建本地历史与图片缓存。
9. 保留 AES-256-GCM、PBKDF2 100000 次、userId 派生、SQLite tokens、无 FOREIGN KEY 和旧 Cloud API。

## 明确尚未实现

- mDNS 设备发现；
- TCP/Noise/TLS 局域网握手；
- LAN 文本/图片/文件传输；
- Android 原生局域网网络服务；
- OSS 直传；
- LAN-only 模式；
- 删除/恢复的 durable cursor/tombstone 改造；
- 6GB 流量指标和成本观测。

## 当前验证结果（整改后，2026-08-09）

### 已通过

- `bash server/smoke-test.sh`：`SMOKE TEST PASSED`（25 组检查全过）。
- `/opt/homebrew/bin/flutter test` 全量：`330/330` 通过。
- 重点目标文件集：`42/42` 通过（sync_coordinator 8 条、file/image provider、outbox_store、monitor、cloud transport、sync_service download、operation 序列化）。
- `/opt/homebrew/bin/flutter analyze`：0 error（剩余 70 条 warning/info 均为基线既有，exit 1 仅为非 error 提示）。
- `git diff --check` 与改动范围校验：仅 6 个整改文件（2 生产 + 4 测试），无 server/加密/DB/API 改动。
- 终审（reviewer）：验收通过（DONE），7 项确认全部通过，置信度无 ≥80 阻塞问题。

### 遗留风险（非阻塞，Phase 2 前置）

1. **桌面文件首传相位锁定**（置信度 80）：`_checkClipboard` 500ms 轮询在首传前重复检测同一文件并重置 500ms debounce，文件首传可能间歇延迟。本次仅测试侧 armed-mock 规避，未改生产。→ Phase 2 建议先修。
2. **ghost 历史窗口**（置信度 80）：drain 单飞 + `upload*` 乐观返回，在途 drain 永久失败时本地历史先于服务器落地。→ 可作独立里程碑。

## Phase 2 预定范围

Phase 2 才开始真实 LAN 文本/图片加速，顺序如下：

1. 引入 `LanTransport` 接口，但先不改变 CloudTransport。
2. mDNS 只广播服务类型、随机实例、协议版本、能力和临时公钥指纹，不广播密码、userId、Bearer token 或 AES 主密钥。
3. TCP 连接必须双向挑战认证，设备级凭据可撤销，不能只使用账户派生密钥。
4. 第一版优先做 Cloud-backed LAN acceleration；LAN-only 是独立模式，不混入云端历史语义。
5. 先支持文本和图片，文件与 Android 原生服务另行评估。
6. 使用 operationId、ACK、cursor/version 和 outbox，禁止 LAN/Cloud 各自创建一条历史。
7. 先处理遗留风险 1（桌面文件首传相位锁定）。

## 重要约束

- 不删除或重构现有 CloudBaseService/CloudRepository/服务端 API。
- 不修改 AES-256-GCM、PBKDF2、userId 派生算法、SQLite tokens、无 FOREIGN KEY 约束。
- 不在 Phase 2 前引入 OSS。
- 不把“mDNS 发现成功”当成认证成功。
- 不把 Bearer token 放入局域网广播或传输协议。
- 不在真实 LAN 协议和 Android 后台策略未验证前承诺 6GB 目标。
