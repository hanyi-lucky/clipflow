# 005 · 局域网优先同步 Phase 2.2：LAN 文件传输（≤15MiB）

- 日期：2026-08-09
- 档位/组合：完整（2 explorer 并行 → architect → coder → tester → reviewer）

## 背景
- Phase 2.1 已实现文本/图片 LAN 加速；Phase 2.2 目标为文件 ≤15MiB 走 LAN，保留 Cloud 权威与 history 唯一性，且 LAN 报文不得出现明文/文件名明文。

## 决策
1. **载荷分块**：新增 `fileStart`/`fileChunk` JSON 帧（1MiB 分块、`lanMaxFileChunks=128` 上限），`lan_protocol.dart` 编解码与 16MiB 帧上限零改动；否决二进制帧（硬顶不可演进）与提帧上限（内存翻倍）。半途失败删 `.part` 安全丢弃回 Cloud（无续传）。
2. **元数据最小化**：`hash/fileSize/source_*/timestamp/history_id` 明文上 LAN；`marker` 随行携带保 `decodeCurrentClipboard` 零改动；**fileName 加密为 `enc_file_name`**（prepareFile 加密、decode 解密）满足「禁文件名明文」且保粘贴名正确；mimeType 省略走 Cloud 兜底。
3. **集成**：`LanSyncManager` 注入 `LocalFileStore`，push 从 artifact 流式读密文分块发送；接收端 `saveEncryptedFromStream` 原子落盘（`.enc` rename 后才触发下载）；Provider `_runFileDownload` 改为本地 `.enc` 优先 + Cloud 兜底（同一 historyId，明文 SHA-256/size 校验，坏 `.enc` 删后回 Cloud）。
4. **幂等/防回声**：historyId=operationId=artifactId 三合一；`_knownHistoryIds` + `_fileDownloads` 双层防重 + `markAsDownloadedFileHash` + `_suppressWrittenFileEcho`；push 不回推来源设备、绝不 rethrow；≤15MiB 走 LAN、>15MiB 走 Cloud。
5. **边界**：无 ACK/续传/诊断 UI（归 2.3）；服务端零改动；caps 加 `f` 位。

## 后果
- 服务端、AES-256-GCM/PBKDF2/userId 派生/tokens/无外键、`lan_protocol` 编解码与 16MiB 帧上限全部零改动（4 commit/11 文件全在 lib/+test/）。
- 验收通过：flutter test 414/414、analyze 0 error、server smoke 27/27、终审 DONE。
- 未覆盖/前置：macOS 双实例实证与真机验证（归 2.4/2.3 前补）；2.3 需加 fileAck 帧、持久化 LAN outbox、诊断计数，并考虑 LAN 行 hash 与 artifact 不符时的重下熔断（低置信防御缺口）。
