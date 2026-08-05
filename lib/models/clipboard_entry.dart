import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';

enum ContentType {
  text,
  image,
  file,
}

class ClipboardEntry {
  final String id;
  final String content;
  final String sourceDeviceId;
  final String sourceDeviceName;
  final String sourcePlatform;
  final DateTime timestamp;
  final ContentType type;
  final bool isPinned;
  // 图片字段
  final Uint8List? imageThumbBytes; // 解密缩略图（仅内存，不序列化）
  final String? imageThumbEncryptedBase64; // 缩略图密文（序列化到本地历史 JSON）
  final String? imageEncryptedBase64; // 全图密文（仅瞬时传递，不序列化）
  final int? imageWidth;
  final int? imageHeight;
  final String? imageFormat;
  final String? stableHash; // 图片压缩后明文字节哈希，文本为 null

  const ClipboardEntry({
    required this.id,
    required this.content,
    required this.sourceDeviceId,
    required this.sourceDeviceName,
    this.sourcePlatform = 'unknown',
    required this.timestamp,
    required this.type,
    this.isPinned = false,
    this.imageThumbBytes,
    this.imageThumbEncryptedBase64,
    this.imageEncryptedBase64,
    this.imageWidth,
    this.imageHeight,
    this.imageFormat,
    this.stableHash,
  });

  String get contentHash =>
      stableHash ?? sha256.convert(utf8.encode(content)).toString();

  ClipboardEntry copyWith({
    String? id,
    String? content,
    String? sourceDeviceId,
    String? sourceDeviceName,
    String? sourcePlatform,
    DateTime? timestamp,
    ContentType? type,
    bool? isPinned,
    Uint8List? imageThumbBytes,
    String? imageThumbEncryptedBase64,
    String? imageEncryptedBase64,
    int? imageWidth,
    int? imageHeight,
    String? imageFormat,
    String? stableHash,
  }) {
    return ClipboardEntry(
      id: id ?? this.id,
      content: content ?? this.content,
      sourceDeviceId: sourceDeviceId ?? this.sourceDeviceId,
      sourceDeviceName: sourceDeviceName ?? this.sourceDeviceName,
      sourcePlatform: sourcePlatform ?? this.sourcePlatform,
      timestamp: timestamp ?? this.timestamp,
      type: type ?? this.type,
      isPinned: isPinned ?? this.isPinned,
      imageThumbBytes: imageThumbBytes ?? this.imageThumbBytes,
      imageThumbEncryptedBase64:
          imageThumbEncryptedBase64 ?? this.imageThumbEncryptedBase64,
      imageEncryptedBase64: imageEncryptedBase64 ?? this.imageEncryptedBase64,
      imageWidth: imageWidth ?? this.imageWidth,
      imageHeight: imageHeight ?? this.imageHeight,
      imageFormat: imageFormat ?? this.imageFormat,
      stableHash: stableHash ?? this.stableHash,
    );
  }

  Map<String, dynamic> toMap() => {
    'id': id,
    'content': content,
    'sourceDeviceId': sourceDeviceId,
    'sourceDeviceName': sourceDeviceName,
    'sourcePlatform': sourcePlatform,
    'timestamp': timestamp.toIso8601String(),
    'type': type.name,
    'isPinned': isPinned,
    if (imageThumbEncryptedBase64 != null) 'imageThumb': imageThumbEncryptedBase64,
    if (imageWidth != null) 'imageWidth': imageWidth,
    if (imageHeight != null) 'imageHeight': imageHeight,
    if (imageFormat != null) 'imageFormat': imageFormat,
    if (stableHash != null) 'hash': stableHash,
  };

  factory ClipboardEntry.fromMap(Map<String, dynamic> map) {
    return ClipboardEntry(
      id: map['id'] as String,
      content: map['content'] as String,
      sourceDeviceId: map['sourceDeviceId'] as String,
      sourceDeviceName: map['sourceDeviceName'] as String,
      sourcePlatform: map['sourcePlatform'] as String? ?? 'unknown',
      timestamp: DateTime.parse(map['timestamp'] as String),
      type: ContentType.values.firstWhere((e) => e.name == map['type']),
      isPinned: map['isPinned'] as bool? ?? false,
      imageThumbEncryptedBase64: map['imageThumb'] as String?,
      imageWidth: map['imageWidth'] as int?,
      imageHeight: map['imageHeight'] as int?,
      imageFormat: map['imageFormat'] as String?,
      stableHash: map['hash'] as String?,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ClipboardEntry && id == other.id;

  @override
  int get hashCode => id.hashCode;
}
