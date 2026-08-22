# 009 · Windows LAN 支持：Win32 DNS-SD 插件（Phase 2.5，三端补齐）

- 日期：2026-08-22
- 档位/组合：完整（2 explorer 并行 → architect → coder M1-M4 → 真机 M5 → 主代理排障+修复）

## 背景
- Windows 端无 LAN 插件（isSupported=false → Cloud-only）；需与 macOS/Android 对齐的 mDNS 广告+发现，使 Windows 加入 LAN 同步。
- `LanTransport.startServer` 先绑定随机 TLS 端口再 `advertise(port)`——插件必须广播 Dart 已绑定的端口。

## 决策
1. **API 定案：Win32 DNS-SD（`windns.h`/`dnsapi.lib`）**，否决 WinRT `Dnssd`——WinRT 注册以 socket 绑定端口为准，与 Dart 预绑定 TLS 端口冲突（唯一出路是反传端口改 Dart 流程，触「Dart lan_* 零改动」红线）；Win32 `DNS_SERVICE_INSTANCE.wPort` 直接广播 Dart 端口，零 Dart 改动。
2. 新增 `windows/runner/lan_network_plugin.h/.cpp`（手动注册仿 image_clipboard_plugin，不进 generated 注册表），实现 `clipflow/lan_network` 四方法 + `clipflow/lan_network_events` 事件流；DNS-SD 回调线程池 → PostMessage 主 HWND marshal 回平台线程，状态机单线程化。
3. **真机 Bug 修复**：`DnsServiceRegister` 在 `pszHostName`/`ip4Address` 为空时返回 status 14/87 注册失败（原生探测实证：browse 正常，register 需 host）→ 补机器主机名（GetComputerNameExW FQDN→NetBIOS）+ 首选 IPv4（GetAdaptersAddresses），CMake 链接 `iphlpapi.lib`。
4. 手动注册路径：`windows/runner/CMakeLists.txt` 源列表 + `flutter_window.cpp` OnCreate/OnDestroy 注册/注销 + MessageHandler marshal 分发。

## 后果
- Windows 三端 LAN 补齐：广告被 Mac/Android 可见、浏览发现对端、双向挑战握手、内容交付（真机实证：Mac dns-sd 见 Windows 实例、Windows 诊断发现=1/握手=1、Mac→Windows 交付成功）；TXT 白名单仅 proto/device/caps/port（零敏感字段实证）。
- Dart `lan_*`/constants、generated 插件文件、既有插件、macOS/Android/服务端零改动；红线零触碰。
- `isSupported` 门槛 Windows 10 build≥16299（RtlGetVersion）；低于门槛或注册失败静默 Cloud-only 兜底；Windows 防火墙首启可能拦 UDP 5353（环境问题，失败路径不阻塞）。
- 风险：`DNS_SERVICE_INSTANCE` 结构体布局随 SDK 版本变化（22621 实机确认）；`DnsServiceRegister` 依赖本机主机名/IP 枚举（多网卡以 IfOperStatusUp 过滤）。
- 全量 `flutter test` 523/523；`flutter analyze` 0 error。
