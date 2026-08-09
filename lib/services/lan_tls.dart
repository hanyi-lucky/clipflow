import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter/services.dart' show rootBundle;

/// LAN TLS 传输：静态自签证书 + 指纹固定（平移 pinned_client 先例）。
///
/// - 服务端（responder）：`createServerSecurityContext()` 加载打包进 App 的
///   自签证书（**私钥必须 PKCS#8 PEM**，`BEGIN PRIVATE KEY`；PKCS#1 会导致
///   `usePrivateKey` 挂起）。
/// - 客户端（initiator）：`SecureSocket.connect(..., onBadCertificate:
///   LanTls.isTrustedCertificate)` 按「证书 DER SHA-256 == 内置指纹」放行。
///
/// 证书资产：`assets/lan/lan-cert.pem` + `assets/lan/lan-key.pem`
/// （RSA-2048，10 年有效，CN=clipflow-lan）。多设备共用同一内置证书：
/// TLS 只提供传输加密与防窃听，设备级身份由应用层双向挑战完成。
class LanTls {
  LanTls._();

  static const String certAssetPath = 'assets/lan/lan-cert.pem';
  static const String keyAssetPath = 'assets/lan/lan-key.pem';

  /// 自签证书（DER）的 SHA-256 指纹（十六进制大写）。
  /// 与 `assets/lan/lan-cert.pem` 严格一致；更换证书必须同步更新此常量。
  static const String certFingerprintHex =
      '66AE27C8BD8FADD7F62761904D31D12DFB2F38936F06A17B3679526D6B85C095';

  /// 加载服务端 [SecurityContext]（证书链 + PKCS#8 私钥）。
  static Future<SecurityContext> createServerSecurityContext() async {
    final cert = await rootBundle.loadString(certAssetPath);
    final key = await rootBundle.loadString(keyAssetPath);
    final context = SecurityContext();
    context.useCertificateChainBytes(utf8.encode(cert));
    context.usePrivateKeyBytes(utf8.encode(key));
    return context;
  }

  /// 客户端指纹固定回调：仅放行内置自签证书。
  static bool isTrustedCertificate(X509Certificate cert) {
    final fingerprint = sha256.convert(cert.der).toString().toUpperCase();
    return fingerprint == certFingerprintHex;
  }
}
