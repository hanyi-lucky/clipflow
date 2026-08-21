import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:clipflow/models/clipboard_entry.dart';
import 'package:clipflow/providers/clipboard_provider.dart';
import 'package:clipflow/repositories/cloud_repository.dart';
import 'package:clipflow/repositories/local_image_store.dart';
import 'package:clipflow/repositories/local_storage.dart';
import 'package:clipflow/services/cloudbase_service.dart';
import 'package:clipflow/services/encryption_service.dart';

/// 服务器历史列表会对文本行密文做 substr(10000) 截断（列表瘦身），
/// 客户端直接解列表密文必然 GCM 认证失败。本组测试验证：
/// 解密失败 → 按 id 调 GET /api/history/:id/content 拉全量密文重试一次 →
/// 成功入历史 / 垃圾箱正常显示；仍失败才跳过/降级。
class FakeFallbackRepo extends CloudRepository {

  @override
  Future<Map<String, dynamic>?> getSyncChanges({required int after, int? limit}) async => null;
  FakeFallbackRepo() : super(CloudBaseService());

  List<Map<String, dynamic>> history = [];
  List<Map<String, dynamic>> trash = [];
  Map<String, Map<String, dynamic>> fullContentById = {};
  int contentFetchCalls = 0;

  @override
  Future<List<Map<String, dynamic>>> getHistoryEntries({int limit = 100}) async =>
      history;

  @override
  Future<List<Map<String, dynamic>>> getTrashEntries() async => trash;

  @override
  Future<Map<String, dynamic>?> getHistoryEntryContent(String entryId) async {
    contentFetchCalls++;
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
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const password = 'provider-fallback-test';
  final salt = List<int>.generate(32, (i) => i % 256);

  late EncryptionService encryption;
  late Uint8List key;
  late FakeFallbackRepo repo;
  late LocalStorage storage;
  late LocalImageStore imageStore;
  late Directory tempDir;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    encryption = EncryptionService();
    key = await encryption.deriveKey(password, salt);
    repo = FakeFallbackRepo();
    storage = LocalStorage(await SharedPreferences.getInstance());
    tempDir = await Directory.systemTemp.createTemp('clipflow_provider_fb_');
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

  /// 等待初始化触发的后台历史加载链结束，避免 dispose 后仍有回调
  Future<void> settle() =>
      Future.delayed(const Duration(milliseconds: 200));

  /// 生成 >10000 base64 字符的密文（模拟明文 8000 字符左右），
  /// 返回 (完整密文, 被服务器列表截断到 10000 字符的密文)。
  Future<(String, String)> truncatedCipherPair(String plaintext) async {
    final full = (await encryption.encrypt(plaintext, key)).toBase64();
    expect(full.length, greaterThan(10000),
        reason: 'test premise: ciphertext must exceed list truncation limit');
    final truncated = full.substring(0, 10000);
    // 前提自检：截断密文必须解密失败，否则测试没在测回补路径
    await expectLater(
      encryption.decrypt(EncryptedData.fromBase64(truncated), key),
      throwsA(anything),
    );
    return (full, truncated);
  }

  group('text list truncation -> /content fallback', () {
    test('truncated list ciphertext is recovered via /content and entry loads',
        () async {
      final plaintext = 'a' * 8000;
      final (full, truncated) = await truncatedCipherPair(plaintext);
      repo.history = [textRow('txt-long', truncated)];
      repo.fullContentById['txt-long'] = {
        'id': 'txt-long',
        'content': full,
        'type': 'text',
      };

      final provider = await createProvider();
      await waitFor(
        provider,
        () => provider.history.any((e) => e.id == 'txt-long'),
        message: 'entry should be recovered via /content fallback',
      );

      final entry = provider.history.firstWhere((e) => e.id == 'txt-long');
      expect(entry.type, ContentType.text);
      expect(entry.content, plaintext);
      // 回补确确实实被触发（直接解密截断密文必然失败）
      expect(repo.contentFetchCalls, 1);

      await settle();
      provider.dispose();
    });

    test('normal untruncated entry loads without /content fallback', () async {
      final full = (await encryption.encrypt('short text', key)).toBase64();
      repo.history = [textRow('txt-normal', full)];

      final provider = await createProvider();
      await waitFor(
        provider,
        () => provider.history.any((e) => e.id == 'txt-normal'),
        message: 'normal entry should load',
      );

      expect(
        provider.history.firstWhere((e) => e.id == 'txt-normal').content,
        'short text',
      );
      expect(repo.contentFetchCalls, 0);

      await settle();
      provider.dispose();
    });

    test('entry is skipped when /content fallback also fails to decrypt',
        () async {
      final plaintext = 'b' * 8000;
      final (_, truncated) = await truncatedCipherPair(plaintext);
      repo.history = [textRow('txt-broken', truncated)];
      // fullContentById 不设置 → 回补返回 null，仍失败

      final provider = await createProvider();
      await waitFor(
        provider,
        () => repo.contentFetchCalls >= 1,
        message: 'fallback should be attempted once',
      );
      // 短暂等待确保加载循环结束，条目确实被跳过
      await Future.delayed(const Duration(milliseconds: 100));

      expect(
        provider.history.any((e) => e.id == 'txt-broken'),
        isFalse,
        reason: 'entry must stay hidden when both ciphertexts are undecryptable',
      );

      await settle();
      provider.dispose();
    });
  });

  group('trash list truncation -> /content fallback', () {
    test('trash entry with truncated ciphertext is recovered via /content',
        () async {
      final plaintext = 'c' * 8000;
      final (full, truncated) = await truncatedCipherPair(plaintext);
      repo.trash = [textRow('trash-long', truncated)];
      repo.fullContentById['trash-long'] = {
        'id': 'trash-long',
        'content': full,
        'type': 'text',
      };

      final provider = await createProvider();
      final entries = await provider.getTrashEntries();

      expect(entries, hasLength(1));
      expect(entries.first['content'], plaintext);
      expect(repo.contentFetchCalls, 1);

      await settle();
      provider.dispose();
    });

    test('trash entry degrades to [解密失败] when fallback also fails',
        () async {
      final plaintext = 'd' * 8000;
      final (_, truncated) = await truncatedCipherPair(plaintext);
      repo.trash = [textRow('trash-broken', truncated)];

      final provider = await createProvider();
      final entries = await provider.getTrashEntries();

      expect(entries, hasLength(1));
      expect(entries.first['content'], '[解密失败]');
      expect(repo.contentFetchCalls, 1);

      await settle();
      provider.dispose();
    });
  });
}
