import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:clipflow/providers/clipboard_provider.dart';
import 'package:clipflow/repositories/cloud_repository.dart';
import 'package:clipflow/repositories/local_image_store.dart';
import 'package:clipflow/repositories/local_storage.dart';
import 'package:clipflow/services/cloudbase_service.dart';
import 'package:clipflow/services/encryption_service.dart';

/// 模拟服务器（可注入当前剪切板行），用于验证「打开并同步」的 triggerSync 下载路径。
class OpenSyncRepo extends CloudRepository {

  @override
  Future<Map<String, dynamic>?> getSyncChanges({required int after, int? limit}) async => null;
  OpenSyncRepo() : super(CloudBaseService());

  List<Map<String, dynamic>> history = [];
  Map<String, dynamic>? currentClipboard;

  /// 下载调用计数，用于验证并发窗口内不会触发第二次下载。
  int downloadCalls = 0;

  /// 可选门控：非 null 时挂起下载，直到该 Completer 完成。
  Completer<void>? downloadGate;

  @override
  Future<List<Map<String, dynamic>>> getHistoryEntries({int limit = 100}) async =>
      history;

  @override
  Future<Map<String, dynamic>?> getCurrentClipboardWithDeletions() async {
    downloadCalls++;
    final gate = downloadGate;
    if (gate != null) {
      await gate.future;
    }
    if (currentClipboard == null) return null;
    return {...currentClipboard!};
  }

  @override
  Future<Map<String, dynamic>?> getHistoryEntryContent(String entryId) async => null;

  @override
  Future<void> deleteHistoryEntry(String entryId) async {}

  @override
  Future<void> updateHistoryEntry(String entryId, Map<String, dynamic> data) async {}

  @override
  Future<void> restoreHistoryEntry(String entryId) async {}

  @override
  Future<List<Map<String, dynamic>>> getTrashEntries() async => [];

  @override
  Future<String?> getSalt() async => null;

  @override
  Future<void> setSalt(String salt) async {}

  @override
  Future<void> setCurrentClipboard(Map<String, dynamic> data) async {}

  @override
  Future<void> addHistoryEntry(Map<String, dynamic> data) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const password = 'open-sync-test';
  final salt = List<int>.generate(32, (i) => i % 256);

  late EncryptionService encryption;
  late Uint8List key;
  late OpenSyncRepo repo;
  late LocalStorage storage;
  late LocalImageStore imageStore;
  late Directory tempDir;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    encryption = EncryptionService();
    key = await encryption.deriveKey(password, salt);
    repo = OpenSyncRepo();
    storage = LocalStorage(await SharedPreferences.getInstance());
    tempDir = await Directory.systemTemp.createTemp('clipflow_open_sync_');
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

  group('triggerSync (notification "open and sync")', () {
    test('轮询停止后 triggerSync 补一次下载，另一设备内容进入历史', () async {
      final textEnc = await encryption.encrypt('from other device', key);

      final provider = await createProvider();
      await settle(); // 让后台历史加载与首轮同步完成
      provider.stopSync(); // 模拟「后台自动同步」关闭：轮询停止
      repo.currentClipboard = textRow('row-1', textEnc.toBase64());

      await provider.triggerSync();

      await waitFor(
        provider,
        () => provider.history.any((e) => e.content == 'from other device'),
        message: 'triggerSync should download the injected row once',
      );
      expect(
        provider.history.where((e) => e.content == 'from other device'),
        hasLength(1),
      );
    });

    test('轮询运行时 triggerSync 不重复下载，历史无重复条目', () async {
      final textEnc = await encryption.encrypt('polling content', key);
      repo.currentClipboard = textRow('row-1', textEnc.toBase64());

      final provider = await createProvider();
      await waitFor(
        provider,
        () => provider.history.any((e) => e.content == 'polling content'),
        message: 'initial poll should download once',
      );

      await provider.triggerSync();
      await settle();

      expect(
        provider.history.where((e) => e.content == 'polling content'),
        hasLength(1),
      );
    });

    test('在途下载未完成时第二次 triggerSync 不并发第二次下载', () async {
      final textEnc = await encryption.encrypt('single download', key);
      repo.currentClipboard = textRow('row-1', textEnc.toBase64());

      final provider = await createProvider();
      await settle(); // 让后台历史加载与首轮同步完成
      provider.stopSync(); // 模拟「后台自动同步」关闭：轮询停止
      repo.downloadCalls = 0; // 排除首轮同步的计数，只统计 triggerSync 触发的下载
      repo.downloadGate = Completer<void>();

      // 第一次 triggerSync 进入在途，挂起在门控上
      final firstSync = provider.triggerSync();
      await waitFor(
        provider,
        () => repo.downloadCalls == 1,
        message: 'first triggerSync should enter in-flight download',
      );

      // 第二次 triggerSync 应立即返回，不触发第二次下载
      provider.triggerSync();
      await settle();
      expect(repo.downloadCalls, 1);

      // 放行门控，内容正常进入历史，全程只下载一次
      repo.downloadGate!.complete();
      await firstSync;
      await waitFor(
        provider,
        () => provider.history.any((e) => e.content == 'single download'),
        message: 'gated download should complete after release',
      );
      expect(repo.downloadCalls, 1);
      expect(
        provider.history.where((e) => e.content == 'single download'),
        hasLength(1),
      );
    });
  });
}
