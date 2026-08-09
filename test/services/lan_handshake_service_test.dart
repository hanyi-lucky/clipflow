import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:clipflow/repositories/cloud_repository.dart';
import 'package:clipflow/services/cloudbase_service.dart';
import 'package:clipflow/services/lan_handshake_service.dart';

/// 最小 fake：只覆写 LAN 票据两个方法，验证握手服务对 Cloud 依赖的接缝。
class _FakeCloudRepository extends CloudRepository {
  _FakeCloudRepository({
    this.userId = 'user_test',
    this.ticketTtlMs = 5 * 60 * 1000,
    this.expiredTickets = false,
    this.failVerify = false,
  }) : super(CloudBaseService());

  final String userId;
  final int ticketTtlMs;
  final bool expiredTickets;
  final bool failVerify;

  @override
  Future<Map<String, dynamic>> getLanTicket({required String deviceId}) async {
    final expiresAtMs = DateTime.now().millisecondsSinceEpoch +
        (expiredTickets ? -5000 : ticketTtlMs);
    return <String, dynamic>{
      'ticket': 'fake-ticket-$deviceId',
      'expiresAtMs': expiresAtMs,
    };
  }

  @override
  Future<Map<String, dynamic>> verifyLanTicket({required String ticket}) async {
    if (failVerify) {
      throw Exception('HTTP 403: 设备已被移除，请清除应用数据后重新添加');
    }
    final deviceId = ticket.replaceFirst('fake-ticket-', '');
    return <String, dynamic>{
      'userId': userId,
      'deviceId': deviceId,
      'expiresAtMs': DateTime.now().millisecondsSinceEpoch + ticketTtlMs,
    };
  }
}

typedef _PairResult = ({
  Object? aError,
  Object? bError,
  LanSession? aSession,
  LanSession? bSession,
});

void main() {
  late Uint8List accountKey;

  setUp(() {
    accountKey = Uint8List.fromList(List<int>.generate(32, (i) => i));
  });

  Future<(Socket, Socket)> socketPair() async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final client = await Socket.connect('127.0.0.1', server.port);
    final serverSocket = await server.first;
    await server.close();
    return (client, serverSocket);
  }

  Future<_PairResult> runPair({
    required LanHandshakeService a,
    required LanHandshakeService b,
    required Uint8List keyA,
    required Uint8List keyB,
  }) async {
    final (client, server) = await socketPair();
    addTearDown(() {
      client.destroy();
      server.destroy();
    });
    final aFuture = a.performHandshake(
      socket: client,
      isInitiator: true,
      deviceId: 'device-a',
      userId: 'user_test',
      accountKey: keyA,
      timeout: const Duration(seconds: 1),
    );
    final bFuture = b.performHandshake(
      socket: server,
      isInitiator: false,
      deviceId: 'device-b',
      userId: 'user_test',
      accountKey: keyB,
      timeout: const Duration(seconds: 1),
    );
    // 立即给两个 future 挂监听：否则先完成的 future 报错时若还未被 await，
    // 会被当作未处理异步错误直接判测试失败。
    final results = await Future.wait<Object?>([
      aFuture.then<Object?>((s) => s, onError: (Object e) => e),
      bFuture.then<Object?>((s) => s, onError: (Object e) => e),
    ]);
    Object? aError;
    Object? bError;
    LanSession? aSession;
    LanSession? bSession;
    final aValue = results[0];
    final bValue = results[1];
    if (aValue is LanSession) {
      aSession = aValue;
    } else {
      aError = aValue;
    }
    if (bValue is LanSession) {
      bSession = bValue;
    } else {
      bError = bValue;
    }
    return (aError: aError, bError: bError, aSession: aSession, bSession: bSession);
  }

  List<String> rejectionReasons(_PairResult result) {
    return [result.aError, result.bError]
        .whereType<LanHandshakeException>()
        .map((e) => e.reason)
        .toList();
  }

  test('K_lan derivation is deterministic and differs across account keys', () {
    final k1 = LanHandshakeService.deriveLanAuthKey(accountKey);
    final k2 = LanHandshakeService.deriveLanAuthKey(accountKey);
    expect(k1, equals(k2));
    expect(k1.length, equals(32));
    final otherKey = Uint8List.fromList(List<int>.generate(32, (i) => i + 1));
    final k3 = LanHandshakeService.deriveLanAuthKey(otherKey);
    expect(k1, isNot(equals(k3)));
  });

  test('proof verifies with the same K_lan and is rejected with a different account key', () {
    final lanAuthKey = LanHandshakeService.deriveLanAuthKey(accountKey);
    final otherAuthKey = LanHandshakeService.deriveLanAuthKey(
      Uint8List.fromList(List<int>.generate(32, (i) => i + 1)),
    );
    final proof = LanHandshakeService.buildProof(
      lanAuthKey: lanAuthKey,
      initiatorNonce: 'nonceA',
      responderNonce: 'nonceB',
      ticket: 'ticket-x',
    );
    expect(
      LanHandshakeService.verifyProof(
        lanAuthKey: lanAuthKey,
        initiatorNonce: 'nonceA',
        responderNonce: 'nonceB',
        ticket: 'ticket-x',
        proof: proof,
      ),
      isTrue,
    );
    expect(
      LanHandshakeService.verifyProof(
        lanAuthKey: otherAuthKey,
        initiatorNonce: 'nonceA',
        responderNonce: 'nonceB',
        ticket: 'ticket-x',
        proof: proof,
      ),
      isFalse,
    );
  });

  test('replay nonce is rejected by claimNonce', () {
    final service = LanHandshakeService(
      cloudRepository: _FakeCloudRepository(),
    );
    expect(service.claimNonce('nonce-1'), isTrue);
    expect(service.claimNonce('nonce-1'), isFalse);
    expect(service.claimNonce('nonce-2'), isTrue);
  });

  test('successful handshake establishes verified sessions for both sides', () async {
    final a = LanHandshakeService(cloudRepository: _FakeCloudRepository());
    final b = LanHandshakeService(cloudRepository: _FakeCloudRepository());
    final result = await runPair(a: a, b: b, keyA: accountKey, keyB: accountKey);
    expect(result.aError, isNull, reason: 'initiator error: ${result.aError}');
    expect(result.bError, isNull, reason: 'responder error: ${result.bError}');
    expect(result.aSession?.peerDeviceId, equals('device-b'));
    expect(result.bSession?.peerDeviceId, equals('device-a'));
    expect(result.aSession?.expiresAtMs, greaterThan(DateTime.now().millisecondsSinceEpoch));
  });

  test('handshake rejects a peer using a different account key (wrongAccount)', () async {
    final a = LanHandshakeService(cloudRepository: _FakeCloudRepository());
    final b = LanHandshakeService(cloudRepository: _FakeCloudRepository());
    final otherKey = Uint8List.fromList(List<int>.generate(32, (i) => i + 100));
    final result = await runPair(a: a, b: b, keyA: accountKey, keyB: otherKey);
    expect(rejectionReasons(result), contains('wrongAccount'));
  });

  test('handshake rejects an expired ticket (expiredTicket)', () async {
    final a = LanHandshakeService(
      cloudRepository: _FakeCloudRepository(expiredTickets: true),
    );
    final b = LanHandshakeService(
      cloudRepository: _FakeCloudRepository(expiredTickets: true),
    );
    final result = await runPair(a: a, b: b, keyA: accountKey, keyB: accountKey);
    expect(rejectionReasons(result), contains('expiredTicket'));
  });

  test('handshake fails when ticket verification is rejected (removed device)', () async {
    final a = LanHandshakeService(cloudRepository: _FakeCloudRepository());
    final b = LanHandshakeService(
      cloudRepository: _FakeCloudRepository(failVerify: true),
    );
    final result = await runPair(a: a, b: b, keyA: accountKey, keyB: accountKey);
    expect(rejectionReasons(result), contains('ticketRejected'));
  });

  test('handshake rejects a peer reusing a previously seen nonce (replayNonce)', () async {
    final aNonces = <String>['a1', 'a1'];
    final bNonces = <String>['b1', 'b2'];
    final a = LanHandshakeService(
      cloudRepository: _FakeCloudRepository(),
      nonceGenerator: () => aNonces.removeAt(0),
    );
    final b = LanHandshakeService(
      cloudRepository: _FakeCloudRepository(),
      nonceGenerator: () => bNonces.removeAt(0),
    );

    final first = await runPair(a: a, b: b, keyA: accountKey, keyB: accountKey);
    expect(first.aError, isNull, reason: 'first handshake failed: ${first.aError}');
    expect(first.bError, isNull, reason: 'first handshake failed: ${first.bError}');

    final second = await runPair(a: a, b: b, keyA: accountKey, keyB: accountKey);
    expect(rejectionReasons(second), contains('replayNonce'));
  });
  test('新↔新握手：双方 peerSupportsAcks=true（hello 携带 acks:1）', () async {
    final a = LanHandshakeService(cloudRepository: _FakeCloudRepository());
    final b = LanHandshakeService(cloudRepository: _FakeCloudRepository());
    final result = await runPair(a: a, b: b, keyA: accountKey, keyB: accountKey);
    expect(result.aError, isNull, reason: 'initiator error: ${result.aError}');
    expect(result.bError, isNull, reason: 'responder error: ${result.bError}');
    expect(result.aSession?.peerSupportsAcks, isTrue);
    expect(result.bSession?.peerSupportsAcks, isTrue);
  });

  test('旧 peer（hello 无 acks 字段）→ 新端 peerSupportsAcks=false', () async {
    // 旧端 helloBuilder 省略 acks，模拟 Phase 2.2 及更早的 peer。
    final oldPeer = LanHandshakeService(
      cloudRepository: _FakeCloudRepository(),
      helloBuilder: ({required String deviceId, required String nonce}) {
        return <String, dynamic>{
          'v': 1,
          'type': 'hello',
          'deviceId': deviceId,
          'nonce': nonce,
        };
      },
    );
    final newPeer = LanHandshakeService(
      cloudRepository: _FakeCloudRepository(),
    );
    final result = await runPair(
      a: newPeer,
      b: oldPeer,
      keyA: accountKey,
      keyB: accountKey,
    );
    expect(result.aError, isNull, reason: 'new side error: ${result.aError}');
    expect(result.bError, isNull, reason: 'old side error: ${result.bError}');
    // 新端（initiator a）看到旧端 hello 无 acks → 不支持
    expect(result.aSession?.peerSupportsAcks, isFalse);
    // 旧端（responder b）看到新端 hello 带 acks → 新端支持（但旧端自身不会发 ack）
    expect(result.bSession?.peerSupportsAcks, isTrue);
  });
}
