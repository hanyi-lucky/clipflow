# macOS 端完成状态

> 最后更新：2026-06-27
> 版本：v1.0.0
> 状态：✅ 稳定可用

---

## 架构概览

```
ClipFlow App (Flutter)
    ↓ HTTP POST (JSON)
Node.js Server (Express + SQLite)
    ↓
阿里云 ECS (2核2G, 40GB SSD)
```

- **服务器地址：** `http://121.196.222.122:3000/api`
- **数据库：** SQLite（本地存储）
- **API 端点：** `/api/clipboard`、`/api/history`、`/api/device`、`/api/salt`

## 已实现功能

### 核心功能
| 功能 | 实现方式 | 状态 |
|-----|---------|------|
| 剪切板自动同步 | 500ms 轮询 `Clipboard.getData()` | ✅ |
| 端到端加密 | AES-256-GCM + PBKDF2-HMAC-SHA256 | ✅ |
| 历史记录 | 本地 SharedPreferences + 云端存储 | ✅ |
| 多选拼接 | 自定义分隔符（换行/逗号/分号/空格） | ✅ |
| 手动刷新 | 一键拉取云端最新内容 | ✅ |
| Salt 云端同步 | 首台设备上传 Salt，后续设备下载 | ✅ |

### 界面功能
| 功能 | 实现方式 | 状态 |
|-----|---------|------|
| 主题切换 | 浅色/深色/跟随系统（ThemeMode） | ✅ |
| 设备图标 | 根据 platform 字段显示真实设备类型 | ✅ |
| 解锁页 | 渐变背景 + 主密码输入 | ✅ |
| 空状态 | 图标 + 文字提示 | ✅ |
| 同步状态 | 绿点指示器（已连接/同步中/失败） | ✅ |

### 系统集成
| 功能 | 实现方式 | 状态 |
|-----|---------|------|
| macOS 系统托盘 | NSStatusItem + 菜单 | ✅ |
| Cmd+W 退到后台 | keyDown 事件拦截 | ✅ |
| 红色 X 退到后台 | applicationShouldTerminateAfterLastWindowClosed | ✅ |
| Dock 图标重新打开 | applicationShouldHandleReopen | ✅ |
| App 图标 | 自定义 ClipFlow 图标 | ✅ |

## 账户与加密机制

### 密码即账户

```
用户输入密码
    ↓
SHA256("clipflow:$password") → userId（前16位，加 user_ 前缀）
    ↓
POST /api/auth { userId } → 获取 token
```

- 相同密码 → 相同 userId → 共享数据
- 不同密码 → 不同 userId → 数据完全隔离
- 无需注册，密码本身就是身份标识

### 端到端加密

```
主密码 → PBKDF2(100000轮, SHA-256) → 256位 AES 密钥
Salt（所有设备共享）→ 存储在 clipboard/salt

加密：AES-256-GCM + 随机12字节 IV
解密：同密钥 + 同 IV
```

- 不同密码 → 不同密钥 → 解密失败
- 相同密码 + 相同 Salt → 相同密钥 → 解密成功

### Token 持久化

服务器 token 存储在 SQLite `tokens` 表中（非内存），重启不丢失。客户端收到 401 时自动重新登录并重试请求。

## 同步去重

- **上传：** SHA256(明文) 与 `_lastUploadedHash` 比对，相同跳过
- **下载：** 时间戳比对 + 来源设备检查，跳过自己的数据

## 项目依赖

| 包 | 用途 |
|---|------|
| flutter | 框架 |
| http | HTTP 请求 |
| pointycastle | AES/PBKDF2 加密 |
| crypto | SHA256 哈希 |
| shared_preferences | 本地存储 |
| provider | 状态管理 |
| uuid | 唯一 ID 生成 |

## 构建命令

```bash
# 开发调试
flutter run -d macos

# 构建发布版
flutter build macos --release

# 打包 DMG
hdiutil create -volname "ClipFlow" -srcfolder /path/to/ClipFlow.app -ov -format UDZO ~/Desktop/ClipFlow.dmg
```

## 构建产物

| 产物 | 路径 |
|-----|------|
| Debug | `build/macos/Build/Products/Debug/ClipFlow.app` |
| Release | `build/macos/Build/Products/Release/ClipFlow.app` |
| DMG | `releases/macos/ClipFlow.dmg` |

## 已知限制

| 限制 | 说明 |
|-----|------|
| 仅支持文本 | 图片和文件同步在后续版本开发 |
| 轮询模式 | 非实时推送，最大 500ms 延迟 |
| iPad 无原生 App | 通过快捷指令 + Web App 补充 |

## 版本历史

| 版本 | 日期 | 内容 |
|-----|------|------|
| v1.0.0 | 2026-06-24 | 初版：核心同步功能 |
| v1.1.0 | 2026-06-26 | UI 设计 + Salt 同步修复 + 主题切换 |
| v1.2.0 | 2026-06-27 | 迁移阿里云自建服务器 |
| v1.3.0 | 2026-07-05 | 密码即账户 + Token 持久化 + 401 自动重登录 |

---

## 文件结构

```
lib/
├── core/constants.dart          # 常量配置
├── core/exceptions.dart         # 异常定义
├── models/clipboard_entry.dart  # 剪切板条目模型（含 platform 字段）
├── models/device.dart           # 设备模型
├── services/cloudbase_service.dart  # 服务器 API 封装
├── services/encryption_service.dart # AES 加密
├── services/sync_service.dart   # 同步服务
├── services/clipboard_monitor.dart # 剪切板监听（桌面轮询）
├── services/history_service.dart   # 历史记录管理
├── services/auth_service.dart   # 认证服务
├── repositories/cloud_repository.dart # 云数据库操作
├── repositories/local_storage.dart # 本地存储
├── providers/clipboard_provider.dart # 核心调度器
├── providers/auth_provider.dart # 认证状态
├── providers/settings_provider.dart # 设置（含主题）
├── screens/unlock_screen.dart   # 解锁页
├── screens/home_screen.dart     # 主页
├── screens/settings_screen.dart # 设置页
├── widgets/clipboard_item.dart  # 条目卡片
├── widgets/merge_bar.dart       # 拼接栏
└── widgets/status_indicator.dart # 状态指示器
```
