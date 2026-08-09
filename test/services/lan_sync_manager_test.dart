import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:clipflow/core/constants.dart';
import 'package:clipflow/models/sync_operation.dart';
import 'package:clipflow/repositories/cloud_repository.dart';
import 'package:clipflow/repositories/local_file_store.dart';
import 'package:clipflow/repositories/lan_outbox_store.dart';
import 'package:clipflow/services/lan_diagnostics.dart';
import 'package:clipflow/services/cloudbase_service.dart';
import 'package:clipflow/services/lan_discovery_service.dart';
import 'package:clipflow/services/lan_handshake_service.dart';
import 'package:clipflow/services/lan_network_channel.dart';
import 'package:clipflow/services/lan_sync_manager.dart';
import 'package:clipflow/services/lan_transport.dart';

/// 可控时钟：测试过期/黑名单冷却用。
class _MutableClock {
  DateTime now = DateTime.fromMillisecondsSinceEpoch(1_700_000_000_000);
}

/// 可控 discovery fake：candidates 由测试直接注入。
class _FakeDiscovery extends LanDiscoveryService {
  _FakeDiscovery() : super(channel: LanNetworkChannel());

  bool startCalled = false;
  bool startResult = true;
  Object? startError;
  String? startDeviceId;
  String? startCaps;
  int? startPort;
  int stopCalls = 0;
  final List<String> rejected = [];
  List<LanPeer> candidatesResult = [];

  @override
  Future<bool> start({
    required String deviceId,
    required String caps,
    required int port,
  }) async {
    startCalled = true;
    startDeviceId = deviceId;
    startCaps = caps;
    startPort = port;
    final error = startError;
    if (error != null) {
      throw error;
    }
    return startResult;
  }

  @override
  Future<void> stop() async {
    stopCalls++;
  }

  @override
  List<LanPeer> get candidates => candidatesResult;

  @override
  void markHandshakeRejected(String deviceId) {
    rejected.add(deviceId);
  }
}

/// 可控 transport fake：连接/推送/拉取全部由测试驱动。
class _FakeTransport extends LanTransport {
  _FakeTransport() : super(handshakeService: _NoopHandshake());

  int startServerCalls = 0;
  final List<String> connected = [];
  final List<String> connectAttempts = [];
  Object? connectError;
  bool connectResult = true;
  int closeCalls = 0;
  final Set<String> sessions = {};
  final List<String> pushedTo = [];
  final List<Map<String, dynamic>> pushedRows = [];
  final List<String> dropped = [];
  final Map<String, Future<Map<String, dynamic>?>> fetchResults = {};
  int fetchCalls = 0;

  @override
  Future<int> startServer({
    required String deviceId,
    required String userId,
    required Uint8List accountKey,
  }) async {
    startServerCalls++;
    return 45678;
  }

  @override
  Future<void> connect({
    required String peerDeviceId,
    required String host,
    required int port,
    required String userId,
    required String deviceId,
    required Uint8List accountKey,
  }) async {
    connectAttempts.add(peerDeviceId);
    final error = connectError;
    if (error != null) throw error;
    if (!connectResult) return;
    sessions.add(peerDeviceId);
    connected.add(peerDeviceId);
  }

  @override
  bool hasSession(String peerDeviceId) => sessions.contains(peerDeviceId);

  @override
  List<String> get verifiedPeerIds => sessions.toList();

  @override
  Future<Map<String, dynamic>?> fetchLatest(String peerDeviceId) async {
    fetchCalls++;
    return fetchResults[peerDeviceId] ?? Future.value(null);
  }

  LanPushResult pushResult = LanPushResult.delivered;
  LanPushResult pushFileResult = LanPushResult.delivered;
  bool peerSupportsAcksResult = false;

  @override
  bool supportsAcks(String peerDeviceId) => peerSupportsAcksResult;

  @override
  Future<LanPushResult> push(String peerDeviceId, Map<String, dynamic> row) async {
    pushedTo.add(peerDeviceId);
    pushedRows.add(row);
    return pushResult;
  }

  final List<String> pushedFilesTo = [];
  final List<Map<String, dynamic>> pushedFileRows = [];
  final List<String> pushedFilePaths = [];
  final List<int> pushedFileSizes = [];

  @override
  Future<LanPushResult> pushFile(
    String peerDeviceId,
    Map<String, dynamic> row, {
    required String encryptedPath,
    required int encSize,
  }) async {
    pushedFilesTo.add(peerDeviceId);
    pushedFileRows.add(row);
    pushedFilePaths.add(encryptedPath);
    pushedFileSizes.add(encSize);
    return pushFileResult;
  }

  @override
  void dropSession(String peerDeviceId) {
    dropped.add(peerDeviceId);
    sessions.remove(peerDeviceId);
  }

  @override
  Future<void> closeAll() async {
    closeCalls++;
    sessions.clear();
  }
}

/// 握手服务最小替身：transport fake 不会真正执行握手。
class _NoopHandshake extends LanHandshakeService {
  _NoopHandshake() : super(cloudRepository: CloudRepository(CloudBaseService()));
}

LanPeer _peer(String deviceId, {int port = 10000, DateTime? seen}) {
  return LanPeer(
    deviceId: deviceId,
    host: '192.168.1.10',
    port: port,
    lastSeenAt: seen ?? DateTime.fromMillisecondsSinceEpoch(1_700_000_000_000),
  );
}

SyncOperation _fileOp({
  required String operationId,
  required String artifactId,
  required String encFileName,
  required int fileSize,
  String sourceDevice = 'device-a',
  int timestamp = 1,
}) {
  return SyncOperation(
    operationId: operationId,
    userId: 'user_test',
    kind: SyncOperationKind.file,
    state: SyncOperationState.sending,
    dedupeKey: 'file:h-$operationId',
    createdAtMs: 1,
    updatedAtMs: 1,
    attemptCount: 0,
    nextAttemptAtMs: 1,
    payload: <String, dynamic>{
      'hash': 'h-$operationId',
      'encFileName': encFileName,
      'fileSize': fileSize,
      'marker': 'marker-$operationId',
      'sourceDevice': sourceDevice,
      'sourceDeviceName': 'Mac A',
      'sourcePlatform': 'macos',
      'timestamp': timestamp,
    },
    artifactId: artifactId,
  );
}

SyncOperation _textOp({
  required String operationId,
  required int timestamp,
}) {
  return SyncOperation(
    operationId: operationId,
    userId: 'user_test',
    kind: SyncOperationKind.text,
    state: SyncOperationState.sending,
    dedupeKey: 'hash-$operationId',
    createdAtMs: 1,
    updatedAtMs: 1,
    attemptCount: 0,
    nextAttemptAtMs: 1,
    payload: <String, dynamic>{
      'content': 'encrypted-$operationId',
      'hash': 'hash-$operationId',
      'sourceDevice': 'device-a',
      'sourceDeviceName': 'Mac A',
      'sourcePlatform': 'macos',
      'timestamp': timestamp,
      'type': 'text',
      'historyId': operationId,
    },
  );
}

void main() {
  late _MutableClock clock;
  late _FakeDiscovery discovery;
  late _FakeTransport transport;
  late Directory tempDir;
  late LocalFileStore fileStore;

  setUp(() async {
    clock = _MutableClock();
    discovery = _FakeDiscovery();
    transport = _FakeTransport();
    tempDir = await Directory.systemTemp.createTemp('lan_sync_manager_');
    fileStore = LocalFileStore(directoryPath: tempDir.path);
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  LanSyncManager createManager({
    Duration fetchTimeout = const Duration(milliseconds: 50),
    LocalFileStore? fileStoreOverride,
    LanOutboxStore? outboxStore,
    Duration? retrySweepInterval,
    Duration? retryBaseDelay,
  }) {
    return LanSyncManager(
      discovery: discovery,
      transport: transport,
      fetchTimeout: fetchTimeout,
      // 默认用 tempDir 版 fileStore，避免测试环境 path_provider 不可用。
      fileStore: fileStoreOverride ?? fileStore,
      outboxStore: outboxStore ?? LanOutboxStore(directoryPath: tempDir.path),
      retrySweepInterval: retrySweepInterval,
      retryBaseDelay: retryBaseDelay,
    );
  }

  Future<void> waitFor(
    Future<bool> Function() condition, {
    String? message,
  }) async {
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (DateTime.now().isBefore(deadline)) {
      if (await condition()) return;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    fail(message ?? 'condition not met within timeout');
  }

  Future<String> importArtifact(String entryId, List<int> bytes) async {
    final src = File('${tempDir.path}/src-$entryId.enc')..writeAsBytesSync(bytes);
    return fileStore.importEncryptedFile(entryId, src.path);
  }

  group('LanDiscoveryService', () {
    test('发现事件生成 peer 候选；协议版本不匹配进入黑名单冷却', () {
      final service = LanDiscoveryService(
        channel: LanNetworkChannel(),
        now: () => clock.now,
      );
      service.handleDiscoveryEvent(<String, dynamic>{
        'name': 'Mac-A',
        'host': '192.168.1.5',
        'port': 4000,
        'txt': <String, dynamic>{'proto': '1', 'device': 'dev-1', 'caps': 't/i'},
      });
      expect(service.candidates, hasLength(1));
      final peer = service.candidates.single;
      expect(peer.deviceId, 'dev-1');
      expect(peer.host, '192.168.1.5');
      expect(peer.port, 4000);
      expect(peer.capabilities, 't/i');

      // 版本不匹配 → 进入黑名单（不作为候选），合法 peer 不受影响
      service.handleDiscoveryEvent(<String, dynamic>{
        'name': 'Old',
        'host': '192.168.1.6',
        'port': 4001,
        'txt': <String, dynamic>{'proto': '0', 'device': 'dev-2', 'caps': 't'},
      });
      expect(
        service.candidates.map((e) => e.deviceId),
        isNot(contains('dev-2')),
      );
      expect(service.candidates, hasLength(1));
    });

    test('peer 超过 30s 未刷新即过期剔除', () {
      final service = LanDiscoveryService(
        channel: LanNetworkChannel(),
        now: () => clock.now,
      );
      service.handleDiscoveryEvent(<String, dynamic>{
        'name': 'Mac-A',
        'host': '192.168.1.5',
        'port': 4000,
        'txt': <String, dynamic>{'proto': '1', 'device': 'dev-1', 'caps': 't/i'},
      });
      clock.now = clock.now.add(const Duration(seconds: 31));
      expect(service.candidates, isEmpty);

      // 刷新 lastSeenAt 后重新可见
      service.handleDiscoveryEvent(<String, dynamic>{
        'name': 'Mac-A',
        'host': '192.168.1.5',
        'port': 4000,
        'txt': <String, dynamic>{'proto': '1', 'device': 'dev-1', 'caps': 't/i'},
      });
      expect(service.candidates, hasLength(1));
    });

    test('markHandshakeRejected 进入黑名单，冷却期内不作为候选', () {
      final service = LanDiscoveryService(
        channel: LanNetworkChannel(),
        now: () => clock.now,
      );
      Map<String, dynamic> event() => <String, dynamic>{
            'name': 'Mac-A',
            'host': '192.168.1.5',
            'port': 4000,
            'txt': <String, dynamic>{
              'proto': '1',
              'device': 'dev-1',
              'caps': 't/i',
            },
          };
      service.handleDiscoveryEvent(event());
      service.markHandshakeRejected('dev-1');
      expect(service.candidates, isEmpty);

      // 冷却期内刷新发现（lastSeenAt 保持新鲜），仍被黑名单排除
      clock.now = clock.now.add(const Duration(seconds: 30));
      service.handleDiscoveryEvent(event());
      expect(service.candidates, isEmpty);

      // 60s 冷却到期（t0+60 不早于 until），且 peer 未过期
      clock.now = clock.now.add(const Duration(seconds: 30));
      service.handleDiscoveryEvent(event());
      expect(service.candidates, hasLength(1));
    });
  });

  group('LanSyncManager.start', () {
    test('enabled:false 置为 disabled 且不抛', () async {
      final manager = createManager();
      await manager.start(
        userId: 'user_test',
        deviceId: 'device-a',
        accountKey: Uint8List(32),
        enabled: false,
      );
      expect(manager.isEnabled, isFalse);
      expect(discovery.startCalled, isFalse);
      expect(transport.startServerCalls, 0);
      // disabled 后 fetch/push 均为 no-op
      expect(await manager.fetchLatestContent(), isNull);
      await manager.pushOperation(_textOp(operationId: 'h1', timestamp: 1));
      expect(transport.pushedTo, isEmpty);
    });

    test('平台不支持（discovery.start=false）→ disabled 不抛', () async {
      discovery.startResult = false;
      final manager = createManager();
      await manager.start(
        userId: 'user_test',
        deviceId: 'device-a',
        accountKey: Uint8List(32),
      );
      expect(manager.isEnabled, isFalse);
      expect(await manager.fetchLatestContent(), isNull);
    });

    test('permissionDenied → disabled 不抛', () async {
      discovery.startError = LanNetworkException(
        'permissionDenied',
        'NEARBY_WIFI_DEVICES denied',
      );
      final manager = createManager();
      await manager.start(
        userId: 'user_test',
        deviceId: 'device-a',
        accountKey: Uint8List(32),
      );
      expect(manager.isEnabled, isFalse);
      expect(await manager.fetchLatestContent(), isNull);
    });

    test('start 成功后按 deviceId/caps/port 发起广播', () async {
      final manager = createManager();
      final key = Uint8List.fromList(List<int>.generate(32, (i) => i));
      await manager.start(
        userId: 'user_test',
        deviceId: 'device-a',
        accountKey: key,
      );
      expect(manager.isEnabled, isTrue);
      expect(transport.startServerCalls, 1);
      expect(discovery.startCalled, isTrue);
      expect(discovery.startDeviceId, 'device-a');
      expect(discovery.startCaps, 't/i/f');
      expect(discovery.startPort, 45678);
    });
  });

  group('LanSyncManager.fetchLatestContent', () {
    test('无候选/无 verified peer → null', () async {
      final manager = createManager();
      await manager.start(
        userId: 'user_test',
        deviceId: 'device-a',
        accountKey: Uint8List(32),
      );
      expect(await manager.fetchLatestContent(), isNull);
    });

    test('最多连接 4 个 peer 并 round-robin 拉取，命中后返回 row', () async {
      discovery.candidatesResult = List<LanPeer>.generate(
        5,
        (i) => _peer('peer-$i', port: 10000 + i),
      );
      final manager = createManager();
      await manager.start(
        userId: 'user_test',
        deviceId: 'device-a',
        accountKey: Uint8List(32),
      );
      // 只有 peer-3 有 row
      transport.fetchResults['peer-3'] = Future.value(<String, dynamic>{
        'history_id': 'h-3',
        'type': 'text',
        'content': 'enc',
        'source_device': 'peer-3',
        'source_device_name': 'Peer 3',
        'source_platform': 'macos',
        'timestamp': 3000,
        '_deletedIds': <String>[],
        '_restoredEntries': <Map<String, dynamic>>[],
      });

      final row = await manager.fetchLatestContent();

      expect(row, isNotNull);
      expect(row!['history_id'], 'h-3');
      // 最多连接 4 个（maxVerifiedPeers），第 5 个不被连接
      expect(transport.connectAttempts.length, 4);
      expect(transport.connectAttempts, isNot(contains('peer-4')));
      // round-robin 覆盖全部已连接 peer
      expect(transport.fetchCalls, greaterThanOrEqualTo(1));
      // 返回的 LAN 行恒带空删除/恢复数组
      expect(row['_deletedIds'], isEmpty);
      expect(row['_restoredEntries'], isEmpty);
    });

    test('fetch 超时（300ms 上限）→ 丢弃该会话并继续下一个 peer', () async {
      discovery.candidatesResult = [_peer('peer-slow'), _peer('peer-fast')];
      final manager = createManager(fetchTimeout: const Duration(milliseconds: 30));
      await manager.start(
        userId: 'user_test',
        deviceId: 'device-a',
        accountKey: Uint8List(32),
      );
      // peer-slow 永不返回
      final never = Completer<Map<String, dynamic>?>();
      transport.fetchResults['peer-slow'] = never.future;
      transport.fetchResults['peer-fast'] = Future.value(<String, dynamic>{
        'history_id': 'h-fast',
        'type': 'text',
        'content': 'enc',
        'source_device': 'peer-fast',
        'source_device_name': 'Peer Fast',
        'source_platform': 'macos',
        'timestamp': 100,
        '_deletedIds': <String>[],
        '_restoredEntries': <Map<String, dynamic>>[],
      });

      final sw = Stopwatch()..start();
      final row = await manager.fetchLatestContent();
      sw.stop();

      expect(row, isNotNull);
      expect(row!['history_id'], 'h-fast');
      // 慢 peer 被超时丢弃（会话清理），总耗时受 300ms 上限约束
      expect(transport.dropped, contains('peer-slow'));
      expect(sw.elapsedMilliseconds, lessThan(300));
      never.complete(null);
    });

    test('已见过的 historyId（同 row 重复 fetch）不再返回', () async {
      discovery.candidatesResult = [_peer('peer-a'), _peer('peer-b')];
      final manager = createManager();
      await manager.start(
        userId: 'user_test',
        deviceId: 'device-a',
        accountKey: Uint8List(32),
      );
      final rowA = <String, dynamic>{
        'history_id': 'h-same',
        'type': 'text',
        'content': 'enc',
        'source_device': 'peer-a',
        'source_device_name': 'Peer A',
        'source_platform': 'macos',
        'timestamp': 100,
        '_deletedIds': <String>[],
        '_restoredEntries': <Map<String, dynamic>>[],
      };
      transport.fetchResults['peer-a'] = Future.value(rowA);
      transport.fetchResults['peer-b'] = Future.value(rowA);

      final first = await manager.fetchLatestContent();
      expect(first, isNotNull);
      final second = await manager.fetchLatestContent();
      // 两个 peer 都返回同一 row：第二次因 historyId 去重返回 null
      expect(second, isNull);
    });
  });

  group('LanSyncManager.pushOperation', () {
    test('text/image 才推送；file 缺 fileSize/artifact 不推送', () async {
      discovery.candidatesResult = [_peer('peer-b')];
      final manager = createManager();
      await manager.start(
        userId: 'user_test',
        deviceId: 'device-a',
        accountKey: Uint8List(32),
      );
      final fileOp = SyncOperation(
        operationId: 'f1',
        userId: 'user_test',
        kind: SyncOperationKind.file,
        state: SyncOperationState.sending,
        dedupeKey: 'file:h',
        createdAtMs: 1,
        updatedAtMs: 1,
        attemptCount: 0,
        nextAttemptAtMs: 1,
        payload: <String, dynamic>{'hash': 'h'},
      );
      await manager.pushOperation(fileOp);
      expect(transport.pushedTo, isEmpty);
      expect(transport.pushedFilesTo, isEmpty);
      await manager.pushOperation(_textOp(operationId: 't1', timestamp: 1));
      expect(transport.pushedTo, hasLength(1));
    });

    test('不向来源设备回推（peer.deviceId == source_device 跳过）', () async {
      discovery.candidatesResult = [_peer('device-a'), _peer('device-c')];
      final manager = createManager();
      await manager.start(
        userId: 'user_test',
        deviceId: 'device-a',
        accountKey: Uint8List(32),
      );
      await manager.pushOperation(_textOp(operationId: 't1', timestamp: 1));
      // source_device 是 device-a：peer-a(device-a) 被跳过，只推给 device-c
      expect(transport.pushedTo, ['device-c']);
    });

    test('同 historyId 二次 push 去重，不覆盖新 row 缓存', () async {
      discovery.candidatesResult = [_peer('peer-b')];
      final manager = createManager();
      await manager.start(
        userId: 'user_test',
        deviceId: 'device-a',
        accountKey: Uint8List(32),
      );
      await manager.pushOperation(_textOp(operationId: 'h1', timestamp: 200));
      expect(transport.pushedTo, hasLength(1));
      expect(transport.latestRowProvider!()!['timestamp'], 200);

      // 同 historyId 但更旧时间戳：去重，不推送、不覆盖缓存
      await manager.pushOperation(_textOp(operationId: 'h1', timestamp: 100));
      expect(transport.pushedTo, hasLength(1));
      expect(transport.latestRowProvider!()!['timestamp'], 200);
    });

    test('push 行转 server-shape（snake_case + 空删除/恢复）', () async {
      discovery.candidatesResult = [_peer('peer-b')];
      final manager = createManager();
      await manager.start(
        userId: 'user_test',
        deviceId: 'device-a',
        accountKey: Uint8List(32),
      );
      await manager.pushOperation(_textOp(operationId: 't1', timestamp: 5));
      final row = transport.pushedRows.single;
      expect(row['history_id'], 't1');
      expect(row['source_device'], 'device-a');
      expect(row['source_device_name'], 'Mac A');
      expect(row['source_platform'], 'macos');
      expect(row['content'], 'encrypted-t1');
      expect(row['_deletedIds'], isEmpty);
      expect(row['_restoredEntries'], isEmpty);
      expect(row.containsKey('userId'), isFalse);
    });
  });

  group('LanSyncManager.push 接收 + stop 清理', () {
    test('收到 push 帧 → 去重 + 更新缓存 + 触发 onPushReceived', () async {
      final manager = createManager();
      await manager.start(
        userId: 'user_test',
        deviceId: 'device-a',
        accountKey: Uint8List(32),
      );
      var notifyCount = 0;
      manager.onPushReceived = () {
        notifyCount++;
      };
      final row = <String, dynamic>{
        'history_id': 'h-push',
        'type': 'text',
        'content': 'enc',
        'source_device': 'peer-b',
        'source_device_name': 'Peer B',
        'source_platform': 'macos',
        'timestamp': 42,
        '_deletedIds': <String>[],
        '_restoredEntries': <Map<String, dynamic>>[],
      };
      transport.onPushReceived?.call(row);
      expect(notifyCount, 1);
      // 推送后下一次 fetch 命中本机缓存（LAN 加速，不再走网络）
      expect(transport.latestRowProvider!()!['history_id'], 'h-push');
      final fetched = await manager.fetchLatestContent();
      expect(fetched, isNotNull);
      expect(fetched!['history_id'], 'h-push');

      // 重复 push 同 row → 不再通知
      transport.onPushReceived?.call(row);
      expect(notifyCount, 1);
    });

    test('stop 清理全部状态：缓存/去重集合/会话/广播', () async {
      discovery.candidatesResult = [_peer('peer-b')];
      final manager = createManager();
      await manager.start(
        userId: 'user_test',
        deviceId: 'device-a',
        accountKey: Uint8List(32),
      );
      await manager.pushOperation(_textOp(operationId: 'h1', timestamp: 1));
      expect(transport.pushedTo, hasLength(1));
      expect(transport.latestRowProvider!(), isNotNull);

      await manager.stop();

      expect(manager.isEnabled, isFalse);
      expect(discovery.stopCalls, 1);
      expect(transport.closeCalls, 1);
      expect(transport.latestRowProvider!(), isNull);
      expect(await manager.fetchLatestContent(), isNull);
      await manager.pushOperation(_textOp(operationId: 'h2', timestamp: 2));
      expect(transport.pushedTo, hasLength(1)); // stop 后不再推送
    });
  });

  group('LanSyncManager.pushOperation file', () {
    test('file ≤15MiB 且 artifact 存在 → pushFile 文件行（enc_file_name、无明文 file_name/mime_type）', () async {
      discovery.candidatesResult = [_peer('peer-b')];
      final manager = createManager(fileStoreOverride: fileStore);
      await manager.start(
        userId: 'user_test',
        deviceId: 'device-a',
        accountKey: Uint8List(32),
      );
      await importArtifact('f1', List<int>.filled(10, 1));

      await manager.pushOperation(_fileOp(
        operationId: 'f1',
        artifactId: 'f1',
        encFileName: 'enc-name-b64',
        fileSize: 1024,
      ));

      expect(transport.pushedFilesTo, ['peer-b']);
      expect(transport.pushedFilePaths.single, endsWith('f1.enc'));
      expect(transport.pushedFileSizes.single, 10);
      final row = transport.pushedFileRows.single;
      expect(row['history_id'], 'f1');
      expect(row['type'], 'file');
      expect(row['content'], 'marker-f1');
      expect(row['hash'], 'h-f1');
      expect(row['enc_file_name'], 'enc-name-b64');
      expect(row['file_size'], 1024);
      expect(row['source_device'], 'device-a');
      expect(row['source_device_name'], 'Mac A');
      expect(row['source_platform'], 'macos');
      expect(row['_deletedIds'], isEmpty);
      expect(row['_restoredEntries'], isEmpty);
      // 红线：LAN 行无明文 file_name / mime_type / userId
      expect(row.containsKey('file_name'), isFalse);
      expect(row.containsKey('mime_type'), isFalse);
      expect(row.containsKey('userId'), isFalse);
      // 本机缓存也更新为文件行（可应答 peers 的 latestRequest）
      expect(transport.latestRowProvider!()!['history_id'], 'f1');
    });

    test('file 明文 >15MiB → 跳过 LAN（Cloud-only）', () async {
      discovery.candidatesResult = [_peer('peer-b')];
      final manager = createManager(fileStoreOverride: fileStore);
      await manager.start(
        userId: 'user_test',
        deviceId: 'device-a',
        accountKey: Uint8List(32),
      );
      await importArtifact('big1', List<int>.filled(10, 1));

      await manager.pushOperation(_fileOp(
        operationId: 'big1',
        artifactId: 'big1',
        encFileName: 'enc',
        fileSize: LanConstants.lanMaxFileBytes + 1,
      ));

      expect(transport.pushedFilesTo, isEmpty);
      expect(transport.pushedTo, isEmpty);
    });

    test('file artifact 缺失 → 跳过 LAN', () async {
      discovery.candidatesResult = [_peer('peer-b')];
      final manager = createManager(fileStoreOverride: fileStore);
      await manager.start(
        userId: 'user_test',
        deviceId: 'device-a',
        accountKey: Uint8List(32),
      );

      await manager.pushOperation(_fileOp(
        operationId: 'noenc',
        artifactId: 'noenc',
        encFileName: 'enc',
        fileSize: 100,
      ));

      expect(transport.pushedFilesTo, isEmpty);
      expect(transport.pushedTo, isEmpty);
    });

    test('文件不回推来源设备（peer.deviceId == source_device 跳过）', () async {
      discovery.candidatesResult = [_peer('device-a'), _peer('peer-c')];
      final manager = createManager(fileStoreOverride: fileStore);
      await manager.start(
        userId: 'user_test',
        deviceId: 'device-a',
        accountKey: Uint8List(32),
      );
      await importArtifact('f2', List<int>.filled(5, 2));

      await manager.pushOperation(_fileOp(
        operationId: 'f2',
        artifactId: 'f2',
        encFileName: 'enc',
        fileSize: 100,
        sourceDevice: 'device-a',
      ));

      expect(transport.pushedFilesTo, ['peer-c']);
    });

    test('同 historyId 二次 file push 去重', () async {
      discovery.candidatesResult = [_peer('peer-b')];
      final manager = createManager(fileStoreOverride: fileStore);
      await manager.start(
        userId: 'user_test',
        deviceId: 'device-a',
        accountKey: Uint8List(32),
      );
      await importArtifact('f3', List<int>.filled(5, 3));

      await manager.pushOperation(_fileOp(
        operationId: 'f3',
        artifactId: 'f3',
        encFileName: 'enc',
        fileSize: 100,
      ));
      expect(transport.pushedFilesTo, hasLength(1));

      await manager.pushOperation(_fileOp(
        operationId: 'f3',
        artifactId: 'f3',
        encFileName: 'enc',
        fileSize: 100,
      ));
      expect(transport.pushedFilesTo, hasLength(1));
    });
  });

  group('LanSyncManager file push 接收', () {
    test('_handleFilePushReceived：.enc 落盘后触发 onPushReceived；重复 historyId 不重触发', () async {
      final manager = createManager(fileStoreOverride: fileStore);
      await manager.start(
        userId: 'user_test',
        deviceId: 'device-a',
        accountKey: Uint8List(32),
      );
      var notifyCount = 0;
      manager.onPushReceived = () {
        notifyCount++;
      };
      final row = <String, dynamic>{
        'history_id': 'h-file-push',
        'type': 'file',
        'content': 'marker',
        'hash': 'h',
        'enc_file_name': 'enc',
        'file_size': 10,
        'source_device': 'peer-b',
        'source_device_name': 'Peer B',
        'source_platform': 'macos',
        'timestamp': 42,
        '_deletedIds': <String>[],
        '_restoredEntries': <Map<String, dynamic>>[],
      };
      // 模拟 transport：.enc 已原子落盘后才回调
      final encPath = await importArtifact('h-file-push', List<int>.filled(4, 9));
      transport.onFilePushReceived?.call(row, encPath);

      expect(notifyCount, 1);
      // 缓存可应答 latestRequest + 下一次 fetch 命中本机缓存
      expect(transport.latestRowProvider!()!['history_id'], 'h-file-push');
      final fetched = await manager.fetchLatestContent();
      expect(fetched, isNotNull);
      expect(fetched!['history_id'], 'h-file-push');
      expect(fetched['_deletedIds'], isEmpty);
      expect(fetched['_restoredEntries'], isEmpty);

      // 重复 push 同 row → 不再通知
      transport.onFilePushReceived?.call(row, encPath);
      expect(notifyCount, 1);
    });

    test('未启动时收到文件 push → 忽略不触发', () async {
      final manager = createManager(fileStoreOverride: fileStore);
      var notifyCount = 0;
      manager.onPushReceived = () {
        notifyCount++;
      };
      final encPath = await importArtifact('h-off', List<int>.filled(4, 0));
      transport.onFilePushReceived?.call(<String, dynamic>{
        'history_id': 'h-off',
        'type': 'file',
        'content': 'marker',
        'enc_file_name': 'enc',
        'file_size': 10,
        'source_device': 'peer-b',
        'timestamp': 1,
        '_deletedIds': <String>[],
        '_restoredEntries': <Map<String, dynamic>>[],
      }, encPath);
      expect(notifyCount, 0);
      expect(await manager.fetchLatestContent(), isNull);
    });
  });

  group('LanSyncManager ACK / 待确认表 / 重试', () {
    test('旧 peer（无 acks）→ push 不落 outbox、无待确认', () async {
      discovery.candidatesResult = [_peer('peer-b')];
      final outbox = LanOutboxStore(directoryPath: tempDir.path);
      final manager = createManager(outboxStore: outbox);
      await manager.start(
        userId: 'user_test',
        deviceId: 'device-a',
        accountKey: Uint8List(32),
      );
      transport.peerSupportsAcksResult = false;
      transport.pushResult = LanPushResult.delivered;

      await manager.pushOperation(_textOp(operationId: 't-old', timestamp: 1));

      expect(transport.pushedTo, ['peer-b']);
      expect(await outbox.loadActive('user_test'), isEmpty);
      await manager.stop();
    });

    test('新 peer（acks）delivered → outbox 先持久化后删除', () async {
      discovery.candidatesResult = [_peer('peer-b')];
      final outbox = LanOutboxStore(directoryPath: tempDir.path);
      final manager = createManager(outboxStore: outbox);
      await manager.start(
        userId: 'user_test',
        deviceId: 'device-a',
        accountKey: Uint8List(32),
      );
      transport.peerSupportsAcksResult = true;
      transport.pushResult = LanPushResult.delivered;

      await manager.pushOperation(_textOp(operationId: 't-ack', timestamp: 1));

      expect(transport.pushedTo, ['peer-b']);
      // 最终无残留 outbox 条目（delivered → remove-on-ack）
      expect(await outbox.loadActive('user_test'), isEmpty);
      await manager.stop();
    });

    test('超时 pending → 重试绕过发送侧去重 → delivered 清 outbox', () async {
      discovery.candidatesResult = [_peer('peer-b')];
      final outbox = LanOutboxStore(directoryPath: tempDir.path);
      final manager = createManager(
        outboxStore: outbox,
        retrySweepInterval: const Duration(milliseconds: 30),
        retryBaseDelay: const Duration(milliseconds: 30),
      );
      await manager.start(
        userId: 'user_test',
        deviceId: 'device-a',
        accountKey: Uint8List(32),
      );
      transport.peerSupportsAcksResult = true;
      transport.pushResult = LanPushResult.pending;

      await manager.pushOperation(_textOp(operationId: 't-retry', timestamp: 1));
      expect(transport.pushedTo, hasLength(1));
      expect(await outbox.loadActive('user_test'), hasLength(1));

      // 重试发生：第二次 push 同 historyId（_knownHistoryIds 已登记也必须重推）
      transport.pushResult = LanPushResult.delivered;
      await waitFor(() async => (await outbox.loadActive('user_test')).isEmpty);
      expect(transport.pushedTo, hasLength(2));
      expect(transport.pushedRows.map((r) => r['history_id']), contains('t-retry'));
      await manager.stop();
    });

    test('pending 持续 → 重试耗尽（≤maxAttempts）→ give-up 删 outbox', () async {
      discovery.candidatesResult = [_peer('peer-b')];
      final outbox = LanOutboxStore(directoryPath: tempDir.path);
      final manager = createManager(
        outboxStore: outbox,
        retrySweepInterval: const Duration(milliseconds: 20),
        retryBaseDelay: const Duration(milliseconds: 20),
      );
      await manager.start(
        userId: 'user_test',
        deviceId: 'device-a',
        accountKey: Uint8List(32),
      );
      transport.peerSupportsAcksResult = true;
      transport.pushResult = LanPushResult.pending;

      await manager.pushOperation(_textOp(operationId: 't-giveup', timestamp: 1));

      await waitFor(() async => (await outbox.loadActive('user_test')).isEmpty);
      // 初始 1 + 重试 ≤ lanPushMaxAttempts 次；重试确实发生（>1）
      expect(transport.pushedTo.length, greaterThan(1));
      expect(
        transport.pushedTo.length,
        lessThanOrEqualTo(1 + LanConstants.lanPushMaxAttempts),
      );
      await manager.stop();
    });

    test('重启恢复：持久化 outbox 重新加载并重试；stop 不删持久化条目', () async {
      discovery.candidatesResult = [_peer('peer-b')];
      final outbox = LanOutboxStore(directoryPath: tempDir.path);
      final manager1 = createManager(
        outboxStore: outbox,
        retrySweepInterval: const Duration(milliseconds: 30),
        retryBaseDelay: const Duration(milliseconds: 30),
      );
      await manager1.start(
        userId: 'user_test',
        deviceId: 'device-a',
        accountKey: Uint8List(32),
      );
      transport.peerSupportsAcksResult = true;
      transport.pushResult = LanPushResult.pending;
      await manager1.pushOperation(_textOp(operationId: 't-restore', timestamp: 1));
      expect(await outbox.loadActive('user_test'), hasLength(1));

      await manager1.stop();
      // LAN 关闭/重启保留持久化 outbox（账户切换才 clearPersistedOutbox）
      expect(await outbox.loadActive('user_test'), hasLength(1));

      // 新 manager 模拟重启：start 恢复 outbox → 重试 → delivered → 删除
      transport.pushedTo.clear();
      transport.pushResult = LanPushResult.delivered;
      final manager2 = createManager(
        outboxStore: outbox,
        retrySweepInterval: const Duration(milliseconds: 30),
        retryBaseDelay: const Duration(milliseconds: 30),
      );
      await manager2.start(
        userId: 'user_test',
        deviceId: 'device-a',
        accountKey: Uint8List(32),
      );
      await waitFor(() async => (await outbox.loadActive('user_test')).isEmpty);
      expect(transport.pushedRows.map((r) => r['history_id']), contains('t-restore'));
      await manager2.stop();
    });

    test('恢复条目登记 _knownHistoryIds 防回声', () async {
      discovery.candidatesResult = [_peer('peer-b')];
      final outbox = LanOutboxStore(directoryPath: tempDir.path);
      await outbox.put(LanOutboxEntry(
        userId: 'user_test',
        peerId: 'peer-b',
        historyId: 't-echo',
        kind: 'text',
        row: <String, dynamic>{
          'history_id': 't-echo',
          'type': 'text',
          'content': 'enc',
          'source_device': 'device-a',
          'source_device_name': 'Mac A',
          'source_platform': 'macos',
          'timestamp': 5,
        },
        enqueuedAtMs: 1,
      ));
      final manager = createManager(outboxStore: outbox);
      await manager.start(
        userId: 'user_test',
        deviceId: 'device-a',
        accountKey: Uint8List(32),
      );
      // 对端 latestResponse 返回同 historyId → 恢复登记后视为重复，不再返回
      transport.fetchResults['peer-b'] = Future.value(<String, dynamic>{
        'history_id': 't-echo',
        'type': 'text',
        'content': 'enc',
        'source_device': 'peer-b',
        'source_device_name': 'Peer B',
        'source_platform': 'macos',
        'timestamp': 5,
        '_deletedIds': <String>[],
        '_restoredEntries': <Map<String, dynamic>>[],
      });
      expect(await manager.fetchLatestContent(), isNull);
      await manager.stop();
    });

    test('恢复时缺 artifact 的文件条目被丢弃', () async {
      final outbox = LanOutboxStore(directoryPath: tempDir.path);
      await outbox.put(LanOutboxEntry(
        userId: 'user_test',
        peerId: 'peer-b',
        historyId: 'f-missing',
        kind: 'file',
        row: <String, dynamic>{'history_id': 'f-missing', 'type': 'file'},
        artifactId: 'f-missing',
        enqueuedAtMs: 1,
      ));
      final manager = createManager(outboxStore: outbox);
      await manager.start(
        userId: 'user_test',
        deviceId: 'device-a',
        accountKey: Uint8List(32),
      );
      expect(await outbox.loadActive('user_test'), isEmpty);
      await manager.stop();
    });

    test('clearPersistedOutbox 只清指定用户（账户切换）', () async {
      final outbox = LanOutboxStore(directoryPath: tempDir.path);
      await outbox.put(LanOutboxEntry(
        userId: 'user_test',
        peerId: 'peer-b',
        historyId: 'h-u1',
        kind: 'text',
        row: <String, dynamic>{'history_id': 'h-u1'},
        enqueuedAtMs: 1,
      ));
      await outbox.put(LanOutboxEntry(
        userId: 'user_other',
        peerId: 'peer-b',
        historyId: 'h-u2',
        kind: 'text',
        row: <String, dynamic>{'history_id': 'h-u2'},
        enqueuedAtMs: 1,
      ));
      final manager = createManager(outboxStore: outbox);
      await manager.clearPersistedOutbox('user_test');
      expect(await outbox.loadActive('user_test'), isEmpty);
      expect(await outbox.loadActive('user_other'), hasLength(1));
    });
  });

  group('LanSyncManager 诊断计数', () {
    test('fetch hit/miss + pushSent 埋点；start/stop reset 清零', () async {
      final manager = createManager();
      await manager.start(
        userId: 'user_test',
        deviceId: 'device-a',
        accountKey: Uint8List(32),
      );
      final d = manager.diagnostics;
      expect(d.lanFetchMiss, 0);
      expect(d.lanFetchHit, 0);

      // 无 peer → miss
      await manager.fetchLatestContent();
      expect(d.lanFetchMiss, 1);

      // push sent（旧 peer 无 acks）
      discovery.candidatesResult = [_peer('peer-b')];
      transport.peerSupportsAcksResult = false;
      await manager.pushOperation(_textOp(operationId: 'd-push', timestamp: 1));
      expect(d.pushSent, 1);
      expect(d.pushReceived, 0);

      // 网络命中新 historyId
      transport.fetchResults['peer-b'] = Future.value(<String, dynamic>{
        'history_id': 'd-new',
        'type': 'text',
        'content': 'enc',
        'source_device': 'peer-b',
        'source_device_name': 'Peer B',
        'source_platform': 'macos',
        'timestamp': 100,
        '_deletedIds': <String>[],
        '_restoredEntries': <Map<String, dynamic>>[],
      });
      final row = await manager.fetchLatestContent();
      expect(row, isNotNull);
      expect(d.lanFetchHit, 1);
      expect(d.lanFetchMiss, 1);

      // stop → reset
      await manager.stop();
      expect(d.pushSent, 0);
      expect(d.lanFetchHit, 0);
      expect(d.lanFetchMiss, 0);
    });

    test('handshakeRejected 汇入 fallbackReason', () async {
      final manager = createManager();
      await manager.start(
        userId: 'user_test',
        deviceId: 'device-a',
        accountKey: Uint8List(32),
      );
      final d = manager.diagnostics;
      transport.connectError = LanHandshakeException(
        'wrongAccount',
        'peer proof does not match our account key',
      );
      discovery.candidatesResult = [_peer('peer-b')];
      await manager.fetchLatestContent();
      // fake transport 绕过真实握手，handshakeRejected 计数由握手服务负责
      // （lan_handshake_service_test 覆盖）；此处断言 manager 汇入 fallback。
      expect(
        d.fallbackCount(LanFallbackReason.handshakeRejected),
        greaterThan(0),
      );
      await manager.stop();
    });
  });
}
