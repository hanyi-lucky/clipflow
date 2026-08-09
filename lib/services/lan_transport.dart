import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;

import '../core/constants.dart';
import '../repositories/cloud_repository.dart';
import '../services/cloudbase_service.dart';
import 'lan_handshake_service.dart';
import 'lan_protocol.dart';
import 'lan_tls.dart';

/// 会话级传输状态（内部结构：socket + 复用帧连接）。
///
/// `LanFrameConnection` 必须与握手共用同一实例：`Socket` 是单订阅流，
/// 握手结束后不能在同一个 socket 上再创建新的读取器。
class _LanSession {
  _LanSession({
    required this.peerDeviceId,
    required this.expiresAtMs,
    required this.socket,
    required this.connection,
    required this.isInitiator,
  });

  final String peerDeviceId;
  final int expiresAtMs;
  final Socket socket;
  final LanFrameConnection connection;
  final bool isInitiator;
}

/// LAN TCP/TLS 生命周期管理。
///
/// - responder：`SecureServerSocket` 接受连接 → 握手（responder 角色）→
///   会话帧循环（应答 `latestRequest`、接收 `push`）；
/// - initiator：`SecureSocket.connect` + 指纹固定 → 握手（initiator 角色）→
///   复用连接做 `fetchLatest`（latestRequest/latestResponse）与 `push`。
///
/// 任何帧错误只断单个 session，不拖垮整体；`noDelay=true`。
class LanTransport {
  LanTransport({
    LanHandshakeService? handshakeService,
    DateTime Function()? now,
  })  : _handshake =
            handshakeService ?? LanHandshakeService(cloudRepository: CloudRepository(CloudBaseService())),
        _now = now ?? DateTime.now;

  final LanHandshakeService _handshake;
  final DateTime Function() _now;
  SecureServerSocket? _server;
  final Map<String, _LanSession> _initiatorSessions = {};
  final Map<String, _LanSession> _responderSessions = {};
  bool _closed = false;

  /// responder 应答 `latestRequest` 时提供本机最新 row（由 LanSyncManager 注入）。
  Map<String, dynamic>? Function()? latestRowProvider;

  /// responder 收到 peer 的 `push` 帧时回调（由 LanSyncManager 注入）。
  void Function(Map<String, dynamic> row)? onPushReceived;

  /// 会话被丢弃（帧错误/超时）时回调（预留诊断）。
  void Function(String peerDeviceId)? onSessionDropped;

  /// 启动 responder 服务，返回绑定的临时端口（供 mDNS 广告）。
  Future<int> startServer({
    required String deviceId,
    required String userId,
    required Uint8List accountKey,
  }) async {
    if (_closed) throw LanProtocolException('LAN transport closed');
    final context = await LanTls.createServerSecurityContext();
    _server = await SecureServerSocket.bind(
      InternetAddress.anyIPv4,
      0,
      context,
    );
    final port = _server!.port;
    unawaited(_acceptLoop(
      deviceId: deviceId,
      userId: userId,
      accountKey: accountKey,
    ));
    return port;
  }

  Future<void> _acceptLoop({
    required String deviceId,
    required String userId,
    required Uint8List accountKey,
  }) async {
    final server = _server;
    if (server == null) return;
    try {
      await for (final socket in server) {
        if (_closed) {
          socket.destroy();
          break;
        }
        if (_responderSessions.length >= LanConstants.maxConcurrentSessions) {
          socket.destroy();
          continue;
        }
        unawaited(_handleResponderSocket(
          socket,
          deviceId: deviceId,
          userId: userId,
          accountKey: accountKey,
        ));
      }
    } catch (e) {
      debugPrint('[LAN-TRANSPORT] accept loop ended: $e');
    }
  }

  /// 作为 responder 处理一条入站连接：握手 → 会话帧循环。
  Future<void> _handleResponderSocket(
    Socket socket, {
    required String deviceId,
    required String userId,
    required Uint8List accountKey,
  }) async {
    var sessionPeerId = '';
    try {
      socket.setOption(SocketOption.tcpNoDelay, true);
      final connection = LanFrameConnection(
        socket,
        timeout: LanConstants.lanSessionIdleTimeout,
      );
      final session = await _handshake
          .performHandshake(
            socket: socket,
            existingConnection: connection,
            isInitiator: false,
            deviceId: deviceId,
            userId: userId,
            accountKey: accountKey,
          )
          .timeout(LanConstants.lanHandshakeTimeout);
      sessionPeerId = session.peerDeviceId;
      _responderSessions[sessionPeerId] = _LanSession(
        peerDeviceId: session.peerDeviceId,
        expiresAtMs: session.expiresAtMs,
        socket: socket,
        connection: connection,
        isInitiator: false,
      );
      // 会话帧循环：latestRequest → 应答；push → 通知；未知帧 → 断链。
      while (true) {
        final frame = await connection.read();
        final type = frame['type'];
        if (type == 'latestRequest') {
          connection.write(<String, dynamic>{
            'v': LanConstants.lanProtoVersion,
            'type': 'latestResponse',
            'row': latestRowProvider?.call(),
          });
        } else if (type == 'push') {
          final row = frame['row'];
          if (row is Map<String, dynamic>) {
            onPushReceived?.call(row);
          }
        } else {
          break;
        }
      }
    } on TimeoutException {
      debugPrint('[LAN-TRANSPORT] responder handshake timed out');
    } on LanHandshakeException catch (e) {
      debugPrint('[LAN-TRANSPORT] responder handshake rejected: ${e.reason}');
    } on LanProtocolException catch (e) {
      debugPrint('[LAN-TRANSPORT] responder session dropped: ${e.message}');
    } on SocketException catch (e) {
      debugPrint('[LAN-TRANSPORT] responder socket error: ${e.message}');
    } catch (e) {
      debugPrint('[LAN-TRANSPORT] responder session error: $e');
    } finally {
      if (sessionPeerId.isNotEmpty) {
        _responderSessions.remove(sessionPeerId);
      }
      socket.destroy();
    }
  }

  /// 作为 initiator 连接 peer：TLS + 指纹固定 + 双向挑战握手。
  ///
  /// 握手被拒（错账户/票据等）抛 [LanHandshakeException]；网络错误抛
  /// [SocketException]/[TimeoutException]——由调用方决定是否黑名单。
  Future<void> connect({
    required String peerDeviceId,
    required String host,
    required int port,
    required String userId,
    required String deviceId,
    required Uint8List accountKey,
  }) async {
    if (_closed) throw LanProtocolException('LAN transport closed');
    final socket = await SecureSocket.connect(
      host,
      port,
      onBadCertificate: LanTls.isTrustedCertificate,
      timeout: LanConstants.lanConnectTimeout,
    );
    try {
      socket.setOption(SocketOption.tcpNoDelay, true);
      final connection = LanFrameConnection(
        socket,
        timeout: LanConstants.lanSessionIdleTimeout,
      );
      final session = await _handshake
          .performHandshake(
            socket: socket,
            existingConnection: connection,
            isInitiator: true,
            deviceId: deviceId,
            userId: userId,
            accountKey: accountKey,
          )
          .timeout(LanConstants.lanHandshakeTimeout);
      _initiatorSessions[peerDeviceId] = _LanSession(
        peerDeviceId: session.peerDeviceId,
        expiresAtMs: session.expiresAtMs,
        socket: socket,
        connection: connection,
        isInitiator: true,
      );
    } catch (e) {
      socket.destroy();
      rethrow;
    }
  }

  bool hasSession(String peerDeviceId) =>
      _initiatorSessions.containsKey(peerDeviceId);

  /// 已建立 initiator 会话（可 fetch/push）的 peer 列表。
  List<String> get verifiedPeerIds => _initiatorSessions.keys.toList();

  /// 向 [peerDeviceId] 发送 latestRequest 并等待 latestResponse。
  ///
  /// peer 无内容时返回 null（会话保持健康）；超时/帧错误会丢弃该会话并
  /// 返回 null（调用方无需区分——下一轮会自动重连）。
  Future<Map<String, dynamic>?> fetchLatest(String peerDeviceId) async {
    final session = _initiatorSessions[peerDeviceId];
    if (session == null) return null;
    try {
      session.connection.write(<String, dynamic>{
        'v': LanConstants.lanProtoVersion,
        'type': 'latestRequest',
      });
      final response = await session.connection.read();
      if (response['type'] != 'latestResponse') {
        _dropInitiatorSession(peerDeviceId);
        return null;
      }
      final row = response['row'];
      if (row is! Map<String, dynamic>) return null;
      return row;
    } on LanProtocolException {
      _dropInitiatorSession(peerDeviceId);
      return null;
    } on SocketException {
      _dropInitiatorSession(peerDeviceId);
      return null;
    }
  }

  /// 向 [peerDeviceId] 推送一行（写后即返回，无持久 ACK；2.3 再做 ACK）。
  Future<void> push(String peerDeviceId, Map<String, dynamic> row) async {
    final session = _initiatorSessions[peerDeviceId];
    if (session == null) return;
    try {
      session.connection.write(<String, dynamic>{
        'v': LanConstants.lanProtoVersion,
        'type': 'push',
        'row': row,
      });
    } on LanProtocolException {
      _dropInitiatorSession(peerDeviceId);
    } on SocketException {
      _dropInitiatorSession(peerDeviceId);
    }
  }

  /// 丢弃单个 initiator 会话（超时/帧错误后连接可能处于脏状态）。
  void dropSession(String peerDeviceId) {
    _dropInitiatorSession(peerDeviceId);
  }

  void _dropInitiatorSession(String peerDeviceId) {
    final session = _initiatorSessions.remove(peerDeviceId);
    if (session == null) return;
    session.socket.destroy();
    onSessionDropped?.call(peerDeviceId);
  }

  /// 关闭服务器与全部会话。
  Future<void> closeAll() async {
    _closed = true;
    for (final session in _initiatorSessions.values) {
      session.socket.destroy();
    }
    _initiatorSessions.clear();
    for (final session in _responderSessions.values) {
      session.socket.destroy();
    }
    _responderSessions.clear();
    final server = _server;
    _server = null;
    if (server != null) {
      await server.close();
    }
  }
}
