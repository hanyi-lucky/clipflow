# ClipFlow 局域网优先同步改造交接记录

> 最后更新：2026-08-09（Asia/Shanghai）
> 当前状态：**Phase 2.4 完成（2026-08-10）**——Android 真机生命周期、macOS 双实例实证、图片/文件（≤15MiB）LAN 真机交付、LAN 会话稳定性、Mac 自动刷新问题全部验证/解决。

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
- Phase 2.5：独立 RFC（LAN-only/durable cursor/OSS）——**不含 6GB 容量/流量观测项**（6GB 是 ECS 月度流量额度背景，见下文）；
  - **最终方案已落盘**：`docs/phase25-final-plan.md`（5.1 LAN-only 正式化优先，后续 5.2 durable cursor+tombstone / 5.3 OSS 独立 RFC / 附加稳定性与 Windows）。
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

## 真机端到端验证（2026-08-10，Mac + Android 真机同 Wi-Fi）

### 已验证通过
1. mDNS 发现（双端互见、端口正确）；TLS 自签证书指纹固定（openssl 实测手机服务端证书指纹与内置一致）。
2. A3 双向挑战握手全流程（hello → 服务端取票 → auth 交换 → 服务端验票），两端均握手成功。
3. **LAN 内容交付（双向）**：Mac→手机、手机→Mac 均秒达；服务器数据库实测**零内容写入**（纯 LAN 内容只在局域网报文，history_id 不出现在服务端）。
4. 防回声/去重：收到内容写剪贴板走 ignoreHashes，不重复上传。

### 本次修复（已提交 463d7d0）
- **Android 原生崩溃**：NsdManager 回调线程调 `eventSink/result` 触发 `@UiThread` 崩溃 → 全部回调 post 主线程（`mainHandler.post`）。
- **macOS Zone mismatch**：`ensureInitialized` 移到 `runZonedGuarded` 内（修复后不再出现 runApp Zone mismatch）。
- **Xcode 工程注册**（已提交 a2ab9f0）：`LanNetworkPlugin.swift` 未进 build phase → macOS 构建失败。

### 实验性「仅局域网同步」开关
- `ClipboardProvider.lanOnlyMode`（static，**默认 false**）：文本上传/下载完全走 LAN、跳过云端内容读写；Android 原生监听路径经 `ClipboardMonitor.uploadOverride` 一并覆盖；握手票据仍走服务端。
- 真机双向验证：内容零服务器写入（DB 证据）。已知局限：仅文本、对端离线无兜底、历史仅本地、无删除/恢复、状态显示为模拟。
- 尚未接入设置页 UI（下一轮）；正式完整版（删除/游标/文件/降级）归 Phase 2.5。

### 已知问题（待跟进）
1. **LAN 会话周期性断开后自动重连**（架构已接受的迟到帧竞态；不阻塞交付，但会产生反复握手）——Phase 2.4 实测内容交付无丢失，仍待后续优化。
2. ~~**Mac 端自动刷新偶发不生效**~~ → **已解决**：`463d7d0` Zone mismatch 修复后，手机→Mac 自动写剪贴板/列表更新连续验证通过。
3. **MIUI 会撤销 adb 授予的 NEARBY_WIFI_DEVICES**（应用内授权可持久；真机需走设置页开关授权）。
4. **Windows 端无 LAN 插件**（isSupported=false → 自动走云端）。补全可参考 macOS/Android 实现：原生 mDNS（WinRT Dnssd 系列）+ dart:io TLS + 复用 `lib/services/lan_*` 全部逻辑，注册进 `generated_plugin_registrant.cc` 即可。

## Phase 2.4 预定范围（Android 真机 + 后台生命周期 + 端到端实证）

1. **已部分完成（2026-08-10）**：Mac+Android 真机双向文本 LAN 交付实证（≤15MiB 文件/图片/文件名正确/无回声环仍需补验）；macOS 双实例实证（双 bundle ID + 真实 Wi-Fi）仍未做；生产部署已写入 `LAN_TICKET_SECRET` 并上线 LAN 票据端点。
2. Android 真机验证：NEARBY_WIFI_DEVICES 权限降级、后台保活、锁屏、前台服务绑定、网络切换。
3. 依据实证结果修复发现的问题（如有）。

## Phase 2.4 验证结果（2026-08-10，全量真机实证）

### 1. 图片/文件（≤15MiB）LAN 真机交付 — ✅ 通过
- 图片（800×600 PNG）：Mac→手机秒达，手机解码成功（`clipflow_images/*.bin` 落盘）。
- 5MiB / 12MiB 文件：`.enc` 密文 + 解密明文 **SHA-256 双端字节一致**，文件名正确，无回声环。
- **>15MiB（16MiB）自动走 Cloud 兜底**：LAN enc 目录无落盘、服务器有记录、明文一致——边界正确。

### 2. Android 真机生命周期验证（Xiaomi 24129PN74C / Android 16 / MIUI）— ✅ 通过
| 场景 | 结果 |
|---|---|
| NEARBY_WIFI_DEVICES 权限降级 | `[LAN-DISCOVERY] start disabled: permissionDenied` 优雅降级不崩溃 → Cloud 兜底正常 → 重新授权后 LAN 恢复 |
| 后台保活 | Home 后台化后新内容仍被下载（含 MIUI idle 冻结期） |
| 锁屏 | 屏幕熄灭时同步暂停（MIUI Doze 策略：进程未冻结但 Dart 事件循环挂起、LAN 端口无响应），**唤醒后立即补收**——MIUI 后台策略，非应用缺陷 |
| 前台服务绑定 | `SyncForegroundService isForeground=true`（dataSync 类型） |
| 网络切换 | Wi-Fi 断开/恢复后 LAN manager 自动重启新端口，双向同步恢复正常 |

### 3. macOS 双实例实证 — ✅ 通过
- 双 bundle ID（`com.clipflow.clipflow` / `com.clipflow.clipflow.test`）隔离 SharedPreferences，相同密码 0000 → 相同 userId。
- A↔B 通过 **loopback LAN 直连**（mDNS→TLS→双向挑战握手→LAN 帧，连接持续 ESTABLISHED），**双向互同步**（A 收到 B 来源、B 收到 A 来源），**无回声环**（双方历史无重复内容）。

### 4. LAN 会话稳定性 — ✅ 符合预期
- 连续 5 次同步全部成功交付（0/6/13/19/25 秒前逐条到达），内容无丢失。
- 偶发 `responder session dropped: socket closed before frame completed`（已知迟到帧竞态），自动重连收敛，不阻塞交付。

### 5. Mac 自动刷新问题 — ✅ 已解决（Zone mismatch 修复后验证通过）
- 手机→Mac：**自动写入 Mac 剪贴板 + 列表自动更新**（无需手动刷新），连续两次验证通过。
- Mac→手机反向同样自动到达。
- 结论：`463d7d0`（runZonedGuarded 内初始化 FlutterBinding）修复后，Mac 自动刷新链路正常。

### 回归验证
- `flutter test`：**458/458 全部通过**；`flutter analyze`：0 error（83 issues 与基线一致）。
- 生产服务器 LAN 端点已上线并验证（ticket/verify 401/403 语义正确）。

## Phase 2.5 进度（2026-08-22）

### 5.1 LAN-only 独立模式正式化 — ✅ 已完成并真机验收
- 实现：设置页「仅局域网同步（实验）」开关（默认关、实验提示）、三型内容（文本/图片/≤15MiB 文件）LAN-only 路由、`SyncStatus.localOnly` 真实状态、降级横幅、启动恢复持久化历史（跨重启保留本地内容）。
- 单测：`flutter test` 474/474；`flutter analyze` 0 error；红线零触碰。
- **真机回归（Xiaomi 15 / Android 16 + macOS debug，同 Wi-Fi）全部通过**：
  1. LAN-only 文本/图片/≤15MiB 文件双向交付，服务器 DB **零内容写入**（客观验证：服务器最近写入全部为 Mac 来源）。
  2. **重启保留本地内容**（reviewer 遗留注记闭合）：复制图片 → 杀进程重开 → 历史条目 + `.bin`/`.enc` artifact 全部保留。
  3. 对端离线降级：横幅「内容仅在本地、未同步到其他设备」+ 状态 `localOnly`；对端恢复回 `connected`。
  4. 开关切换不丢内容：LAN-only 时内容零写入、关闭后走 Cloud（服务器有写入）、本地历史不丢。
  5. 回归锚点：关闭 LAN-only 后 Cloud 行为与未开启一致。
- P2 修复（真机发现）：LAN-only 图片条目重启后缩略图灰色 → `_rebuildRestoredImageThumbs` 恢复时重建 `imageThumbBytes`（复用 decryptImage，失败静默保留占位）；单测覆盖 + 密文损坏边界验证通过。
- 决策：`docs/decisions/007-lan-only-mode-phase51.md`。

### 5.2 durable cursor + tombstone — ✅ 已完成（2026-08-22）
- 实现：服务端 `sync_operations`/`sync_tombstones`（零 FK）+ `/api/sync/commit`（幂等/冲突 409/ignored、服务端自建快照）+ `/api/sync/changes`（单调游标分页）+ `pruneSyncState`（op 7d / tombstone 24h）；客户端 `SyncOperationKind.delete/restore` 稳定 opId 走统一 outbox + durable cursor 替换 30s 窗口；删除/恢复 LAN `op` 帧分发（hello `ops:1` 能力位门控，默认 Cloud-only 兜底）；能力探测 404 回退 legacy，旧客户端/旧 API 零影响。
- 整改闭环：删除→恢复→再删除周期改为「当前状态与 op 意图匹配」判定（周期后缀 opId 新事件）；LAN restore row 白名单清洗（零 userId/明文 file_name/mime_type/file_key）。
- 验证：`server/smoke-test.sh` 34/34（含第 34 节周期用例）；`flutter test` 511/511；`flutter analyze` 0 error；红线零触碰。
- **真机回归（2026-08-22，生产服务器已部署 5.2）**：删除/恢复跨端收敛、离线 >35s 重放、重启不复活、周期删除新事件（`del:<id>#n`）、**LAN op 帧端到端**全部通过（Mac + Xiaomi 15/Android 16，密码 0000；Mac `flutter.sync_cursor` 随 op log 推进确证 durable 路径；Android 诊断「握手成功=2、推送发送=1」确证 LAN op 帧）。初版 Mac 曾因 `cp -R` 嵌套安装跑旧 build，已 ditto 重装修复并复验。详见 `.codex/pipeline/phase25-5.2-device-verification.md`。
- 决策：`docs/decisions/008-durable-cursor-tombstone-phase52.md`。

## 重要约束

- 不删除或重构现有 CloudBaseService/CloudRepository/服务端 API（只能 additive）。
- 不修改 AES-256-GCM、PBKDF2、userId 派生算法、SQLite tokens、无 FOREIGN KEY 约束。
- 不在 Phase 2.1 前引入 OSS；LAN-only 是独立模式（2.5），不混入云端历史语义。
- 不把“mDNS 发现成功”当成认证成功（必须双向挑战握手）。
- 不把 Bearer token / userId / 密码 / 账户 key / LAN key / salt / 证书指纹 / 文件名 / 明文放入局域网广播或传输。
- 不在真实 LAN 协议和 Android 后台策略未验证前承诺 6GB 目标。（注：6GB 指阿里云服务器月度剩余流量额度，是 LAN 同步的动机，不是容量功能。）
