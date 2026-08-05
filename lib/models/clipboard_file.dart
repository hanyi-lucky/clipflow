/// 原生剪切板文件元数据（D1 契约）。
///
/// 字节不经过 MethodChannel，只传路径/名称/MIME/大小等元数据；
/// 缺失字段安全降级，`errorCode` 用于表达超限/读取失败。
class ClipboardFile {
  final String? path;
  final String? name;
  final String? mimeType;
  final int? size;
  final int? lastModified;
  final bool temp;
  final String? errorCode;

  const ClipboardFile({
    this.path,
    this.name,
    this.mimeType,
    this.size,
    this.lastModified,
    this.temp = false,
    this.errorCode,
  });

  factory ClipboardFile.fromMap(Map<String, dynamic> map) {
    final rawSize = map['size'];
    final rawLastModified = map['lastModified'];
    return ClipboardFile(
      path: map['path'] is String ? map['path'] as String : null,
      name: map['name'] is String ? map['name'] as String : null,
      mimeType: map['mimeType'] is String
          ? map['mimeType'] as String
          : null,
      size: rawSize is num ? rawSize.toInt() : null,
      lastModified: rawLastModified is num ? rawLastModified.toInt() : null,
      temp: map['temp'] is bool ? map['temp'] as bool : false,
      errorCode: map['errorCode'] is String
          ? map['errorCode'] as String
          : null,
    );
  }
}
