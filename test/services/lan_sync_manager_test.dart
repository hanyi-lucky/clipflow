import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:clipflow/core/constants.dart';
import 'package:clipflow/models/sync_operation.dart';
import 'package:clipflow/repositories/cloud_repository.dart';
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

  @override
  Future<void> push(String peerDeviceId, Map<String, dynamic> row) async {
    pushedTo.add(peerDeviceId);
    pushedRows.add(row);
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

  setUp(() {
    clock = _MutableClock();
    discovery = _FakeDiscovery();
    transport = _FakeTransport();
  });

  LanSyncManager createManager({Duration fetchTimeout = const Duration(milliseconds: 50)}) {
    return LanSyncManager(
      discovery: discovery,
      transport: transport,
      fetchTimeout: fetchTimeout,
    );
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
      expect(discovery.startCaps, 't/i');
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
    test('text/image 才推送；file 不推送', () async {
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
}
