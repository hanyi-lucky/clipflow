# ClipFlow

跨平台剪切板同步工具，端到端加密，支持 macOS、Android、Windows。

## 功能

- 🔄 **自动同步** — 复制内容后自动加密上传，其他设备秒级同步
- 🔒 **端到端加密** — AES-256-GCM + PBKDF2，服务器只存密文
- 🗑️ **垃圾箱** — 删除后可恢复，24 小时自动清理
- 🖼️ **图片同步** — 复制图片自动同步，压缩 + 缩略图 + 全屏查看
- 📋 **历史记录** — 默认保留最近 100 条，支持置顶和搜索
- 🔀 **多选拼接** — 选择多条内容，自定义分隔符合并复制
- 🔄 **混合同步** — 启动全量加载 + 周期轻量轮询，兼顾性能和实时性
- 🌙 **主题切换** — 浅色/深色/跟随系统

## 支持平台

| 平台 | 状态 | 安装方式 |
|-----|------|---------|
| macOS | ✅ 已完成 | DMG 安装包 |
| Android | ✅ 已完成 | APK 安装包 |
| Windows | ✅ 已完成（文本；图片代码已就绪） | 解压即用 |
| iOS/iPadOS | ⏳ 规划中 | 快捷指令 + Web App |

## 技术栈

- **前端**：Flutter（跨平台）
- **后端**：Node.js + Express + SQLite
- **加密**：AES-256-GCM + PBKDF2-HMAC-SHA256（10 万次迭代）
- **服务器**：阿里云 ECS（自建，固定成本，无限调用）

## 快速开始

### 1. 安装依赖

```bash
flutter pub get
```

### 2. 部署服务器

```bash
cd server
# 在阿里云服务器上执行
bash deploy.sh
```

### 3. 运行

```bash
# macOS
flutter run -d macos

# Android（需连接设备或启动模拟器）
flutter run -d <device_id>

# Windows
flutter run -d windows
```

### 4. 构建发布版

```bash
flutter build macos --release        # → build/macos/Build/Products/Release/ClipFlow.app
flutter build apk --release          # → build/app/outputs/flutter-apk/app-release.apk
flutter build windows --release      # → build/windows/x64/runner/Release/
```

## 架构

```
Flutter App (macOS / Android / Windows)
    ↓ HTTP (JSON)
Node.js Server (Express + SQLite)
    ↓
阿里云 ECS

同步策略：
  启动/刷新 → 全量加载历史（GET /api/history?limit=200；服务端保留最近 100 条）
  周期轮询 → 轻量同步删除/恢复（GET /api/clipboard → deletedIds + restoredEntries）
  桌面端 500ms 轮询剪切板，Android 原生监听 + Foreground Service
```

## 加密机制

```
用户密码 → SHA256("clipflow:password") → userId（身份标识）
用户密码 → PBKDF2(100000轮, SHA-256, 全局Salt) → 256位 AES 密钥

加密：AES-256-GCM + 随机12字节 IV → 密文上传
解密：同密钥 + 同 IV → 明文
```

- 相同密码 → 相同密钥 → 数据共享
- 不同密码 → 不同密钥 → 数据完全隔离
- 无需注册，密码即账户

## 项目结构

```
lib/
├── core/          # 常量、异常、工具函数
├── models/        # 数据模型（ClipboardEntry, Device）
├── services/      # 核心业务（同步、加密、监听、历史）
├── repositories/  # 数据仓库（API 调用、本地存储）
├── providers/     # 状态管理（ClipboardProvider, AuthProvider, SettingsProvider）
├── screens/       # 页面（解锁、主页、设置、垃圾箱）
└── widgets/       # 可复用组件（条目卡片、拼接栏、状态指示器）

test/              # 215 个测试（加密、同步、模型、Provider、Monitor、文件/图片集成）
server/            # Node.js 后端（Express + SQLite）
docs/              # 项目文档
```

## 许可证

MIT License
