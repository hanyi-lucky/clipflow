import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:clipflow/models/sync_operation.dart';
import 'package:clipflow/providers/clipboard_provider.dart';
import 'package:clipflow/repositories/outbox_store.dart';
import 'package:clipflow/providers/settings_provider.dart';
import 'package:clipflow/repositories/cloud_repository.dart';
import 'package:clipflow/repositories/local_image_store.dart';
import 'package:clipflow/repositories/local_storage.dart';
import 'package:clipflow/services/cloudbase_service.dart';
import 'package:clipflow/services/encryption_service.dart';
import 'package:clipflow/services/lan_sync_manager.dart';

/// 模拟服务器：可注入当前剪切板行，可让 fetch 抛错。
class _LanCloudRepo extends CloudRepository {
  _LanCloudRepo() : super(CloudBaseService());

  Map<String, dynamic>? currentClipboard;
  bool throwOnFetch = false;
  int downloadCalls = 0;
  int addHistoryEntryCalls = 0;
  int setCurrentClipboardCalls = 0;
  int uploadFileCalls = 0;

  @override
  Future<List<Map<String, dynamic>>> getHistoryEntries({int limit = 100}) async =>
      [];

  @override
  Future<Map<String, dynamic>?> getCurrentClipboardWithDeletions() async {
    downloadCalls++;
    if (throwOnFetch) {
      throw const SocketException('cloud down');
    }
    if (currentClipboard == null) return null;
    return {...currentClipboard!};
  }

  @override
  Future<Map<String, dynamic>?> getHistoryEntryContent(String entryId) async =>
      null;

  @override
  Future<void> deleteHistoryEntry(String entryId) async {}

  @override
  Future<void> updateHistoryEntry(
    String entryId,
    Map<String, dynamic> data,
  ) async {}

  @override
  Future<void> restoreHistoryEntry(String entryId) async {}

  @override
  Future<List<Map<String, dynamic>>> getTrashEntries() async => [];

  @override
  Future<String?> getSalt() async => null;

  @override
  Future<void> setSalt(String salt) async {}

  @override
  Future<void> setCurrentClipboard(Map<String, dynamic> data) async {
    setCurrentClipboardCalls++;
  }

  @override
  Future<void> addHistoryEntry(Map<String, dynamic> data) async {
    addHistoryEntryCalls++;
  }

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
    uploadFileCalls++;
  }
}

/// fake LanSyncManager：LAN 命中/未命中/禁用/推送全部由测试驱动。
class _FakeLanSyncManager extends LanSyncManager {
  _FakeLanSyncManager({this.disabled = false})
      : super(cloudRepository: CloudRepository(CloudBaseService()));

  final bool disabled;
  Map<String, dynamic>? lanRow;
  int startCalls = 0;
  int stopCalls = 0;
  int fetchCalls = 0;
  final List<SyncOperation> pushed = [];

  /// 真实握手态测试注入：驱动 Provider 状态派生（connected/localOnly）。
  bool hasVerifiedPeersValue = false;

  @override
  bool get hasVerifiedPeers => hasVerifiedPeersValue;

  /// 若设置，start() 会挂起等待该 gate（模拟真实 socket bind 的
  /// FakeAsync 下永不完成，用于验证 initialize 不阻塞）。
  Completer<void>? startGate;

  @override
  Future<void> start({
    required String userId,
    required String deviceId,
    required Uint8List accountKey,
    bool enabled = true,
  }) async {
    startCalls++;
    final gate = startGate;
    if (gate != null) {
      await gate.future;
    }
  }

  @override
  Future<Map<String, dynamic>?> fetchLatestContent() async {
    fetchCalls++;
    if (disabled) return null;
    return lanRow;
  }

  @override
  Future<void> pushOperation(SyncOperation op) async {
    pushed.add(op);
  }

  @override
  Future<void> stop() async {
    stopCalls++;
  }

  int clearPersistedCalls = 0;
  String? clearedUserId;

  @override
  Future<void> clearPersistedOutbox(String userId) async {
    clearPersistedCalls++;
    clearedUserId = userId;
  }
}

/// 内存 outbox：避免 resetAccountSync 触发 path_provider 真实通道。
class _MemoryOutbox implements OutboxStore {
  final List<SyncOperation> ops = [];

  @override
  Future<List<SyncOperation>> loadActive(String userId) async =>
      ops.where((o) => o.userId == userId && o.isActive).toList();

  @override
  Future<void> put(SyncOperation operation) async {
    ops.add(operation);
  }

  @override
  Future<void> update(SyncOperation operation) async {
    final i = ops.indexWhere((o) => o.operationId == operation.operationId);
    if (i >= 0) ops[i] = operation;
  }

  @override
  Future<SyncOperation?> findActiveByDedupeKey(
    String userId,
    SyncOperationKind kind,
    String dedupeKey,
  ) async {
    for (final o in ops) {
      if (o.userId == userId &&
          o.kind == kind &&
          o.dedupeKey == dedupeKey &&
          o.isActive) {
        return o;
      }
    }
    return null;
  }

  @override
  Future<void> remove(String userId, String operationId) async {
    ops.removeWhere(
      (o) => o.userId == userId && o.operationId == operationId,
    );
  }

  @override
  Future<List<String>> clearUser(String userId) async {
    ops.removeWhere((o) => o.userId == userId);
    return [];
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const password = 'lan-test';
  final salt = List<int>.generate(32, (i) => i % 256);

  late EncryptionService encryption;
  late Uint8List key;
  late _LanCloudRepo repo;
  late LocalStorage storage;
  late LocalImageStore imageStore;
  late Directory tempDir;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    encryption = EncryptionService();
    key = await encryption.deriveKey(password, salt);
    repo = _LanCloudRepo();
    storage = LocalStorage(await SharedPreferences.getInstance());
    tempDir = await Directory.systemTemp.createTemp('clipflow_lan_');
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
      'history_id': id,
      'content': contentBase64,
      'type': 'text',
      'source_device': 'device-a',
      'source_device_name': 'Mac A',
      'source_platform': 'macos',
      'timestamp': 1700000001000,
      'pinned': 0,
      '_deletedIds': <String>[],
      '_restoredEntries': <Map<String, dynamic>>[],
    };
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

  Future<void> settle() => Future.delayed(const Duration(milliseconds: 200));

  Future<ClipboardProvider> createProvider(
    _FakeLanSyncManager? lanManager,
  ) async {
    final provider = ClipboardProvider(
      imageStore: imageStore,
      outbox: _MemoryOutbox(),
      lanSyncManager: lanManager,
    );
    await provider.initialize(
      storage: storage,
      cloudRepo: repo,
      deviceId: 'device-test',
      deviceName: 'Test Mac',
      encryptionKey: key,
    );
    return provider;
  }

  group('ClipboardProvider LAN-first download', () {
    test('LAN 命中 → 内容应用且 Cloud 重复行被游标过滤（历史仅一条）', () async {
      final textEnc = await encryption.encrypt('lan delivered', key);
      final row = textRow('lan-1', textEnc.toBase64());
      final lanManager = _FakeLanSyncManager();

      final provider = await createProvider(lanManager);
      await settle();
      provider.stopSync();

      // 首轮同步完成后注入：LAN 与 Cloud 返回同一行
      lanManager.lanRow = row;
      repo.currentClipboard = row;

      await provider.triggerSync();

      await waitFor(
        provider,
        () => provider.history.any((e) => e.content == 'lan delivered'),
        message: 'LAN row should be applied exactly once',
      );
      expect(lanManager.fetchCalls, greaterThanOrEqualTo(1));
      expect(
        provider.history.where((e) => e.content == 'lan delivered'),
        hasLength(1),
      );
    });

    test('LAN 未命中 → 走 Cloud 权威', () async {
      final textEnc = await encryption.encrypt('cloud delivered', key);
      final lanManager = _FakeLanSyncManager(); // lanRow = null

      final provider = await createProvider(lanManager);
      await settle();
      provider.stopSync();

      repo.currentClipboard = textRow('cloud-1', textEnc.toBase64());
      final cloudCallsBefore = repo.downloadCalls;

      await provider.triggerSync();

      await waitFor(
        provider,
        () => provider.history.any((e) => e.content == 'cloud delivered'),
        message: 'cloud row should be applied when LAN misses',
      );
      expect(repo.downloadCalls, greaterThan(cloudCallsBefore));
      expect(
        provider.history.where((e) => e.content == 'cloud delivered'),
        hasLength(1),
      );
    });

    test('LAN 交付 + Cloud 抛错 → 保持 connected、consecutiveFailures 不增', () async {
      final lanManager = _FakeLanSyncManager();
      final provider = await createProvider(lanManager);
      await settle(); // 首轮 Cloud 成功（空内容）→ serverConnected=true
      expect(provider.serverConnected, isTrue);
      expect(provider.consecutiveFailures, 0);

      final textEnc = await encryption.encrypt('lan rescue', key);
      lanManager.lanRow = textRow('lan-2', textEnc.toBase64());
      repo.throwOnFetch = true;
      provider.stopSync();

      await provider.triggerSync();

      await waitFor(
        provider,
        () => provider.history.any((e) => e.content == 'lan rescue'),
        message: 'LAN content should be delivered even if cloud fails',
      );
      // Cloud 抛错但内容已由 LAN 送达：不计数、保持 connected
      expect(provider.serverConnected, isTrue);
      expect(provider.consecutiveFailures, 0);
    });
  });

  group('ClipboardProvider LAN disabled equivalence', () {
    test('权限缺失（manager disabled）→ 纯 Cloud 行为与现有（null manager）等价', () async {
      final textEnc = await encryption.encrypt('cloud only', key);
      repo.currentClipboard = textRow('cloud-only', textEnc.toBase64());

      // 对照组：lanAcceleration=false → _lanManager 恒为 null（现有行为锚点）
      final settings = SettingsProvider();
      await settings.initialize(storage);
      await settings.setLanAcceleration(false);
      final controlProvider = ClipboardProvider(
        imageStore: imageStore,
        outbox: _MemoryOutbox(),
      );
      controlProvider.setSettingsProvider(settings);
      await controlProvider.initialize(
        storage: storage,
        cloudRepo: repo,
        deviceId: 'device-test',
        deviceName: 'Test Mac',
        encryptionKey: key,
      );

      // 实验组：LAN manager 存在但 disabled（权限缺失降级）
      final lanManager = _FakeLanSyncManager(disabled: true);
      final lanProvider = await createProvider(lanManager);
      await settle();
      controlProvider.stopSync();
      lanProvider.stopSync();
      await controlProvider.triggerSync();
      await lanProvider.triggerSync();

      await waitFor(
        lanProvider,
        () => lanProvider.history.any((e) => e.content == 'cloud only'),
        message: 'disabled LAN should behave exactly like cloud-only',
      );
      expect(
        controlProvider.history.map((e) => e.content).toList(),
        lanProvider.history.map((e) => e.content).toList(),
      );
      expect(lanManager.fetchCalls, greaterThanOrEqualTo(1));
    });
  });

  group('ClipboardProvider initialize 非阻塞（FakeAsync 回归）', () {
    testWidgets('LAN start 未完成时 initialize 及时返回，不阻塞解锁', (tester) async {
      final lanManager = _FakeLanSyncManager()
        ..startGate = Completer<void>(); // start 永不完成，等价真实 socket bind
      final settings = SettingsProvider();
      await settings.setBackgroundSync(false);
      await settings.setNotificationSync(false);

      final provider = ClipboardProvider(
        imageStore: imageStore,
        outbox: _MemoryOutbox(),
        lanSyncManager: lanManager,
      );
      provider.setSettingsProvider(settings);

      var initReturned = false;
      provider
          .initialize(
            storage: storage,
            cloudRepo: repo,
            deviceId: 'device-test',
            deviceName: 'Test Mac',
            encryptionKey: key,
          )
          .then((_) {
            initReturned = true;
          });

      // FakeAsync 下只泵微任务，不推进真实网络 I/O；
      // 若 initialize 错误地 await 了 _startLanManager，此处不会返回。
      try {
        await tester.pump();
        await tester.pump();
        expect(
          initReturned,
          isTrue,
          reason: 'initialize 不应阻塞在 LAN start 上'
              '（回归：await _startLanManager 在 FakeAsync 下挂起）',
        );
      } finally {
        provider.dispose();
      }
      expect(lanManager.startCalls, 1);
    });
  });

  group('ClipboardProvider LAN push lifecycle', () {
    test('push 回调触发 _performDownload（LAN 命中即交付）', () async {
      final lanManager = _FakeLanSyncManager();

      final provider = await createProvider(lanManager);
      await settle();
      provider.stopSync();

      // Provider 已注册 onPushReceived；收到 push 帧 → 立即下载
      expect(lanManager.onPushReceived, isNotNull);
      final textEnc = await encryption.encrypt('pushed over lan', key);
      lanManager.lanRow = textRow('push-1', textEnc.toBase64());
      final fetchBefore = lanManager.fetchCalls;

      lanManager.onPushReceived?.call();

      await waitFor(
        provider,
        () => provider.history.any((e) => e.content == 'pushed over lan'),
        message: 'push callback should trigger an immediate download',
      );
      expect(lanManager.fetchCalls, greaterThan(fetchBefore));
    });

    test('initialize 启动 LAN；resetAccountSync 与 dispose 停止', () async {
      final lanManager = _FakeLanSyncManager();
      final provider = await createProvider(lanManager);
      expect(lanManager.startCalls, 1);
      expect(lanManager.stopCalls, 0);

      await provider.resetAccountSync();
      expect(lanManager.stopCalls, 1);
      // 切账户同时清理持久化 LAN outbox（旧账户 userId）
      expect(lanManager.clearPersistedCalls, 1);
      expect(lanManager.clearedUserId, 'user_device-test');

      // dispose 后再 stop 一次不抛（幂等）
      final lanManager2 = _FakeLanSyncManager();
      final provider2 = await createProvider(lanManager2);
      provider2.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(lanManager2.stopCalls, greaterThanOrEqualTo(1));
    });
  });

  group('ClipboardProvider LAN-only mode', () {
    Future<void> mockClipboardText(String text, {bool armed = true}) async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.getData') {
              return <String, Object?>{'text': armed ? text : null};
            }
            return null;
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null);
      });
    }

    test('开启后文本走 LAN（pushed op）、Cloud 零写、无 peer → localOnly + lanOnlyDegraded', () async {
      final lanManager = _FakeLanSyncManager(); // hasVerifiedPeersValue = false
      final provider = await createProvider(lanManager);
      await settle();
      provider.stopSync();

      await provider.setLanOnlyMode(true);
      expect(provider.lanOnlyMode, isTrue);
      expect(provider.lanOnlyDegraded, isTrue);

      await mockClipboardText('lan only text');
      await provider.debugFileCheck();

      await waitFor(
        provider,
        () => lanManager.pushed.any((o) => o.kind == SyncOperationKind.text),
        message: 'text should be pushed to LAN manager',
      );
      expect(repo.addHistoryEntryCalls, 0);
      expect(repo.setCurrentClipboardCalls, 0);
      // durable-local：无 peer 也保留本地历史
      await waitFor(
        provider,
        () => provider.history.any((e) => e.content == 'lan only text'),
        message: 'text should be kept in local history',
      );
      expect(provider.syncStatus, SyncStatus.localOnly);
    });

    test('开启后文本推送到 LAN 且存在 verified peer → connected（非模拟）', () async {
      final lanManager = _FakeLanSyncManager()..hasVerifiedPeersValue = true;
      final provider = await createProvider(lanManager);
      await settle();
      provider.stopSync();

      await provider.setLanOnlyMode(true);
      expect(provider.lanOnlyDegraded, isFalse);
      expect(provider.syncStatus, SyncStatus.connected);

      await mockClipboardText('lan with peer');
      await provider.debugFileCheck();

      await waitFor(
        provider,
        () => lanManager.pushed.any((o) => o.kind == SyncOperationKind.text),
        message: 'text should be pushed to LAN manager',
      );
      expect(repo.addHistoryEntryCalls, 0);
      expect(provider.syncStatus, SyncStatus.connected);
    });

    test('关闭后文本恢复 Cloud 权威（回归锚点：与未开一致）', () async {
      final lanManager = _FakeLanSyncManager();
      final provider = await createProvider(lanManager);
      await settle();
      provider.stopSync();

      await provider.setLanOnlyMode(true);
      expect(provider.lanOnlyMode, isTrue);
      await provider.setLanOnlyMode(false);
      expect(provider.lanOnlyMode, isFalse);
      expect(provider.lanOnlyDegraded, isFalse);

      await mockClipboardText('cloud again');
      await provider.debugFileCheck();

      await waitFor(
        provider,
        () => repo.addHistoryEntryCalls > 0,
        message: 'text should go to Cloud after lanOnly is off',
      );
      // Cloud 成功后的 LAN 接力推送属 lanAcceleration 既有行为（加速旁路），
      // 关闭 lanOnly 的回归锚点是「Cloud 权威写入恢复」，此处只断言 repo 写入。
      await waitFor(
        provider,
        () => provider.history.any((e) => e.content == 'cloud again'),
        message: 'cloud text should be in history',
      );
    });

    test('降级状态：peer 出现 → lanOnlyDegraded 清除并回 connected；消失 → 恢复 localOnly', () async {
      final lanManager = _FakeLanSyncManager();
      final provider = await createProvider(lanManager);
      await settle();
      provider.stopSync();

      await provider.setLanOnlyMode(true);
      expect(provider.lanOnlyDegraded, isTrue);
      expect(provider.lanOnlyUnsyncedAt, isNotNull);

      // peer 出现：下个 tick 状态派生回 connected
      lanManager.hasVerifiedPeersValue = true;
      await provider.triggerSync();
      expect(provider.syncStatus, SyncStatus.connected);
      expect(provider.lanOnlyDegraded, isFalse);
      expect(provider.lanOnlyUnsyncedAt, isNull);

      // peer 消失：回到 localOnly
      lanManager.hasVerifiedPeersValue = false;
      await provider.triggerSync();
      expect(provider.syncStatus, SyncStatus.localOnly);
      expect(provider.lanOnlyDegraded, isTrue);
      expect(provider.lanOnlyUnsyncedAt, isNotNull);
    });

    test('重启恢复：LAN-only 文本本地历史在 provider 重建后保留（同 storage、Cloud 空历史）', () async {
      final lanManager = _FakeLanSyncManager();
      final provider = await createProvider(lanManager);
      await settle();
      provider.stopSync();

      await provider.setLanOnlyMode(true);
      await mockClipboardText('restart survives text');
      await provider.debugFileCheck();

      await waitFor(
        provider,
        () => provider.history.any((e) => e.content == 'restart survives text'),
        message: 'text should be in local history before restart',
      );
      // dispose 触发未落盘历史立即写入 storage（模拟退出）
      provider.dispose();
      await settle();

      // 重建 provider（同 storage、空服务器历史）：LAN-only 本地条目应恢复
      final restarted = await createProvider(_FakeLanSyncManager());
      await settle();

      expect(
        restarted.history.any((e) => e.content == 'restart survives text'),
        isTrue,
        reason: 'LAN-only 本地历史应在重启后从持久化 JSON 恢复',
      );
      restarted.dispose();
    });
  });
}
