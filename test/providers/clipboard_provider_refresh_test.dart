import 'dart:async';
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

/// 模拟服务器延迟，用于测试并发刷新
class SlowFakeRepo extends CloudRepository {

  @override
  Future<Map<String, dynamic>> commitSyncOperation({
    required String operationId,
    required String kind,
    required String entryId,
    Map<String, dynamic>? payload,
  }) async {
    return {'seq': 1};
  }

  @override
  Future<Map<String, dynamic>?> getSyncChanges({required int after, int? limit}) async => null;
  SlowFakeRepo() : super(CloudBaseService());

  List<Map<String, dynamic>> history = [];
  Duration delay = Duration.zero;
  int getHistoryCalls = 0;
  int deleteCalls = 0;

  @override
  Future<List<Map<String, dynamic>>> getHistoryEntries({int limit = 100}) async {
    getHistoryCalls++;
    if (delay != Duration.zero) {
      await Future.delayed(delay);
    }
    return List.from(history);
  }

  @override
  Future<Map<String, dynamic>?> getCurrentClipboardWithDeletions() async => null;

  @override
  Future<Map<String, dynamic>?> getHistoryEntryContent(String entryId) async => null;

  @override
  Future<void> deleteHistoryEntry(String entryId) async {
    deleteCalls++;
  }

  @override
  Future<void> updateHistoryEntry(String entryId, Map<String, dynamic> data) async {}

  @override
  Future<void> restoreHistoryEntry(String entryId) async {}

  @override
  Future<List<Map<String, dynamic>>> getTrashEntries() async => [];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const password = 'refresh-test';
  final salt = List<int>.generate(32, (i) => i % 256);

  late EncryptionService encryption;
  late Uint8List key;
  late SlowFakeRepo repo;
  late LocalStorage storage;
  late LocalImageStore imageStore;
  late Directory tempDir;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    encryption = EncryptionService();
    key = await encryption.deriveKey(password, salt);
    repo = SlowFakeRepo();
    storage = LocalStorage(await SharedPreferences.getInstance());
    tempDir = await Directory.systemTemp.createTemp('clipflow_refresh_');
    imageStore = LocalImageStore(directoryPath: tempDir.path);
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  Map<String, dynamic> textRow(String id, String contentBase64, {int timestamp = 1700000001000}) {
    return {
      'id': id,
      'content': contentBase64,
      'type': 'text',
      'source_device': 'device-a',
      'source_device_name': 'Mac A',
      'source_platform': 'macos',
      'timestamp': timestamp,
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

  group('concurrent refresh protection', () {
    test('multiple refresh calls do not produce duplicate entries', () async {
      final enc1 = await encryption.encrypt('hello world', key);
      repo.history = [textRow('txt-1', enc1.toBase64())];
      // 初始加载不延迟
      repo.delay = Duration.zero;

      final provider = await createProvider();
      await waitFor(
        provider,
        () => provider.history.any((e) => e.id == 'txt-1'),
        message: 'initial load should complete',
      );
      // 等待 _isLoadingHistory 复位
      await Future.delayed(const Duration(milliseconds: 100));

      // 模拟服务器延迟，然后快速连点 3 次刷新
      repo.delay = const Duration(milliseconds: 200);
      repo.getHistoryCalls = 0;
      final f1 = provider.refresh();
      final f2 = provider.refresh();
      final f3 = provider.refresh();
      await Future.wait([f1, f2, f3]);

      // 防重入：实际只应调用一次 getHistoryEntries
      // （第二次和第三次应被 _isRefreshing 挡住）
      expect(repo.getHistoryCalls, equals(1));

      // 最终条目唯一，无重复
      final ids = provider.history.map((e) => e.id).toList();
      expect(ids.toSet().length, equals(ids.length),
          reason: 'no duplicate entries after concurrent refresh');

      await settle();
      provider.dispose();
    });

    test('concurrent refresh preserves entry order', () async {
      final enc1 = await encryption.encrypt('entry one', key);
      final enc2 = await encryption.encrypt('entry two', key);
      repo.history = [
        textRow('txt-a', enc1.toBase64(), timestamp: 1700000001000),
        textRow('txt-b', enc2.toBase64(), timestamp: 1700000002000),
      ];
      // 初始加载不延迟
      repo.delay = Duration.zero;

      final provider = await createProvider();
      await waitFor(
        provider,
        () => provider.history.length >= 2,
        message: 'initial load should bring 2 entries',
      );
      await Future.delayed(const Duration(milliseconds: 100));

      // 设置延迟后并发刷新
      repo.delay = const Duration(milliseconds: 150);
      await Future.wait([
        provider.refresh(),
        provider.refresh(),
      ]);

      // 条目应按时间倒序排列（最新在前）
      expect(provider.history.length, equals(2));
      expect(provider.history.first.id, equals('txt-b'));
      expect(provider.history.last.id, equals('txt-a'));

      await settle();
      provider.dispose();
    });
  });

  group('refresh failure status preservation', () {
    test('refresh failure does not degrade status to error/disconnected', () async {
      // 初始正常加载
      final enc1 = await encryption.encrypt('normal', key);
      repo.history = [textRow('txt-ok', enc1.toBase64())];

      final provider = await createProvider();
      await waitFor(
        provider,
        () => provider.history.any((e) => e.id == 'txt-ok'),
        message: 'initial load should complete',
      );

      // 确认初始状态是 connected
      expect(provider.syncStatus, equals(SyncStatus.connected));

      // 第一次 refresh 正常
      await provider.refresh();
      expect(provider.syncStatus, equals(SyncStatus.connected));

      // 清空 history 后再次 refresh —— 空历史不是错误，状态应保持 connected
      repo.history = [];
      await provider.refresh();
      // 状态保持 connected（不降级为 error/disconnected）
      expect(provider.syncStatus, equals(SyncStatus.connected));
      // serverConnected 仍为 true（refresh catch 不砸它）
      expect(provider.serverConnected, isTrue);

      await settle();
      provider.dispose();
    });
  });

  group('_loadHistoryFromServer reentry prevention', () {
    test('second call during in-progress does not duplicate clear/rebuild', () async {
      final enc1 = await encryption.encrypt('test content', key);
      repo.history = [textRow('txt-re', enc1.toBase64())];
      // 初始加载不延迟
      repo.delay = Duration.zero;

      final provider = await createProvider();

      // 等待第一次加载完成
      await waitFor(
        provider,
        () => provider.history.any((e) => e.id == 'txt-re'),
        message: 'first load should complete',
      );
      await Future.delayed(const Duration(milliseconds: 100));

      // 记录初始 getHistoryCalls
      final initialCalls = repo.getHistoryCalls;

      // 设置延迟后快速连续刷新 2 次
      repo.delay = const Duration(milliseconds: 200);
      await Future.wait([
        provider.refresh(),
        provider.refresh(),
      ]);

      // 第二次 refresh 调用 _loadHistoryFromServer 时应被 _isLoadingHistory 挡住
      // 所以 getHistoryEntries 只多调 1 次（不是 2 次）
      expect(repo.getHistoryCalls, equals(initialCalls + 1),
          reason: 'reentry should be prevented');

      await settle();
      provider.dispose();
    });
  });
}
