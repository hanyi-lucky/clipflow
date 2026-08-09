import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:clipflow/services/lan_tls.dart';

/// 从 PEM 证书文本中提取 DER 编码（剥离 PEM 头尾，base64 解码正文）。
Uint8List _pemToDer(String pem) {
  final body = pem
      .replaceAll(RegExp(r'-----BEGIN [A-Z ]+-----'), '')
      .replaceAll(RegExp(r'-----END [A-Z ]+-----'), '')
      .replaceAll(RegExp(r'\s'), '');
  return Uint8List.fromList(base64.decode(body));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('asset certificate and key load, private key is PKCS#8', () async {
    final cert = await rootBundle.loadString(LanTls.certAssetPath);
    final key = await rootBundle.loadString(LanTls.keyAssetPath);
    expect(cert, contains('BEGIN CERTIFICATE'));
    expect(key, contains('BEGIN PRIVATE KEY'));
    expect(key, isNot(contains('BEGIN RSA PRIVATE KEY')));
  });

  test('fingerprint constant matches DER SHA-256 of asset certificate', () async {
    final cert = await rootBundle.loadString(LanTls.certAssetPath);
    final der = _pemToDer(cert);
    final fingerprint = sha256.convert(der).toString().toUpperCase();
    expect(LanTls.certFingerprintHex, equals(fingerprint));
  });

  test('createServerSecurityContext loads cert chain and PKCS#8 key', () async {
    final context = await LanTls.createServerSecurityContext();
    expect(context, isA<SecurityContext>());
  });

  test('localhost TLS handshake succeeds with pinned fingerprint', () async {
    final serverContext = await LanTls.createServerSecurityContext();
    final server = await SecureServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
      serverContext,
    );
    addTearDown(() async {
      await server.close();
    });

    final acceptedFuture = server.first;
    final client = await SecureSocket.connect(
      '127.0.0.1',
      server.port,
      onBadCertificate: LanTls.isTrustedCertificate,
    );
    final serverSocket = await acceptedFuture.timeout(const Duration(seconds: 5));
    addTearDown(() async {
      client.destroy();
      serverSocket.destroy();
    });

    client.add(utf8.encode('ping'));
    final chunk = await serverSocket.first.timeout(const Duration(seconds: 5));
    expect(utf8.decode(chunk), equals('ping'));
  });

  test('localhost TLS handshake rejected when fingerprint does not match', () async {
    final serverContext = await LanTls.createServerSecurityContext();
    final server = await SecureServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
      serverContext,
    );
    addTearDown(() async {
      await server.close();
    });

    final acceptedFuture = server.first;
    await expectLater(
      SecureSocket.connect(
        '127.0.0.1',
        server.port,
        onBadCertificate: (_) => false,
      ),
      throwsA(isA<HandshakeException>()),
    );
    // 服务端 accept 可能因对端中止握手而抛错——客户端已被拒绝即视为通过
    try {
      final serverSocket = await acceptedFuture.timeout(const Duration(seconds: 5));
      serverSocket.destroy();
    } catch (_) {
      // 握手失败预期内，忽略服务端 accept 错误
    }
  });
}
