# ClipFlow 架构与数据流

> 本文是架构、数据流、加密、LAN、数据库与同步机制的专题事实源。
> 当前完成状态只看 `PROGRESS.md`；设计理由看 `docs/decisions/`；服务器地址与运维看 `docs/server-operations.md`。

## 整体架构

ClipFlow 是跨平台剪切板同步工具，端到端加密。客户端为 Flutter，服务端为 Node.js + SQLite。原生支持 macOS、Android、Windows；iPad/iOS 通过快捷指令 + Web App 补充。

```
Flutter App
    ├─ 云端同步：HTTPS 直连 IP + 自签证书指纹固定（pinned_client.dart）
    │       ↓ JSON over TLS
    │   Node.js Server (Express + SQLite，仅监听 127.0.0.1，本机 TLS 层持自签证书对外；域名/Tunnel 已废弃，决策 001)
    │       ↓ 阿里云 ECS (2核2G, 40GB SSD)
    ├─ LAN 优先同步：mDNS 发现 + 自签 TLS + A3 双向挑战握手，文本/图片/文件直传，云端兜底
    │       ↓ LanSyncManager/LanTransport/LanProtocol 等 8 个 lan_*.dart
    └─ 混合同步调度：SyncCoordinator + durable outbox（离线操作排队重放），LAN-only 独立模式
```


## 早期选型

以下记录早期选型背景；最新规则仍以 `docs/decisions/` 为准。

### 后端三迁：Firebase → 腾讯云 → 阿里云自建

| 阶段 | 方案 | 迁移原因 |
|------|------|----------|
| v1.0 | Firebase | 初期快速验证，但国内需要梯子，用户无法使用 |
| v1.1 | 腾讯云开发 CloudBase | 国内直连，通过云函数 HTTP 端点访问数据库。但使用的是体验版，每月有资源点上限，而本项目的轮询机制会 24 小时与数据库互动，资源点很快耗尽 |
| v1.2+ | 阿里云 ECS 自建 | 买了一年服务器，无限次调用，完全自主可控，可直接 SSH 调试 |

**教训：** 有持续轮询需求的项目不适合按量计费或有资源上限的 BaaS 服务。自建服务器固定成本，无调用次数限制。

### 桌面端轮询 vs 系统原生 API

**决策：** macOS/Windows 使用 `Timer.periodic` 500ms 轮询 `Clipboard.getData()`，而非系统原生剪切板变更通知 API。

**原因：**
- Flutter 没有跨平台的剪切板变更通知 API
- 各平台原生 API 差异大（macOS 用 NSPasteboard observer，Windows 用 AddClipboardFormatListener）
- 500ms 轮询对剪切板场景完全够用，CPU 占用极低
- 实现简单，一个文件覆盖所有桌面平台

**例外：** Android 使用原生 `ClipboardManager.OnPrimaryClipChangedListener`（通过 MethodChannel），因为 Android 10+ 限制了后台剪切板访问，轮询方式不可靠。

### 端到端加密 vs 服务器端加密

**决策：** 所有数据在客户端加密后才上传，服务器只存储密文。

**原因：** 剪切板内容可能包含密码、token、私密信息等极度敏感数据。如果服务器被攻破，密文无法被解读。即使是我们自己运维的服务器，也不应该能看到用户数据。

### SQLite vs MongoDB/Redis

**决策：** 使用 SQLite 作为服务器数据库。

**原因：** 阿里云 ECS 是 2核2G 小机器，SQLite 零配置、零运维、单文件存储，对这个量级（个人工具，几台设备）绰绰有余。MongoDB/Redis 会额外占用几百 MB 内存，对小机器不友好。

---

## 核心设计决策（重要！）

以下是不可轻易更改的架构决策，修改前必须理解其原因。

### 1. 密码即账户（Password-as-Identity）

**机制：** userId = `user_` + `SHA256("clipflow:$password").substring(0, 16)`

- 相同密码 → 相同 userId → 共享数据
- 不同密码 → 不同 userId → 数据完全隔离
- 不存在传统的注册/登录/用户名系统

**为什么这样做：** 用户无需注册账号，输入密码即可跨设备同步。密码本身就是身份标识。

**⚠️ 不要做的事：**
- 不要实现邮箱/用户名注册系统
- 不要让用户创建独立的账户
- 不要修改 userId 的派生算法（会导致已有数据无法访问）

### 2. Token 持久化

**机制：** 服务器 token 存储在 SQLite `tokens` 表中（不是内存 Map），重启不丢失。

**为什么这样做：** 早期版本用内存 Map 存 token，服务器重启后所有客户端 token 失效，触发 FOREIGN KEY 错误。

**⚠️ 不要做的事：**
- 不要把 token 改回内存存储
- 不要删除 `tokens` 表
- 客户端收到 401 时会自动重新登录（`cloudbase_service.dart` 的 `_callApi`），不要手动处理

### 3. 数据库无外键约束

**机制：** 所有表都没有 FOREIGN KEY 约束；当前 schema 与完整表清单以 `server/index.js` 的建表语句为准。

**为什么这样做：** 早期有 FOREIGN KEY，当 token 失效导致 userId fallback 到不存在的 `'default'` 时，INSERT 操作报错且无法被客户端优雅处理。

**⚠️ 不要做的事：**
- 不要给现有表添加 FOREIGN KEY 约束
- 如果需要新建表，也不要加 FOREIGN KEY

### 4. 认证流程

```
用户输入密码
    ↓
SHA256("clipflow:$password") → userId
    ↓
POST /api/auth { userId } → 获取 token
    ↓
后续请求 Authorization: Bearer <token>
    ↓
token 失效(401) → 自动重新 POST /api/auth → 获取新 token → 重试
```

### 5. 前端跨平台样式一致性

**原则：三端（Android / macOS / Windows）使用完全相同的代码，不写平台分支，不做平台区分。**

**为什么这样做：** Flutter 的 `InputDecorationTheme` 等全局主题属性通过 `merge` 机制向子树传播，不同平台的渲染引擎对 `InputBorder.none` 的合成行为不一致，导致同一份代码在 Mac 上显示边框、Android 上正常。热重载也无法完全刷新主题继承。

**具体规则：**

1. **不在全局 `ThemeData` 中设置 `inputDecorationTheme` 的边框。** 需要边框的 TextField（如解锁密码框）在自己的 `InputDecoration` 中显式声明 `OutlineInputBorder`；不需要边框的 TextField（如搜索框）显式声明 `InputBorder.none` + `filled: false`
2. **UI 样式/布局层禁止 `Platform.isXXX` / `kIsWeb` 分支。** 同一份 Widget 树 = 同一份渲染结果。功能层的平台适配不受此限制（如 Android MethodChannel 剪切板监听、设备名称映射）
3. **自定义 Material 组件设 `surfaceTintColor: Colors.transparent`。** 防止 Material 3 默认 tint 在不同平台上的合成差异
4. **组件级颜色优先用 `ColorScheme` token**（`cs.surfaceContainerHighest`、`cs.onSurfaceVariant` 等）。应用级品牌色和固定设计值可硬编码（如 `Color(0xFF5B6CF0)`），但组件内部不得硬编码会被暗色模式影响的颜色
5. **样式修改后必须重启完整应用测试三端**，热重载不能可靠刷新主题继承

**新增 TextField 时的检查清单：**
- 是否显式声明了 `border`？（不声明会拿到 Flutter 默认 underline）
- 是否设置了 `filled`？（不设置会继承全局主题的 filled 值）
- 用 `grep -rn "TextField" lib/` 确认项目中所有 TextField 的边框样式是否统一

**⚠️ 不要做的事：**
- 不要在 `app.dart` 的 `inputDecorationTheme` 中设置 `border: OutlineInputBorder(...)` 然后期望子组件用 `InputBorder.none` 覆盖——Flutter 的 merge 在桌面端不可靠
- 不要为不同平台写不同的 Widget 树
- 不要新增未声明边框的 TextField——会拿到 Flutter 默认下划线，破坏三端一致性

## 数据流（复制 → 同步 → 粘贴）

```
[设备 A 复制内容]
    ↓ ClipboardMonitor 检测变化（桌面端 500ms 轮询，Android 原生监听）
    ↓ _onClipboardChanged() → 防抖 500ms → _uploadContent()
    ↓ SyncCoordinator 统一调度（single-flight/去重/退避）：
        文本/图片/文件 → AES-256-GCM 客户端加密 → outbox 持久化
        → 优先 LAN 推送（mDNS 对端在线时）→ 云端 API 兜底上传
    ↓
[其他设备通过 _startSyncLoop() 周期轮询 + durable cursor 增量拉取]
    ↓ SyncService.downloadLatestContent()：跳过自己的上传或过期数据 → 解密 → 返回
    ↓ ClipboardProvider 写入系统剪切板（先暂停监听器防止循环同步）
    ↓ 条目加入 HistoryService（按 historyLimit 截断，置顶不占名额）
    ↓ 删除/恢复操作经 durable outbox + sync_tombstones 多设备收敛
```

## 服务器 API

服务器通过 HTTP/HTTPS 接收 JSON 请求（`/api/auth` 有 IP+userId 双桶限流；`/api/crash` 可选认证+独立限流）；端点清单见 `server/index.js`。

## 加密

- `EncryptionService` 在 `lib/services/encryption_service.dart` — AES-256-GCM（128-bit tag；基于 pointycastle ^3.9.1，4.x 升级已列入计划）。密钥通过 PBKDF2-HMAC-SHA256 派生（`AppConstants.pbkdf2Iterations = 100000`，密钥 32 字节，IV 12 字节）。**`EncryptedData` 序列化为 `[2字节 IV 长度][IV][密文+tag]` 的整体 base64**（`toBytes()` / `fromBytes()`）——**注意那 2 字节长度前缀**，漏了会读出不兼容的数据。文件用 `FileProcessingService` 流式加解密（同一套密钥）。
- 主密码在 `UnlockScreen` 输入。Salt 存储在服务器数据库。所有设备使用相同密码即可派生相同密钥。
- **LAN 认证密钥隔离：** `K_lan = HMAC-SHA256(账户密钥, "clipflow:lan-auth-v1")`，与内容加密密钥用途隔离；LAN 传输经自签 TLS（证书指纹固定，区别于云端指纹）。

## LAN 同步子系统（Phase 2.1-2.4 / 5.1-5.2，详见 docs/decisions/003-009）

- 8 个服务：`lan_discovery_service`（mDNS 桥接+黑名单）、`lan_handshake_service`（A3 双向挑战+nonce 重放防护）、`lan_tls`（自签证书指纹固定）、`lan_protocol`（帧编解码）、`lan_transport`（TLS 会话+分块帧+逐帧超时）、`lan_sync_manager`（push/pull/待确认表）、`lan_network_channel`（平台 MethodChannel：macOS NSNetService / Android NsdManager / Windows Win32 DNS-SD）、`lan_diagnostics`（计数埋点）。
- 平台插件：macOS `LanNetworkPlugin.swift`、Android `LanNetworkPlugin.kt`、Windows `lan_network_plugin.cpp`（决策 009：Win32 DNS-SD，否决 WinRT）。
- 可靠性：LAN 专属 outbox（`clipflow_lan_outbox/`，原子写）、fileAck 确认帧、`FileDownloadBreaker` 重下熔断（3 次坏 artifact → 60s 冷却）、幂等会话替换。
- LAN-only 模式（决策 007）：三型内容路由 + 降级横幅 + 重启恢复，默认关。

## 剪切板监听

- `ClipboardMonitor` 在 `lib/services/clipboard_monitor.dart`
- **桌面端（macOS/Windows）：** `Timer.periodic` 每 500ms 轮询 `Clipboard.getData()`
- **Android：** 通过 `MethodChannel` (`clipflow/clipboard`) 与原生层通信。原生层使用 `ClipboardManager.OnPrimaryClipChangedListener` + Foreground Service 保活，检测到变化后调用 `syncClipboard` 传入剪切板内容（Android 10+ 限制后台读取剪切板，因此由原生层传递内容而非 Flutter 层主动读取）
- 提供 `pause()`/`resume()` 方法，在将接收到的数据写入剪切板时暂停监听以防止循环同步
- `ignoreHashes` 机制：从其他设备同步来的内容加入忽略列表，防止上传自己刚下载的内容
- 文件在途签名守卫（Phase 2.1 ⑧）：防止文件回写触发重复上传

## OSS 直传（Phase 5.3，决策 010：实现完成、生产暂缓）

- 无 OSS env 时服务器 presign 端点返回 503，客户端自动回退经 ECS relay——当前生产即此 compat 模式。
- 启用阈值：月非 LAN 流量逼近 6GB / 磁盘 >30GB。客户端 `oss_direct_client.dart` + 仓库层 direct/fallback 已就绪并有单测。

## 数据库模型

服务器使用 SQLite，表在启动时自动创建，**所有表无 FOREIGN KEY 约束**；建表语句见 `server/index.js`。

- `clipboard` 表仅保留每用户最新 1 条记录（上传时 DELETE + INSERT）
- `history` 表保留最近 100 条**非置顶活跃**条目（服务端自动清理；**置顶条目不占名额永不裁剪，垃圾箱软删条目不参与裁剪不占名额**——与客户端 `HistoryService._trim()` 语义对齐），支持软删除（`deleted_at`）和恢复（`restored_at`）
- `sync_operations` 7 天清理；`sync_tombstones` 快照 24h 清理；`tokens` 每小时清理超过 24 小时的过期 token；`crash_reports` 30 天清理；软删 history 超 24h 触发文件清理

## 同步去重

- 上传：明文 SHA256 与 `_lastUploadedHash` 比对 — 相同则跳过。
- 下载：时间戳比对 + 来源设备检查 — 跳过自己的上传和过期数据。

## 多选拼接

- `ClipboardProvider` 维护 `_isMergeMode`、`_selectedIds`（有序集合）、`_mergeSeparator`。
- `MergeBar` 组件显示实时拼接预览和分隔符下拉选择器（换行、逗号、分号、空格）。
- 复制拼接内容：用选定的分隔符将已选条目的内容拼接为一个字符串写入剪切板。

## 测试覆盖

功能测试覆盖加密、历史、同步、LAN 协议/传输/管理器、outbox、备份、i18n 护栏和 Provider 集成；服务端行为由 `server/smoke-test.sh` 覆盖，当前数量以实际运行结果为准。i18n 护栏为 `hardcoded_chinese_test.dart`。
