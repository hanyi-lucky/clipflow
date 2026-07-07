---
name: build-deploy
description: "打包并安装 ClipFlow 到指定平台。当用户说「打包」「部署」「安装到手机」「build」「deploy」「装一下」或修改了平台相关代码后需要测试时触发。自动检测改动的平台（macOS/Android/Windows），只构建受影响的那一端，部署前自动校验设备连接和环境就绪状态。"
---

# Build & Deploy Skill

根据代码改动自动判断目标平台，构建前校验环境就绪，构建后自动安装到对应设备。

## 触发时机

- 用户说「打包」「部署」「安装」「build」「deploy」「装一下」「跑一下」
- 修改了平台相关代码（`android/`、`macos/`、`windows/`、`ios/`）后需要测试
- 用户明确指定平台：「打包 Android」「装到手机」

## 执行流程

### Step 1: 检测改动平台

运行 `git diff --name-only HEAD` 查看改动文件，按路径前缀判断：

| 路径前缀 | 平台 |
|----------|------|
| `android/` | Android |
| `macos/` | macOS |
| `windows/` | Windows |
| `ios/` 或涉及 xcodeproj/xcworkspace | iOS/iPadOS |
| `lib/`、`pubspec.yaml`、`test/` | 全平台（所有端都需要重新构建） |

如果用户明确指定了平台，跳过检测直接进入该平台的 Step 2。

### Step 2: 环境预检（每端独立校验）

在构建之前，必须先确认目标平台的环境就绪。任何一项不满足则停下来告知用户，不要强行构建。

#### macOS 环境预检

```bash
# 检查 Flutter 是否可用
/opt/homebrew/bin/flutter --version
```
- 失败 → 提示：「Flutter 未安装或路径异常，请检查 /opt/homebrew/bin/flutter」

无需额外设备检测，macOS 本机构建本机安装。

#### Android 环境预检

按顺序执行以下检查，任一失败则停下来提示用户：

```bash
# 1. 检查 adb 是否可用
ADB="/Users/hanyi/Library/Android/sdk/platform-tools/adb"
$ADB version

# 2. 检查是否有设备连接
$ADB devices | grep -w "device"

# 3. 检查设备是否开启了 USB 调试（通过尝试 shell 命令）
$ADB shell echo "ok"
```

**常见失败及提示语：**

| 检查项 | 失败表现 | 提示用户 |
|--------|---------|----------|
| 无设备连接 | `devices` 输出只有 `List of devices attached` | 「未检测到 Android 设备，请用数据线连接手机并确认已开启 USB 调试」 |
| USB 调试未开 | `shell echo` 返回 `error: device unauthorized` | 「手机上弹出了 USB 调试授权弹窗，请点击「允许」，然后重试」 |
| 仅充电模式 | `shell echo` 成功但设备状态是 `offline` | 「设备处于离线状态，请在手机上将 USB 连接模式从「仅充电」改为「文件传输」」 |
| USB 安装未开 | 构建后 `adb install` 返回 `INSTALL_FAILED_USER_RESTRICTED` | 「请在手机「开发者选项」中开启「USB 安装」（部分国产手机需要登录小米/华为账号才能开启）」 |

#### Windows 环境预检

Windows 无法远程安装，只做构建验证：
- 如果用户在 macOS 上触发 Windows 构建，构建完成后提示：「请将 build/windows/x64/runner/Release/ 文件夹复制到 Windows 电脑运行 clipflow.exe」
- 如果检测到当前系统是 Windows（罕见），可尝试直接运行构建产物

#### iOS/iPadOS 环境预检

```bash
# 检查 Xcode 是否安装
xcodebuild -version
# 检查连接的 iOS 设备
xcrun xctrace list devices 2>&1 | grep -v "Simulator"
```

- Xcode 未安装 → 提示：「需要安装 Xcode 才能构建 iOS 应用」
- 无 iOS 设备连接 → 提示：「请用数据线连接 iPhone/iPad，并在设备上信任此电脑」
- iOS 无法自动安装，构建成功后提示用户在 Xcode 中手动安装：「请打开 ios/Runner.xcworkspace，选择你的设备后点击 Run」

### Step 3: 构建

使用项目 Flutter 路径 `/opt/homebrew/bin/flutter`。构建超时设为 300000ms（5 分钟）。

**macOS:**
```bash
/opt/homebrew/bin/flutter build macos --release
```

**Android:**
```bash
/opt/homebrew/bin/flutter build apk --release
```

**Windows:**
```bash
/opt/homebrew/bin/flutter build windows --release
```

**iOS/iPadOS:**
```bash
/opt/homebrew/bin/flutter build ios --release --no-codesign
```

构建失败时，输出错误摘要（不要输出完整日志），然后停下来。不要自动重试，除非是明显的缓存问题（提示用户是否要 `flutter clean` 后重试）。

### Step 4: 安装部署

**macOS:**
```bash
# 关闭正在运行的旧版本
pkill -f "ClipFlow" 2>/dev/null
# 覆盖安装
cp -R build/macos/Build/Products/Release/ClipFlow.app /Applications/ClipFlow.app
# 启动
open /Applications/ClipFlow.app
```

**Android:**
```bash
ADB="/Users/hanyi/Library/Android/sdk/platform-tools/adb"
# 覆盖安装（-r 允许覆盖）
$ADB install -r build/app/outputs/flutter-apk/app-release.apk
# 启动应用
$ADB shell am start -n com.clipflow.clipflow/.MainActivity
```
如果 `adb install` 失败，根据错误码给出具体提示：
- `INSTALL_FAILED_ALREADY_EXISTS` → 尝试 `adb uninstall com.clipflow.clipflow` 后重装
- `INSTALL_FAILED_USER_RESTRICTED` → 提示开启「USB 安装」
- `INSTALL_FAILED_INSUFFICIENT_STORAGE` → 提示手机存储空间不足

**Windows:**
告知用户产物路径，无法远程安装。

**iOS/iPadOS:**
告知用户在 Xcode 中手动安装。

## 输出格式

构建完成后输出简洁报告：

```
🔍 检测到改动：android/、lib/
📱 Android 环境预检：✅ 设备已连接 (8fadc5d0)
🔨 构建 Android APK...
✅ Android 构建成功 (51.1MB)
📲 安装到设备...
✅ 已安装并启动
```

失败时：
```
🔍 检测到改动：android/
📱 Android 环境预检：❌ 未检测到设备
💡 请用数据线连接手机，确认已开启 USB 调试，然后重试
```

## 项目关键路径

- Flutter: `/opt/homebrew/bin/flutter`
- ADB: `/Users/hanyi/Library/Android/sdk/platform-tools/adb`
- Android 包名: `com.clipflow.clipflow`
- macOS 产物: `build/macos/Build/Products/Release/ClipFlow.app`
- Android 产物: `build/app/outputs/flutter-apk/app-release.apk`
- Windows 产物: `build/windows/x64/runner/Release/`
