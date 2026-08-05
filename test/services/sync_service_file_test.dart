import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:clipflow/models/clipboard_entry.dart';
import 'package:clipflow/repositories/cloud_repository.dart';
import 'package:clipflow/services/cloudbase_service.dart';
import 'package:clipflow/services/encryption_service.dart';
import 'package:clipflow/services/sync_service.dart';

class FileFakeCloudRepository extends CloudRepository {
  FileFakeCloudRepository() : super(CloudBaseService());

  Map<String, dynamic>? currentClipboard;
  final List<Map<String, dynamic>> uploadCalls = [];

  @override
  Future<void> uploadFile({
    required String encryptedPath,
    required String historyId,
    required String plaintextHash,
    required String fileName,
    required int fileSize,
    required String mimeType,
    required String marker,
    required String sourceDevice,
    required String sourceDeviceName,
    required String sourcePlatform,
    required int timestamp,
  }) async {
    uploadCalls.add({
      'encryptedPath': encryptedPath,
      'historyId': historyId,
      'plaintextHash': plaintextHash,
      'fileName': fileName,
      'fileSize': fileSize,
      'mimeType': mimeType,
      'marker': marker,
      'sourceDevice': sourceDevice,
      'sourceDeviceName': sourceDeviceName,
      'sourcePlatform': sourcePlatform,
      'timestamp': timestamp,
    });
  }

  @override
  Future<Map<String, dynamic>?> getCurrentClipboardWithDeletions() async {
    if (currentClipboard == null) return null;
    return {
      ...currentClipboard!,
      '_deletedIds': <String>[],
      '_restoredEntries': <Map<String, dynamic>>[],
    };
  }
}

void main() {
  final testSalt = List<int>.generate(32, (i) => i % 256);
  late EncryptionService encryption;
  late Uint8List key;
  late FileFakeCloudRepository repo;
  late SyncService service;

  setUp(() async {
    encryption = EncryptionService();
    key = await encryption.deriveKey('file-sync-password', testSalt);
    repo = FileFakeCloudRepository();
    service = SyncService(
      repo: repo,
      encryption: encryption,
      deviceId: 'device-a',
      deviceName: 'Mac A',
      devicePlatform: 'macos',
      key: key,
    );
  });

  group('SyncService.uploadFile', () {
    test('uploads metadata and records file:<hash> dedupe domain', () async {
      final result = await service.uploadFile(
        encryptedPath: '/tmp/x.enc',
        fileName: '报告.pdf',
        fileSize: 2048,
        mimeType: 'application/pdf',
        plaintextHash: 'plaintext-hash-1',
        timestamp: 1700000000000,
      );

      expect(result, isNotNull);
      expect(repo.uploadCalls, hasLength(1));
      final call = repo.uploadCalls.first;
      expect(call['encryptedPath'], '/tmp/x.enc');
      expect(call['historyId'], result!.historyId);
      expect(call['fileName'], '报告.pdf');
      expect(call['fileSize'], 2048);
      expect(call['mimeType'], 'application/pdf');
      expect(call['sourceDevice'], 'device-a');
      expect(call['timestamp'], 1700000000000);
      // marker 是 base64url 编码的加密空字符串
      final marker = call['marker'] as String;
      final encrypted = EncryptedData.fromBase64(marker);
      expect(await encryption.decrypt(encrypted, key), isEmpty);

      expect(service.isFileHashUploaded('plaintext-hash-1'), isTrue);
      expect(service.lastUploadedHash, 'file:plaintext-hash-1');
    });

    test('duplicate file hash skips upload', () async {
      final first = await service.uploadFile(
        encryptedPath: '/tmp/a.enc',
        fileName: 'a.txt',
        fileSize: 1,
        mimeType: 'text/plain',
        plaintextHash: 'same-hash',
        timestamp: 1700000000000,
      );
      final second = await service.uploadFile(
        encryptedPath: '/tmp/b.enc',
        fileName: 'b.txt',
        fileSize: 2,
        mimeType: 'text/plain',
        plaintextHash: 'same-hash',
        timestamp: 1700000001000,
      );

      expect(first, isNotNull);
      expect(second, isNull);
      expect(repo.uploadCalls, hasLength(1));
    });

    test('text and file hash domains do not collide', () async {
      service.markAsDownloaded('plaintext-hash-2');

      final result = await service.uploadFile(
        encryptedPath: '/tmp/c.enc',
        fileName: 'c.txt',
        fileSize: 3,
        mimeType: 'text/plain',
        plaintextHash: 'plaintext-hash-2',
        timestamp: 1700000000000,
      );

      // 文本域不等于 file: 域，文件仍会上传
      expect(result, isNotNull);
      expect(repo.uploadCalls, hasLength(1));
    });
  });

  group('SyncService.markAsDownloadedFileHash', () {
    test('prevents re-upload of downloaded file content', () async {
      service.markAsDownloadedFileHash('downloaded-hash');

      final result = await service.uploadFile(
        encryptedPath: '/tmp/d.enc',
        fileName: 'd.txt',
        fileSize: 4,
        mimeType: 'text/plain',
        plaintextHash: 'downloaded-hash',
        timestamp: 1700000000000,
      );

      expect(result, isNull);
      expect(repo.uploadCalls, isEmpty);
    });
  });

  group('SyncService.downloadLatestContent file branch', () {
    test('returns metadata only for file type (no content download)', () async {
      repo.currentClipboard = {
        'id': 'clip-1',
        'user_id': 'user_x',
        'content': 'marker-ciphertext',
        'hash': 'file-hash-abc',
        'source_device': 'device-b',
        'source_device_name': 'Phone B',
        'source_platform': 'android',
        'timestamp': 1700000000000,
        'type': 'file',
        'file_name': 'archive.zip',
        'file_size': 4096,
        'mime_type': 'application/zip',
        'file_key': 'uuid-123',
        'history_id': 'hist-file-1',
      };

      final result = await service.downloadLatestContent();

      expect(result, isNotNull);
      expect(result!.type, equals(ContentType.file));
      expect(result.hasFile, isTrue);
      expect(result.hasContent, isFalse);
      expect(result.content, isEmpty);
      expect(result.id, 'hist-file-1');
      expect(result.fileName, 'archive.zip');
      expect(result.fileSize, 4096);
      expect(result.mimeType, 'application/zip');
      expect(result.fileHash, 'file-hash-abc');
      expect(result.imageBytes, isNull);
    });

    test('own device file upload is skipped by source check', () async {
      repo.currentClipboard = {
        'id': 'clip-2',
        'user_id': 'user_x',
        'content': 'marker',
        'hash': 'hash',
        'source_device': 'device-a',
        'source_device_name': 'Mac A',
        'source_platform': 'macos',
        'timestamp': 1700000000000,
        'type': 'file',
        'file_name': 'x.bin',
        'file_size': 1,
        'mime_type': 'application/octet-stream',
        'file_key': 'uuid-456',
        'history_id': 'hist-file-2',
      };

      final result = await service.downloadLatestContent();

      expect(result, isNull);
    });
  });
}
