import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {

  override func applicationDidFinishLaunching(_ notification: Notification) {
    // 注册图片剪切板原生插件（必须放在 super 之前，super 之后的代码不会执行）
    registerImagePlugin()
    // 注册 LAN 网络原生插件（mDNS 广告/浏览）
    registerLanNetworkPlugin()
    super.applicationDidFinishLaunching(notification)
  }

  /// 注册 LAN 网络原生插件：与 ImageClipboardPlugin 同款多级兜底获取 FlutterViewController。
  private func registerLanNetworkPlugin() {
    if let controller = mainFlutterWindow?.contentViewController as? FlutterViewController {
      doRegisterLan(controller)
      return
    }
    for window in NSApp.windows {
      if let controller = window.contentViewController as? FlutterViewController {
        doRegisterLan(controller)
        return
      }
    }
  }

  private func doRegisterLan(_ controller: FlutterViewController) {
    LanNetworkPlugin().register(with: controller.engine.binaryMessenger)
  }

  /// 注册图片剪切板原生插件：直接绑定 engine 的 binaryMessenger，
  /// 多级兜底获取 FlutterViewController，确保 Dart 首次调用前注册完成。
  private func registerImagePlugin() {
    // ① mainFlutterWindow?.contentViewController
    if let controller = mainFlutterWindow?.contentViewController as? FlutterViewController {
      doRegister(controller)
      return
    }

    // ② NSApp.windows 中第一个 FlutterViewController
    for window in NSApp.windows {
      if let controller = window.contentViewController as? FlutterViewController {
        doRegister(controller)
        return
      }
    }
  }

  private func doRegister(_ controller: FlutterViewController) {
    let channel = FlutterMethodChannel(
      name: "clipflow/clipboard",
      binaryMessenger: controller.engine.binaryMessenger
    )
    let plugin = ImageClipboardPlugin()
    channel.setMethodCallHandler { call, result in
      plugin.handle(call, result: result)
    }
  }

  // 点击 Dock 图标时重新显示窗口
  override func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    if !flag {
      mainFlutterWindow?.makeKeyAndOrderFront(nil)
    }
    return true
  }

  // 关闭最后一个窗口时不退出，退到后台
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
