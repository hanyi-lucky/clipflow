import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:crypto/crypto.dart';
import 'package:clipflow/models/clipboard_entry.dart';
import 'package:clipflow/repositories/cloud_repository.dart';
import 'package:clipflow/services/cloudbase_service.dart';
import 'package:clipflow/services/encryption_service.dart';
import 'package:clipflow/services/sync_service.dart';

class FakeCloudRepository extends CloudRepository {
  Map<String, dynamic>? currentClipboard;
  final List<Map<String, dynamic>> historyEntries = [];

  FakeCloudRepository() : super(CloudBaseService());

  @override
  Future<void> setCurrentClipboard(Map<String, dynamic> data) async {
    currentClipboard = {...data};
  }

  @override
  Future<void> addHistoryEntry(Map<String, dynamic> data) async {
    historyEntries.add({...data});
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

class SpyEncryptionService extends EncryptionService {
  int isolateDecryptCalls = 0;

  @override
  Future<Uint8List> decryptBytesIsolate(Uint8List key, String encryptedBase64) {
    isolateDecryptCalls++;
    return super.decryptBytesIsolate(key, encryptedBase64);
  }
}

void main() {
  const testPassword = 'image-test-password';
  final testSalt = List<int>.generate(32, (i) => i % 256);
  late EncryptionService encryption;
  late Uint8List key;
  late FakeCloudRepository repo;
  late SyncService service;

  final imageBytes = Uint8List.fromList(List.generate(4096, (i) => i % 251));
  final thumbBytes = Uint8List.fromList(List.generate(1024, (i) => (i * 7) % 251));
  final stableHash = 'stable-hash-001'; // 像素内容稳定哈希（压缩 isolate 内计算）

  setUp(() async {
    encryption = EncryptionService();
    key = await encryption.deriveKey(testPassword, testSalt);
    repo = FakeCloudRepository();
    service = SyncService(
      repo: repo,
      encryption: encryption,
      deviceId: 'device-a',
      deviceName: 'Mac A',
      devicePlatform: 'macos',
      key: key,
    );
  });

  group('SyncService.uploadImage', () {
    test('uploads encrypted full image and thumb with metadata', () async {
      final result = await service.uploadImage(
        bytes: imageBytes,
        thumbBytes: thumbBytes,
        width: 1024,
        height: 768,
        format: 'jpeg',
        stableHash: stableHash,
      );

      expect(result, isNotNull);
      final payload = repo.currentClipboard!;
      expect(payload['type'], equals('image'));
      expect(payload['width'], equals(1024));
      expect(payload['height'], equals(768));
      expect(payload['format'], equals('jpeg'));
      expect(payload['hash'], equals(stableHash));

      // 全图与缩略图是两次独立加密，解密后还原原始字节
      final decryptedFull = await encryption.decryptBytes(
        EncryptedData.fromBase64(payload['content'] as String),
        key,
      );
      final decryptedThumb = await encryption.decryptBytes(
        EncryptedData.fromBase64(payload['thumb'] as String),
        key,
      );
      expect(decryptedFull, equals(imageBytes));
      expect(decryptedThumb, equals(thumbBytes));

      // 返回结果携带 historyId 与两份密文
      expect(result!.historyId, isNotEmpty);
      expect(result.encryptedBase64, equals(payload['content']));
      expect(result.encryptedThumbBase64, equals(payload['thumb']));

      // 历史记录也写入服务器
      expect(repo.historyEntries, hasLength(1));
      expect(repo.historyEntries.first['historyId'], equals(result.historyId));
    });

    test('deduplicates same stableHash even when re-encoded bytes differ', () async {
      final first = await service.uploadImage(
        bytes: imageBytes,
        thumbBytes: thumbBytes,
        width: 10,
        height: 10,
        format: 'png',
        stableHash: stableHash,
      );
      // 模拟重编码：字节不同但像素内容一致（稳定哈希相同）
      final reencodedBytes = Uint8List.fromList(
        List.generate(4096, (i) => (i * 3) % 251),
      );
      final second = await service.uploadImage(
        bytes: reencodedBytes,
        thumbBytes: thumbBytes,
        width: 10,
        height: 10,
        format: 'png',
        stableHash: stableHash,
      );

      expect(first, isNotNull);
      expect(second, isNull);
    });

    test('uploads again when stableHash differs', () async {
      final first = await service.uploadImage(
        bytes: imageBytes,
        thumbBytes: thumbBytes,
        width: 10,
        height: 10,
        format: 'png',
        stableHash: 'stable-hash-A',
      );
      final second = await service.uploadImage(
        bytes: imageBytes,
        thumbBytes: thumbBytes,
        width: 10,
        height: 10,
        format: 'png',
        stableHash: 'stable-hash-B',
      );

      expect(first, isNotNull);
      expect(second, isNotNull);
    });

    test('markAsDownloadedHash prevents re-upload of downloaded image', () async {
      service.markAsDownloadedHash(stableHash);

      final result = await service.uploadImage(
        bytes: imageBytes,
        thumbBytes: thumbBytes,
        width: 10,
        height: 10,
        format: 'png',
        stableHash: stableHash,
      );

      expect(result, isNull);
    });

    test('decryptImage returns original bytes', () async {
      final result = await service.uploadImage(
        bytes: imageBytes,
        thumbBytes: thumbBytes,
        width: 10,
        height: 10,
        format: 'jpeg',
        stableHash: stableHash,
      );

      final decrypted = await service.decryptImage(result!.encryptedBase64);

      expect(decrypted, equals(imageBytes));
    });
  });

  group('SyncService.downloadLatestContent image branch', () {
    test('returns decrypted image bytes and metadata for image type', () async {
      final fullEncrypted = await encryption.encryptBytes(imageBytes, key);
      final thumbEncrypted = await encryption.encryptBytes(thumbBytes, key);
      repo.currentClipboard = {
        'id': 'clip-1',
        'user_id': 'user_x',
        'content': fullEncrypted.toBase64(),
        'thumb': thumbEncrypted.toBase64(),
        'hash': sha256.convert(imageBytes).toString(),
        'source_device': 'device-b',
        'source_device_name': 'Phone B',
        'source_platform': 'android',
        'timestamp': 1700000000000,
        'type': 'image',
        'width': 640,
        'height': 480,
        'format': 'png',
        'history_id': 'hist-42',
      };

      final result = await service.downloadLatestContent();

      expect(result, isNotNull);
      expect(result!.type, equals(ContentType.image));
      expect(result.imageBytes, equals(imageBytes));
      expect(result.imageThumbBytes, equals(thumbBytes));
      expect(result.imageEncryptedBase64, equals(fullEncrypted.toBase64()));
      expect(result.imageHash, equals(sha256.convert(imageBytes).toString()));
      expect(result.imageWidth, equals(640));
      expect(result.imageHeight, equals(480));
      expect(result.imageFormat, equals('png'));
      expect(result.id, equals('hist-42'));
      expect(result.hasContent, isTrue);
      expect(result.sourceDeviceId, equals('device-b'));
    });

    test('full image download decryption runs in an isolate', () async {
      final spyEncryption = SpyEncryptionService();
      final spyService = SyncService(
        repo: repo,
        encryption: spyEncryption,
        deviceId: 'device-a',
        deviceName: 'Mac A',
        devicePlatform: 'macos',
        key: key,
      );
      final fullEncrypted = await encryption.encryptBytes(imageBytes, key);
      final thumbEncrypted = await encryption.encryptBytes(thumbBytes, key);
      repo.currentClipboard = {
        'id': 'clip-iso',
        'user_id': 'user_x',
        'content': fullEncrypted.toBase64(),
        'thumb': thumbEncrypted.toBase64(),
        'hash': 'HASH_ISO',
        'source_device': 'device-b',
        'source_device_name': 'Phone B',
        'source_platform': 'android',
        'timestamp': 1700000000000,
        'type': 'image',
        'width': 640,
        'height': 480,
        'format': 'png',
        'history_id': 'hist-iso',
      };

      final result = await spyService.downloadLatestContent();

      expect(result, isNotNull);
      expect(result!.imageBytes, equals(imageBytes));
      expect(spyEncryption.isolateDecryptCalls, greaterThanOrEqualTo(1));
    });

    test('id is null for legacy clipboard rows without history_id', () async {
      final fullEncrypted = await encryption.encryptBytes(imageBytes, key);
      repo.currentClipboard = {
        'id': 'clip-legacy',
        'user_id': 'user_x',
        'content': fullEncrypted.toBase64(),
        'hash': 'HASH_LEGACY',
        'source_device': 'device-b',
        'source_device_name': 'Phone B',
        'source_platform': 'android',
        'timestamp': 1700000000000,
        'type': 'image',
        'width': 640,
        'height': 480,
        'format': 'png',
      };

      final result = await service.downloadLatestContent();

      expect(result, isNotNull);
      expect(result!.id, isNull);
    });

    test('text clipboard still downloads as text', () async {
      final encrypted = await encryption.encrypt('hello text', key);
      repo.currentClipboard = {
        'id': 'clip-2',
        'user_id': 'user_x',
        'content': encrypted.toBase64(),
        'hash': sha256.convert('hello text'.codeUnits).toString(),
        'source_device': 'device-b',
        'source_device_name': 'Phone B',
        'source_platform': 'android',
        'timestamp': 1700000000000,
        'type': 'text',
      };

      final result = await service.downloadLatestContent();

      expect(result, isNotNull);
      expect(result!.type, equals(ContentType.text));
      expect(result.content, equals('hello text'));
      expect(result.imageBytes, isNull);
    });

    test('own device upload is skipped', () async {
      final encrypted = await encryption.encryptBytes(imageBytes, key);
      repo.currentClipboard = {
        'id': 'clip-3',
        'user_id': 'user_x',
        'content': encrypted.toBase64(),
        'hash': sha256.convert(imageBytes).toString(),
        'source_device': 'device-a',
        'source_device_name': 'Mac A',
        'source_platform': 'macos',
        'timestamp': 1700000000000,
        'type': 'image',
      };

      final result = await service.downloadLatestContent();

      expect(result, isNull);
    });
  });
}
