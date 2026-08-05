import Cocoa
import FlutterMacOS

/// macOS 图片剪切板原生实现（复用 clipflow/clipboard 通道）
///
/// - hasImage: 读取 NSPasteboard 是否包含图片
/// - getImage: 读取图片并统一归一为 PNG 字节 + 宽高
/// - setImage: 将 PNG/JPEG 字节写入 NSPasteboard
/// - hasFiles/getFiles/setFiles: 文件剪贴板元数据通道（检测顺序：图片之后）
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
    case "hasFiles":
      result(hasFiles())
    case "getFiles":
      result(getFilesResult())
    case "setFiles":
      guard let paths = parseStringList(call.arguments) else {
        result(false)
        return
      }
      result(setFiles(paths))
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
    // Finder 复制 PDF/DOCX 等普通文件时，剪贴板同时带文件 URL 和文件图标缩略图
    // （NSImage 可读）。此时必须优先走文件分支，不能把图标当图片上传。
    let urls = pasteboard.readObjects(
      forClasses: [NSURL.self],
      options: [NSPasteboard.ReadingOptionKey.urlReadingFileURLsOnly: true]
    ) as? [URL] ?? []
    let hasNonImageFile = urls.contains {
      !Self.imageFileExtensions.contains($0.pathExtension.lowercased())
    }
    if hasNonImageFile {
      return false
    }
    if pasteboard.canReadObject(forClasses: [NSImage.self]) {
      return true
    }
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

  /// 解析 Dart 传入的 List<String>（兼容带 "paths" 键的 Map）。
  private func parseStringList(_ arguments: Any?) -> [String]? {
    if let list = arguments as? [String] {
      return list
    }
    if let map = arguments as? [String: Any], let list = map["paths"] as? [String] {
      return list
    }
    return nil
  }

  /// 剪贴板是否包含非图片文件 URL。
  private func hasFiles() -> Bool {
    let pasteboard = NSPasteboard.general
    let urls = pasteboard.readObjects(
      forClasses: [NSURL.self],
      options: [NSPasteboard.ReadingOptionKey.urlReadingFileURLsOnly: true]
    ) as? [URL] ?? []
    return urls.contains { !Self.imageFileExtensions.contains($0.pathExtension.lowercased()) }
  }

  /// 返回剪贴板全部文件 URL 的元数据；单项读取失败带 errorCode，不抛异常。
  private func getFilesResult() -> [[String: Any]] {
    let pasteboard = NSPasteboard.general
    let urls = pasteboard.readObjects(
      forClasses: [NSURL.self],
      options: [NSPasteboard.ReadingOptionKey.urlReadingFileURLsOnly: true]
    ) as? [URL] ?? []
    return urls.compactMap { url in
      guard !Self.imageFileExtensions.contains(url.pathExtension.lowercased()) else {
        return nil
      }
      var metadata = fileMetadata(url)
      metadata["temp"] = false
      return metadata
    }
  }

  /// 单文件元数据：path/name/mimeType/size/lastModified；属性读取失败时保留
  /// path/name 并追加 errorCode，调用方不会收到未捕获异常。
  private func fileMetadata(_ url: URL) -> [String: Any] {
    var metadata: [String: Any] = [
      "path": url.path,
      "name": url.lastPathComponent,
      "mimeType": mimeType(forExtension: url.pathExtension),
      "temp": false,
    ]
    do {
      let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
      if let size = attributes[.size] as? NSNumber {
        metadata["size"] = size.int64Value
      }
      if let modified = attributes[.modificationDate] as? Date {
        metadata["lastModified"] = Int64(modified.timeIntervalSince1970 * 1000)
      }
    } catch {
      metadata["errorCode"] = "READ_ERROR"
    }
    return metadata
  }

  /// 扩展名到 MIME 的 best-effort 映射，缺失回退 octet-stream。
  private func mimeType(forExtension ext: String) -> String {
    let ext = ext.lowercased()
    let table: [String: String] = [
      "txt": "text/plain", "md": "text/markdown", "csv": "text/csv",
      "json": "application/json", "xml": "application/xml", "pdf": "application/pdf",
      "zip": "application/zip", "gz": "application/gzip", "tar": "application/x-tar",
      "7z": "application/x-7z-compressed", "rar": "application/vnd.rar",
      "doc": "application/msword",
      "docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
      "xls": "application/vnd.ms-excel",
      "xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
      "ppt": "application/vnd.ms-powerpoint",
      "pptx": "application/vnd.openxmlformats-officedocument.presentationml.presentation",
      "mp3": "audio/mpeg", "wav": "audio/wav", "flac": "audio/flac",
      "mp4": "video/mp4", "mov": "video/quicktime", "mkv": "video/x-matroska",
      "webm": "video/webm", "dart": "text/x-dart", "swift": "text/x-swift",
      "kt": "text/x-kotlin", "cpp": "text/x-c", "h": "text/x-c", "py": "text/x-python",
      "js": "text/javascript", "ts": "text/typescript", "html": "text/html",
      "css": "text/css",
    ]
    return table[ext] ?? "application/octet-stream"
  }

  /// 将一组路径写回系统剪贴板为 file-url。
  private func setFiles(_ paths: [String]) -> Bool {
    let urls = paths.compactMap { URL(fileURLWithPath: $0) }
    guard !urls.isEmpty else {
      return false
    }
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    return pasteboard.writeObjects(urls as [NSURL])
  }
}
