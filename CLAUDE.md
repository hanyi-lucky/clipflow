# CLAUDE.md

本文件为 Claude Code (claude.ai/code) 在此仓库中工作提供指引。

## 构建、测试、检查

```bash
# 运行所有测试（无需服务器连接即可跑核心服务测试）
flutter test

# 运行单个测试文件
flutter test test/services/encryption_service_test.dart

# 静态检查（info 级别也会导致 exit code 1，只有 error 需要关注）
flutter analyze

# 在 macOS 上运行
flutter run -d macos

# 构建发布版本
flutter build macos --release     # macOS .app
flutter build apk --release       # Android .apk
flutter build windows --release   # Windows .exe
```

**Flutter 安装路径：** `/opt/homebrew/bin/flutter`，如直接运行 `flutter` 命令找不到，请使用完整路径。

## 架构

**跨平台剪切板同步工具，端到端加密。** Flutter 前端，Node.js + SQLite 自建服务器后端。支持 macOS、Android、Windows，iPad/iOS 通过快捷指令 + Web App 补充。

### 整体架构

```
Flutter App
    ↓ HTTP POST (JSON)
Node.js Server (Express + SQLite)
    ↓
阿里云 ECS (2核2G, 40GB SSD)
```

### 服务器地址

- **API 基础地址：** `http://121.196.222.122:3000/api`
- **健康检查：** `http://121.196.222.122:3000/api/ping`

### 入口与路由

- `lib/main.dart` — 应用入口。用 `MultiProvider` 包裹组件树启动 App。
- `lib/app.dart` — `MaterialApp`，3 个命名路由：`/unlock` → `/home` → `/settings`。

### Provider 状态层

- `AuthProvider` — 生成设备 ID + 设备注册。通过 `LocalStorage` 在本地存储 `deviceId`/`deviceName`。
- `SettingsProvider` — 自动同步开关、历史记录条数限制。底层使用 `SharedPreferences`。
- `ClipboardProvider` — **核心调度器。** 持有 `SyncService`、`ClipboardMonitor`、`HistoryService`、`EncryptionService`。管理同步循环（500ms 轮询）、多选拼接状态、以及所有剪切板读写（含循环防护）。

### 数据流（复制 → 同步 → 粘贴）

```
[设备 A 复制内容]
    ↓ ClipboardMonitor 检测变化（桌面端 500ms 轮询，Android 原生监听）
    ↓ _onClipboardChanged() → 防抖 500ms → _uploadContent()
    ↓ SyncService.uploadContent()：SHA256 哈希 → AES-256-GCM 加密 → 调用服务器 API 写入数据库
    ↓
[其他设备通过 _startSyncLoop() 每 500ms 轮询云函数]
    ↓ SyncService.downloadLatestContent()：跳过自己的上传或过期数据 → 解密 → 返回
    ↓ ClipboardProvider 写入系统剪切板（先暂停监听器防止循环同步）
    ↓ 条目加入 HistoryService
```

### 服务器 API

服务器通过 HTTP 接收 JSON 请求：

| 方法 | 路径 | 说明 |
|-----|------|------|
| GET | `/api/ping` | 健康检查 |
| POST | `/api/auth` | 登录/注册 |
| GET | `/api/clipboard` | 获取最新剪切板 |
| POST | `/api/clipboard` | 上传剪切板内容 |
| GET | `/api/history` | 获取历史记录 |
| PATCH | `/api/history/:id` | 更新历史记录（置顶等） |
| DELETE | `/api/history/:id` | 删除历史记录 |
| POST | `/api/device` | 注册/更新设备 |
| GET | `/api/devices` | 获取设备列表 |
| GET | `/api/salt` | 获取加密盐值 |
| POST | `/api/salt` | 设置加密盐值 |

### 加密

- `EncryptionService` 在 `lib/services/encryption_service.dart` — AES-256-GCM（基于 pointycastle）。密钥通过 PBKDF2-HMAC-SHA256 派生（10 万次迭代）。`EncryptedData` 将 IV + 密文打包为单个 base64 字符串。
- 主密码在 `UnlockScreen` 输入。Salt 存储在服务器数据库。所有设备使用相同密码即可派生相同密钥。

### 剪切板监听

- `ClipboardMonitor` 在 `lib/services/clipboard_monitor.dart` — 桌面端：`Timer.periodic` 每 500ms 检查 `Clipboard.getData()`。Android：通过 `MethodChannel` 调用原生 `ClipboardManager.OnPrimaryClipChangedListener`。提供 `pause()`/`resume()` 方法，在将接收到的数据写入剪切板时暂停监听以防止循环同步。

### 数据库模型

```
devices/{deviceId}        — 设备信息
clipboard/current         — 最新剪切板条目（已加密）
clipboard/salt            — PBKDF2 密钥派生盐值
history/{entryId}         — 剪切板历史记录（已加密）
```

数据库表在服务器启动时自动创建（SQLite）。

### 同步去重

- 上传：明文 SHA256 与 `_lastUploadedHash` 比对 — 相同则跳过。
- 下载：时间戳比对 + 来源设备检查 — 跳过自己的上传和过期数据。

### 多选拼接

- `ClipboardProvider` 维护 `_isMergeMode`、`_selectedIds`（有序集合）、`_mergeSeparator`。
- `MergeBar` 组件显示实时拼接预览和分隔符下拉选择器（换行、逗号、分号、空格）。
- 复制拼接内容：用选定的分隔符将已选条目的内容拼接为一个字符串写入剪切板。

### 测试说明

核心服务测试（加密、历史记录、数据模型）不依赖服务器，可直接运行。UI 测试需要网络连接，当前以 smoke test 为主。`test/widget_test.dart` 包含核心模型和服务的基础验证。

### 服务器部署

```bash
# 在阿里云服务器上
ssh -i key241294.pem root@121.196.222.122
cd /opt/clipflow
bash deploy.sh
```
