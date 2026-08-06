/// 密文备份清单（.clipflow-backup.json）。
///
/// 版本化 schema：条目密文保持 EncryptedData 兼容（text/image = EncryptedData
/// base64；file = marker base64 + 原始文件密文字节 base64），**不含任何明文**。
class BackupManifest {
  static const String kFormat = 'clipflow-backup';
  static const int kVersion = 1;

  final DateTime exportedAt;
  final String sourceDevice;
  final String saltHex;
  final List<BackupEntry> entries;

  String get format => kFormat;
  int get version => kVersion;

  BackupManifest({
    required this.exportedAt,
    required this.sourceDevice,
    required this.saltHex,
    required this.entries,
  });

  Map<String, dynamic> toJson() => {
        'format': kFormat,
        'version': kVersion,
        'exportedAt': exportedAt.toIso8601String(),
        'sourceDevice': sourceDevice,
        'account': {'saltHex': saltHex},
        'entries': entries.map((e) => e.toJson()).toList(),
      };

  /// 解析并校验备份文件；format/version 不合法抛 [FormatException]。
  factory BackupManifest.fromJson(Map<String, dynamic> json) {
    if (json['format'] != kFormat) {
      throw FormatException('不是有效的 ClipFlow 备份文件（format 不匹配）');
    }
    if (json['version'] != kVersion) {
      throw FormatException('不支持的备份版本: ${json['version']}');
    }
    final account = json['account'] as Map<String, dynamic>? ?? const {};
    final rawEntries = json['entries'] as List? ?? const [];
    return BackupManifest(
      exportedAt:
          DateTime.tryParse(json['exportedAt'] as String? ?? '') ?? DateTime.now(),
      sourceDevice: json['sourceDevice'] as String? ?? '',
      saltHex: account['saltHex'] as String? ?? '',
      entries: rawEntries
          .map((e) => BackupEntry.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }

  /// 估算 JSON 文件体积（密文 base64 + 元数据开销），用于导出前的大体积警告。
  int estimateBytes() {
    var total = 0;
    for (final e in entries) {
      total += e.content.length;
      total += e.thumb?.length ?? 0;
      total += e.fileCiphertextBase64?.length ?? 0;
      total += 256; // 每条目的元数据与 JSON 结构开销
    }
    return total;
  }
}

/// 单条备份条目。type ∈ text / image / file；字段与服务器历史行对齐。
class BackupEntry {
  final String id;
  final String type;
  final int timestamp;
  final String sourceDeviceId;
  final String sourceDeviceName;
  final String sourcePlatform;
  final bool pinned;
  /// EncryptedData base64（text/image 全量密文；file 为 marker）。
  final String content;
  // 图片
  final String? thumb;
  final int? width;
  final int? height;
  final String? format;
  final String? stableHash;
  // 文件
  final String? fileName;
  final int? fileSize;
  final String? mimeType;
  final String? fileHash;
  /// 文件密文原始字节 base64（服务端存的 EncryptedData 字节序）。
  final String? fileCiphertextBase64;

  const BackupEntry({
    required this.id,
    required this.type,
    required this.timestamp,
    required this.sourceDeviceId,
    required this.sourceDeviceName,
    this.sourcePlatform = 'unknown',
    this.pinned = false,
    required this.content,
    this.thumb,
    this.width,
    this.height,
    this.format,
    this.stableHash,
    this.fileName,
    this.fileSize,
    this.mimeType,
    this.fileHash,
    this.fileCiphertextBase64,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type,
        'timestamp': timestamp,
        'sourceDeviceId': sourceDeviceId,
        'sourceDeviceName': sourceDeviceName,
        'sourcePlatform': sourcePlatform,
        'pinned': pinned,
        'content': content,
        if (thumb != null) 'thumb': thumb,
        if (width != null) 'width': width,
        if (height != null) 'height': height,
        if (format != null) 'format': format,
        if (stableHash != null) 'stableHash': stableHash,
        if (fileName != null) 'fileName': fileName,
        if (fileSize != null) 'fileSize': fileSize,
        if (mimeType != null) 'mimeType': mimeType,
        if (fileHash != null) 'fileHash': fileHash,
        if (fileCiphertextBase64 != null)
          'fileCiphertextBase64': fileCiphertextBase64,
      };

  factory BackupEntry.fromJson(Map<String, dynamic> json) {
    return BackupEntry(
      id: json['id'] as String? ?? '',
      type: json['type'] as String? ?? 'text',
      timestamp: (json['timestamp'] as num?)?.toInt() ?? 0,
      sourceDeviceId: json['sourceDeviceId'] as String? ?? '',
      sourceDeviceName: json['sourceDeviceName'] as String? ?? '',
      sourcePlatform: json['sourcePlatform'] as String? ?? 'unknown',
      pinned: json['pinned'] as bool? ?? false,
      content: json['content'] as String? ?? '',
      thumb: json['thumb'] as String?,
      width: (json['width'] as num?)?.toInt(),
      height: (json['height'] as num?)?.toInt(),
      format: json['format'] as String?,
      stableHash: json['stableHash'] as String?,
      fileName: json['fileName'] as String?,
      fileSize: (json['fileSize'] as num?)?.toInt(),
      mimeType: json['mimeType'] as String?,
      fileHash: json['fileHash'] as String?,
      fileCiphertextBase64: json['fileCiphertextBase64'] as String?,
    );
  }
}
