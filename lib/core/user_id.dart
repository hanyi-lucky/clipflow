import 'dart:convert';
import 'package:crypto/crypto.dart';

/// 从主密码派生账户 userId（项目红线公式，禁止改动）。
///
/// 公式：`user_` + SHA256('clipflow:$password') 的 16 位十六进制前缀。
/// 相同密码 → 相同 userId → 共享数据；不同密码 → 完全隔离。
/// 解锁页与「从云端拉取」共用此实现，避免双实现漂移。
String deriveUserId(String password) {
  final hash = sha256.convert(utf8.encode('clipflow:$password')).toString();
  return 'user_${hash.substring(0, 16)}';
}
