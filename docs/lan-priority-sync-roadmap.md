# ClipFlow 局域网优先同步改造交接记录

> 最后更新：2026-08-09（Asia/Shanghai）
> 当前状态：Phase 2.3（LAN 可靠性/ACK/诊断/重下熔断）已完成并验收通过；未部署到生产。

## 当前 Git 状态

- 分支：`codex/lan-priority-sync`
- Phase 1 实现 + 整改：见历史提交（`4f33c0b` ~ `2275cbe`）
- Phase 2.1 提交（11 个，`e85b60f` ~ `2b8da67`）：
  - 基础层 ①-⑤：`e85b60f`（常量/证书/TLS/协议）、`2cf5333`（server 票据 2 端点）、`828c6fb`（cloud additive）、`e0fbfeb`（握手服务）、`e4d0635`（双端原生插件）
  - 集成层 ⑥-⑨：`d254708`（发现/传输/管理器）、`40bc84b`（Provider LAN-first+push）、`f9d6260`（文件相位锁修复）、`0bdc2a1`（设置开关）
  - 整改：`5ae7b85`（FakeAsync 回归测试）、`2b8da67`（initialize 不阻塞 LAN 启动）
- Android 插件修复提交：`16f0e58`（stopAll 拆分 stopAdvertisement/stopDiscovery）、`b6eec75`（修复 Phase 2.1 遗留 4 处编译错误）
- Phase 2.2 提交（4 个，`97a5dca` ~ `d8f8209`）：`97a5dca`（常量+enc_file_name）、`6fa8c8d`（fileStart/fileChunk 分块帧）、`4460234`（LanSyncManager 文件 push/收）、`d8f8209`（Provider 本地 .enc 优先+Cloud 兜底）
- Phase 2.3 提交（10 个，`e7bd2d1` ~ `17a871a`）：常量+LanDiagnostics+hello acks 协商 / fileAck+reader slot / lan_outbox_store / manager 待确认表+重试绕过去重 / 诊断接线+设置页诊断区 / FileDownloadBreaker / 账户切换清理 / 整改（组合测试+三处注入）
- 当前工作树：干净。

## 已完成的 Phase 2.1 内容

真实 LAN 文本/图片加速（Cloud-backed LAN acceleration），未做 LAN-only：

1. mDNS 原生双端发现（macOS NSNetService/NSNetServiceBrowser + Android NsdManager，`clipflow/lan_network` MethodChannel）；广播仅服务类型/端口/deviceId/能力位。
2. TLS 自签证书 + 指纹固定传输（PKCS#8 私钥资产，平移 pinned_client 先例）。
3. 双向挑战认证（族 A3）：`K_lan=HMAC-SHA256(账户key,"clipflow:lan-auth-v1")` + 服务端 HMAC 短时票据（5min TTL，`POST /api/lan/ticket` + `/verify`，设备 removed_at 复查可撤销）；票据不含 userId。
4. Provider 自持 `LanSyncManager`：`_performDownload` LAN 先试 + Cloud 权威兜底；上传挂 `_onOperationSucceeded` durable success 点推送（`peer.deviceId != source_device` 不回推）；LAN 行与云端同构、复用 decodeCurrentClipboard/防回声/游标；删除/恢复只走 Cloud。
5. 桌面文件首传相位锁定修复（ClipboardMonitor 文件在途签名守卫）。
6. 设置页「局域网加速」开关（默认开）+ Android 权限（NEARBY_WIFI_DEVICES 运行时请求，拒绝降级）+ macOS Info.plist（NSLocalNetworkUsageDescription/NSBonjourServices）。
7. 服务端新增 2 个端点（只增不改）：取票/校验；`LAN_TICKET_SECRET` 支持 env 或启动随机。

## 已完成的 Phase 2.2 内容（LAN 文件 ≤15MiB）

1. 分块文件帧：`fileStart`/`fileChunk`（1MiB 分块、`lanMaxFileChunks=128`），`lan_protocol` 编解码与 16MiB 帧上限零改动；半途失败删 `.part` 安全丢弃回 Cloud。
2. 元数据最小化：`hash/fileSize/source_*/timestamp/history_id` 明文；`marker` 随行；**fileName 加密为 `enc_file_name`**；mimeType 省略走 Cloud 兜底。
3. `LanSyncManager` 注入 `LocalFileStore`：push 从 artifact 流式读密文分块发送，接收端原子落盘 `.enc` 后才触发下载。
4. Provider `_runFileDownload` 本地 `.enc` 优先 + Cloud 兜底（同一 historyId，明文 SHA-256/size 校验，坏 `.enc` 删后回 Cloud）。
5. 幂等/防回声：historyId=operationId=artifactId；`_knownHistoryIds` + `_fileDownloads` 双层防重 + `markAsDownloadedFileHash` + `_suppressWrittenFileEcho`；≤15MiB 走 LAN、>15MiB 走 Cloud；push 不回推来源、绝不 rethrow。
6. 服务端零改动；caps 加 `f` 位。

## 已完成的 Phase 2.3 内容（LAN 可靠性/ACK/诊断/重下熔断）

1. fileAck 帧 + hello `acks:1` 能力协商（版本仍 1、原生插件零改动）；发送侧 per(peer,historyId) 待确认表，重试绕过 `_knownHistoryIds` 发送侧去重；initiator per-session reader slot 读串行化（fetchLatest 遇 busy 跳过不排队）。
2. 持久化 LAN outbox（`clipflow_lan_outbox/<userId>/<peerId>/` 独立目录）：put 在 push 前、ACK remove、give-up 删除、重启恢复、账户切换清理、LAN 开关关闭保留；只装云 durable 已提交操作防双发。
3. 诊断计数 `lan_diagnostics.dart`（8 类 roadmap 计数 + fallbackReason 10 分类 + ackSent/ackReceived），设置页「诊断（局域网）」调试区可查看/清零；默认构造三处注入单例（整改后 5/9 计数生产可达 UI）。
4. `FileDownloadBreaker` 重下熔断：per-historyId 3 次坏 artifact → 60s 冷却 + half-open 探针，五重 reset；不碰 `markAsReceived` 成功顺序。

## 明确尚未实现

- Phase 2.2：LAN 文件传输（≤15MiB）；
- Phase 2.3：LAN 可靠性/ACK/诊断指标 UI；
- Phase 2.4：Android 真机 + 后台生命周期 + 原生插件缺陷修复；
- Phase 2.5：独立 RFC（LAN-only/durable cursor/OSS/6GB）；
- mDNS 广播黑名单/白名单细节已按设计实现。

## 当前验证结果（Phase 2.3，2026-08-10）

### 已通过

- `flutter test` 全量：**458/458**（含 LAN 协议/TLS/握手/管理器/文件分块帧/fileAck/持久化 outbox/诊断/熔断回归）。
- `flutter test test/screens/cloud_pull_screen_test.dart`：4/4 无挂起（此前 FakeAsync 挂起已修复）。
- `flutter analyze`：0 error（11 warning + 67 info，均为基线既有）。
- `server/smoke-test.sh`：**SMOKE TEST PASSED**（27 组，含 LAN 取票/校验/设备移除 403）。
- 安全红线审查：mDNS TXT / LAN 帧不含 userId/密码/token/K_lan/salt/证书指纹/文件名/明文；错账户/过期/重放/removed 握手拒绝；push 不回推来源；`_onOperationSucceeded` 绝不 rethrow。
- 终审（reviewer）：**验收通过**（六项验收标准全部满足）。

### 明确未覆盖 / 前置（非阻塞）

1. **Android 插件缺陷已修复**（`16f0e58`/`b6eec75`，终审通过）：browse/advertise 解耦、stopAll 语义保留、并修复 Phase 2.1 遗留 4 处编译错误（该 Kotlin 文件此前从未编译通过；gradle 全量编译 + flutter build apk 通过）。
2. **Android 真机 mDNS 双向可见性**（Android-Android / Android-macOS、advertise+browse 共存）未在设备实测 → 归 2.4。
3. **macOS 双实例实证**：需双 bundle ID 构建 + 真实 Wi-Fi + 双 GUI 实例，当前环境未做；LAN 端到端真实链路（<500ms push）仍待实证。
4. **生产部署**：`LAN_TICKET_SECRET` 需写入环境变量（否则重启后票据失效，客户端自动重取，无感）。
5. **Android 真机**：权限降级、后台保活、锁屏、网络切换，归 2.4。
6. **低置信防御缺口**（置信度 40，2.3 处理）：LAN 行 hash 与 artifact 不符时可能反复重下，建议 2.3 加熔断。

## Phase 2.4 预定范围（Android 真机 + 后台生命周期 + 端到端实证）

1. **必须前置（全部为外部依赖，代码侧已完成）**：真实双实例/真机 fileAck 端到端实证（≤15MiB push 交付 + 粘贴文件名正确 + >15MiB Cloud-only + 无回声环）；macOS 双实例实证（双 bundle ID + 真实 Wi-Fi）；生产部署写入 `LAN_TICKET_SECRET`。
2. Android 真机验证：NEARBY_WIFI_DEVICES 权限降级、后台保活、锁屏、前台服务绑定、网络切换。
3. 依据实证结果修复发现的问题（如有）。

## 重要约束

- 不删除或重构现有 CloudBaseService/CloudRepository/服务端 API（只能 additive）。
- 不修改 AES-256-GCM、PBKDF2、userId 派生算法、SQLite tokens、无 FOREIGN KEY 约束。
- 不在 Phase 2.1 前引入 OSS；LAN-only 是独立模式（2.5），不混入云端历史语义。
- 不把“mDNS 发现成功”当成认证成功（必须双向挑战握手）。
- 不把 Bearer token / userId / 密码 / 账户 key / LAN key / salt / 证书指纹 / 文件名 / 明文放入局域网广播或传输。
- 不在真实 LAN 协议和 Android 后台策略未验证前承诺 6GB 目标。
