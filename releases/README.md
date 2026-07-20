# ClipFlow 安装包

## 目录结构

```
releases/
├── macos/      # macOS DMG 安装包
├── windows/    # Windows 构建产物（clipflow.exe + 依赖）
├── android/    # Android APK 安装包
└── ios/        # iOS/iPadOS（快捷指令 + Web App）
```

## 各平台打包命令

```bash
# macOS
flutter build macos --release
# DMG 打包
hdiutil create -volname "ClipFlow" \
  -srcfolder build/macos/Build/Products/Release/ClipFlow.app \
  -ov -format UDZO releases/macos/ClipFlow.dmg

# Android
flutter build apk --release
cp build/app/outputs/flutter-apk/app-release.apk releases/android/ClipFlow.apk

# Windows
flutter build windows --release
cp -r build/windows/x64/runner/Release/* releases/windows/
```

## 最新版本

| 平台 | 版本 | 日期 | 文件 |
|-----|------|------|------|
| macOS | v1.1.0 | 2026-06-26 | `macos/ClipFlow.dmg` |
| Android | v1.3.0 | 2026-07-05 | `android/ClipFlow.apk` |
| Windows | v1.0.0 | 2026-07-21 | `windows/clipflow.exe` |
