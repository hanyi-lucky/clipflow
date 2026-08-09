import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:clipflow/core/constants.dart';
import 'package:clipflow/services/lan_protocol.dart';
import 'package:clipflow/services/lan_transport.dart';

void main() {
  group('fileAck 帧格式（红线：只带 historyId+status，无敏感字段）', () {
    test('buildFileAckFrame 只含 v/type/historyId/status', () {
      final frame = buildFileAckFrame('op-123');
      expect(frame.keys.toSet(), {'v', 'type', 'historyId', 'status'});
      expect(frame['v'], LanConstants.lanProtoVersion);
      expect(frame['type'], 'fileAck');
      expect(frame['historyId'], 'op-123');
      expect(frame['status'], 'ok');
    });

    test('fileAck 帧不含任何账户/密钥/文件名敏感字段', () {
      final frame = buildFileAckFrame('op-456');
      const sensitive = [
        'userId', 'password', 'token', 'K_lan', 'salt', 'fingerprint',
        'file_name', 'mime_type', 'proof', 'ticket', 'nonce',
      ];
      for (final key in sensitive) {
        expect(frame.containsKey(key), isFalse, reason: 'must not contain $key');
      }
    });
  });

  group('isMatchingFileAck 判定', () {
    test('匹配 historyId + status=ok → true', () {
      expect(isMatchingFileAck(buildFileAckFrame('op-1'), 'op-1'), isTrue);
    });

    test('historyId 不匹配 → false（协议违规，断会话）', () {
      expect(isMatchingFileAck(buildFileAckFrame('op-1'), 'op-2'), isFalse);
    });

    test('status 非 ok → false（协议违规，断会话）', () {
      final frame = buildFileAckFrame('op-1')..['status'] = 'error';
      expect(isMatchingFileAck(frame, 'op-1'), isFalse);
    });

    test('type 非 fileAck（如 latestResponse）→ false', () {
      final frame = <String, dynamic>{
        'v': 1,
        'type': 'latestResponse',
        'row': <String, dynamic>{'history_id': 'op-1'},
      };
      expect(isMatchingFileAck(frame, 'op-1'), isFalse);
    });
  });

  group('LanReaderSlot 读串行化', () {
    test('空闲 tryAcquire 成功，release 后再次可获取', () {
      final slot = LanReaderSlot();
      expect(slot.tryAcquire(), isTrue);
      expect(slot.tryAcquire(), isFalse, reason: 'busy 时非阻塞获取失败');
      slot.release();
      expect(slot.tryAcquire(), isTrue);
    });

    test('busy 时无超时 acquire 立即失败（fetchLatest 跳过语义）', () async {
      final slot = LanReaderSlot();
      slot.tryAcquire();
      expect(await slot.acquire(), isFalse);
    });

    test('有界等待：占用者在超时内释放 → 获取成功', () async {
      final slot = LanReaderSlot();
      slot.tryAcquire();
      Future<void>.delayed(const Duration(milliseconds: 40), slot.release);
      final acquired = await slot.acquire(
        timeout: const Duration(milliseconds: 200),
      );
      expect(acquired, isTrue);
    });

    test('有界等待：超过超时仍未释放 → false', () async {
      final slot = LanReaderSlot();
      slot.tryAcquire();
      final sw = Stopwatch()..start();
      final acquired = await slot.acquire(
        timeout: const Duration(milliseconds: 50),
      );
      sw.stop();
      expect(acquired, isFalse);
      expect(sw.elapsedMilliseconds, greaterThanOrEqualTo(40));
    });
  });

  group('socket-pair push→fileAck 帧交换', () {
    Future<(Socket, Socket)> socketPair() async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final client = await Socket.connect('127.0.0.1', server.port);
      final serverSocket = await server.first;
      await server.close();
      return (client, serverSocket);
    }

    test('push 帧 → responder 回 fileAck → initiator 读到匹配 ack', () async {
      final (client, server) = await socketPair();
      addTearDown(() {
        client.destroy();
        server.destroy();
      });
      final initiatorConn = LanFrameConnection(
        client,
        timeout: const Duration(seconds: 2),
      );
      final responderConn = LanFrameConnection(
        server,
        timeout: const Duration(seconds: 2),
      );

      final row = <String, dynamic>{
        'history_id': 'op-sock',
        'type': 'text',
        'content': 'enc',
        'source_device': 'device-a',
        'source_device_name': 'Mac A',
        'source_platform': 'macos',
        'timestamp': 1,
      };

      // responder：读 push → 写 fileAck
      final responderFuture = () async {
        final frame = await responderConn.read();
        expect(frame['type'], 'push');
        expect((frame['row'] as Map)['history_id'], 'op-sock');
        responderConn.write(buildFileAckFrame('op-sock'));
      }();

      // initiator：写 push → 读 ack
      initiatorConn.write(<String, dynamic>{
        'v': LanConstants.lanProtoVersion,
        'type': 'push',
        'row': row,
      });
      final ack = await initiatorConn
          .read()
          .timeout(const Duration(seconds: 2));
      expect(ack['type'], 'fileAck');
      expect(ack['historyId'], 'op-sock');
      expect(ack['status'], 'ok');
      expect(isMatchingFileAck(ack, 'op-sock'), isTrue);
      await responderFuture;
    });
  });
}
