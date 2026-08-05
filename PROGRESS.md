# ClipFlow 开发进度

> 更新时间：2026-08-05

---

## 已完成的功能

### 1. 核心同步机制
- [x] 跨设备剪切板同步（macOS ↔ Android ↔ Windows）
- [x] 端到端加密（AES-256-GCM + PBKDF2）
- [x] 密码即账户（无需注册）
- [x] 设备来源显示（正确区分 Mac / Android Phone / Windows PC）

### 2. 混合同步架构
- [x] 启动/刷新时全量加载服务器历史（200 条）
- [x] 周期轮询轻量同步（deletedIds + restoredEntries）
- [x] 本地独有条目保护（全量加载后合并）
- [x] 服务器不可达时保留内存历史
- [x] 刷新时暂停 sync loop 防并发

### 3. 垃圾箱系统
- [x] 软删除（deleted_at 时间戳）
- [x] 垃圾箱页面（左下角入口）
- [x] 恢复操作（restored_at 时间戳）
- [x] 删除/恢复实时同步（通过 GET /api/clipboard 的 deletedIds/restoredEntries）
- [x] 24 小时自动清理
- [x] 垃圾箱内容解密显示

### 4. 同步健壮性
- [x] 指数退避重试（500ms ~ 30s）
- [x] 删除防护（_recentlyDeletedHashes 防止 30s 内重新下载）
- [x] addEntry 去重时更新 ID
- [x] 启动时立即执行一次完整同步
- [x] DecryptionException 区分解密失败和无内容

### 5. 服务器修复
- [x] clipboard 表无限膨胀修复（DELETE + INSERT）
- [x] 全局错误处理中间件
- [x] token 定期清理（每小时）
- [x] restored_at 列支持
- [x] 客户端提供 historyId，服务器使用客户端 ID
- [x] history INSERT 主键冲突修复（INSERT → INSERT OR REPLACE）

### 6. Windows 平台支持
- [x] Windows 剪切板监听（500ms 轮询 Clipboard.getData）
- [x] Windows 构建和部署（flutter build windows）
- [x] Windows 应用图标（从 PNG 生成多尺寸 ICO）
- [x] Windows 开发环境搭建指南（WINDOWS_SETUP.md）

### 7. 同步 Bug 修复
- [x] _lastUploadedHash 时序修复（移到上传成功后赋值，防止失败后永久跳过）
- [x] _lastReceivedTimestamp 时序修复（移到内容处理成功后标记）

### 8. 客户端代码质量
- [x] ClipboardMonitor 类型安全（dynamic → SyncService?）
- [x] syncClipboard/syncClipboardWithContent 合并
- [x] hex_utils 工具类提取
- [x] 生产环境 print 语句清理
- [x] signOut 清除 token
- [x] togglePin/removeEntry 同步服务器
- [x] maxContentLength 截断
- [x] selectedEntries 排序优化
- [x] Android 单实例模式（singleTask）

### 9. UI/UX
- [x] 列表排序：置顶优先 + 时间倒序
- [x] 刷新按钮：全量同步 + 删除/恢复处理
- [x] 垃圾箱入口：左下角浮窗
- [x] 已删除条目显示：剩余保留时间

---

## 测试覆盖（当前 130 个测试）

| 模块 | 测试文件 | 数量 |
|------|---------|------|
| EncryptionService | encryption_service_test.dart | 12 |
| HistoryService | history_service_test.dart | 7 |
| ClipboardEntry | clipboard_entry_test.dart | 4 |
| HexUtils | hex_utils_test.dart | 7 |
| Exceptions | exceptions_test.dart | 1 |
| DownloadResult | download_result_test.dart | 3 |
| SyncService | sync_service_download_test.dart | 1 |
| SyncService Trash | sync_service_trash_test.dart | 1 |
| ClipboardProvider Trash | clipboard_provider_trash_test.dart | 1 |
| ClipboardProvider Hybrid | clipboard_provider_hybrid_sync_test.dart | 6 |
| Widget Smoke Test | widget_test.dart | 4 |

### v1.3 新增测试（71 个，含对既有文件的增量）

| 模块 | 测试文件 | 数量 |
|------|---------|------|
| ClipboardImage 模型 | clipboard_image_test.dart | 1 |
| 图片压缩/稳定哈希 | image_compression_service_test.dart | 9 |
| 图片通道封装 | image_clipboard_service_test.dart | 8 |
| 同步图片链路 | sync_service_image_test.dart | 10 |
| 本地密文缓存 | local_image_store_test.dart | 6 |
| Provider 图片 | clipboard_provider_image_test.dart | 8 |
| 长文本 /content 回补 | clipboard_provider_content_fallback_test.dart | 5 |
| 删除持久化 | clipboard_provider_deletion_test.dart | 3 |
| 图片预览页 | image_preview_screen_test.dart | 3 |
| Monitor 文本守卫 | clipboard_monitor_test.dart | 8 |
| 既有文件增量（加密字节/模型/历史） | 其余文件 | ~10 |

> v1.4 文件同步已完成（2026-08-05），共 212 个测试。详见 `docs/version-roadmap.md`。

### v1.3 已完成功能

| 功能 | 状态 | 说明 |
|------|------|------|
| 图片复制同步 | ✅ | macOS/Android 检测剪切板图片（含文件 URL），加密上传/下载，防回声闭环 |
| 图片压缩 | ✅ | 纯 Dart `image` 包 + compute isolate；2048 长边 / JPEG q80 / alpha 转 PNG |
| 缩略图预览 | ✅ | 256 缩略图独立加密存库；列表缩略图块 + 尺寸角标 |
| 图片查看器 | ✅ | 全屏 InteractiveViewer；全图密文本地文件缓存 + 惰性加载 |
| 图片筛选 | ✅ | 搜索栏"图片"类型筛选解锁（"文件"锁定，v1.4） |
| 服务器图片字段 | ✅ | clipboard/history 新增 thumb/width/height/format/hash/history_id（无外键、ALTER 兼容） |
| 历史列表瘦身 | ✅ | 图片行 content 剥离、文本行截断 10000；/history/:id/content 按需取全量 |
| Windows 图片通道 | ✅ | windows/runner WIC 实现（hasImage/getImage/setImage），待 Windows 真机验证 |

### v1.3 修复（2026-08-05）

- macOS 图片通道运行时注册修复（根因：注册代码位于 `super.applicationDidFinishLaunching` 之后，该调用之后的代码不执行；改为注册先行 + 直接绑定 engine.binaryMessenger，运行时探针实测 hasImage=true）
- 占位文本防护："[文件]"/"[图片]" 等不再作为文本上传；NUL/乱码（U+FFFD）文本跳过；hasImage 为真但读取失败时不落文本分支（三处路径一致，含 Android 原生回调）
- 服务器历史列表瘦身：文本行 content 截断 10000 字符（2.98MB → 123KB）；上传不再截断密文（修复明文 3.7万–5万 字符被静默损坏的隐患）；超限返回 413
- 长文本解密失败自动经 `/content` 拉全量重试（历史 + 垃圾箱）
- 删除持久化：removeEntry 写回本地 + `deletedEntryIds` 集合，刷新/重启不再复活已删条目
- 历史/垃圾箱请求超时放宽至 20s（其余保持 10s）

### v1.4 已完成功能（2026-08-05）

| 功能 | 状态 | 说明 |
|------|------|------|
| 文件复制同步 | ✅ | macOS file-url / Windows CF_HDROP / Android URI 预拷贝；检测顺序图片后、文本前 |
| 服务器文件存储 | ✅ | `POST/GET /api/file` 二进制端点 + 磁盘配额（用户 1GB/全局 4GB）+ 孤儿清理 + 声明大小校验（400 FILE_SIZE_MISMATCH） |
| 流式加密 | ✅ | 单载荷 AES-256-GCM，与现有 `EncryptedData` 格式互操作（兼容门禁测试） |
| 文件类型图标/大小/MIME | ✅ | 列表行按扩展名/MIME 映射 Material 图标 |
| 下载进度条 | ✅ | pending/downloading/processing/completed/failed/cancelled + 真实取消 + 手动重试保留元数据 |
| 文件筛选 | ✅ | 搜索栏"文件"类型解锁，按 fileName 匹配 |
| 垃圾箱 file 行 | ✅ | 按文件名/大小/MIME 展示，不尝试解密 |
| 倾倒垃圾桶 | ✅ | `DELETE /api/history/trash` 一键彻底删除本地、服务器、磁盘文件 |
| 垃圾箱预览 | ✅ | 文本解密预览、文件行文件名/大小/MIME、图片行缩略图 |
| 设置兼容性说明 | ✅ | 图片与文件格式兼容性、平台差异、大小限制说明 |
| Windows 文件通道 | ✅ | 静态交付（标准 DROPFILES 双 NUL 终止），待 Windows 真机验证 |

### v1.4 新增测试（73 个，总 212）

| 模块 | 测试文件 | 说明 |
|------|---------|------|
| 文件模型 | clipboard_file_test / clipboard_entry_test | map 解析与 file 字段 round-trip |
| 文件通道 | file_clipboard_service_test | 防御式类型转换/降级 |
| 流式加解密 | file_processing_service_test | EncryptedData 互操作、篡改/错 key、跨 chunk |
| 本地文件缓存 | local_file_store_test | 读写/删除/孤儿/容量 |
| Sync 文件链路 | sync_service_file_test | uploadFile headers、file: 去重域、元数据下载 |
| Provider 文件闭环 | clipboard_provider_file_test | 上传/下载/取消/重试互斥/元数据/竞态回归 |
| UI/监控 | clipboard_item_file_test / clipboard_monitor_test | 文件行渲染、进度状态、检测分支与回声 |
| 垃圾箱清空/长文本截断 | clipboard_provider_empty_trash_test | emptyTrash 委托 + 50000 截断 |
| 长文本预览 | clipboard_item_long_text_test | 500 字符预览 + 展开完整内容 |

### v1.4 验收与修复（2026-08-05）

- 修复孤儿清理与下载缓存落盘的并发竞态（图片先入史再落盘 + 进行中下载 ID 保护）。
- 修复取消不中断下载、取消后自动重试、手动重试丢元数据/并发窗口、服务器声明大小≠实际字节绕过配额。
- 复测修复：macOS 普通文件（PDF/DOCX）不再被文件图标缩略图误判为图片，优先走文件分支。
- 复测修复：Android 文件导入 MethodChannel 回调改主线程，修复滚动历史列表闪退（FlutterJNI @UiThread）。
- 复测修复：v1.3 残留 262.8 万字符乱码文本行改为 isolate 解密 + 50000 截断 + 列表 500 字符预览，消除历史/垃圾箱卡顿。
- 复测修复：文件签名只在上传成功后记录，失败后同文件可再次复制重试。
- 复测修复：Windows CF_HDROP 写入改为标准 DROPFILES 双 NUL 终止（静态修复，待 Windows 真机验证）。
- tester 独立验收 PASS；reviewer 终审 PASS-WITH-RISKS（置信度 8/10）。
- 发布门禁（未在本机验证）：Windows 真机 CF_HDROP/DROPFILES、macOS/Android 真机文件 E2E、双设备混合回归、50MB 压测。

### v1.2 已完成功能

| 功能 | 状态 | 说明 |
|------|------|------|
| 历史记录搜索 | ✅ | 搜索框 + 类型/设备筛选，模糊匹配不区分大小写 |
| 长文本展开/折叠 | ✅ | 超过 3 行显示"展开"按钮 |
| 搜索关键词高亮 | ✅ | 匹配文本用主题色标记 |
| 图片网格框架 | ✅ | v1.3 填充，当前显示空状态 |
| 网络状态检测 | ✅ | HTTP 10s timeout，断网灰点/服务错误红点 |
| 状态点交互 | ✅ | Tooltip + 点击重试 |
| 侧滑返回状态管理 | ✅ | 系统默认行为，侧滑返回直接退出 App（前台服务继续运行） |
| 搜索栏 UI 优化 | ✅ | 单行布局、圆角 16、彻底透明输入框 |
| 剪切板权限引导 | ✅ | macOS/Android 首次使用时引导用户授权 |
| 同步失败重试 | ✅ | 自动重试 3 次，失败后显示错误提示 |

### v1.2 待修复问题

1. **搜索框样式不一致（Mac vs Android）**：✅ 已修复。根因：全局 `inputDecorationTheme` 的 `OutlineInputBorder` 通过 Flutter merge 机制泄漏到搜索框。修复：移除 `app.dart` 中全局 `inputDecorationTheme` 的边框定义，各 TextField 显式声明自己的边框样式。同步在 CLAUDE.md 新增"前端跨平台样式一致性"规则。
2. **侧滑返回退出逻辑**：✅ 已修复。根因：`WillPopScope`（已废弃）和 `PopScope` 在 Android 14+ 预测性返回手势下均不可靠，`showDialog` 创建的独立路由与返回手势存在不可调和的冲突。修复方案：移除所有返回拦截逻辑（`PopScope`、`WillPopScope`、`WidgetsBindingObserver`、退出确认弹窗），改为系统默认行为——侧滑返回直接退出 App，前台服务继续运行。用户通过清理后台来彻底退出。

---

## 架构概览

```
Flutter App (macOS / Android / Windows)
    ↓ HTTP POST (JSON)
Node.js Server (Express + SQLite)
    ↓
阿里云 ECS (2核2G, 40GB SSD)

数据流：
复制 → ClipboardMonitor → SyncService.uploadContent → 服务器
服务器 → SyncService.downloadLatestContent → 系统剪切板

同步策略：
启动/刷新 → 全量加载 (GET /api/history?limit=200)
周期轮询 → 轻量同步 (GET /api/clipboard → deletedIds + restoredEntries)
```

## 关键文件

| 文件 | 职责 |
|------|------|
| `lib/providers/clipboard_provider.dart` | 核心调度器：同步循环、历史管理、刷新 |
| `lib/services/sync_service.dart` | 上传/下载/解密、DownloadResult |
| `lib/services/clipboard_monitor.dart` | 剪切板监听、上传触发 |
| `lib/services/image_compression_service.dart` | 图片压缩/缩略图/稳定哈希（isolate） |
| `lib/services/image_clipboard_service.dart` | 图片通道封装（防御式类型转换） |
| `lib/screens/image_preview_screen.dart` | 图片全屏查看器 |
| `lib/repositories/local_image_store.dart` | 全图密文文件缓存 |
| `windows/runner/resources/app_icon.ico` | Windows 应用图标 |
| `WINDOWS_SETUP.md` | Windows 开发环境搭建指南 |
| `server/smoke-test.sh` | 服务器冒烟测试（10 步断言） |
| `lib/services/history_service.dart` | 内存历史列表、去重、排序 |
| `lib/services/cloudbase_service.dart` | HTTP API 封装 |
| `lib/screens/trash_screen.dart` | 垃圾箱页面 |
| `lib/screens/home_screen.dart` | 主界面、垃圾箱入口 |
| `server/index.js` | 服务器 API、SQLite 操作 |

---

## 服务器信息

- **地址：** `http://121.196.222.122:3000/api`
- **SSH：** `ssh -i /Users/hanyi/Downloads/key241294.pem root@121.196.222.122`
- **服务管理：** `systemctl restart clipflow`
- **代码路径：** `/opt/clipflow/index.js`
- **数据库：** `/opt/clipflow/clipflow.db`（SQLite）
