# 010 · OSS 直传（Phase 5.3，大文件不经 ECS 中转）

- 日期：2026-08-22
- 档位/组合：完整（2 explorer 并行 → architect RFC → coder M1-M6 → tester → reviewer）

## 背景
- 文件字节目前全部经 ECS 中转（`/opt/clipflow/data/files` 本地磁盘 + relay API），消耗 ECS 公共流量与磁盘；OSS 直传让客户端直传/直下 OSS（仍为客户端加密密文），服务端只存历史元数据 + object key。
- 生产实测（只读采集）：file 行 7 条 / 39.2MB（AVG 5.6MB / MAX 16MB），个人量级。

## 决策
1. **预签名 URL（非 STS）**：`ali-oss` Node SDK 服务端签发；object key = `clipflow/<userId>/<uuid>`；`file_key` 存 `oss:<uuid>` 前缀路由（**零 schema 变更**）；新端点 `POST /file/presign-upload` + `/confirm`、`GET /file/:id/presign-download`；旧 relay 端点 additive 扩展支持 oss 行兜底。
2. **客户端 additive**：改动收敛在 `CloudRepository.uploadFile/downloadFile` 内部 + 新增可注入普通 `http.Client` 的 `OssDirectClient`；对外签名不变（outbox/LAN/既有 fake 测试零改动）；presign/OSS 不可达 → 自动回退服务器 relay；大文件流式直传（StreamedRequest + File.openRead）；本地 artifact 缓存保留（LAN 硬依赖 + 回退）。
3. **防配额绕过**：直传模式「流式计数」失效 → confirm 端点 `HEAD` 实测对象 size ∈ [声明, +1024] 替代；`SUM(file_size)` 配额口径不变。
4. **生命周期**：trash 倾倒 / 24h 清理 / 100 条裁剪 / 同 id 重传覆盖 4 处统一 `deleteFileByBackend` 分派；孤儿回收 = OSS list + history `oss:` 有效集 + LastModified 宽限 1h（> 预签名 TTL 15min），启动 + 小时任务；5.2 恢复边界完整继承（字节已删 → 下载 404）。
5. **成本模型**：月成本公式 + 生产量级 S0≈¥0.06 / S1≈¥0.74 / S2≈¥27.4；当前量级 OSS 非省钱，价值在释放 ECS 6GB 免费额度、磁盘/带宽解耦；启用阈值：月非 LAN 文件流量逼近 6GB / 磁盘 >30GB / 扩缩需求。
6. **双读切单写**：灰度默认形态（新文件单写 OSS、旧文件留磁盘、客户端 OSS 优先读 + relay 兜底、旧客户端经 relay 兼容）；5 项退出条件通过后正式单写；回滚 = 去 env 重启，客户端零发版。

## 后果
- 文件字节不再经 ECS 中转（灰度后），ECS 公共流量/磁盘压力下降；客户端密文语义与经服务器一致。
- 红线零触碰：加密格式/PBKDF2/userId 派生/tokens/无外键零改动；既有 API 只 additive。
- 已记录限制：兼容模式完全去 OSS env 后 `oss:` 行 relay 下载 404（可逆回滚边界，D9 一致）；presign 查配额、confirm 不复查的竞态窗口略宽（relay 同样非原子）。
- 验证：smoke 34+16 全绿（本地 stub OSS 端到端）；`flutter test` 531；`flutter analyze` 0 error；reviewer 高置信通过。
- 未做：M7 生产部署（需配置 OSS_ACCESS_KEY_ID/SECRET/BUCKET/REGION/ENDPOINT env 后灰度观察）；真机 Mac/Android 回归。
