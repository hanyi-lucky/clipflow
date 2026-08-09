# 004 · 局域网优先同步 Phase 2.1：文本/图片 LAN 加速

- 日期：2026-08-09
- 档位/组合：完整（3 explorer 并行 → architect → coder1(基础层) → coder2(集成层) → tester → fix-coder → retest → reviewer）

## 背景
- Phase 1 已把云端路径放入 SyncCoordinator/outbox 协调层；Phase 2 开始真实 LAN 加速（文本/图片），要求：不破坏云端权威、设备级可撤销、广播/报文零敏感字段、权限缺失安全降级。

## 决策
1. **mDNS 原生双端**（macOS NSNetService/NSNetServiceBrowser + Android NsdManager，统一 `clipflow/lan_network` MethodChannel）；否决自研 Dart responder（5353/SO_REUSEPORT 高风险）与 multicast_dns 包（无广告端）。
2. **传输 TLS 自签证书 + 指纹固定**（平移 pinned_client 先例，PKCS#8 私钥资产 `assets/lan/`）；否决 Noise（需新增 cryptography 依赖且触加密红线）。
3. **双向挑战认证族 A3**：`K_lan = HMAC-SHA256(账户key, "clipflow:lan-auth-v1")` + 服务端 HMAC 短时票据（5min TTL，`POST /api/lan/ticket` + `/verify`，只增不改）；票据 payload 不含 userId（deviceId+exp+HMAC，userId 由 verify 从 devices 反查），设备 removed_at 复查实现可撤销；零表结构改动、零客户端秘密落盘。
4. **集成**：Provider 自持 `LanSyncManager`，coordinator/transport 零改动；`_performDownload` LAN 先试 + Cloud 每 tick 权威兜底（删除/恢复只走 Cloud）；上传挂 `_onOperationSucceeded` durable success 点推送，规则 `peer.deviceId != source_device`；LAN 行与 `getClipboardWithDeletedIds` 同构，复用 decodeCurrentClipboard/防回声/游标。
5. **遗留风险 1 修复**：ClipboardMonitor 文件在途签名守卫，解决 500ms poll 与 500ms debounce 相位锁定。
6. **启动时序**：`initialize()` 中 LAN 启动 `unawaited`（加速器不阻塞解锁；LAN 未就绪走 Cloud 兜底），修复 widget 测试 FakeAsync 挂起。

## 后果
- 云端权威、删除/恢复语义、AES-256-GCM/PBKDF2/userId 派生/tokens/无外键/现有端点全部零改动（11 commit 纯新增，server 仅新增 2 端点）。
- 验收通过：flutter test 388/388、analyze 0 error、server smoke 27/27、安全红线审查通过。
- 明确未覆盖/前置：Android 真机（含 LanNetworkPlugin.kt browse() 注销广告缺陷，置信度 88，建议 2.2 前修）、macOS 双实例实证、生产写入 `LAN_TICKET_SECRET` 环境变量。
