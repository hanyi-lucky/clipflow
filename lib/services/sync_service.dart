import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:uuid/uuid.dart';
import '../repositories/cloud_repository.dart';
import '../services/encryption_service.dart';
import '../core/hex_utils.dart';
import '../core/exceptions.dart';
import '../core/constants.dart';
import '../models/clipboard_entry.dart';
import '../models/sync_changes_page.dart';
import '../models/sync_operation.dart';

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
  // 文件元数据（D3：轮询只返回元数据，内容由 Provider 懒下载）
  final String? fileName;
  final int? fileSize;
  final String? mimeType;
  final String? fileHash;
  // durable cursor：成功应用后由 Provider 持久化（LocalStorage.syncCursor）
  final int? syncCursor;

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
    this.fileName,
    this.fileSize,
    this.mimeType,
    this.fileHash,
    this.syncCursor,
  });

  /// 创建一个只有同步数据的空结果（无新内容需要下载）
  factory DownloadResult.empty({
    List<String> deletedIds = const [],
    List<Map<String, dynamic>> restoredEntries = const [],
    int? syncCursor,
  }) {
    return DownloadResult(
      content: '',
      sourceDeviceId: '',
      sourceDeviceName: '',
      sourcePlatform: '',
      timestamp: DateTime.fromMillisecondsSinceEpoch(0),
      deletedIds: deletedIds,
      restoredEntries: restoredEntries,
      syncCursor: syncCursor,
    );
  }

  bool get hasContent => content.isNotEmpty || imageBytes != null;
  bool get hasFile => type == ContentType.file && (id?.isNotEmpty ?? false);
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

/// 文件上传结果：服务器历史 ID。
class FileUploadResult {
  final String historyId;

  const FileUploadResult({required this.historyId});
}

class PreparedSyncOperation {
  final SyncOperationKind kind;
  final String dedupeKey;
  final Map<String, dynamic> payload;

  const PreparedSyncOperation({
    required this.kind,
    required this.dedupeKey,
    required this.payload,
  });
}

class SyncService {
  final CloudRepository _repo;
  final EncryptionService _encryption;
  final String _deviceId;
  String _deviceName;
  final String _devicePlatform;
  final Uint8List _key;

  String _lastUploadedHash = '';
  DateTime? _lastReceivedTimestamp;
  int? _lastAppliedCursor;

  /// 每条目「删除周期计数」：恢复被观察到（本机/远端）后递增。
  /// 下一次 delete/restore 的 opId 追加周期后缀（`del:<id>#<n>`），保证
  /// 「删除→恢复→再删除」产生唯一 opId——服务端 UNIQUE 幂等不吞新事件、
  /// LAN `_knownOpIds` 去重不误杀第二次删除。
  final Map<String, int> _deleteCycleByEntry = {};

  String get deviceId => _deviceId;
  String get deviceName => _deviceName;
  String get devicePlatform => _devicePlatform;
  String get lastUploadedHash => _lastUploadedHash;
  DateTime? get lastReceivedTimestamp => _lastReceivedTimestamp;
  Uint8List get key => _key;

  /// 已成功应用的 durable cursor（内存态；持久化由 Provider 经 LocalStorage 负责）。
  int? get lastAppliedCursor => _lastAppliedCursor;

  /// 当前删除周期计数（0 = 首轮，opId 无后缀）。
  int deleteCycleFor(String entryId) => _deleteCycleByEntry[entryId] ?? 0;

  /// 记录一次「恢复已被观察到」（本机 outbox 成功 or Cloud/LAN 恢复帧），
  /// 使该条目下一次 delete/restore 使用唯一 opId（周期后缀）。
  void markRestoreObserved(String entryId) {
    _deleteCycleByEntry[entryId] = deleteCycleFor(entryId) + 1;
  }

  /// 应用成功后推进 cursor（与 markAsReceived 同纪律：成功才推进）。
  void setLastAppliedCursor(int? cursor) {
    _lastAppliedCursor = cursor;
  }

  /// 更新设备名（供重命名当前设备后使用）
  void updateDeviceName(String name) {
    _deviceName = name;
  }

  /// 解密内容（供外部加载历史记录时使用）
  Future<String> decryptContent(String encryptedBase64) async {
    final encryptedData = EncryptedData.fromBase64(encryptedBase64);
    return await _encryption.decrypt(encryptedData, _key);
  }

  /// 使用 isolate 解密文本密文并 utf8 解码，避免超长文本阻塞 UI。
  Future<String> decryptContentIsolate(String encryptedBase64) async {
    final bytes = await _encryption.decryptBytesIsolate(_key, encryptedBase64);
    return utf8.decode(bytes);
  }

  /// 标记内容为"已同步"，防止剪切板监听器重复上传刚下载的内容
  void markAsDownloaded(String content) {
    _lastUploadedHash = sha256.convert(utf8.encode(content)).toString();
  }

  /// 用外部稳定哈希标记"已同步"（图片哈希基于压缩后明文字节）
  void markAsDownloadedHash(String hash) {
    _lastUploadedHash = hash;
  }

  /// 用文件内容 SHA-256 标记"已同步"（独立 `file:` 域，与文本/图片隔离）。
  void markAsDownloadedFileHash(String hash) {
    _lastUploadedHash = 'file:$hash';
  }

  /// 文件内容哈希是否已在 `file:` 域中记录（避免重复上传）。
  bool isFileHashUploaded(String hash) => _lastUploadedHash == 'file:$hash';

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

  bool isContentHashUploaded(String hash) => _lastUploadedHash == hash;

  Future<PreparedSyncOperation?> prepareContent({
    required String content,
    required String operationId,
    DateTime? timestamp,
  }) async {
    final hash = sha256.convert(utf8.encode(content)).toString();
    if (hash == _lastUploadedHash) return null;
    final encrypted = await _encryption.encrypt(content, _key);
    final data = <String, dynamic>{
      'content': encrypted.toBase64(),
      'hash': hash,
      'sourceDevice': _deviceId,
      'sourceDeviceName': _deviceName,
      'sourcePlatform': _devicePlatform,
      'timestamp': (timestamp ?? DateTime.now()).millisecondsSinceEpoch,
      'type': 'text',
      'historyId': operationId,
    };
    return PreparedSyncOperation(
      kind: SyncOperationKind.text,
      dedupeKey: hash,
      payload: data,
    );
  }

  Future<PreparedSyncOperation?> prepareImage({
    required Uint8List bytes,
    required Uint8List thumbBytes,
    required int width,
    required int height,
    required String format,
    required String stableHash,
    required String operationId,
    DateTime? timestamp,
  }) async {
    if (stableHash == _lastUploadedHash) return null;
    final encrypted = await _encryption.encryptBytes(bytes, _key);
    final encryptedThumb = await _encryption.encryptBytes(thumbBytes, _key);
    final data = <String, dynamic>{
      'content': encrypted.toBase64(),
      'thumb': encryptedThumb.toBase64(),
      'hash': stableHash,
      'sourceDevice': _deviceId,
      'sourceDeviceName': _deviceName,
      'sourcePlatform': _devicePlatform,
      'timestamp': (timestamp ?? DateTime.now()).millisecondsSinceEpoch,
      'type': 'image',
      'width': width,
      'height': height,
      'format': format,
      'historyId': operationId,
    };
    return PreparedSyncOperation(
      kind: SyncOperationKind.image,
      dedupeKey: stableHash,
      payload: data,
    );
  }

  Future<PreparedSyncOperation?> prepareFile({
    required String plaintextHash,
    required String operationId,
    required String fileName,
    required int fileSize,
    required String mimeType,
    required int timestamp,
  }) async {
    if (isFileHashUploaded(plaintextHash)) return null;
    final marker = (await _encryption.encrypt('', _key)).toBase64();
    // 文件名随数据 key 加密（随机 IV）：LAN 报文只携带密文 encFileName，
    // 明文 fileName 绝不上 LAN；Cloud 侧仍走原有明文 file_name 元数据。
    final encFileName = (await _encryption.encrypt(fileName, _key)).toBase64();
    return PreparedSyncOperation(
      kind: SyncOperationKind.file,
      dedupeKey: 'file:$plaintextHash',
      payload: {
        'hash': plaintextHash,
        'fileName': fileName,
        'encFileName': encFileName,
        'fileSize': fileSize,
        'mimeType': mimeType,
        'marker': marker,
        'sourceDevice': _deviceId,
        'sourceDeviceName': _deviceName,
        'sourcePlatform': _devicePlatform,
        'timestamp': timestamp,
      },
    );
  }

  /// 准备删除操作：opId = `del:<entryId>`（恢复过则为 `del:<entryId>#<n>`），
  /// payload 只含来源元数据（LAN 红线：请求体绝不携带行数据/密码/token/salt/指纹/明文文件名）。
  PreparedSyncOperation prepareDelete(String entryId) {
    final cycle = deleteCycleFor(entryId);
    final suffix = cycle > 0 ? '#$cycle' : '';
    return PreparedSyncOperation(
      kind: SyncOperationKind.delete,
      dedupeKey: 'del:$entryId$suffix',
      payload: {
        'entryId': entryId,
        'sourceDevice': _deviceId,
        'sourceDeviceName': _deviceName,
        'sourcePlatform': _devicePlatform,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      },
    );
  }

  /// 准备恢复操作：opId = `rest:<entryId>`（再次删除过则为 `rest:<entryId>#<n>`）。
  PreparedSyncOperation prepareRestore(String entryId) {
    final cycle = deleteCycleFor(entryId);
    final suffix = cycle > 0 ? '#$cycle' : '';
    return PreparedSyncOperation(
      kind: SyncOperationKind.restore,
      dedupeKey: 'rest:$entryId$suffix',
      payload: {
        'entryId': entryId,
        'sourceDevice': _deviceId,
        'sourceDeviceName': _deviceName,
        'sourcePlatform': _devicePlatform,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      },
    );
  }

  void markUploadSucceeded(String dedupeKey) {
    _lastUploadedHash = dedupeKey;
  }

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

  /// 流式上传文件密文。headers 按蓝图走 `x-clipflow-*`；
  /// 成功后把 `file:<sha256>` 写入 `_lastUploadedHash` 域。
  Future<FileUploadResult?> uploadFile({
    required String encryptedPath,
    required String fileName,
    required int fileSize,
    required String mimeType,
    required String plaintextHash,
    required int timestamp,
  }) async {
    if (isFileHashUploaded(plaintextHash)) return null;

    final marker = (await _encryption.encrypt('', _key)).toBase64();
    final historyId = const Uuid().v4();

    await _repo.uploadFile(
      encryptedPath: encryptedPath,
      historyId: historyId,
      plaintextHash: plaintextHash,
      fileName: fileName,
      fileSize: fileSize,
      mimeType: mimeType,
      marker: marker,
      sourceDevice: _deviceId,
      sourceDeviceName: _deviceName,
      sourcePlatform: _devicePlatform,
      timestamp: timestamp,
    );
    _lastUploadedHash = 'file:$plaintextHash';
    return FileUploadResult(historyId: historyId);
  }

  Future<DownloadResult?> downloadLatestContent() async {
    return decodeCurrentClipboard(await _repo.getCurrentClipboardWithDeletions());
  }

  Future<DownloadResult?> decodeCurrentClipboard(
    Map<String, dynamic>? current, {
    SyncChangesPage? opsPage,
  }) async {
    // 提取 deletedIds 和 restoredEntries：
    // durable 模式（opsPage != null）把 op log 转成既有形状（restore row:null 跳过，
    // 快照已 GC 时由启动全量刷新收敛）；legacy 模式读取 /api/clipboard 的 30s 窗口字段。
    final deletedIds = <String>[];
    final restoredRaw = <Map<String, dynamic>>[];
    int? syncCursor;
    if (opsPage != null) {
      syncCursor = opsPage.cursor;
      for (final change in opsPage.changes) {
        if (change.isDelete) {
          deletedIds.add(change.entryId);
        } else if (change.isRestore) {
          final row = change.row;
          if (row != null) {
            restoredRaw.add(row);
          } else {
            debugPrint(
              '[SYNC] restore op row:null (snapshot GC), skip: ${change.entryId}',
            );
          }
        }
      }
    } else if (current != null) {
      deletedIds.addAll(
        (current['_deletedIds'] as List?)?.cast<String>() ?? const [],
      );
      restoredRaw.addAll(
        (current['_restoredEntries'] as List?)?.cast<Map<String, dynamic>>() ??
            const [],
      );
    }

    // 空剪切板边界：clipboard 为 null 但 ops 非空时返回 empty 结果（不能整体 null，
    // 否则空剪切板用户丢 tombstone）。即使 ops 全部被跳过（restore row:null），
    // 只要 op log 有变更就必须返回非空以推进 cursor，否则同一 op 会被无限重取。
    if (current == null) {
      if (opsPage == null) return null; // legacy NOT_FOUND：无 ops 通道
      if (opsPage.changes.isEmpty) return null; // 无变更：无需推进
      return DownloadResult.empty(
        deletedIds: deletedIds,
        restoredEntries: restoredRaw,
        syncCursor: syncCursor,
      );
    }

    final sourceDevice = current['source_device'] as String?;
    if (sourceDevice == _deviceId) {
      if (deletedIds.isEmpty && restoredRaw.isEmpty) return null;
      return DownloadResult.empty(
        deletedIds: deletedIds,
        restoredEntries: restoredRaw,
        syncCursor: syncCursor,
      );
    }

    final timestamp = DateTime.fromMillisecondsSinceEpoch(
      current['timestamp'] as int,
    );

    if (_lastReceivedTimestamp != null &&
        !timestamp.isAfter(_lastReceivedTimestamp!)) {
      if (deletedIds.isEmpty && restoredRaw.isEmpty) return null;
      return DownloadResult.empty(
        deletedIds: deletedIds,
        restoredEntries: restoredRaw,
        syncCursor: syncCursor,
      );
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
          syncCursor: syncCursor,
        );
      }

      if (type == 'file') {
        // D3：轮询热路径只返回元数据，文件内容走独立下载任务。
        // 文件名：LAN 行优先解密 enc_file_name（密文）；Cloud 行回退
        // 明文 file_name。enc_file_name 缺失/解密失败 → null（占位 'file'，
        // 历史 refresh 自然修正展示名）。
        String? fileName = current['file_name'] as String?;
        final encFileName = current['enc_file_name'] as String?;
        if (encFileName != null && encFileName.isNotEmpty) {
          try {
            fileName = await _encryption.decrypt(
              EncryptedData.fromBase64(encFileName),
              _key,
            );
          } catch (_) {
            // 解密失败保留 Cloud 回退值或 null
          }
        }
        return DownloadResult(
          content: '',
          sourceDeviceId: current['source_device'] as String? ?? 'unknown',
          sourceDeviceName: current['source_device_name'] as String? ?? 'Unknown',
          sourcePlatform: current['source_platform'] as String? ?? 'unknown',
          timestamp: timestamp,
          deletedIds: deletedIds,
          restoredEntries: restoredRaw,
          type: ContentType.file,
          id: current['history_id'] as String?,
          fileName: fileName,
          fileSize: current['file_size'] as int?,
          mimeType: current['mime_type'] as String?,
          fileHash: current['hash'] as String?,
          syncCursor: syncCursor,
        );
      }

      final content = await decryptContentIsolate(encryptedBase64);
      // 超长旧文本（v1.3 图片被当文本上传）与客户端统一 50000 上限，
      // 避免整段 2.6MB 明文在主 isolate 解密并渲染
      final cappedContent = content.length > AppConstants.maxContentLength
          ? content.substring(0, AppConstants.maxContentLength)
          : content;
      return DownloadResult(
        content: cappedContent,
        sourceDeviceId: current['source_device'] as String? ?? 'unknown',
        sourceDeviceName: current['source_device_name'] as String? ?? 'Unknown',
        sourcePlatform: current['source_platform'] as String? ?? 'unknown',
        timestamp: timestamp,
        deletedIds: deletedIds,
        restoredEntries: restoredRaw,
        id: current['history_id'] as String?,
        syncCursor: syncCursor,
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
