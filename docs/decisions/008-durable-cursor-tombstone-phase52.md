# 008 · durable cursor + tombstone（Phase 2.5-5.2，删除/恢复持久化收敛）

- 日期：2026-08-22
- 档位/组合：完整（2 explorer 并行 → architect → coder → tester → reviewer → 1 轮整改 → retest → fix-reviewer；触数据库结构红线）

## 背景
- 删除/恢复原为「Cloud-only 的 30 秒尽力而为广播」（`GET /api/clipboard` 顺带 `deleted_at/restored_at > now-30s`），四个已实证致命边界：空剪切板 NOT_FOUND 阻断、tombstone 受 24h 清理/100 条裁剪/trash 倾倒三重物理删除、恢复依赖 30s 窗口完整行、云 outbox 无 TTL。
- 5.2 目标：服务端 durable operation log / 单调 cursor / tombstone 替换 30s 窗口；删除/恢复稳定 operationId 走统一 outbox；之后才允许删除/恢复经 LAN 分发（默认 Cloud-only 兜底）；旧 API/旧客户端不受影响。

## 决策
1. 服务端新增 `sync_operations`（AUTOINCREMENT seq + `UNIQUE(user_id, operation_id)` 幂等）+ `sync_tombstones`（删除态 + 删除时服务端自建全行快照），**零 FOREIGN KEY**；保留期双轨 op 7 天 / tombstone 快照 24 小时，`pruneSyncState(now)` 启动 + 小时任务各一次。
2. `POST /api/sync/commit`（幂等：同 opId 同结果、冲突 409、未知条目 ignored）+ `GET /api/sync/changes`（after 游标分页、limit 1..100）独立于 `/api/clipboard`，绕开空剪切板 NOT_FOUND 边界；restore row 按既有规则整形（file content=''）。
3. 客户端 `SyncOperationKind` 扩 `delete`/`restore`，稳定 opId `del:<id>`/`rest:<id>`（周期后缀 `#<n>`）走统一 outbox（`findActiveByDedupeKey` 幂等）；delete/restore 4xx/dead 立即移出 + 7d sweep（补云 outbox 无 TTL 技术债）。
4. durable cursor 持久化（`LocalStorage.syncCursor` + `SyncService._lastAppliedCursor`），仅应用成功后才推进；能力探测：Cloud 用 changes 404 回退 30s 窗口、LAN 用 hello `ops:1` 位门控——新旧客户端/服务器全兼容。
5. LAN 新增 `op` 帧（delete 恒推、restore 带 commit 响应 row），fire-once best-effort、`_knownOpIds`（≤200）去重、不回推来源、Cloud 500ms 游标兜底；togglePin 不纳入 5.2。
6. 整改（reviewer 2 个高置信问题）：① 删除→恢复→再删除周期改为「当前状态与 op 意图匹配」判定——delete 时条目活跃→新删除事件、restore 时条目已删→新恢复事件，周期后缀 opId 绕 UNIQUE 生成新 seq；客户端 `markRestoreObserved` 周期计数保证 LAN `_knownOpIds` 不误杀第二次删除。② LAN restore row 经 `_sanitizeRestoreRow` 白名单清洗，零 userId/明文 file_name/mime_type/file_key，与 `_toFileServerRow` 同构（file 缺名按占位 + 历史 refresh 修正）。

## 后果
- 离线 >30s（乃至数天）设备经 7d op log + 单调游标重放收敛删除/恢复，不复活、不丢失；同 operationId 重复提交只产生 1 条 history；LAN/Cloud 乱序不重复写。
- 恢复在 24h 快照内自包含（text/image 完整、file 仅元数据下载 404——trash 倾倒后正面副作用）；快照 GC 后 restore `row:null` 客户端跳过、靠启动全量刷新收敛；>7d 离线降级为全量刷新 + `deletedEntryIds` 兜底。
- 旧 `/api/clipboard` 30s 字段、旧 delete/restore 端点、`deleted_at/restored_at` 语义零改动；`/api/sync/changes` 404 时客户端回退 legacy 路径。
- 红线零触碰：新表零 FOREIGN KEY；userId 派生/AES/PBKDF2/tokens 未动；LAN 报文（含内嵌 row）零敏感明文。
- 全量 `server/smoke-test.sh` 34/34；`flutter test` 511/511；`flutter analyze` 0 error（93 项存量 info/warning 为基线）。
