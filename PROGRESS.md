# ClipFlow 开发进度

> 更新时间：2026-07-21

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

## 测试覆盖（49 个测试）

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

> v1.1 已完成（Android 正式签名、服务器非 root 运行）。下一阶段：v1.2 体验优化。详见 `docs/version-roadmap.md`。

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
| `windows/runner/resources/app_icon.ico` | Windows 应用图标 |
| `WINDOWS_SETUP.md` | Windows 开发环境搭建指南 |
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
