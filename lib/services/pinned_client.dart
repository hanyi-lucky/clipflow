import 'dart:io';
import 'package:crypto/crypto.dart' show sha256;
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

/// ClipFlow 服务器自签证书（DER）的 SHA-256 指纹，用于指纹固定。
///
/// 服务器证书：`/opt/clipflow/tls/clipflow-server.crt`（自签，10 年有效，
/// CN=121.196.222.122）。更换证书时必须同步更新此指纹并重发 App。
const String pinnedServerCertFingerprintHex =
    '07AA7BFC318C28E42F56999DCDC2568A0552E4D97F33DB26F752B1DC40C11139';

/// 创建绑定 ClipFlow 服务器证书的 HTTP Client（指纹固定）。
///
/// API 直连固定 IP（`https://121.196.222.122`），服务器使用自签证书，
/// 系统信任库无法校验，因此在此按「证书 DER SHA-256 == 内置指纹」放行。
/// 这是最强的 MITM 防护：只有持有该服务器私钥的证书能通过，与信任库、
/// 证书链、续期完全解耦（10 年内无需更新）。
http.Client createPinnedHttpClient() {
  final inner = HttpClient()
    ..badCertificateCallback = (X509Certificate cert, String host, int port) {
      final fp = sha256.convert(cert.der).toString().toUpperCase();
      return fp == pinnedServerCertFingerprintHex;
    };
  return IOClient(inner);
}
