import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:clipflow/core/constants.dart';
import 'package:clipflow/providers/clipboard_provider.dart';
import 'package:clipflow/repositories/cloud_repository.dart';
import 'package:clipflow/repositories/local_image_store.dart';
import 'package:clipflow/repositories/local_storage.dart';
import 'package:clipflow/services/cloudbase_service.dart';
import 'package:clipflow/services/encryption_service.dart';

/// 第三轮整改：垃圾箱倾倒 + 超长文本截断。
/// 服务端历史列表会把文本密文截断到 10000 字符，客户端经
/// GET /api/history/:id/content 回补全量密文；解密结果必须走 isolate
/// 并统一截断到 AppConstants.maxContentLength（50000）。
class FakeTrashRepo extends CloudRepository {
  FakeTrashRepo() : super(CloudBaseService());

  List<Map<String, dynamic>> history = [];
  List<Map<String, dynamic>> trash = [];
  Map<String, Map<String, dynamic>> fullContentById = {};
  int emptyTrashCalls = 0;
  int deleted = 0;

  @override
  Future<List<Map<String, dynamic>>> getHistoryEntries({int limit = 100}) async =>
      history;

  @override
  Future<List<Map<String, dynamic>>> getTrashEntries() async => trash;

  @override
  Future<Map<String, dynamic>?> getHistoryEntryContent(String entryId) async {
    return fullContentById[entryId];
  }

  @override
  Future<Map<String, dynamic>?> getCurrentClipboardWithDeletions() async => null;

  @override
  Future<void> deleteHistoryEntry(String entryId) async {}

  @override
  Future<void> updateHistoryEntry(String entryId, Map<String, dynamic> data) async {}

  @override
  Future<void> restoreHistoryEntry(String entryId) async {}

  @override
  Future<int> emptyTrash() async {
    emptyTrashCalls++;
    return deleted;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const password = 'provider-empty-trash-test';
  final salt = List<int>.generate(32, (i) => i % 256);

  late EncryptionService encryption;
  late Uint8List key;
  late FakeTrashRepo repo;
  late LocalStorage storage;
  late LocalImageStore imageStore;
  late Directory tempDir;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    encryption = EncryptionService();
    key = await encryption.deriveKey(password, salt);
    repo = FakeTrashRepo();
    storage = LocalStorage(await SharedPreferences.getInstance());
    tempDir = await Directory.systemTemp.createTemp('clipflow_provider_trash_');
    imageStore = LocalImageStore(directoryPath: tempDir.path);
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  Map<String, dynamic> textRow(String id, String contentBase64) {
    return {
      'id': id,
      'content': contentBase64,
      'type': 'text',
      'source_device': 'device-a',
      'source_device_name': 'Mac A',
      'source_platform': 'macos',
      'timestamp': 1700000001000,
      'pinned': 0,
    };
  }

  Future<ClipboardProvider> createProvider() async {
    final provider = ClipboardProvider(imageStore: imageStore);
    await provider.initialize(
      storage: storage,
      cloudRepo: repo,
      deviceId: 'device-test',
      deviceName: 'Test Mac',
      encryptionKey: key,
    );
    return provider;
  }

  Future<void> waitFor(
    ClipboardProvider provider,
    bool Function() condition, {
    String? message,
  }) async {
    for (var i = 0; i < 120; i++) {
      if (condition()) return;
      await Future.delayed(const Duration(milliseconds: 50));
    }
    fail(message ?? 'condition not met within timeout');
  }

  Future<void> settle() =>
      Future.delayed(const Duration(milliseconds: 200));

  Future<(String, String)> truncatedCipherPair(String plaintext) async {
    final full = (await encryption.encrypt(plaintext, key)).toBase64();
    expect(full.length, greaterThan(10000),
        reason: 'test premise: ciphertext must exceed list truncation limit');
    final truncated = full.substring(0, 10000);
    await expectLater(
      encryption.decrypt(EncryptedData.fromBase64(truncated), key),
      throwsA(anything),
    );
    return (full, truncated);
  }

  group('emptyTrash', () {
    test('delegates to repository and returns deleted count', () async {
      repo.deleted = 7;
      final provider = await createProvider();

      final count = await provider.emptyTrash();

      expect(count, 7);
      expect(repo.emptyTrashCalls, 1);

      await settle();
      provider.dispose();
    });
  });

  group('long text cap after fallback decrypt', () {
    test('history text longer than 50000 is capped before addEntry', () async {
      final plaintext = 'L' * 52000;
      final (full, truncated) = await truncatedCipherPair(plaintext);
      repo.history = [textRow('txt-huge', truncated)];
      repo.fullContentById['txt-huge'] = {
        'id': 'txt-huge',
        'content': full,
        'type': 'text',
      };

      final provider = await createProvider();
      await waitFor(
        provider,
        () => provider.history.any((e) => e.id == 'txt-huge'),
        message: 'huge entry should be recovered via /content fallback',
      );

      final entry = provider.history.firstWhere((e) => e.id == 'txt-huge');
      expect(entry.content.length, AppConstants.maxContentLength);
      expect(
        entry.content,
        plaintext.substring(0, AppConstants.maxContentLength),
      );

      await settle();
      provider.dispose();
    });

    test('trash text longer than 50000 is capped', () async {
      final plaintext = 'T' * 52000;
      final (full, truncated) = await truncatedCipherPair(plaintext);
      repo.trash = [textRow('trash-huge', truncated)];
      repo.fullContentById['trash-huge'] = {
        'id': 'trash-huge',
        'content': full,
        'type': 'text',
      };

      final provider = await createProvider();
      final entries = await provider.getTrashEntries();

      expect(entries, hasLength(1));
      expect(
        entries.first['content'],
        plaintext.substring(0, AppConstants.maxContentLength),
      );

      await settle();
      provider.dispose();
    });
  });
}
