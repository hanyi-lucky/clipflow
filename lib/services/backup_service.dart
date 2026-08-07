import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import '../core/constants.dart';
import '../core/exceptions.dart';
import '../core/hex_utils.dart';
import '../core/user_id.dart';
import '../models/backup_manifest.dart';
import '../models/clipboard_entry.dart';
import '../repositories/cloud_repository.dart';
import '../repositories/local_file_store.dart';
import '../repositories/local_image_store.dart';
import '../repositories/local_storage.dart';
import '../services/encryption_service.dart';
import '../services/history_service.dart';
import '../l10n/app_strings.dart';

/// 密文备份导出 / 迁移码导入。
///
/// 导出：服务端历史列表为权威清单，条目密文「本地缓存优先 + 服务端 /content
/// 与文件流兜底」；全部保持 EncryptedData 兼容，零明文。
/// 导入：旧密钥（旧密码 + 备份 salt）解密 → 当前会话密钥重加密 → 复用
/// POST /clipboard 与 POST /file 上传，保留原始 historyId/timestamp。
class BackupService {
  final CloudRepository cloudRepo;
  final LocalStorage storage;
  final LocalImageStore imageStore;
  final LocalFileStore fileStore;
  final HistoryService historyService;
  final EncryptionService encryption;

  BackupService({
    required this.cloudRepo,
    required this.storage,
    required this.imageStore,
    required this.fileStore,
    required this.historyService,
    required this.encryption,
  });

  /// 构建导出清单。数据源：服务端 `GET /api/history?limit=100` 权威 +
  /// 本地缓存优先 + 服务端兜底；salt 取本地，缺失时服务端 /api/salt 兜底。
  Future<BackupManifest> buildExport({
    required String deviceName,
    required Uint8List encryptionKey,
    void Function(double progress, String label)? onProgress,
  }) async {
    final records = await cloudRepo.getHistoryEntries(limit: 100);
    final saltHex = storage.encryptionSalt ?? await cloudRepo.getSalt() ?? '';

    final entries = <BackupEntry>[];
    for (var i = 0; i < records.length; i++) {
      final record = records[i];
      onProgress?.call(
        records.isEmpty ? 1.0 : i / records.length,
        AppStrings.backupExporting(i + 1, records.length),
      );
      final entry = await _buildBackupEntry(record, encryptionKey);
      if (entry != null) entries.add(entry);
    }
    onProgress?.call(1.0, AppStrings.backupExportDone);

    return BackupManifest(
      exportedAt: DateTime.now(),
      sourceDevice: deviceName,
      saltHex: saltHex,
      entries: entries,
    );
  }

  Future<BackupEntry?> _buildBackupEntry(
    Map<String, dynamic> record,
    Uint8List key,
  ) async {
    final id = record['id'] as String? ?? '';
    if (id.isEmpty) return null;
    final type = record['type'] as String? ?? 'text';
    final timestamp = (record['timestamp'] as num?)?.toInt() ?? 0;
    final pinned = (record['pinned'] as int?) == 1;
    final sourceDeviceId = record['source_device'] as String? ?? 'unknown';
    final sourceDeviceName = record['source_device_name'] as String? ?? 'Unknown';
    final sourcePlatform = record['source_platform'] as String? ?? 'unknown';

    if (type == ContentType.image.name) {
      var content = await imageStore.load(id);
      if (content == null || content.isEmpty) {
        content = await _fetchServerContent(id);
      }
      if (content == null || content.isEmpty) return null;
      return BackupEntry(
        id: id,
        type: type,
        timestamp: timestamp,
        sourceDeviceId: sourceDeviceId,
        sourceDeviceName: sourceDeviceName,
        sourcePlatform: sourcePlatform,
        pinned: pinned,
        content: content,
        thumb: record['thumb'] as String?,
        width: (record['width'] as num?)?.toInt(),
        height: (record['height'] as num?)?.toInt(),
        format: record['format'] as String?,
        stableHash: record['hash'] as String?,
      );
    }

    if (type == ContentType.file.name) {
      // marker：服务端 /content 返回标记密文，兜底重新加密空串（事实格式同 sync_service）
      var marker = await _fetchServerContent(id);
      marker ??= (await encryption.encrypt('', key)).toBase64();

      // 文件密文字节：本地 .enc 缓存优先 → 服务端文件流兜底
      String? cipherB64;
      final localPath = await fileStore.loadEncryptedPath(id);
      if (localPath != null) {
        final bytes = await File(localPath).readAsBytes();
        cipherB64 = base64Encode(bytes);
      } else {
        final response = await cloudRepo.downloadFile(id);
        if (response.statusCode == 200) {
          final builder = BytesBuilder(copy: false);
          await response.stream.forEach(builder.add);
          cipherB64 = base64Encode(builder.takeBytes());
        }
      }
      if (cipherB64 == null || cipherB64.isEmpty) return null;
      return BackupEntry(
        id: id,
        type: type,
        timestamp: timestamp,
        sourceDeviceId: sourceDeviceId,
        sourceDeviceName: sourceDeviceName,
        sourcePlatform: sourcePlatform,
        pinned: pinned,
        content: marker,
        fileName: record['file_name'] as String?,
        fileSize: (record['file_size'] as num?)?.toInt(),
        mimeType: record['mime_type'] as String?,
        fileHash: record['hash'] as String?,
        fileCiphertextBase64: cipherB64,
      );
    }

    // 文本：本地明文长度 < 截断上限（50000）→ 本地重加密；达到上限（疑似
    // v1.3 遗留被截断的超长文本）优先走服务端 /content 全量密文，保证备份
    // 不丢数据；服务端缺失时回退本地明文（可能被截断，但优于丢弃条目）。
    String? content;
    final localPlain = _findLocalTextPlain(id);
    final useLocal = localPlain != null &&
        localPlain.isNotEmpty &&
        localPlain.length < AppConstants.maxContentLength;
    if (useLocal) {
      content = (await encryption.encrypt(localPlain, key)).toBase64();
    } else {
      final fetched = await _fetchServerContent(id);
      if (fetched != null && fetched.isNotEmpty) {
        content = fetched;
      } else if (localPlain != null && localPlain.isNotEmpty) {
        content = (await encryption.encrypt(localPlain, key)).toBase64();
      }
    }
    if (content == null || content.isEmpty) return null;
    return BackupEntry(
      id: id,
      type: type,
      timestamp: timestamp,
      sourceDeviceId: sourceDeviceId,
      sourceDeviceName: sourceDeviceName,
      sourcePlatform: sourcePlatform,
      pinned: pinned,
      content: content,
    );
  }

  String? _findLocalTextPlain(String id) {
    for (final e in historyService.entries) {
      if (e.id == id && e.type == ContentType.text && e.content.isNotEmpty) {
        return e.content;
      }
    }
    return null;
  }

  Future<String?> _fetchServerContent(String id) async {
    final data = await cloudRepo.getHistoryEntryContent(id);
    final content = data?['content'] as String?;
    if (content == null || content.isEmpty) return null;
    return content;
  }

  /// 迁移码导入：旧密钥（旧密码 + 备份 salt）解密 → 当前会话密钥重加密 →
  /// 复用 POST /clipboard（文本/图片）与 POST /file（文件流）上传，保留原始
  /// historyId/timestamp；置顶条目最后统一 PATCH 恢复。
  /// 首条解密失败（GCM tag 错）视为旧密码错误，抛 [DecryptionException] 中止。
  Future<ImportResult> importBackup({
    required BackupManifest manifest,
    required String oldPassword,
    required Uint8List newKey,
    required String deviceId,
    required String deviceName,
    required String devicePlatform,
    void Function(double progress, String label)? onProgress,
  }) async {
    final oldSalt = hexToBytes(manifest.saltHex);
    final oldKey = await encryption.deriveKey(oldPassword, oldSalt);

    var imported = 0;
    var failed = 0;
    final errors = <String>[];
    final pinnedIds = <String>[];

    for (var i = 0; i < manifest.entries.length; i++) {
      final entry = manifest.entries[i];
      onProgress?.call(
        manifest.entries.isEmpty ? 1.0 : i / manifest.entries.length,
        AppStrings.backupImporting(i + 1, manifest.entries.length),
      );
      try {
        final decrypted = await _decryptWithOldKey(entry, oldKey);
        await _uploadEntry(
          entry,
          decrypted,
          newKey,
          deviceId: deviceId,
          deviceName: deviceName,
          devicePlatform: devicePlatform,
        );
        if (entry.pinned) pinnedIds.add(entry.id);
        imported++;
      } on DecryptionException {
        rethrow; // 旧密码错误，中止（后续条目不导入）
      } catch (e) {
        failed++;
        errors.add('${entry.id}: $e');
      }
    }

    // 置顶条目恢复（上传时 INSERT OR REPLACE 会重置 pinned）
    for (final id in pinnedIds) {
      try {
        await cloudRepo.updateHistoryEntry(id, {'pinned': true});
      } catch (e) {
        failed++;
        errors.add(AppStrings.backupPinRestoreFailed(id, '$e'));
      }
    }

    onProgress?.call(1.0, AppStrings.backupImportDone);
    return ImportResult(imported: imported, failed: failed, errors: errors);
  }

  /// 云拉取前置预检：确认旧账户存在且旧密码可解密（轻量，避免全量下载后才失败）。
  ///
  /// - 旧 salt 缺失 / 历史为空 → [CloudPullException]（emptyAccount）。
  /// - 首条 text/image 条目解密失败（GCM tag 错）→ [DecryptionException]（旧密码错误）。
  /// - 旧账户全是 file（罕见）→ 静默通过，由 [importBackup] 首条解密兜底。
  Future<void> verifyCloudAccount({
    required CloudRepository sourceRepo,
    required String oldPassword,
  }) async {
    final salt = await sourceRepo.getSalt();
    if (salt == null || salt.isEmpty) {
      throw CloudPullException(
        CloudPullErrorType.emptyAccount,
        AppStrings.cloudPullEmptyAccount,
      );
    }
    final records = await sourceRepo.getHistoryEntries(limit: 10);
    if (records.isEmpty) {
      throw CloudPullException(
        CloudPullErrorType.emptyAccount,
        AppStrings.cloudPullEmptyAccount,
      );
    }
    for (final record in records) {
      final type = record['type'] as String? ?? 'text';
      if (type == ContentType.file.name) continue;
      final entry = await _buildCloudEntry(record, sourceRepo);
      if (entry == null) continue;
      final oldKey = await encryption.deriveKey(oldPassword, hexToBytes(salt));
      await _decryptWithOldKey(entry, oldKey); // 解密失败抛 DecryptionException
      return;
    }
  }

  /// 构建云拉取数据源清单（与备份文件等价的 [BackupManifest]）。
  ///
  /// 强制服务端全量：text/image 一律 `GET /api/history/:id/content` 全量密文
  /// （列表接口 content 服务端截断至 10000 字符，截断密文解密必 GCM 失败，
  /// 禁用）；file 走文件流。manifest.saltHex 强制取旧 repo `GET /api/salt`
  /// （禁用本地盐——切换账户后 storage.encryptionSalt 是新账户盐）。
  Future<BackupManifest> buildCloudManifest({
    required CloudRepository sourceRepo,
    void Function(double progress, String label)? onProgress,
  }) async {
    final saltHex = await sourceRepo.getSalt();
    if (saltHex == null || saltHex.isEmpty) {
      throw CloudPullException(
        CloudPullErrorType.emptyAccount,
        AppStrings.cloudPullEmptyAccount,
      );
    }
    final records = await sourceRepo.getHistoryEntries(limit: 100);
    if (records.isEmpty) {
      throw CloudPullException(
        CloudPullErrorType.emptyAccount,
        AppStrings.cloudPullEmptyAccount,
      );
    }

    final entries = <BackupEntry>[];
    for (var i = 0; i < records.length; i++) {
      onProgress?.call(
        records.isEmpty ? 1.0 : i / records.length,
        AppStrings.cloudPullFetching(i + 1, records.length),
      );
      final entry = await _buildCloudEntry(records[i], sourceRepo);
      if (entry != null) entries.add(entry);
    }
    onProgress?.call(1.0, AppStrings.cloudPullFetchingLabel);

    return BackupManifest(
      exportedAt: DateTime.now(),
      sourceDevice: '',
      saltHex: saltHex,
      entries: entries,
    );
  }

  /// 云拉取单条数据源条目：与 [_buildBackupEntry] 平行、强制纯服务端来源。
  /// 绝不读当前账户本地缓存（imageStore/fileStore/historyService）——旧账户
  /// 数据必须完全来自旧 repo。
  Future<BackupEntry?> _buildCloudEntry(
    Map<String, dynamic> record,
    CloudRepository sourceRepo,
  ) async {
    final id = record['id'] as String? ?? '';
    if (id.isEmpty) return null;
    final type = record['type'] as String? ?? 'text';
    final timestamp = (record['timestamp'] as num?)?.toInt() ?? 0;
    final pinned = (record['pinned'] as int?) == 1;
    final sourceDeviceId = record['source_device'] as String? ?? 'unknown';
    final sourceDeviceName = record['source_device_name'] as String? ?? 'Unknown';
    final sourcePlatform = record['source_platform'] as String? ?? 'unknown';

    if (type == ContentType.image.name) {
      final content = await _fetchSourceContent(sourceRepo, id);
      if (content == null) return null;
      return BackupEntry(
        id: id,
        type: type,
        timestamp: timestamp,
        sourceDeviceId: sourceDeviceId,
        sourceDeviceName: sourceDeviceName,
        sourcePlatform: sourcePlatform,
        pinned: pinned,
        content: content,
        thumb: record['thumb'] as String?,
        width: (record['width'] as num?)?.toInt(),
        height: (record['height'] as num?)?.toInt(),
        format: record['format'] as String?,
        stableHash: record['hash'] as String?,
      );
    }

    if (type == ContentType.file.name) {
      // marker：服务端 /content 返回标记密文，缺失时 '' 兜底（file 解密走
      // fileCiphertextBase64，_uploadEntry 会重新生成 marker）
      final markerData = await sourceRepo.getHistoryEntryContent(id);
      final marker = markerData?['content'] as String? ?? '';

      // 文件密文字节：服务端文件流全量下载（云拉取无本地 .enc 缓存）
      String? cipherB64;
      final response = await sourceRepo.downloadFile(id);
      if (response.statusCode == 200) {
        final builder = BytesBuilder(copy: false);
        await response.stream.forEach(builder.add);
        cipherB64 = base64Encode(builder.takeBytes());
      }
      if (cipherB64 == null || cipherB64.isEmpty) return null;
      return BackupEntry(
        id: id,
        type: type,
        timestamp: timestamp,
        sourceDeviceId: sourceDeviceId,
        sourceDeviceName: sourceDeviceName,
        sourcePlatform: sourcePlatform,
        pinned: pinned,
        content: marker,
        fileName: record['file_name'] as String?,
        fileSize: (record['file_size'] as num?)?.toInt(),
        mimeType: record['mime_type'] as String?,
        fileHash: record['hash'] as String?,
        fileCiphertextBase64: cipherB64,
      );
    }

    // 文本：强制 /content 全量密文（绝不取列表截断 content）
    final content = await _fetchSourceContent(sourceRepo, id);
    if (content == null) return null;
    return BackupEntry(
      id: id,
      type: type,
      timestamp: timestamp,
      sourceDeviceId: sourceDeviceId,
      sourceDeviceName: sourceDeviceName,
      sourcePlatform: sourcePlatform,
      pinned: pinned,
      content: content,
    );
  }

  Future<String?> _fetchSourceContent(
    CloudRepository sourceRepo,
    String id,
  ) async {
    final data = await sourceRepo.getHistoryEntryContent(id);
    final content = data?['content'] as String?;
    if (content == null || content.isEmpty) return null;
    return content;
  }

  /// 云端拉取前置上限检查：目标（当前）账户已有条目且合并后总量可能超过
  /// 服务端「保留最近 100 条」上限时返回 [CloudPullLimitWarning]；否则返回 null。
  ///
  /// 服务端每次上传后按 timestamp DESC 仅保留最近 [AppConstants.maxHistoryEntries]
  /// 条历史（server/index.js 的「清理旧历史记录」）。迁移条目保留旧时间戳，
  /// 「旧数据并入已使用账户」时，较早时间戳的已迁移条目会在导入过程中被服务端
  /// 静默清理。因此迁移前必须先统计目标账户现有条数，超限时交由 UI 警告并由
  /// 用户确认。条数以服务端列表长度为准（服务端本身只保留最近 100 条，长度即
  /// 精确条数）。
  Future<CloudPullLimitWarning?> checkCloudPullHistoryLimit({
    required CloudRepository sourceRepo,
  }) async {
    final targetCount = (await cloudRepo.getHistoryEntries(
      limit: AppConstants.maxHistoryEntries,
    )).length;
    if (targetCount == 0) return null; // 空目标账户：合并后 ≤ 100，不触发清理
    final sourceCount = (await sourceRepo.getHistoryEntries(
      limit: AppConstants.maxHistoryEntries,
    )).length;
    if (targetCount + sourceCount <= AppConstants.maxHistoryEntries) {
      return null;
    }
    return CloudPullLimitWarning(
      targetCount: targetCount,
      sourceCount: sourceCount,
      totalCount: targetCount + sourceCount,
    );
  }

  /// 从云端拉取：旧账户数据迁移到当前账户。
  ///
  /// ① 同账户守卫（在任何网络调用前拒绝）→ ② [verifyCloudAccount] 预检 →
  /// ③ [buildCloudManifest] 构建数据源（拉取阶段）→ ④ [importBackup] 导入
  /// （复用完整导入管线：旧密钥解密 → 新密钥重加密 → 新账户上传）。
  Future<ImportResult> pullFromCloud({
    required CloudRepository sourceRepo,
    required String currentUserId,
    required String oldPassword,
    required Uint8List newKey,
    required String deviceId,
    required String deviceName,
    required String devicePlatform,
    void Function(double progress, String label)? onProgress,
  }) async {
    if (deriveUserId(oldPassword) == currentUserId) {
      throw CloudPullException(
        CloudPullErrorType.sameAccount,
        AppStrings.cloudPullSameAccount,
      );
    }
    await verifyCloudAccount(sourceRepo: sourceRepo, oldPassword: oldPassword);
    final manifest = await buildCloudManifest(
      sourceRepo: sourceRepo,
      onProgress: onProgress,
    );
    return importBackup(
      manifest: manifest,
      oldPassword: oldPassword,
      newKey: newKey,
      deviceId: deviceId,
      deviceName: deviceName,
      devicePlatform: devicePlatform,
      onProgress: onProgress,
    );
  }

  /// 用旧密钥解密条目。解密失败（密钥/密文不匹配）抛 [DecryptionException]。
  Future<Object> _decryptWithOldKey(BackupEntry entry, Uint8List oldKey) async {
    try {
      if (entry.type == 'image') {
        final imageBytes = await encryption.decryptBytes(
          EncryptedData.fromBase64(entry.content),
          oldKey,
        );
        Uint8List? thumbBytes;
        final thumbB64 = entry.thumb;
        if (thumbB64 != null && thumbB64.isNotEmpty) {
          thumbBytes = await encryption.decryptBytes(
            EncryptedData.fromBase64(thumbB64),
            oldKey,
          );
        }
        return (imageBytes, thumbBytes);
      }
      if (entry.type == 'file') {
        return await encryption.decryptBytes(
          EncryptedData.fromBytes(
            Uint8List.fromList(base64Decode(entry.fileCiphertextBase64 ?? '')),
          ),
          oldKey,
        );
      }
      return await encryption.decrypt(
        EncryptedData.fromBase64(entry.content),
        oldKey,
      );
    } on EncryptionException {
      throw DecryptionException(AppStrings.backupWrongOldPassword);
    }
  }

  /// 重加密并上传单条导入条目（保留原始 historyId/timestamp）。
  Future<void> _uploadEntry(
    BackupEntry entry,
    Object decrypted,
    Uint8List newKey, {
    required String deviceId,
    required String deviceName,
    required String devicePlatform,
  }) async {
    final base = {
      'sourceDevice': deviceId,
      'sourceDeviceName': deviceName,
      'sourcePlatform': devicePlatform,
      'timestamp': entry.timestamp,
    };

    if (entry.type == 'image') {
      final (imageBytes, thumbBytes) = decrypted as (Uint8List, Uint8List?);
      final newCipher = await encryption.encryptBytes(imageBytes, newKey);
      final newThumb = await encryption.encryptBytes(
        thumbBytes ?? imageBytes,
        newKey,
      );
      final data = {
        ...base,
        'content': newCipher.toBase64(),
        'thumb': newThumb.toBase64(),
        'hash': entry.stableHash ?? '',
        'type': 'image',
        'width': entry.width,
        'height': entry.height,
        'format': entry.format,
        'historyId': entry.id,
      };
      await cloudRepo.setCurrentClipboard(data);
      await cloudRepo.addHistoryEntry({...data, 'pinned': false});
      return;
    }

    if (entry.type == 'file') {
      final fileBytes = decrypted as Uint8List;
      final newCipher = await encryption.encryptBytes(fileBytes, newKey);
      final marker = (await encryption.encrypt('', newKey)).toBase64();
      final tempPath = await fileStore.newTempPath('.enc');
      await File(tempPath).writeAsBytes(newCipher.toBytes(), flush: true);
      try {
        await cloudRepo.uploadFile(
          encryptedPath: tempPath,
          historyId: entry.id,
          plaintextHash: entry.fileHash ?? '',
          fileName: entry.fileName ?? 'file',
          fileSize: entry.fileSize ?? 0,
          mimeType: entry.mimeType ?? 'application/octet-stream',
          marker: marker,
          sourceDevice: deviceId,
          sourceDeviceName: deviceName,
          sourcePlatform: devicePlatform,
          timestamp: entry.timestamp,
        );
      } finally {
        try {
          if (await File(tempPath).exists()) await File(tempPath).delete();
        } catch (_) {
          // 清理失败仅残留临时文件，不影响导入结果
        }
      }
      return;
    }

    // 文本
    final plaintext = decrypted as String;
    final newCipher = await encryption.encrypt(plaintext, newKey);
    final data = {
      ...base,
      'content': newCipher.toBase64(),
      'hash': sha256.convert(utf8.encode(plaintext)).toString(),
      'type': 'text',
      'historyId': entry.id,
    };
    await cloudRepo.setCurrentClipboard(data);
    await cloudRepo.addHistoryEntry({...data, 'pinned': false});
  }
}

/// 云端拉取合并超限警告信息：目标账户已有条目，且合并后总量超过服务端
/// 「保留最近 100 条」上限（较早时间戳的迁移条目导入过程中会被服务端清理）。
class CloudPullLimitWarning {
  /// 目标（当前）账户现有历史条数。
  final int targetCount;

  /// 源（旧）账户待迁移条数。
  final int sourceCount;

  /// 合并后总量（targetCount + sourceCount）。
  final int totalCount;

  const CloudPullLimitWarning({
    required this.targetCount,
    required this.sourceCount,
    required this.totalCount,
  });
}

/// 导入结果汇总。
class ImportResult {
  final int imported;
  final int failed;
  final List<String> errors;

  const ImportResult({
    required this.imported,
    required this.failed,
    required this.errors,
  });
}
