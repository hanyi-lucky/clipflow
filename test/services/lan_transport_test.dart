import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:clipflow/core/constants.dart';
import 'package:clipflow/repositories/cloud_repository.dart';
import 'package:clipflow/repositories/local_file_store.dart';
import 'package:clipflow/services/cloudbase_service.dart';
import 'package:clipflow/services/lan_handshake_service.dart';
import 'package:clipflow/services/lan_protocol.dart';
import 'package:clipflow/services/lan_tls.dart';
import 'package:clipflow/services/lan_transport.dart';

/// 最小 fake Cloud：LAN 票据签发/校验无需真实服务器（与 lan_sync_manager_test
/// 的 _FakeCloudRepository 同构，供真实握手组合路径使用）。
class _FakeCloudRepository extends CloudRepository {
  _FakeCloudRepository() : super(CloudBaseService());

  @override
  Future<Map<String, dynamic>> getLanTicket({required String deviceId}) async {
    return <String, dynamic>{
      'ticket': 'fake-ticket-$deviceId',
      'expiresAtMs': DateTime.now().millisecondsSinceEpoch + 5 * 60 * 1000,
    };
  }

  @override
  Future<Map<String, dynamic>> verifyLanTicket({required String ticket}) async {
    final deviceId = ticket.replaceFirst('fake-ticket-', '');
    return <String, dynamic>{
      'userId': 'user_test',
      'deviceId': deviceId,
      'expiresAtMs': DateTime.now().millisecondsSinceEpoch + 5 * 60 * 1000,
    };
  }
}

LanTransport _newTransport(CloudRepository cloud) {
  return LanTransport(
    handshakeService: LanHandshakeService(cloudRepository: cloud),
  );
}

Future<void> _waitUntil(
  Future<bool> Function() condition, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (await condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  fail('condition not met within $timeout');
}

Map<String, dynamic> _textRow(String historyId) => <String, dynamic>{
      'history_id': historyId,
      'type': 'text',
      'content': 'enc',
      'source_device': 'device-a',
      'source_device_name': 'Mac A',
      'source_platform': 'macos',
      'timestamp': 1,
    };

Map<String, dynamic> _fileRow(String historyId) => <String, dynamic>{
      'history_id': historyId,
      'type': 'file',
      'content': 'marker-ciphertext',
      'hash': 'hash-$historyId',
      'enc_file_name': 'encrypted-name',
      'file_size': 100,
      'source_device': 'device-a',
      'source_device_name': 'Mac A',
      'source_platform': 'macos',
      'timestamp': 1,
    };

void main() {
  // 真实 LanTransport（TLS 资产经 rootBundle 加载）需要 binding。
  TestWidgetsFlutterBinding.ensureInitialized();

  late final _FakeCloudRepository cloud;
  late final Uint8List accountKey;

  setUpAll(() {
    // CloudBaseService 构造创建 HTTP 客户端，需在测试 zone 内（flutter_test
    // 的 HttpOverrides 依赖当前 invoker）。
    cloud = _FakeCloudRepository();
    accountKey = Uint8List.fromList(List<int>.generate(32, (i) => i));
  });

  Future<int> startResponder(
    LanTransport responder, {
    Map<String, dynamic> Function()? latestRowProvider,
  }) async {
    final port = await responder.startServer(
      deviceId: 'device-b',
      userId: 'user_test',
      accountKey: accountKey,
    );
    responder.latestRowProvider = latestRowProvider;
    return port;
  }

  Future<void> connectInitiator(
    LanTransport init, {
    required int port,
    String deviceId = 'device-a',
  }) {
    return init.connect(
      peerDeviceId: 'device-b',
      host: '127.0.0.1',
      port: port,
      userId: 'user_test',
      deviceId: deviceId,
      accountKey: accountKey,
    );
  }

  group('LanTransport 会话生命周期（幂等替换 + identity 清理）', () {
    test('responder 重复握手：同 peer 旧 socket 销毁、条目不重复、旧循环收尾不误删新会话', () async {
      final responder = _newTransport(cloud);
      addTearDown(() => responder.closeAll());
      final port = await startResponder(responder, latestRowProvider: () {
        return _textRow('h-new');
      });

      // 第一次连接：device-a 建立 responder 会话
      final initA = _newTransport(cloud);
      addTearDown(() => initA.closeAll());
      await connectInitiator(initA, port: port);
      expect(responder.responderSessionCount, 1);

      // 第二次连接（同 device-a 重连）：幂等替换，条目不重复
      final initB = _newTransport(cloud);
      addTearDown(() => initB.closeAll());
      await connectInitiator(initB, port: port);
      expect(responder.responderSessionCount, 1);

      // 旧会话（initA）socket 已被 responder 销毁 → 其帧循环 EOF → finally
      // 收尾走 identity 校验，不得误删新会话条目。给旧循环收尾留出时间。
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(responder.responderSessionCount, 1);

      // 新会话仍可正常 fetch（若旧 finally 误删，fetchLatest 因无会话返回 null）
      final row = await initB
          .fetchLatest('device-b')
          .timeout(const Duration(seconds: 2));
      expect(row, isNotNull);
      expect(row!['history_id'], 'h-new');
      expect(responder.responderSessionCount, 1);
    });

    test('对端关闭 → fetchLatest 真错误路径仍 drop（降级语义不回退）', () async {
      final responder = _newTransport(cloud);
      final port = await startResponder(responder);
      final init = _newTransport(cloud);
      addTearDown(() => init.closeAll());
      await connectInitiator(init, port: port);
      expect(init.initiatorSessionCount, 1);

      // 对端整体关闭（模拟离线）：initiator 下一次 fetch 读到 EOF →
      // LanProtocolException → _dropInitiatorSession（identity 校验通过）。
      // fetchLatest 自带帧级读超时兜底，保证无论 EOF 传播快慢都必返 null。
      await responder.closeAll();
      final row = await init.fetchLatest('device-b');
      expect(row, isNull);
      expect(init.initiatorSessionCount, 0);
    });

    test('initiator 重复 connect：旧 socket 销毁、条目不重复、新会话可用', () async {
      final responder = _newTransport(cloud);
      addTearDown(() => responder.closeAll());
      final port = await startResponder(responder, latestRowProvider: () {
        return _textRow('h-re');
      });

      final init = _newTransport(cloud);
      addTearDown(() => init.closeAll());
      await connectInitiator(init, port: port);
      expect(init.initiatorSessionCount, 1);

      // 同一 transport 再次 connect：幂等替换（旧 socket 销毁），仍只有 1 条
      await connectInitiator(init, port: port);
      expect(init.initiatorSessionCount, 1);

      final row = await init
          .fetchLatest('device-b')
          .timeout(const Duration(seconds: 2));
      expect(row, isNotNull);
      expect(row!['history_id'], 'h-re');
    });

    test('responder 帧循环中断 → finally 清理：map remove + socket destroy + fileReceiver.abort', () async {
      final tempDir =
          await Directory.systemTemp.createTemp('lan_transport_sess_');
      addTearDown(() async {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });
      final fileStore = LocalFileStore(directoryPath: tempDir.path);
      Future<List<String>> tmpParts() async {
        final dir = Directory('${tempDir.path}/${LocalFileStore.tmpDirName}');
        if (!await dir.exists()) return [];
        final names = <String>[];
        await for (final entity in dir.list()) {
          if (entity is File) names.add(entity.path);
        }
        return names;
      }

      final responder = _newTransport(cloud);
      addTearDown(() => responder.closeAll());
      final port = await startResponder(responder);
      responder.fileSink = ({
        required String entryId,
        required Stream<List<int>> stream,
      }) {
        return fileStore.saveEncryptedFromStream(
          entryId: entryId,
          stream: stream,
        );
      };

      final init = _newTransport(cloud);
      addTearDown(() => init.closeAll());
      await connectInitiator(init, port: port);
      expect(responder.responderSessionCount, 1);

      // 制造「声明 15MiB、实际只发 1 个 chunk」的不完整传输：fileStart 声明
      // total=15，但源文件只有 1MiB → receiver 进入等待后续 chunk 的活跃
      // 传输态（.part 已创建），随后断链触发 finally → fileReceiver.abort。
      // 源密文文件与 receiver 目标（encDir/<entryId>.enc）分离：源文件
      // 放 tmp，receiver 目标 encDir/h-interrupted.enc 初始不存在。
      final encDir =
          Directory('${tempDir.path}/${LocalFileStore.encDirName}')
            ..createSync(recursive: true);
      final sourcePath = '${tempDir.path}/source-15mib.enc';
      File(sourcePath).writeAsBytesSync(List<int>.filled(1024 * 1024, 7));

      final pushFuture = init.pushFile(
        'device-b',
        _fileRow('h-interrupted'),
        encryptedPath: sourcePath,
        encSize: LanConstants.lanMaxFileBytes,
      );
      await _waitUntil(() async => (await tmpParts()).isNotEmpty);

      // 断链：initiator 销毁 socket → responder 帧循环 EOF → finally 清理
      init.dropSession('device-b');
      expect(await pushFuture, LanPushResult.pending);

      // finally 三件事：fileReceiver.abort（.part 删除、不产生 .enc）、
      // map remove（responder 会话清空）、socket destroy（对端已 EOF）。
      await _waitUntil(() async => (await tmpParts()).isEmpty);
      expect(File('${encDir.path}/h-interrupted.enc').existsSync(), isFalse);
      await _waitUntil(() async => responder.responderSessionCount == 0);
    });
  });

  group('EOF 分类（_SocketFrameReader）', () {
    Future<(Socket, Socket)> socketPair() async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final client = await Socket.connect('127.0.0.1', server.port);
      final serverSocket = await server.first;
      await server.close();
      return (client, serverSocket);
    }

    test('帧间 EOF（上帧完整后对端关闭）→ peer closed connection between frames', () async {
      final (client, server) = await socketPair();
      addTearDown(() {
        client.destroy();
        server.destroy();
      });
      final conn = LanFrameConnection(
        server,
        timeout: const Duration(seconds: 2),
      );
      // 写一完整帧 + 关闭：read 首帧成功，下一帧 read 读到「帧间 EOF」。
      client.add(encodeFrame(<String, dynamic>{'v': 1, 'type': 'ping'}));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      client.destroy();

      final first = await conn.read();
      expect(first['type'], 'ping');
      await expectLater(
        conn.read(),
        throwsA(
          isA<LanProtocolException>().having(
            (e) => e.message,
            'message',
            contains('peer closed connection between frames'),
          ),
        ),
      );
    });

    test('半帧 EOF（长度头后关闭）→ socket closed before frame completed', () async {
      final (client, server) = await socketPair();
      addTearDown(() {
        client.destroy();
        server.destroy();
      });
      final conn = LanFrameConnection(
        server,
        timeout: const Duration(seconds: 2),
      );
      // 长度头声明 100 字节，但只发 4 字节后关闭 → 帧中 EOF。
      final header = Uint8List(4);
      ByteData.sublistView(header).setUint32(0, 100);
      client.add(header);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      client.destroy();

      await expectLater(
        conn.read(),
        throwsA(
          isA<LanProtocolException>().having(
            (e) => e.message,
            'message',
            contains('socket closed before frame completed'),
          ),
        ),
      );
    });
  });

  group('逐帧读超时（lanFrameTimeout 注入短值）', () {
    test('responder 帧循环：对端静默 → 超时断链清理（不占用会话槽位）', () async {
      final responder = LanTransport(
        handshakeService: LanHandshakeService(cloudRepository: cloud),
        frameTimeout: const Duration(milliseconds: 150),
      );
      addTearDown(() => responder.closeAll());
      final port = await startResponder(responder);

      final init = LanTransport(
        handshakeService: LanHandshakeService(cloudRepository: cloud),
        frameTimeout: const Duration(milliseconds: 150),
      );
      addTearDown(() => init.closeAll());
      await connectInitiator(init, port: port);
      expect(responder.responderSessionCount, 1);

      // initiator 握手后静默不发帧 → responder 逐帧读超时 → finally 清理
      await _waitUntil(() async => responder.responderSessionCount == 0);
    });

    test('initiator fetchLatest 帧级读超时兜底：静默对端 → 超时后 drop（降级保留）', () async {
      // 手工 responder（真实 TLS + 真实握手后静默）：不回 latestResponse，
      // 验证 initiator 侧帧级读超时（lanFrameTimeout 注入短值）兜底 drop。
      final context = await LanTls.createServerSecurityContext();
      final server = await SecureServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
        context,
      );
      final port = server.port;
      final serverSockets = <Socket>[];
      final serverSub = server.listen((socket) async {
        serverSockets.add(socket);
        try {
          final conn = LanFrameConnection(
            socket,
            timeout: const Duration(seconds: 5),
          );
          await LanHandshakeService(
            cloudRepository: cloud,
          ).performHandshake(
            socket: socket,
            existingConnection: conn,
            isInitiator: false,
            deviceId: 'device-b',
            userId: 'user_test',
            accountKey: accountKey,
          );
          // 静默：不再读/写任何帧（latestRequest 无响应）。
        } catch (_) {
          // 握手/测试清理错误忽略。
        }
      });
      addTearDown(() async {
        await serverSub.cancel();
        for (final s in serverSockets) {
          s.destroy();
        }
      });

      final init = LanTransport(
        handshakeService: LanHandshakeService(cloudRepository: cloud),
        frameTimeout: const Duration(milliseconds: 200),
      );
      addTearDown(() => init.closeAll());
      await init.connect(
        peerDeviceId: 'device-b',
        host: '127.0.0.1',
        port: port,
        userId: 'user_test',
        deviceId: 'device-a',
        accountKey: accountKey,
      );
      expect(init.initiatorSessionCount, 1);

      final row = await init.fetchLatest('device-b');
      expect(row, isNull);
      expect(init.initiatorSessionCount, 0);
    });
  });
}
