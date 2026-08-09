import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;

import '../core/constants.dart';
import '../repositories/cloud_repository.dart';
import '../services/cloudbase_service.dart';
import 'lan_diagnostics.dart';
import 'lan_handshake_service.dart';
import 'lan_protocol.dart';
import 'lan_tls.dart';

/// push/pushFile 的交付结果（Phase 2.3 ACK）。
enum LanPushResult {
  /// 对端已确认（支持 acks 且收到匹配 fileAck）；或不支持 acks 的旧 peer
  /// 写后即返回（Phase 2.2 语义）。
  delivered,

  /// 写帧成功但未在超时内收到匹配 fileAck（或会话丢失）→ 待确认表重试。
  pending,

  /// 无该 peer 的 initiator 会话（静默跳过，与 Phase 2.2 一致）。
  noSession,
}

/// 构造 fileAck 帧：只携带 `historyId`（= operationId，非敏感）与 `status:'ok'`。
/// 红线：不含 userId/密码/token/K_lan/salt/指纹/文件名明文等任何敏感字段。
Map<String, dynamic> buildFileAckFrame(String historyId) {
  return <String, dynamic>{
    'v': LanConstants.lanProtoVersion,
    'type': 'fileAck',
    'historyId': historyId,
    'status': 'ok',
  };
}

/// 判定帧是否为匹配 [historyId] 的 fileAck（status == 'ok'）。
/// 不匹配 / status 非 ok / 非 fileAck → 协议违规（调用方应断会话自愈）。
bool isMatchingFileAck(Map<String, dynamic> frame, String historyId) {
  return frame['type'] == 'fileAck' &&
      frame['historyId'] == historyId &&
      frame['status'] == 'ok';
}

/// 会话级 reader slot：同一时刻只允许一个读方（fetchLatest / ack-wait）。
///
/// - fetchLatest 用 [tryAcquire]：busy 立即返回 false，跳过该 peer 本轮
///   （绝不排队、绝不 dropSession——否则 300ms 超时会把文件 ack-wait 杀死）；
/// - ack-wait 用有界 [acquire]（≤ lanAckSlotWait），超时 → pending 重试。
class LanReaderSlot {
  bool _busy = false;

  bool get busy => _busy;

  /// 非阻塞 try-acquire；成功返回 true。
  bool tryAcquire() {
    if (_busy) return false;
    _busy = true;
    return true;
  }

  /// 有界等待获取；[timeout] 为 null 时等价 [tryAcquire]。
  Future<bool> acquire({Duration? timeout}) async {
    if (tryAcquire()) return true;
    if (timeout == null) return false;
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      if (tryAcquire()) return true;
    }
    return false;
  }

  void release() {
    _busy = false;
  }
}

/// 会话级传输状态（内部结构：socket + 复用帧连接 + 读串行化 slot）。
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
    required this.peerSupportsAcks,
  });

  final String peerDeviceId;
  final int expiresAtMs;
  final Socket socket;
  final LanFrameConnection connection;
  final bool isInitiator;

  /// 对端 hello 是否携带 `acks:1`（Phase 2.3）。旧 peer → false →
  /// 本端不回 ack、不等待 ack（Phase 2.2 写后即返回语义）。
  final bool peerSupportsAcks;

  /// 读串行化：fetchLatest 与 ack-wait 互斥（单订阅流硬约束）。
  final LanReaderSlot readerSlot = LanReaderSlot();
}

/// 单会话文件接收状态机：`fileStart`/`fileChunk` 帧校验 + 流式落盘。
///
/// - 生命周期只活在会话内存（不落盘、无续传、无 ACK——2.3 再补）；
/// - 状态由发送方在 `fileStart` 中声明（encSize/chunkSize/total），
///   接收方严格校验：encSize ∈ (0, lanMaxFileBytes+1024]、total ==
///   ceil(encSize/chunkSize)、total ≤ lanMaxFileChunks、chunkSize ≤ 1MiB、
///   chunk 帧序严格 0..total-1、base64 严格解码、累计字节 ≤ encSize；
/// - 任一违规或新 `fileStart` 抢占 → abort（`controller.addError` →
///   `saveEncryptedFromStream` fail 路径删 `.part`，不产生 `.enc`）；
/// - 字节收齐（== encSize）→ close 流 → 落盘 rename → `onComplete(row, encPath)`。
class LanFileReceiver {
  LanFileReceiver({
    Future<String?> Function({
      required String entryId,
      required Stream<List<int>> stream,
    })? sink,
    void Function(Map<String, dynamic> row, String encPath)? onComplete,
  })  : _sink = sink,
        _onComplete = onComplete;

  final Future<String?> Function({
    required String entryId,
    required Stream<List<int>> stream,
  })? _sink;
  final void Function(Map<String, dynamic> row, String encPath)? _onComplete;

  _FileTransferState? _transfer;

  /// 处理 `fileStart` 帧。返回 false 表示校验失败（调用方应断会话）。
  bool handleFileStart(Map<String, dynamic> frame) {
    abort(); // 新 fileStart 抢占旧传输：先中止旧 .part
    final sink = _sink;
    if (sink == null) return false;
    final row = frame['row'];
    final encSizeRaw = frame['encSize'];
    final totalRaw = frame['total'];
    final chunkSizeRaw = frame['chunkSize'];
    if (row is! Map<String, dynamic>) return false;
    if (row['type'] != 'file') return false;
    final historyId = row['history_id'];
    if (historyId is! String || historyId.isEmpty) return false;
    final encSize = (encSizeRaw as num?)?.toInt() ?? -1;
    final total = (totalRaw as num?)?.toInt() ?? -1;
    final chunkSize = (chunkSizeRaw as num?)?.toInt() ?? -1;
    if (encSize <= 0 || encSize > LanConstants.lanMaxFileBytes + 1024) {
      return false;
    }
    if (chunkSize <= 0 || chunkSize > LanConstants.lanFileChunkBytes) {
      return false;
    }
    if (total <= 0 || total > LanConstants.lanMaxFileChunks) return false;
    if (total != (encSize + chunkSize - 1) ~/ chunkSize) return false;

    final controller = StreamController<List<int>>();
    final saveFuture = sink(entryId: historyId, stream: controller.stream);
    _transfer = _FileTransferState(
      row: row,
      historyId: historyId,
      encSize: encSize,
      total: total,
      chunkSize: chunkSize,
      controller: controller,
    );
    unawaited(saveFuture.then((encPath) {
      if (encPath != null) {
        _onComplete?.call(row, encPath);
      }
    }).catchError((Object e) {
      debugPrint('[LAN-TRANSPORT] file receive save failed: $e');
    }));
    return true;
  }

  /// 处理 `fileChunk` 帧。返回 false 表示违规（已自动 abort，调用方应断会话）。
  bool handleFileChunk(Map<String, dynamic> frame) {
    final transfer = _transfer;
    if (transfer == null) return false;
    if (!_validateChunk(frame, transfer)) {
      abort(); // 违规：删 .part，不产生 .enc
      return false;
    }
    final bytes = base64Url.decode(frame['data'] as String);
    transfer.receivedBytes += bytes.length;
    transfer.expectedSeq++;
    transfer.controller.add(bytes);
    if (transfer.receivedBytes == transfer.encSize) {
      transfer.controller.close();
      _transfer = null;
    }
    return true;
  }

  bool _validateChunk(Map<String, dynamic> frame, _FileTransferState transfer) {
    final historyId = frame['historyId'];
    if (historyId is! String || historyId != transfer.historyId) return false;
    final seq = (frame['seq'] as num?)?.toInt() ?? -1;
    if (seq != transfer.expectedSeq) return false; // 乱序/重复
    final data = frame['data'];
    if (data is! String) return false;
    final List<int> bytes;
    try {
      bytes = base64Url.decode(data);
    } catch (_) {
      return false; // 畸形 base64：严格解码失败
    }
    if (bytes.isEmpty || bytes.length > transfer.chunkSize) return false;
    if (transfer.receivedBytes + bytes.length > transfer.encSize) return false;
    // 防御：字节收满必须在最后一帧（total == ceil(encSize/chunkSize) 保证）
    if (transfer.receivedBytes + bytes.length == transfer.encSize &&
        transfer.expectedSeq + 1 != transfer.total) {
      return false;
    }
    return true;
  }

  /// 中止当前传输：删 `.part`、不产生 `.enc`（半途失败/断链/抢占）。
  void abort() {
    final transfer = _transfer;
    _transfer = null;
    if (transfer == null) return;
    if (!transfer.controller.isClosed) {
      transfer.controller.addError(LanProtocolException('file transfer aborted'));
    }
  }
}

class _FileTransferState {
  _FileTransferState({
    required this.row,
    required this.historyId,
    required this.encSize,
    required this.total,
    required this.chunkSize,
    required this.controller,
  });

  final Map<String, dynamic> row;
  final String historyId;
  final int encSize;
  final int total;
  final int chunkSize;
  final StreamController<List<int>> controller;
  int expectedSeq = 0;
  int receivedBytes = 0;
}

/// 把密文文件按 1MiB 切块写 `fileStart` + N×`fileChunk` 帧。
///
/// 流式读取 artifact（绝不整文件进内存），base64 每帧 ≤1.4MiB，
/// 远低于 16MiB 帧上限。`write` 为逐帧写出回调（会话 connection.write）。
Future<void> writeFileFrames({
  required void Function(Map<String, dynamic> frame) write,
  required Map<String, dynamic> row,
  required String encryptedPath,
  required int encSize,
}) async {
  final chunkSize = LanConstants.lanFileChunkBytes;
  final total = (encSize + chunkSize - 1) ~/ chunkSize;
  if (total > LanConstants.lanMaxFileChunks) {
    throw LanProtocolException(
      'file $encSize bytes exceeds LAN chunk limit '
      '${LanConstants.lanMaxFileChunks}',
    );
  }
  write(<String, dynamic>{
    'v': LanConstants.lanProtoVersion,
    'type': 'fileStart',
    'row': row,
    'encSize': encSize,
    'chunkSize': chunkSize,
    'total': total,
  });
  final file = File(encryptedPath);
  final raf = await file.open();
  try {
    final buffer = BytesBuilder(copy: false);
    var seq = 0;
    while (true) {
      final chunk = await raf.read(chunkSize);
      if (chunk.isEmpty) break;
      buffer.add(chunk);
      if (buffer.length >= chunkSize) {
        write(<String, dynamic>{
          'v': LanConstants.lanProtoVersion,
          'type': 'fileChunk',
          'historyId': row['history_id'],
          'seq': seq,
          'data': base64Url.encode(buffer.takeBytes()),
        });
        seq++;
      }
    }
    if (buffer.length > 0) {
      write(<String, dynamic>{
        'v': LanConstants.lanProtoVersion,
        'type': 'fileChunk',
        'historyId': row['history_id'],
        'seq': seq,
        'data': base64Url.encode(buffer.takeBytes()),
      });
    }
  } finally {
    await raf.close();
  }
}

/// LAN TCP/TLS 生命周期管理。
///
/// - responder：`SecureServerSocket` 接受连接 → 握手（responder 角色）→
///   会话帧循环（应答 `latestRequest`、接收 `push`/`fileStart`/`fileChunk`）；
/// - initiator：`SecureSocket.connect` + 指纹固定 → 握手（initiator 角色）→
///   复用连接做 `fetchLatest`（latestRequest/latestResponse）、`push` 与
///   `pushFile`（fileStart + fileChunk 分块）。
///
/// 任何帧错误只断单个 session，不拖垮整体；`noDelay=true`。
class LanTransport {
  LanTransport({
    LanHandshakeService? handshakeService,
    LanDiagnostics? diagnostics,
    DateTime Function()? now,
  })  : _handshake =
            handshakeService ?? LanHandshakeService(cloudRepository: CloudRepository(CloudBaseService()), diagnostics: diagnostics),
        _diagnostics = diagnostics,
        _now = now ?? DateTime.now;

  final LanHandshakeService _handshake;
  final LanDiagnostics? _diagnostics;
  final DateTime Function() _now;
  SecureServerSocket? _server;
  final Map<String, _LanSession> _initiatorSessions = {};
  final Map<String, _LanSession> _responderSessions = {};
  bool _closed = false;

  /// responder 应答 `latestRequest` 时提供本机最新 row（由 LanSyncManager 注入）。
  Map<String, dynamic>? Function()? latestRowProvider;

  /// responder 收到 peer 的 `push` 帧时回调（由 LanSyncManager 注入）。
  void Function(Map<String, dynamic> row)? onPushReceived;

  /// responder 收到 `fileStart` 帧时为该 historyId 创建密文落盘流。
  /// 注入方（LanSyncManager）用 LocalFileStore.saveEncryptedFromStream 包装：
  /// 写 tmp `.part`，字节收齐（流 close）后 rename 成 `<historyId>.enc`。
  /// 返回的 Future 在流 close（落盘完成）时才 complete。
  Future<String?> Function({
    required String entryId,
    required Stream<List<int>> stream,
  })? fileSink;

  /// 文件密文完整落盘（`.enc` 已 rename）后回调（由 LanSyncManager 注入）。
  void Function(Map<String, dynamic> row, String encPath)? onFilePushReceived;

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
    LanFileReceiver? fileReceiver;
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
      final peerSupportsAcks = session.peerSupportsAcks;
      _responderSessions[sessionPeerId] = _LanSession(
        peerDeviceId: session.peerDeviceId,
        expiresAtMs: session.expiresAtMs,
        socket: socket,
        connection: connection,
        isInitiator: false,
        peerSupportsAcks: peerSupportsAcks,
      );
      fileReceiver = LanFileReceiver(
        sink: fileSink,
        onComplete: (row, encPath) {
          // `.enc` 原子落盘完成 → 通知下载 → 对支持 acks 的 peer 回 fileAck
          //（文件 ack 语义必须是「真实落盘」，不能是「帧到达」）。
          onFilePushReceived?.call(row, encPath);
          if (peerSupportsAcks) {
            try {
              connection.write(buildFileAckFrame(row['history_id'] as String? ?? ''));
              _diagnostics?.ackSent++;
            } catch (e) {
              debugPrint('[LAN-TRANSPORT] fileAck write failed: $e');
            }
          }
        },
      );
      // 会话帧循环：latestRequest → 应答；push → 通知；fileStart/fileChunk
      // → 文件分块重组；未知帧 → 断链。文件帧违规 → 中止 + 断会话。
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
            // 仅对支持 acks 的新 peer 回 fileAck；旧 initiator（hello 无 acks）
            // 不发，否则其 fetchLatest 会读到滞留 fileAck 误判 latestResponse
            // 类型不符 → 无谓断链（老兼容缺口必须堵住）。
            if (session.peerSupportsAcks) {
              try {
                connection.write(
                  buildFileAckFrame(row['history_id'] as String? ?? ''),
                );
                _diagnostics?.ackSent++;
              } catch (e) {
                debugPrint('[LAN-TRANSPORT] fileAck write failed: $e');
              }
            }
          }
        } else if (type == 'fileStart') {
          if (!fileReceiver.handleFileStart(frame)) break;
        } else if (type == 'fileChunk') {
          if (!fileReceiver.handleFileChunk(frame)) break;
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
      // 断链/中止：清理未完成文件传输（删 .part，不产生 .enc）。
      fileReceiver?.abort();
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
        peerSupportsAcks: session.peerSupportsAcks,
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
  ///
  /// 读串行化：ack-wait 占用 reader slot 时**直接跳过本轮**（返回 null），
  /// 绝不排队、绝不 dropSession——否则 fetchLatest 的 300ms 超时会杀死
  /// 文件 ack-wait（15MiB 文件永无法经 LAN 交付，轮询 500ms 必杀）。
  Future<Map<String, dynamic>?> fetchLatest(String peerDeviceId) async {
    final session = _initiatorSessions[peerDeviceId];
    if (session == null) return null;
    if (!session.readerSlot.tryAcquire()) return null; // busy：跳过该 peer
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
    } finally {
      session.readerSlot.release();
    }
  }

  /// 该 peer 的 initiator 会话是否支持 acks（hello 携带 `acks:1`）。
  /// 旧 peer / 无会话 → false（Phase 2.2 写后即返回语义）。
  bool supportsAcks(String peerDeviceId) =>
      _initiatorSessions[peerDeviceId]?.peerSupportsAcks ?? false;

  /// 向 [peerDeviceId] 推送一行。
  ///
  /// - 旧 peer（无 acks）：写后即返回 [LanPushResult.delivered]（Phase 2.2）；
  /// - 新 peer：获取 reader slot（≤ lanAckSlotWait）→ 读 fileAck
  ///   （text/image 超时 lanAckTimeoutText）→ 匹配 delivered / 超时 pending；
  /// - 无会话 → [LanPushResult.noSession]（静默跳过）。
  Future<LanPushResult> push(String peerDeviceId, Map<String, dynamic> row) async {
    final session = _initiatorSessions[peerDeviceId];
    if (session == null) return LanPushResult.noSession;
    try {
      session.connection.write(<String, dynamic>{
        'v': LanConstants.lanProtoVersion,
        'type': 'push',
        'row': row,
      });
      if (!session.peerSupportsAcks) {
        return LanPushResult.delivered; // 旧 peer：写后即返回
      }
      return await _awaitFileAck(
        session,
        row['history_id'] as String? ?? '',
        LanConstants.lanAckTimeoutText,
      );
    } on LanProtocolException {
      _dropInitiatorSession(peerDeviceId);
      return LanPushResult.pending;
    } on SocketException {
      _dropInitiatorSession(peerDeviceId);
      return LanPushResult.pending;
    }
  }

  /// 向 [peerDeviceId] 推送文件密文：`fileStart` + N×`fileChunk`（1MiB 分块）。
  ///
  /// - 旧 peer（无 acks）：写后即返回 [LanPushResult.delivered]（Phase 2.2）；
  /// - 新 peer：写帧阶段不占 reader slot（纯写，与 fetchLatest 的 write+read
  ///   可安全交叠，TCP 保序）；仅最终 ack-read 占 slot，等待对端 `.enc` 原子
  ///   落盘后的 fileAck（超时 lanAckTimeoutFile）。
  /// - 帧错/网络错只断该会话。密文从 [encryptedPath] 流式读取，绝不整文件进内存。
  Future<LanPushResult> pushFile(
    String peerDeviceId,
    Map<String, dynamic> row, {
    required String encryptedPath,
    required int encSize,
  }) async {
    final session = _initiatorSessions[peerDeviceId];
    if (session == null) return LanPushResult.noSession;
    try {
      await writeFileFrames(
        write: session.connection.write,
        row: row,
        encryptedPath: encryptedPath,
        encSize: encSize,
      );
      if (!session.peerSupportsAcks) {
        return LanPushResult.delivered; // 旧 peer：写后即返回
      }
      return await _awaitFileAck(
        session,
        row['history_id'] as String? ?? '',
        LanConstants.lanAckTimeoutFile,
      );
    } on LanProtocolException {
      _dropInitiatorSession(peerDeviceId);
      return LanPushResult.pending;
    } on SocketException {
      _dropInitiatorSession(peerDeviceId);
      return LanPushResult.pending;
    }
  }

  /// 等待匹配 fileAck：占 reader slot（≤ lanAckSlotWait）→ 读帧 → 判定。
  /// 匹配 → delivered；超时 → pending（重试）；不匹配/协议错 → 断会话自愈。
  Future<LanPushResult> _awaitFileAck(
    _LanSession session,
    String historyId,
    Duration timeout,
  ) async {
    final acquired = await session.readerSlot.acquire(
      timeout: LanConstants.lanAckSlotWait,
    );
    if (!acquired) return LanPushResult.pending;
    try {
      // 短超时用 Future.timeout 包裹 read()（LanFrameConnection 的 socket
      // 超时视图在构造时固定为会话空闲超时，不能重建连接）。
      final response = await session.connection.read().timeout(timeout);
      if (isMatchingFileAck(response, historyId)) {
        _diagnostics?.ackReceived++;
        return LanPushResult.delivered;
      }
      // 协议违规（historyId 不匹配 / status 非 ok / 其它帧类型）→ 断会话自愈。
      _dropInitiatorSession(session.peerDeviceId);
      return LanPushResult.pending;
    } on TimeoutException {
      return LanPushResult.pending;
    } on LanProtocolException {
      _dropInitiatorSession(session.peerDeviceId);
      return LanPushResult.pending;
    } on SocketException {
      _dropInitiatorSession(session.peerDeviceId);
      return LanPushResult.pending;
    } finally {
      session.readerSlot.release();
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
