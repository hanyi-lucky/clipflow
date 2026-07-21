# ClipFlow

跨平台剪切板同步工具，支持端到端加密。

## 功能

- 🔄 自动同步：复制内容后自动同步到其他设备
- 🔒 端到端加密：AES-256-GCM + PBKDF2，数据安全
- 📋 历史记录：保留最近 100 条复制记录
- 🔀 多选拼接：选择多条内容合并复制
- 🌙 主题切换：浅色/深色/跟随系统

## 支持平台

| 平台 | 状态 |
|-----|------|
| macOS | ✅ 已完成 |
| Android | ✅ 已完成 |
| Windows | ✅ 已完成 |
| iOS/iPadOS | ⏳ 快捷指令 + Web App |

## 技术栈

- **前端**：Flutter
- **后端**：Node.js + Express + SQLite
- **加密**：AES-256-GCM + PBKDF2-HMAC-SHA256
- **服务器**：阿里云 ECS

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

# Android
flutter run -d <device_id>

# 构建
flutter build macos --release
flutter build apk --release
```

## 架构

```
Flutter App → HTTP POST → Node.js Server (Express + SQLite)
```

## 加密

- 主密码 → PBKDF2 派生 256 位 AES 密钥
- 每台设备共享同一 Salt（存储在云端）
- 相同密码 → 相同密钥 → 数据共享
- 不同密码 → 不同密钥 → 数据隔离

## 项目结构

```
lib/
├── core/          # 常量、异常定义
├── models/        # 数据模型
├── services/      # 核心业务逻辑
├── repositories/  # 数据仓库
├── providers/     # 状态管理
├── screens/       # 页面
└── widgets/       # 可复用组件

server/
├── index.js       # 服务器主文件
├── package.json   # 依赖配置
└── deploy.sh      # 部署脚本
```

## 许可证

MIT License
