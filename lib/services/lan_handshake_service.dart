import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show Hmac, sha256;

import '../core/constants.dart';
import '../repositories/cloud_repository.dart';
import 'lan_protocol.dart';

/// LAN 握手失败。
///
/// [reason] 取值：`wrongAccount` / `expiredTicket` / `replayNonce` /
/// `ticketRejected` / `protocol` / `network` / `timeout`（2.3 接诊断指标用）。
class LanHandshakeException implements Exception {
  LanHandshakeException(this.reason, this.message);

  final String reason;
  final String message;

  @override
  String toString() => 'LanHandshakeException($reason): $message';
}

/// 服务端签发的短时票据（仅内存态，不落盘）。
class LanTicket {
  LanTicket(this.value, this.expiresAtMs);

  final String value;
  final int expiresAtMs;
}

/// 服务端校验票据后的结果。
/// userId 只在内存中与本地比对（「userId 永不落线」），不写入任何 LAN 报文。
class LanVerifiedTicket {
  LanVerifiedTicket(this.userId, this.deviceId, this.expiresAtMs);

  final String userId;
  final String deviceId;
  final int expiresAtMs;
}

/// 握手成功后建立的会话（fetch/push 期间复用，过期需重握手）。
class LanSession {
  LanSession({required this.peerDeviceId, required this.expiresAtMs});

  final String peerDeviceId;
  final int expiresAtMs;
}

/// A3 双向挑战握手（Cloud-backed LAN acceleration）。
///
/// 时序（A 发起 → B 响应），全部报文走 TLS + 指纹固定通道：
/// ```
/// A→B: Hello {v, type:hello, deviceId:A, nonceA}
/// B→A: Hello {v, type:hello, deviceId:B, nonceB}
/// （双方并行向服务端取票：POST /lan/ticket）
/// A→B: auth {ticket:A, proof=HMAC(K_lan, "handshake-v1|nonceA|nonceB|ticketA")}
/// B 校验：proof 用自身 K_lan 比对（错账户 → 拒绝）→ 服务端 verify(ticketA)
///        → userId == 自身 userId → 通过后才回发自己的 auth
/// B→A: auth {ticket:B, proof=HMAC(K_lan, "handshake-v1|nonceA|nonceB|ticketB")}
/// A 校验同上 → 双方 verified → session 建立
/// ```
///
/// 红线：LAN 报文不含 userId/密码/token/K_lan/salt/证书指纹/文件名/明文；
/// 票据只存内存；K_lan 每次解锁重新派生、永不落盘。
class LanHandshakeService {
  LanHandshakeService({
    required CloudRepository cloudRepository,
    String Function()? nonceGenerator,
  })  : _cloud = cloudRepository,
        _nonceGenerator = nonceGenerator ?? _defaultNonce;

  final CloudRepository _cloud;
  final String Function() _nonceGenerator;
  final Set<String> _seenNonces = <String>{};
  final List<String> _seenNonceOrder = <String>[];
  static const int _maxSeenNonces = 1024;

  static String _defaultNonce() {
    final rand = Random.secure();
    return 'n-${DateTime.now().microsecondsSinceEpoch}-${rand.nextInt(1 << 32)}';
  }

  /// K_lan = HMAC-SHA256(key=accountKey, msg=utf8("clipflow:lan-auth-v1"))。
  /// 用途隔离的 LAN 认证 key（32 字节），绝不替换数据加密 key。
  static Uint8List deriveLanAuthKey(Uint8List accountKey) {
    final hmac = Hmac(sha256, accountKey);
    return Uint8List.fromList(
      hmac.convert(utf8.encode('clipflow:lan-auth-v1')).bytes,
    );
  }

  /// proof = base64(HMAC-SHA256(K_lan, "handshake-v1|initiatorNonce|responderNonce|ticket"))。
  static String buildProof({
    required Uint8List lanAuthKey,
    required String initiatorNonce,
    required String responderNonce,
    required String ticket,
  }) {
    final hmac = Hmac(sha256, lanAuthKey);
    final digest = hmac.convert(
      utf8.encode('handshake-v1|$initiatorNonce|$responderNonce|$ticket'),
    );
    return base64Encode(digest.bytes);
  }

  /// 常量时间比对 proof 是否由同一 K_lan 生成。
  static bool verifyProof({
    required Uint8List lanAuthKey,
    required String initiatorNonce,
    required String responderNonce,
    required String ticket,
    required String proof,
  }) {
    try {
      final expected = buildProof(
        lanAuthKey: lanAuthKey,
        initiatorNonce: initiatorNonce,
        responderNonce: responderNonce,
        ticket: ticket,
      );
      return _constantTimeEquals(base64Decode(proof), base64Decode(expected));
    } catch (_) {
      return false;
    }
  }

  static bool _constantTimeEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }

  /// 登记收到的 peer nonce；返回 false 表示重放（已见过，拒绝）。
  /// 有界集合（≤1024），防内存膨胀。
  bool claimNonce(String nonce) {
    if (_seenNonces.contains(nonce)) return false;
    _seenNonces.add(nonce);
    _seenNonceOrder.add(nonce);
    while (_seenNonceOrder.length > _maxSeenNonces) {
      _seenNonces.remove(_seenNonceOrder.removeAt(0));
    }
    return true;
  }

  Future<LanTicket> fetchTicket({required String deviceId}) async {
    final Map<String, dynamic> data;
    try {
      data = await _cloud.getLanTicket(deviceId: deviceId);
    } catch (e) {
      throw LanHandshakeException('ticketRejected', 'failed to fetch LAN ticket: $e');
    }
    final ticket = data['ticket'];
    final expiresAtMs = data['expiresAtMs'];
    if (ticket is! String || ticket.isEmpty || expiresAtMs is! int) {
      throw LanHandshakeException('ticketRejected', 'server returned malformed LAN ticket');
    }
    return LanTicket(ticket, expiresAtMs);
  }

  Future<LanVerifiedTicket> verifyTicket(String ticket) async {
    final Map<String, dynamic> data;
    try {
      data = await _cloud.verifyLanTicket(ticket: ticket);
    } catch (e) {
      throw LanHandshakeException('ticketRejected', 'ticket verification failed: $e');
    }
    final userId = data['userId'];
    final deviceId = data['deviceId'];
    final expiresAtMs = data['expiresAtMs'];
    if (userId is! String || deviceId is! String || expiresAtMs is! int) {
      throw LanHandshakeException(
        'ticketRejected',
        'server returned malformed verification result',
      );
    }
    return LanVerifiedTicket(userId, deviceId, expiresAtMs);
  }

  /// 在已建立的 TLS socket 上完成双向挑战握手，成功返回 [LanSession]。
  ///
  /// [userId] 仅用于本地与服务端返回值的比对，不写入任何 LAN 报文。
  Future<LanSession> performHandshake({
    required Socket socket,
    required bool isInitiator,
    required String deviceId,
    required String userId,
    required Uint8List accountKey,
    Duration? timeout,
    LanFrameConnection? existingConnection,
  }) async {
    final frameTimeout = timeout ?? LanConstants.lanHandshakeTimeout;
    final lanAuthKey = deriveLanAuthKey(accountKey);
    final myNonce = _nonceGenerator();
    // 超时视图必须在构造时应用一次并复用（socket.timeout 返回单订阅流）。
    // 复用调用方传入的连接（如 LanTransport 的长会话连接），保证握手后
    // 同一 socket 上还能继续读帧（Socket 是单订阅流，不能二次 listen）。
    final connection = existingConnection ??
        LanFrameConnection(socket, timeout: frameTimeout);

    Map<String, dynamic> helloMessage() => <String, dynamic>{
          'v': LanConstants.lanProtoVersion,
          'type': 'hello',
          'deviceId': deviceId,
          'nonce': myNonce,
        };

    String peerNonce;
    String peerDeviceId;
    try {
      if (isInitiator) {
        connection.write(helloMessage());
        final peerHello = await connection.read();
        peerNonce = _stringField(peerHello, 'nonce');
        peerDeviceId = _stringField(peerHello, 'deviceId');
      } else {
        final peerHello = await connection.read();
        peerNonce = _stringField(peerHello, 'nonce');
        peerDeviceId = _stringField(peerHello, 'deviceId');
        connection.write(helloMessage());
      }
    } on LanProtocolException catch (e) {
      throw LanHandshakeException('protocol', 'hello exchange failed: ${e.message}');
    }
    if (!claimNonce(peerNonce)) {
      throw LanHandshakeException('replayNonce', 'peer nonce replayed: $peerNonce');
    }

    final myTicket = await fetchTicket(deviceId: deviceId);
    if (myTicket.expiresAtMs <= DateTime.now().millisecondsSinceEpoch) {
      throw LanHandshakeException('expiredTicket', 'own ticket already expired');
    }

    final initiatorNonce = isInitiator ? myNonce : peerNonce;
    final responderNonce = isInitiator ? peerNonce : myNonce;

    final myAuth = <String, dynamic>{
      'v': LanConstants.lanProtoVersion,
      'type': 'auth',
      'ticket': myTicket.value,
      'proof': buildProof(
        lanAuthKey: lanAuthKey,
        initiatorNonce: initiatorNonce,
        responderNonce: responderNonce,
        ticket: myTicket.value,
      ),
    };

    final LanVerifiedTicket peerVerified;
    try {
      if (isInitiator) {
        connection.write(myAuth);
        final peerAuth = await connection.read();
        peerVerified = await _verifyPeer(
          lanAuthKey: lanAuthKey,
          initiatorNonce: initiatorNonce,
          responderNonce: responderNonce,
          peerTicket: _stringField(peerAuth, 'ticket'),
          peerProof: _stringField(peerAuth, 'proof'),
          userId: userId,
        );
      } else {
        final peerAuth = await connection.read();
        peerVerified = await _verifyPeer(
          lanAuthKey: lanAuthKey,
          initiatorNonce: initiatorNonce,
          responderNonce: responderNonce,
          peerTicket: _stringField(peerAuth, 'ticket'),
          peerProof: _stringField(peerAuth, 'proof'),
          userId: userId,
        );
        connection.write(myAuth);
      }
    } on LanHandshakeException {
      rethrow;
    } on LanProtocolException catch (e) {
      throw LanHandshakeException('protocol', 'auth exchange failed: ${e.message}');
    }

    return LanSession(
      peerDeviceId: peerVerified.deviceId,
      expiresAtMs: peerVerified.expiresAtMs,
    );
  }

  /// 校验对端 auth：① proof 必须由「我们的 K_lan」生成（错账户 → 拒绝）；
  /// ② 服务端 verify 票据并实时复查 removed_at；③ 服务端返回的 userId 必须
  /// 等于本地 userId（账户归属一致性）；④ 票据未过期。
  Future<LanVerifiedTicket> _verifyPeer({
    required Uint8List lanAuthKey,
    required String initiatorNonce,
    required String responderNonce,
    required String peerTicket,
    required String peerProof,
    required String userId,
  }) async {
    if (!verifyProof(
      lanAuthKey: lanAuthKey,
      initiatorNonce: initiatorNonce,
      responderNonce: responderNonce,
      ticket: peerTicket,
      proof: peerProof,
    )) {
      throw LanHandshakeException('wrongAccount', 'peer proof does not match our account key');
    }
    final verified = await verifyTicket(peerTicket);
    if (verified.userId != userId) {
      throw LanHandshakeException('wrongAccount', 'peer belongs to a different account');
    }
    if (verified.expiresAtMs <= DateTime.now().millisecondsSinceEpoch) {
      throw LanHandshakeException('expiredTicket', 'peer ticket expired');
    }
    return verified;
  }

  static String _stringField(Map<String, dynamic> message, String key) {
    final value = message[key];
    if (value is! String || value.isEmpty) {
      throw LanProtocolException('missing or invalid field: $key');
    }
    return value;
  }
}
