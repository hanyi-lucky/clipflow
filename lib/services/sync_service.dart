import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:uuid/uuid.dart';
import '../repositories/cloud_repository.dart';
import '../services/encryption_service.dart';
import '../core/hex_utils.dart';
import '../core/exceptions.dart';
import '../models/clipboard_entry.dart';

/// 包含从服务器下载的内容及其来源设备信息
class DownloadResult {
  final String content;
  final String sourceDeviceId;
  final String sourceDeviceName;
  final String sourcePlatform;
  final DateTime timestamp;
  final List<String> deletedIds;
  final List<Map<String, dynamic>> restoredEntries;
  final ContentType type;
  final Uint8List? imageBytes;
  final Uint8List? imageThumbBytes;
  final String? imageEncryptedBase64;
  final String? imageHash;
  final int? imageWidth;
  final int? imageHeight;
  final String? imageFormat;
  final String? id; // 服务器历史行 ID（图片下载条目对齐用，旧行为 null）

  const DownloadResult({
    required this.content,
    required this.sourceDeviceId,
    required this.sourceDeviceName,
    required this.sourcePlatform,
    required this.timestamp,
    this.deletedIds = const [],
    this.restoredEntries = const [],
    this.type = ContentType.text,
    this.imageBytes,
    this.imageThumbBytes,
    this.imageEncryptedBase64,
    this.imageHash,
    this.imageWidth,
    this.imageHeight,
    this.imageFormat,
    this.id,
  });

  /// 创建一个只有同步数据的空结果（无新内容需要下载）
  factory DownloadResult.empty({
    List<String> deletedIds = const [],
    List<Map<String, dynamic>> restoredEntries = const [],
  }) {
    return DownloadResult(
      content: '',
      sourceDeviceId: '',
      sourceDeviceName: '',
      sourcePlatform: '',
      timestamp: DateTime.fromMillisecondsSinceEpoch(0),
      deletedIds: deletedIds,
      restoredEntries: restoredEntries,
    );
  }

  bool get hasContent => content.isNotEmpty || imageBytes != null;
  bool get hasDeletions => deletedIds.isNotEmpty;
  bool get hasRestorations => restoredEntries.isNotEmpty;
}

/// 图片上传结果：服务器历史 ID + 全图/缩略图密文
class ImageUploadResult {
  final String historyId;
  final String encryptedBase64;
  final String encryptedThumbBase64;

  const ImageUploadResult({
    required this.historyId,
    required this.encryptedBase64,
    required this.encryptedThumbBase64,
  });
}

class SyncService {
  final CloudRepository _repo;
  final EncryptionService _encryption;
  final String _deviceId;
  final String _deviceName;
  final String _devicePlatform;
  final Uint8List _key;

  String _lastUploadedHash = '';
  DateTime? _lastReceivedTimestamp;

  String get deviceId => _deviceId;
  String get deviceName => _deviceName;
  String get lastUploadedHash => _lastUploadedHash;

  /// 解密内容（供外部加载历史记录时使用）
  Future<String> decryptContent(String encryptedBase64) async {
    final encryptedData = EncryptedData.fromBase64(encryptedBase64);
    return await _encryption.decrypt(encryptedData, _key);
  }

  /// 标记内容为"已同步"，防止剪切板监听器重复上传刚下载的内容
  void markAsDownloaded(String content) {
    _lastUploadedHash = sha256.convert(utf8.encode(content)).toString();
  }

  /// 用外部稳定哈希标记"已同步"（图片哈希基于压缩后明文字节）
  void markAsDownloadedHash(String hash) {
    _lastUploadedHash = hash;
  }

  /// 标记时间戳为"已接收"，防止重复下载同一条内容
  /// 必须在内容成功处理（写入历史+剪切板）后调用
  void markAsReceived(DateTime timestamp) {
    _lastReceivedTimestamp = timestamp;
  }

  SyncService({
    required CloudRepository repo,
    required EncryptionService encryption,
    required String deviceId,
    required String deviceName,
    required String devicePlatform,
    required Uint8List key,
  })  : _repo = repo,
        _encryption = encryption,
        _deviceId = deviceId,
        _deviceName = deviceName,
        _devicePlatform = devicePlatform,
        _key = key;

  /// 上传内容到服务器。返回服务器分配的历史记录 ID，null 表示跳过（重复内容）
  Future<String?> uploadContent(String content) async {
    final hash = sha256.convert(utf8.encode(content)).toString();
    if (hash == _lastUploadedHash) return null;

    final encrypted = await _encryption.encrypt(content, _key);
    final encryptedBase64 = encrypted.toBase64();
    final now = DateTime.now();
    final historyId = const Uuid().v4();

    final data = {
      'content': encryptedBase64,
      'hash': hash,
      'sourceDevice': _deviceId,
      'sourceDeviceName': _deviceName,
      'sourcePlatform': _devicePlatform,
      'timestamp': now.millisecondsSinceEpoch,
      'type': 'text',
      'historyId': historyId,
    };

    await _repo.setCurrentClipboard(data);
    await _repo.addHistoryEntry({
      ...data,
      'pinned': false,
    });
    // 上传成功后才标记，防止服务器报错后相同内容被永久跳过
    _lastUploadedHash = hash;
    return historyId;
  }

  /// 上传图片（压缩已由调用方完成）。
  ///
  /// 哈希基于压缩后明文字节（跨设备可复现去重）；
  /// 全图与缩略图各自独立加密。返回 null 表示重复内容跳过。
  Future<ImageUploadResult?> uploadImage({
    required Uint8List bytes,
    required Uint8List thumbBytes,
    required int width,
    required int height,
    required String format,
    required String stableHash,
  }) async {
    if (stableHash == _lastUploadedHash) return null;

    final encrypted = await _encryption.encryptBytes(bytes, _key);
    final encryptedThumb = await _encryption.encryptBytes(thumbBytes, _key);
    final encryptedBase64 = encrypted.toBase64();
    final encryptedThumbBase64 = encryptedThumb.toBase64();
    final now = DateTime.now();
    final historyId = const Uuid().v4();

    final data = {
      'content': encryptedBase64,
      'thumb': encryptedThumbBase64,
      'hash': stableHash,
      'sourceDevice': _deviceId,
      'sourceDeviceName': _deviceName,
      'sourcePlatform': _devicePlatform,
      'timestamp': now.millisecondsSinceEpoch,
      'type': 'image',
      'width': width,
      'height': height,
      'format': format,
      'historyId': historyId,
    };

    await _repo.setCurrentClipboard(data);
    await _repo.addHistoryEntry({
      ...data,
      'pinned': false,
    });
    // 上传成功后才标记，防止服务器报错后相同图片被永久跳过
    _lastUploadedHash = stableHash;
    return ImageUploadResult(
      historyId: historyId,
      encryptedBase64: encryptedBase64,
      encryptedThumbBase64: encryptedThumbBase64,
    );
  }

  Future<DownloadResult?> downloadLatestContent() async {
    final current = await _repo.getCurrentClipboardWithDeletions();
    if (current == null) return null;

    // 提取 deletedIds 和 restoredEntries（每次轮询都需要，不受内容过滤影响）
    final deletedIds = (current['_deletedIds'] as List?)?.cast<String>() ?? [];
    final restoredRaw = (current['_restoredEntries'] as List?)?.cast<Map<String, dynamic>>() ?? [];

    final sourceDevice = current['source_device'] as String?;
    if (sourceDevice == _deviceId) {
      if (deletedIds.isEmpty && restoredRaw.isEmpty) return null;
      return DownloadResult.empty(deletedIds: deletedIds, restoredEntries: restoredRaw);
    }

    final timestamp = DateTime.fromMillisecondsSinceEpoch(
      current['timestamp'] as int,
    );

    if (_lastReceivedTimestamp != null &&
        !timestamp.isAfter(_lastReceivedTimestamp!)) {
      if (deletedIds.isEmpty && restoredRaw.isEmpty) return null;
      return DownloadResult.empty(deletedIds: deletedIds, restoredEntries: restoredRaw);
    }

    try {
      final type = current['type'] as String? ?? 'text';
      final encryptedBase64 = current['content'] as String;

      if (type == 'image') {
        // 全图解密走 isolate，避免 500ms 同步循环阻塞 UI（缩略图体积小，保持主 isolate）
        final imageBytes =
            await _encryption.decryptBytesIsolate(_key, encryptedBase64);

        Uint8List? imageThumbBytes;
        final thumbBase64 = current['thumb'] as String?;
        if (thumbBase64 != null && thumbBase64.isNotEmpty) {
          final thumbData = EncryptedData.fromBase64(thumbBase64);
          imageThumbBytes = await _encryption.decryptBytes(thumbData, _key);
        }

        return DownloadResult(
          content: '',
          sourceDeviceId: current['source_device'] as String? ?? 'unknown',
          sourceDeviceName: current['source_device_name'] as String? ?? 'Unknown',
          sourcePlatform: current['source_platform'] as String? ?? 'unknown',
          timestamp: timestamp,
          deletedIds: deletedIds,
          restoredEntries: restoredRaw,
          type: ContentType.image,
          imageBytes: imageBytes,
          imageThumbBytes: imageThumbBytes,
          imageEncryptedBase64: encryptedBase64,
          imageHash: current['hash'] as String?,
          imageWidth: current['width'] as int?,
          imageHeight: current['height'] as int?,
          imageFormat: current['format'] as String?,
          id: current['history_id'] as String?,
        );
      }

      final encryptedData = EncryptedData.fromBase64(encryptedBase64);
      final content = await _encryption.decrypt(encryptedData, _key);
      return DownloadResult(
        content: content,
        sourceDeviceId: current['source_device'] as String? ?? 'unknown',
        sourceDeviceName: current['source_device_name'] as String? ?? 'Unknown',
        sourcePlatform: current['source_platform'] as String? ?? 'unknown',
        timestamp: timestamp,
        deletedIds: deletedIds,
        restoredEntries: restoredRaw,
      );
    } catch (e) {
      throw DecryptionException('Failed to decrypt content: $e');
    }
  }

  /// 解密全图密文为字节（供查看器使用）
  Future<Uint8List> decryptImage(String encryptedBase64) async {
    final data = EncryptedData.fromBase64(encryptedBase64);
    return await _encryption.decryptBytes(data, _key);
  }

  /// 使用 isolate 解密全图密文（供查看器大图加载，不阻塞 UI）
  Future<Uint8List> decryptImageIsolate(String encryptedBase64) async {
    return await _encryption.decryptBytesIsolate(_key, encryptedBase64);
  }

  Future<String?> getSalt() => _repo.getSalt();

  Future<void> saveSaltHex(List<int> salt) async {
    await _repo.setSalt(bytesToHex(salt));
  }

  List<int>? parseSaltHex(String? hex) {
    if (hex == null || hex.isEmpty) return null;
    return hexToBytes(hex);
  }
}
