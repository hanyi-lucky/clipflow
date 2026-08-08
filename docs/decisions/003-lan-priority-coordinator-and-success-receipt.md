# 003 · 局域网优先同步 Phase 1：Coordinator/Outbox 抽象 + 后台 drain 成功回执

- 日期：2026-08-09
- 档位/组合：完整（explorer→architect→coder→tester→reviewer）+ 整改轮（debugger→architect→coder→tester→reviewer）

## 背景
- 目标：为 LAN 优先同步铺路，但本阶段不实现真实局域网 socket/Android mDNS/OSS/服务端新 API，只把云端路径放入可替换的协调层。
- 已知问题：文本下载丢失服务端 `history_id`，删除/置顶链路不可靠。
- 整改起因：Phase 1 测试暴露 path_provider 注入缺口、coordinator 重试断言未 await、后台 drain 重试成功后不通知 Provider（文件历史条目/签名永不落地）。

## 决策
1. 新增 `SyncOperation`（稳定 operationId）+ 按 userId 隔离的文件系统 outbox（`clipflow_outbox/$userId`，manifest 原子写，pending/sending/retryable/dead 状态）+ `SyncTransport`/`CloudSyncTransport` + `SyncCoordinator`（single-flight、有限退避、同 operationId 重试、active dedupe）。
2. 上传/下载统一经 `SyncCoordinator`；文本下载 `DownloadResult.id` 读取服务端 `history_id`，旧数据缺失时保持 null 由 Provider UUID fallback。
3. 整改：`SyncCoordinator` 新增可选成功回执 `onOperationSucceeded`，顺序固定 `markUploadSucceeded → remove → notify`，回调独立 try/catch；`ClipboardProvider` 按 `op.kind` 三分流补账（text 解密补史 / image 补史+imageStore.save / file 只补史+enforceCacheLimit，不重复 import、不 recordFileSignature），幂等由 HistoryService 三级去重收敛。回执挂 durable success 点，direct/后台 drain/dedupe/401 重放成功全部收敛到同一回执。

## 后果
- 旧 Cloud API、AES-256-GCM/PBKDF2、userId 派生、SQLite tokens、无外键约束、`clipflow_outbox/$userId` 目录结构、服务端 API 全部零改动。
- 未实现真实 LAN 传输（Phase 2）；outbox 只存密文/哈希/元数据，不存明文/密码/派生 key/token。
- 遗留（非阻塞）：桌面文件首传相位锁定、ghost 历史窗口（drain 在途时本地历史先于服务器落地）——列为 Phase 2 前置/独立里程碑。
