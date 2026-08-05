import Cocoa
import FlutterMacOS

/// macOS 图片剪切板原生实现（复用 clipflow/clipboard 通道）
///
/// - hasImage: 读取 NSPasteboard 是否包含图片
/// - getImage: 读取图片并统一归一为 PNG 字节 + 宽高
/// - setImage: 将 PNG/JPEG 字节写入 NSPasteboard
public class ImageClipboardPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "clipflow/clipboard",
      binaryMessenger: registrar.messenger
    )
    let instance = ImageClipboardPlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "hasImage":
      result(hasImage())
    case "getImage":
      result(getImageResult())
    case "setImage":
      guard
        let args = call.arguments as? [String: Any],
        let data = args["bytes"] as? FlutterStandardTypedData
      else {
        result(FlutterError(code: "BAD_ARGS", message: "bytes is required", details: nil))
        return
      }
      result(setImage(data.data))
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// 图片文件扩展名集合（Finder/微信/QQ 复制图片文件时的 file-url）。
  private static let imageFileExtensions: Set<String> = [
    "png", "jpg", "jpeg", "gif", "tiff", "tif", "bmp", "webp", "heic",
  ]

  /// 剪贴板是否包含图片（直接图片数据，或图片文件 URL）。
  ///
  /// 微信/QQ/Finder 复制图片**文件**时，剪贴板只有 `public.file-url` + 文本占位
  /// `"[文件]"`，`canReadObject(forClasses: [NSImage.self])` 返回 false；若不识别
  /// file-url，Dart 侧会落入文本分支把占位文本当内容上传。
  private func hasImage() -> Bool {
    let pasteboard = NSPasteboard.general
    if pasteboard.canReadObject(forClasses: [NSImage.self]) {
      return true
    }
    let urls = pasteboard.readObjects(
      forClasses: [NSURL.self],
      options: [NSPasteboard.ReadingOptionKey.urlReadingFileURLsOnly: true]
    ) as? [URL] ?? []
    return urls.contains { Self.imageFileExtensions.contains($0.pathExtension.lowercased()) }
  }

  private func getImageResult() -> [String: Any]? {
    let pasteboard = NSPasteboard.general
    // 1) 剪贴板直接携带图片数据：TIFF/PNG 等经 NSBitmapImageRep 归一为 PNG
    if let image = pasteboard.readObjects(forClasses: [NSImage.self], options: nil)?.first as? NSImage,
      let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) {
      return imageResult(png, rep)
    }
    // 2) 图片文件 URL（Finder/微信复制的文件路径）：读文件加载后同样归一
    guard
      let urls = pasteboard.readObjects(
        forClasses: [NSURL.self],
        options: [NSPasteboard.ReadingOptionKey.urlReadingFileURLsOnly: true]
      ) as? [URL],
      let first = urls.first,
      Self.imageFileExtensions.contains(first.pathExtension.lowercased()),
      let image = NSImage(contentsOf: first),
      let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:])
    else {
      return nil
    }
    return imageResult(png, rep)
  }

  private func imageResult(_ png: Data, _ rep: NSBitmapImageRep) -> [String: Any] {
    [
      "bytes": FlutterStandardTypedData(bytes: png),
      "format": "png",
      "width": rep.pixelsWide,
      "height": rep.pixelsHigh,
    ]
  }

  private func setImage(_ data: Data) -> Bool {
    guard
      let image = NSImage(data: data),
      let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:])
    else {
      return false
    }
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    return pasteboard.setData(png, forType: .png)
  }
}
