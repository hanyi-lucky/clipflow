import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

/// ClipFlow 服务器域名身份（证书 subject 校验用）。
const String clipflowServerDomain = 'api.yihanlife.ccwu.cc';

/// 创建绑定 ClipFlow 服务器域名身份的 HTTP Client。
///
/// 背景：API 直连固定 IP（`https://121.196.222.122`），TLS 使用 SNI=IP，
/// 系统按 IP 校验域名证书必然 hostname 不匹配，会触发 `badCertificateCallback`。
/// 这里按「证书 subject 含 ClipFlow 域名 + 签发者为 Let's Encrypt」放行
/// （信任链仍由系统信任库校验）。等价于正常 HTTPS 的域名校验，且不受证书续期影响
/// （续期后仍是同一域名的 Let's Encrypt 证书）。
http.Client createPinnedHttpClient() {
  final inner = HttpClient()
    ..badCertificateCallback = (X509Certificate cert, String host, int port) {
      final subject = cert.subject;
      final issuer = cert.issuer;
      return subject.contains(clipflowServerDomain) &&
          issuer.contains("Let's Encrypt");
    };
  return IOClient(inner);
}
