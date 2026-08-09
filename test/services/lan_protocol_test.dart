import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:clipflow/core/constants.dart';
import 'package:clipflow/services/lan_protocol.dart';

void main() {
  group('LanProtocol frame codec', () {
    test('encode/decode round-trips a message with version field', () {
      final message = <String, dynamic>{
        'v': LanConstants.lanProtoVersion,
        'type': 'hello',
        'deviceId': 'device-uuid',
        'nonce': 'nonce-123',
      };
      final frame = encodeFrame(message);
      final decoded = decodeFrameBytes(frame);
      expect(decoded, equals(message));
    });

    test('decode rejects unsupported protocol version', () {
      final frame = encodeFrame(<String, dynamic>{
        'v': LanConstants.lanProtoVersion + 1,
        'type': 'hello',
      });
      expect(() => decodeFrameBytes(frame), throwsA(isA<LanProtocolException>()));
    });

    test('decode rejects missing protocol version', () {
      final frame = encodeFrame(<String, dynamic>{'type': 'hello'});
      expect(() => decodeFrameBytes(frame), throwsA(isA<LanProtocolException>()));
    });

    test('encode rejects payload over max frame bytes', () {
      final big = <String, dynamic>{
        'v': LanConstants.lanProtoVersion,
        'data': 'x' * (LanConstants.lanMaxFrameBytes + 1),
      };
      expect(() => encodeFrame(big), throwsA(isA<LanProtocolException>()));
    });

    test('decode rejects frame whose declared length exceeds max', () {
      final bytes = Uint8List(4);
      ByteData.sublistView(bytes).setUint32(0, LanConstants.lanMaxFrameBytes + 1);
      expect(() => decodeFrameBytes(bytes), throwsA(isA<LanProtocolException>()));
    });

    test('decode rejects truncated frame (payload shorter than declared)', () {
      final frame = encodeFrame(<String, dynamic>{'v': LanConstants.lanProtoVersion, 'a': 'b'});
      final truncated = Uint8List.fromList(frame.sublist(0, frame.length - 2));
      expect(() => decodeFrameBytes(truncated), throwsA(isA<LanProtocolException>()));
    });

    test('decode rejects frame shorter than the 4-byte length header', () {
      final bytes = Uint8List.fromList([0, 0, 1]);
      expect(() => decodeFrameBytes(bytes), throwsA(isA<LanProtocolException>()));
    });

    test('decode rejects malformed JSON payload', () {
      final payload = utf8.encode('not-json{');
      final bytes = Uint8List(4 + payload.length);
      ByteData.sublistView(bytes).setUint32(0, payload.length);
      bytes.setRange(4, bytes.length, payload);
      expect(() => decodeFrameBytes(bytes), throwsA(isA<LanProtocolException>()));
    });

    test('decode rejects JSON that is not an object', () {
      final payload = utf8.encode('[1,2,3]');
      final bytes = Uint8List(4 + payload.length);
      ByteData.sublistView(bytes).setUint32(0, payload.length);
      bytes.setRange(4, bytes.length, payload);
      expect(() => decodeFrameBytes(bytes), throwsA(isA<LanProtocolException>()));
    });

    test('writeFrame/readFrame round-trips over a real socket pair', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final client = await Socket.connect('127.0.0.1', server.port);
      final serverSocket = await server.first;
      addTearDown(() async {
        client.destroy();
        serverSocket.destroy();
        server.close();
      });

      final message = <String, dynamic>{
        'v': LanConstants.lanProtoVersion,
        'type': 'auth',
        'ticket': 'ticket-abc',
      };
      writeFrame(client, message);
      final received = await readFrame(serverSocket, timeout: const Duration(seconds: 2));
      expect(received, equals(message));
    });
  });
}
