import Cocoa
import FlutterMacOS

/// LAN 网络原生插件（macOS）：NSNetService 广告 + NSNetServiceBrowser 浏览。
///
/// MethodChannel `clipflow/lan_network`：advertise / browse / stopAll / isSupported
/// EventChannel `clipflow/lan_network_events`：发现结果 `{name, host, port, txt}`
///
/// TXT 记录白名单：proto / port / device / caps。
/// 禁止广播：userId 及任何派生形态、密码、token、K_lan、salt、证书指纹、文件名、明文。
class LanNetworkPlugin: NSObject {
  private var netService: NetService?
  private var browser: NetServiceBrowser?
  private var eventSink: FlutterEventSink?
  private var resolvingServices: [NetService] = []

  func register(with messenger: FlutterBinaryMessenger) {
    let methodChannel = FlutterMethodChannel(
      name: "clipflow/lan_network",
      binaryMessenger: messenger
    )
    methodChannel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }

    let eventChannel = FlutterEventChannel(
      name: "clipflow/lan_network_events",
      binaryMessenger: messenger
    )
    eventChannel.setStreamHandler(self)
  }
}

extension LanNetworkPlugin: FlutterStreamHandler {
  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    eventSink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }
}

extension LanNetworkPlugin {
  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "isSupported":
      result(true)
    case "advertise":
      guard let args = call.arguments as? [String: Any],
            let deviceId = args["deviceId"] as? String,
            let port = args["port"] as? Int else {
        result(FlutterError(code: "badArgs", message: "deviceId/port required", details: nil))
        return
      }
      let caps = args["caps"] as? String ?? "t"
      advertise(deviceId: deviceId, caps: caps, port: port, result: result)
    case "browse":
      browse(result: result)
    case "stopAll":
      stopAll()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func advertise(deviceId: String, caps: String, port: Int, result: @escaping FlutterResult) {
    netService?.stop()
    let service = NetService(domain: "local.", type: "_clipflow._tcp", name: deviceId, port: Int32(port))
    service.setTXTRecord(NetService.data(fromTXTRecord: [
      "proto": Data("1".utf8),
      "port": Data("\(port)".utf8),
      "device": Data(deviceId.utf8),
      "caps": Data(caps.utf8),
    ]))
    service.delegate = self
    service.publish()
    netService = service
    result(nil)
  }

  private func browse(result: @escaping FlutterResult) {
    browser?.stop()
    let browser = NetServiceBrowser()
    browser.delegate = self
    browser.searchForServices(ofType: "_clipflow._tcp", inDomain: "local.")
    self.browser = browser
    result(nil)
  }

  private func stopAll() {
    netService?.stop()
    netService = nil
    browser?.stop()
    browser = nil
    resolvingServices.removeAll()
  }
}

extension LanNetworkPlugin: NetServiceDelegate, NetServiceBrowserDelegate {
  func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
    service.delegate = self
    service.resolve(withTimeout: 5)
    if !resolvingServices.contains(where: { $0 === service }) {
      resolvingServices.append(service)
    }
  }

  func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
    // 广告失败（如名称冲突）仅日志；Dart 侧 discovery 兜底走 Cloud，不阻塞主流程
    NSLog("LanNetworkPlugin: didNotPublish %@", errorDict)
  }

  func netServiceDidResolveAddress(_ service: NetService) {
    var host = service.hostName ?? ""
    if host.isEmpty, let address = service.addresses?.first {
      host = Self.ipAddress(from: address) ?? ""
    }
    var proto = ""
    var device = ""
    var caps = ""
    if let data = service.txtRecordData() {
      let txt = NetService.dictionary(fromTXTRecord: data)
      proto = String(data: txt["proto"] ?? Data(), encoding: .utf8) ?? ""
      device = String(data: txt["device"] ?? Data(), encoding: .utf8) ?? ""
      caps = String(data: txt["caps"] ?? Data(), encoding: .utf8) ?? ""
    }
    let event: [String: Any] = [
      "name": service.name,
      "host": host,
      "port": Int(service.port),
      "txt": ["proto": proto, "device": device, "caps": caps],
    ]
    eventSink?(event)
  }

  /// 从 sockaddr 二进制提取数字 IP（hostName 为空时的兜底）。
  static func ipAddress(from data: Data) -> String? {
    var hostBytes = [CChar](repeating: 0, count: Int(NI_MAXHOST))
    return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> String? in
      guard let base = raw.baseAddress else { return nil }
      let sa = base.assumingMemoryBound(to: sockaddr.self)
      let rc = getnameinfo(sa, socklen_t(raw.count), &hostBytes, socklen_t(hostBytes.count), nil, 0, NI_NUMERICHOST)
      return rc == 0 ? String(cString: hostBytes) : nil
    }
  }
}
