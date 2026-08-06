# Windows 开发环境准备指南

> 在 Windows 上使用 Claude Code 执行以下步骤

---

## Step 1：安装 Flutter SDK

```powershell
# 下载 Flutter SDK
# https://docs.flutter.dev/get-started/install/windows

# 解压到 C:\flutter（或你喜欢的位置）
# 添加 C:\flutter\bin 到系统 PATH

# 验证
flutter --version
```

## Step 2：安装 Git（如果没有）

```powershell
winget install Git.Git
git --version
```

## Step 3：克隆项目

```powershell
git clone https://github.com/hanyi-lucky/clipflow.git
cd clipflow
flutter pub get
```

## Step 4：检查环境

```powershell
flutter doctor
```

确认通过：
- [x] Flutter
- [x] Windows Version
- [x] Visual Studio - develop Windows apps

## Step 5：运行

```powershell
# 运行测试
flutter test

# 启动 Windows 应用
flutter run -d windows

# 构建发布版
flutter build windows
```

## Step 6：首次使用

1. 启动 app 后输入与其他设备相同的密码
2. 自动从服务器同步历史记录
3. 开始使用

---

## 常见问题

### flutter run 报错 "No connected devices"
→ 使用 `flutter run -d windows`（指定 Windows 设备）

### 构建后找不到 exe
→ 在 `build\windows\x64\runner\Release\clipflow.exe`

---

## 一键配置脚本（推荐）

Windows 端环境检查 / 修复 Claude Code / sshd 开机自启，直接双击：

```
scripts\windows\setup-windows.cmd
```

脚本会自动：检查 git、node/npm、flutter → 重装并校验 Claude Code → 把 OpenSSH Server 设为开机自启并启动 → `git pull` 最新代码。

> 注意：`scripts/win-remote-build.sh` 是 macOS 端遥控 Windows 构建的脚本，不要在本机运行。

## 开发工作流

```
Windows 上写代码 → git push → Mac 上拉取验证
Mac 上写代码 → git push → Windows 上拉取测试
```

两端代码完全共享，无需额外配置。
