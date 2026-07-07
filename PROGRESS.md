# ClipFlow 开发进度

> 更新时间：2026-07-07 19:20

---

## 本次改造：Android 端剪切板同步方案（触发式）

### 改造背景

Android 10+ 限制后台 App 访问剪切板，原方案的后台监听模式在新版本 Android 上不可靠。新方案改为"主动触发式同步"，保留原有后台监听模式兼容低版本 Android。

### 改造内容

#### 三种同步模式并存
| 模式 | 触发方式 | 默认状态 | 适用平台 |
|------|---------|---------|---------|
| 后台自动同步 | Timer 500ms 轮询 | 开启 | 桌面端、低版本 Android |
| App 打开自动同步 | onResume | 开启 | Android（所有版本）|
| 通知栏同步 | 点击通知 | 开启 | Android（所有版本）|

#### 核心设计
1. **统一 `syncClipboard()` 方法**：所有入口调用同一方法，避免重复逻辑
2. **`ignoreHashes` HashSet**：最多10个，命中后立即删除，防多设备并发覆盖
3. **低优先级通知**：不发声不震动，点击直接打开 App 触发同步
4. **权限状态显示**：设置页显示通知权限、电池优化状态

#### 改动文件清单

**Dart 层：**
| 文件 | 改动 |
|------|------|
| `lib/services/clipboard_monitor.dart` | 新增 `syncClipboard()`、`ignoreHashes` HashSet、持久化存储、`syncClipboardWithContent()` |
| `lib/providers/clipboard_provider.dart` | 生命周期监听 onResume、Foreground Service 启停、UI 状态转发、`resumeSync()` |
| `lib/providers/settings_provider.dart` | 三个同步开关、权限检查方法 |
| `lib/repositories/local_storage.dart` | 新增持久化 key：lastHash、lastSyncTime、ignoreHashes、同步开关 |
| `lib/screens/settings_screen.dart` | 同步设置分区、权限状态显示（改为 StatefulWidget） |
| `lib/screens/home_screen.dart` | 同步状态栏（连接状态+上次同步时间） |

**Android 原生：**
| 文件 | 改动 |
|------|------|
| `android/.../SyncForegroundService.kt` | **新增** - 前台服务，低优先级常驻通知，点击打开 App |
| `android/.../SyncNotificationReceiver.kt` | **新增** - 通知栏按钮点击处理（现已改为直接打开 App） |
| `android/.../ClipboardPlugin.kt` | 新增 MethodChannel 方法：startSyncService、stopSyncService、权限检查等 |
| `android/app/src/main/AndroidManifest.xml` | 新增权限声明和 Service/Receiver 注册 |

**新增依赖：**
- `permission_handler: ^11.4.0`

### 关键技术决策

1. **通知栏交互简化**：原设计为通知栏"立即同步"按钮，但 Android 10+ 限制 BroadcastReceiver 无法读取剪切板。改为点击通知直接打开 App，利用 onResume 触发同步。

2. **字段名一致性**：服务器端上传使用 camelCase（`sourceDeviceName`），下载返回 snake_case（`source_device_name`）。这是因为服务器代码读取 camelCase 字段后转换为 snake_case 存储到 SQLite。

3. **ignoreHashes 设计为 HashSet**：最多10个，FIFO 淘汰。命中后立即删除，确保用户手动复制相同内容仍能正常同步。

### 已知问题（P2/P3，非阻断）

1. **Timer 泄漏风险**：`_startSyncLoop()` 中 `_syncTimer = Timer.periodic(...)` 未先 cancel 旧 timer。已修复（加了 `_syncTimer?.cancel()`）。

2. **调试日志未清理**：`clipboard_monitor.dart`、`clipboard_provider.dart` 中仍有 `debugPrint` 日志。上线前应清理。

3. **旧数据显示错误设备名**：改造前上传的内容，设备名称可能显示错误（如 Android 显示为 Mac）。新上传的内容已修复。

### 待验证

- [ ] Android → Mac 双向同步：新上传内容设备名称是否正确
- [ ] 通知栏点击 → App 打开 → 自动同步 完整流程
- [ ] 三种模式开关独立可控
- [ ] 设置页面权限状态正确显示

---

## 历史已完成

### 1. 应用清理与重新安装（2026-07-07 03:30）
- Mac 端和 Android 端均已重新构建并安装最新代码

### 2. 同步架构修复 — userId 生成策略
userId 从密码派生：`user_` + `SHA256("clipflow:$password").substring(0, 16)`

### 3. 服务器端修复
- token 改为 SQLite 持久化
- 移除 FOREIGN KEY 约束
- 自动清理过期 token

### 4. 客户端自动重新登录
401 时自动重新登录，重试请求

---

## 服务器信息

- **地址：** `http://121.196.222.122:3000/api`
- **SSH：** `ssh -i /Users/hanyi/Downloads/key241294.pem root@121.196.222.122`
- **服务管理：** `systemctl restart clipflow`
- **代码路径：** `/opt/clipflow/index.js`
- **数据库：** `/opt/clipflow/clipflow.db`（SQLite）

---

## 三代理流程记录

本次改造使用了三代理流程（coder → tester → reviewer）：

1. **coder**：完成 Dart 层 + Android 原生层改造
2. **tester**：发现 `home_screen.dart` 括号不匹配错误，已修复
3. **reviewer**：发现 3 个 P0 阻断性问题（通知栏按钮失效、Foreground Service 未启动、死循环），coder 整改后通过验收

整改轮次：1 轮（coder → tester → reviewer → coder 整改 → tester 验证 → reviewer 验收通过）
