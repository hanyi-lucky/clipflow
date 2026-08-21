import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;

import '../core/constants.dart';
import '../models/sync_operation.dart';
import '../repositories/cloud_repository.dart';
import '../repositories/local_file_store.dart';
import '../repositories/lan_outbox_store.dart';
import '../services/cloudbase_service.dart';
import 'lan_diagnostics.dart';
import 'lan_discovery_service.dart';
import 'lan_handshake_service.dart';
import 'lan_network_channel.dart';
import 'lan_transport.dart';

/// Provider 直接持有的 LAN 门面（Cloud-backed LAN acceleration）。
///
/// - 组合 Discovery（mDNS 候选）+ Transport（TLS/握手/帧）+ 本机缓存；
/// - `fetchLatestContent`：最多 4 个 verified peer、round-robin、300ms/peer
///   超时；刚收到 push 时直接命中本机缓存（LAN 加速）；
/// - `pushOperation`：仅 text/image，payload camelCase → server-shape row，
///   按 `peer.deviceId != row.source_device` 不回推来源；
/// - `_knownHistoryIds` 有界集合（≤200）防 push/fetch 重复缓存；
/// - 生命周期：`start`（失败静默降级 disabled，绝不抛）/ `stop`（清全部状态）。
///
/// 红线：LAN 报文不携带 userId/密码/token/K_lan/salt/指纹/文件名明文；
/// 对外方法绝不把网络错误抛给调用方（内部 catch + debugPrint）。
class LanSyncManager {
  LanSyncManager({
    CloudRepository? cloudRepository,
    LanDiscoveryService? discovery,
    LanTransport? transport,
    LanHandshakeService? handshakeService,
    LocalFileStore? fileStore,
    LanOutboxStore? outboxStore,
    LanDiagnostics? diagnostics,
    @visibleForTesting Duration fetchTimeout = LanConstants.lanFetchTimeout,
    @visibleForTesting Duration? retrySweepInterval,
    @visibleForTesting Duration? retryBaseDelay,
  })  : _fetchTimeout = fetchTimeout,
        _retrySweepInterval =
            retrySweepInterval ?? LanConstants.lanRetrySweepInterval,
        _retryBaseDelay =
            retryBaseDelay ?? LanConstants.lanPushRetryBaseDelay,
        _outboxStore = outboxStore ?? LanOutboxStore(),
        _fileStore = fileStore ?? LocalFileStore() {
    // 单例 diagnostics：先解析一次，再注入 discovery/handshake/transport
    // 三层默认构造分支（生产接线，见 Phase 2.3 reviewer 高置信问题 1）。
    _diagnostics = diagnostics ?? LanDiagnostics();
    _discovery = discovery ??
        LanDiscoveryService(diagnostics: _diagnostics);
    _transport = transport ??
        LanTransport(
          diagnostics: _diagnostics,
          handshakeService: handshakeService ??
              LanHandshakeService(
                cloudRepository: cloudRepository ??
                    CloudRepository(CloudBaseService()),
                diagnostics: _diagnostics,
              ),
        );
    _transport.latestRowProvider = () => _latestRow;
    _transport.onPushReceived = _handlePushReceived;
    // 文件密文落盘：tmp `.part` → 全部字节收齐后原子 rename 成 `.enc`；
    // onFilePushReceived 只在落盘完成后触发（fetch 命中文件行时 .enc 必已存在）。
    _transport.fileSink = ({
      required String entryId,
      required Stream<List<int>> stream,
    }) {
      return _fileStore.saveEncryptedFromStream(
        entryId: entryId,
        stream: stream,
      );
    };
    _transport.onFilePushReceived = _handleFilePushReceived;
    _transport.onOpReceived = _handleOpReceived;
  }

  late final LanDiscoveryService _discovery;
  late final LanTransport _transport;
  final LocalFileStore _fileStore;
  final LanOutboxStore _outboxStore;
  late final LanDiagnostics _diagnostics;
  final Duration _fetchTimeout;
  final Duration _retrySweepInterval;
  final Duration _retryBaseDelay;

  bool _enabled = false;
  bool _disposed = false;
  String? _userId;
  String? _deviceId;
  Uint8List? _accountKey;

  /// 待确认表（纯内存）：per(peerId, historyId) → 重试状态。
  /// 持久化副本在 LAN outbox（remove-on-ack）；本表负责超时重试调度。
  final Map<String, Map<String, _PendingAckEntry>> _pendingAcks = {};
  Timer? _retryTimer;

  /// 本机最新 row（server-shape，仅密文行）：可应答 peers 的 latestRequest。
  Map<String, dynamic>? _latestRow;

  /// historyId 去重（≤200，防 push/fetch 重复缓存）。
  final Set<String> _knownHistoryIds = {};
  static const int _maxKnownHistoryIds = 200;

  /// operationId 去重（≤200，镜像 `_knownHistoryIds`）：op 帧幂等应用。
  final Set<String> _knownOpIds = {};
  static const int _maxKnownOpIds = 200;

  /// Provider 注册：收到 delete op 帧（服务端已 durable 提交）→ 本地移除条目。
  void Function(String entryId)? onDeleteOpReceived;

  /// Provider 注册：收到 restore op 帧（带服务端权威 row）→ 重建条目。
  void Function(Map<String, dynamic> row)? onRestoreOpReceived;

  int _roundRobinIndex = 0;

  /// 刚收到 push 且尚未被下载消费：下一次 fetch 直接命中本机缓存。
  bool _pushPending = false;

  /// Provider 注册：收到 push 帧后触发一次立即下载。
  void Function()? onPushReceived;

  bool get isEnabled => _enabled;

  /// 真实握手态：是否存在已 verified 的 LAN peer（驱动 Provider 状态派生，
  /// 非模拟信号）。initiator 会话建立即 verified（TLS + 票据 + userId 校验通过）。
  bool get hasVerifiedPeers => _transport.verifiedPeerIds.isNotEmpty;

  /// 诊断计数（本会话累计；LAN 启停/切账户清零）。
  LanDiagnostics get diagnostics => _diagnostics;

  /// 测试专用：访问默认构造内部创建的真实 discovery/transport。
  /// 组合测试据此验证「默认构造 → 子服务共享 manager 单例 diagnostics」
  /// 的生产接线（Phase 2.3 修复：三处 `diagnostics: _diagnostics` 注入）。
  @visibleForTesting
  LanDiscoveryService get debugDiscovery => _discovery;

  @visibleForTesting
  LanTransport get debugTransport => _transport;

  /// 诊断 UI「清零」按钮。
  void resetDiagnostics() => _diagnostics.reset();

  /// 账户切换：删除指定用户的持久化 LAN outbox（LAN 开关关闭不调用）。
  Future<void> clearPersistedOutbox(String userId) async {
    try {
      await _outboxStore.clearPersistedOutbox(userId);
    } catch (e) {
      debugPrint('[LAN] clear persisted outbox failed: $e');
    }
  }

  /// 启动 LAN：广播 + 浏览 + responder 服务。任何失败（平台不支持/权限
  /// 缺失/异常）都静默降级为 disabled，绝不抛给调用方。
  Future<void> start({
    required String userId,
    required String deviceId,
    required Uint8List accountKey,
    bool enabled = true,
  }) async {
    if (_disposed) return;
    _resetState();
    if (!enabled) return;
    try {
      final port = await _transport.startServer(
        deviceId: deviceId,
        userId: userId,
        accountKey: accountKey,
      );
      final started = await _discovery.start(
        deviceId: deviceId,
        caps: LanConstants.lanCaps,
        port: port,
      );
      if (!started) {
        await _transport.closeAll();
        return;
      }
      _userId = userId;
      _deviceId = deviceId;
      _accountKey = accountKey;
      _enabled = true;
      // 重启恢复：把持久化 LAN outbox 载入待确认表（缺 artifact 的文件条目
      // 丢弃），并登记 _knownHistoryIds 防回声；随后 sweeper 重试未 ack 条目。
      await _restoreOutbox(userId);
      _startRetrySweeper();
      debugPrint('[LAN] manager started on port $port');
    } on LanNetworkException catch (e) {
      debugPrint('[LAN] start disabled: ${e.code}');
      await _transport.closeAll();
    } catch (e) {
      debugPrint('[LAN] start disabled: $e');
      await _transport.closeAll();
    }
  }

  /// 停止 LAN 并清理全部状态（账户切换/关闭时调用）。
  Future<void> stop() async {
    _enabled = false;
    _resetState();
    try {
      await _discovery.stop();
      await _transport.closeAll();
    } catch (e) {
      debugPrint('[LAN] stop error: $e');
    }
  }

  void _resetState() {
    _userId = null;
    _deviceId = null;
    _accountKey = null;
    _latestRow = null;
    _knownHistoryIds.clear();
    _roundRobinIndex = 0;
    _pushPending = false;
    // 内存态清理：待确认表 + 重试定时器 + 诊断计数。
    // 注意：**不得**删持久化 outbox——LAN 开关关闭保留，
    // 只有账户切换才经 clearPersistedOutbox 清理。
    _retryTimer?.cancel();
    _retryTimer = null;
    _pendingAcks.clear();
    _diagnostics.reset();
  }

  /// 待确认表条目（内存态）：持有持久化 outbox 条目的引用 + 下次重试时间。
  /// [LanOutboxEntry.attempts] 记录已失败（含重试）次数；重试**绕过**
  /// `_knownHistoryIds` 发送侧去重——首次 `_registerHistoryId` 已登记，
  /// 重试若再过该守卫会被拦截（explorer 明确的 bug 源）。
  void _registerPending(LanOutboxEntry entry) {
    final perPeer = _pendingAcks.putIfAbsent(entry.peerId, () => {});
    final existing = perPeer[entry.historyId];
    if (existing == null) {
      // 初次失败：attempts=1，下次重试退避 base*2^0。
      entry.attempts = 1;
      perPeer[entry.historyId] = _PendingAckEntry(
        entry: entry,
        nextAttemptAtMs:
            DateTime.now().millisecondsSinceEpoch + _backoffMs(entry.attempts),
      );
    }
    _evictPendingIfNeeded();
  }

  /// 重试 sweeper：周期扫描待确认表，到点重试（绕过发送侧去重）。
  /// give-up 条件：重试次数超过 [LanConstants.lanPushMaxAttempts] 或条目
  /// 超过 [LanConstants.lanPendingAckTtl] 硬上限 → 删 outbox（拉取 backstop
  /// + Cloud 权威兜底收敛，无需无限重试）。
  void _startRetrySweeper() {
    _retryTimer?.cancel();
    _retryTimer = Timer.periodic(_retrySweepInterval, (_) {
      unawaited(_retryPendingPushes());
    });
  }

  Future<void> _retryPendingPushes() async {
    if (!_enabled || _disposed || _userId == null) return;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    for (final peerEntry in List.of(_pendingAcks.entries)) {
      final peerId = peerEntry.key;
      final perPeer = peerEntry.value;
      for (final pending in List.of(perPeer.values)) {
        if (pending.nextAttemptAtMs > nowMs) continue;
        final entry = pending.entry;
        if (nowMs - entry.enqueuedAtMs >
            LanConstants.lanPendingAckTtl.inMilliseconds) {
          await _giveUpPending(peerId, entry);
          continue;
        }
        if (entry.attempts > LanConstants.lanPushMaxAttempts) {
          await _giveUpPending(peerId, entry);
          continue;
        }
        // 重试：绕过 _registerHistoryId（核心修复）。
        entry.attempts++;
        pending.nextAttemptAtMs = nowMs + _backoffMs(entry.attempts);
        final LanPushResult result;
        try {
          if (entry.kind == 'file') {
            final artifactId = entry.artifactId;
            final encPath = artifactId == null
                ? null
                : await _fileStore.loadEncryptedPath(artifactId);
            if (encPath == null) {
              // artifact 已被容量清理逐出 → 放弃（Cloud 权威兜底）。
              await _giveUpPending(peerId, entry);
              continue;
            }
            result = await _transport.pushFile(
              peerId,
              entry.row,
              encryptedPath: encPath,
              encSize: entry.encSize ?? 0,
            );
            _diagnostics.pushSent++;
          } else {
            result = await _transport.push(peerId, entry.row);
            _diagnostics.pushSent++;
          }
        } catch (e) {
          debugPrint('[LAN] retry push to $peerId failed: $e');
          continue;
        }
        if (result == LanPushResult.delivered) {
          await _removePending(peerId, entry);
        }
      }
    }
  }

  Future<void> _giveUpPending(String peerId, LanOutboxEntry entry) async {
    _pendingAcks[peerId]?.remove(entry.historyId);
    if ((_pendingAcks[peerId]?.isEmpty ?? false)) _pendingAcks.remove(peerId);
    await _safeOutboxRemove(entry);
    debugPrint('[LAN] give up push ${entry.historyId} to $peerId');
  }

  Future<void> _removePending(String peerId, LanOutboxEntry entry) async {
    _pendingAcks[peerId]?.remove(entry.historyId);
    if ((_pendingAcks[peerId]?.isEmpty ?? false)) _pendingAcks.remove(peerId);
    await _safeOutboxRemove(entry);
  }

  /// 重试退避：attempts=1 → base；2 → 2×base；3 → 4×base（指数）。
  int _backoffMs(int attempts) {
    final shift = (attempts - 1).clamp(0, 10);
    return _retryBaseDelay.inMilliseconds * (1 << shift);
  }

  /// 待确认表上限 [LanConstants.lanPendingAckMaxEntries]（LRU：淘汰最旧）。
  void _evictPendingIfNeeded() {
    var total = _pendingAcks.values.fold<int>(
      0,
      (sum, perPeer) => sum + perPeer.length,
    );
    while (total > LanConstants.lanPendingAckMaxEntries) {
      _PendingAckEntry? oldest;
      String? oldestPeer;
      for (final peerEntry in _pendingAcks.entries) {
        for (final pending in peerEntry.value.values) {
          if (oldest == null ||
              pending.entry.enqueuedAtMs < oldest.entry.enqueuedAtMs) {
            oldest = pending;
            oldestPeer = peerEntry.key;
          }
        }
      }
      if (oldest == null || oldestPeer == null) break;
      _pendingAcks[oldestPeer]?.remove(oldest.entry.historyId);
      if ((_pendingAcks[oldestPeer]?.isEmpty ?? false)) {
        _pendingAcks.remove(oldestPeer);
      }
      unawaited(_safeOutboxRemove(oldest.entry));
      total--;
    }
  }

  /// 重启恢复：持久化 outbox → 待确认表 + 防回声登记 + 最新行刷新。
  /// 文件条目缺 artifact（本地 .enc 已清理）→ 直接丢弃。
  Future<void> _restoreOutbox(String userId) async {
    final entries = await _safeOutboxLoad(userId);
    for (final entry in entries) {
      if (entry.kind == 'file') {
        final artifactId = entry.artifactId;
        final encPath = artifactId == null
            ? null
            : await _fileStore.loadEncryptedPath(artifactId);
        if (encPath == null) {
          await _safeOutboxRemove(entry);
          debugPrint('[LAN] drop restored file outbox ${entry.historyId}: '
              'artifact missing');
          continue;
        }
      }
      if (entry.historyId.isNotEmpty) {
        _knownHistoryIds.add(entry.historyId); // 防回声
      }
      _updateLatestRow(entry.row);
      _registerPending(entry);
    }
  }

  Future<void> _safeOutboxPut(LanOutboxEntry entry) async {
    try {
      await _outboxStore.put(entry);
    } catch (e) {
      debugPrint('[LAN] outbox put failed: $e');
    }
  }

  Future<void> _safeOutboxRemove(LanOutboxEntry entry) async {
    try {
      await _outboxStore.remove(entry.userId, entry.peerId, entry.historyId);
    } catch (e) {
      debugPrint('[LAN] outbox remove failed: $e');
    }
  }

  Future<List<LanOutboxEntry>> _safeOutboxLoad(String userId) async {
    try {
      return await _outboxStore.loadActive(userId);
    } catch (e) {
      debugPrint('[LAN] outbox load failed: $e');
      return [];
    }
  }

  /// 拉取最新 row：刚收到 push → 命中本机缓存；否则 round-robin 向
  /// verified peers（≤4）发起 300ms 超时 fetch。无可用 peer → null。
  Future<Map<String, dynamic>?> fetchLatestContent() async {
    if (!_enabled || _disposed || _userId == null) return null;
    // 刚收到 push：直接命中本机缓存（LAN 加速，不再走一轮网络）。
    if (_pushPending && _latestRow != null) {
      _pushPending = false;
      _diagnostics.lanFetchHit++;
      return _sanitizeLanRow(_latestRow!);
    }
    await _ensureConnectedPeers();
    final peerIds = _transport.verifiedPeerIds;
    if (peerIds.isEmpty) {
      _diagnostics.lanFetchMiss++;
      _diagnostics.recordFallback(LanFallbackReason.noPeer);
      return null;
    }
    var tried = 0;
    for (var i = 0; i < peerIds.length && tried < LanConstants.maxVerifiedPeers; i++) {
      final peerId = peerIds[(_roundRobinIndex + i) % peerIds.length];
      // 大文件推送窗口：跳过该 peer（与 readerSlot busy 跳过同语义，不计数）。
      if (_transport.isFilePushInFlight(peerId)) continue;
      tried++;
      Map<String, dynamic>? row;
      try {
        row = await _transport.fetchLatest(peerId).timeout(
              _fetchTimeout,
              onTimeout: () {
                // 300ms 超时 ≠ 会话损坏：健康会话偶发慢响应（RTT>300ms /
                // 大文件在途）不销毁连接，下一轮同会话续读。真断连由
                // transport 帧级读超时（lanFrameTimeout=5s）兜底 drop，
                // 保持离线 peer 的 localOnly 降级语义不回退。
                _diagnostics.lanFetchMiss++;
                _diagnostics.recordFallback(LanFallbackReason.fetchTimeout);
                return null;
              },
            );
      } catch (e) {
        _diagnostics.lanFetchMiss++;
        _diagnostics.recordFallback(LanFallbackReason.fetchError);
        _transport.dropSession(peerId);
        row = null;
      }
      if (row == null) continue;
      final duplicate = _registerHistoryId(row['history_id']);
      _updateLatestRow(row);
      if (duplicate) {
        // 已见过的行，不重复返回
        _diagnostics.lanFetchMiss++;
        _diagnostics.recordFallback(LanFallbackReason.duplicate);
        continue;
      }
      _diagnostics.lanFetchHit++;
      return _sanitizeLanRow(_latestRow!);
    }
    _roundRobinIndex = (_roundRobinIndex + 1) % peerIds.length;
    return null;
  }

  /// 确保已与候选 peer 建立 initiator 会话（上限 [LanConstants.maxVerifiedPeers]）。
  Future<void> _ensureConnectedPeers() async {
    if (_userId == null || _deviceId == null || _accountKey == null) return;
    final candidates = _discovery.candidates;
    for (final peer in candidates) {
      if (_transport.verifiedPeerIds.length >= LanConstants.maxVerifiedPeers) {
        break;
      }
      if (_transport.hasSession(peer.deviceId)) continue;
      try {
        await _transport.connect(
          peerDeviceId: peer.deviceId,
          host: peer.host,
          port: peer.port,
          userId: _userId!,
          deviceId: _deviceId!,
          accountKey: _accountKey!,
        );
      } on LanHandshakeException catch (e) {
        // 错账户/票据拒绝：黑名单冷却，避免反复握手。
        debugPrint('[LAN] handshake to ${peer.deviceId} rejected: ${e.reason}');
        _diagnostics.recordFallback(LanFallbackReason.handshakeRejected);
        _discovery.markHandshakeRejected(peer.deviceId);
      } catch (e) {
        debugPrint('[LAN] connect to ${peer.deviceId} failed: $e');
      }
    }
  }

  /// 发送侧接力推送（挂 coordinator durable success 点之后调用）。
  /// text/image/file；同 historyId 去重；不向来源设备回推；异常只日志。
  ///
  /// file 分支守卫：明文 ≤15MiB 且 artifact（`.enc`）存在才走 LAN，否则
  /// Cloud-only（Cloud 已 durable 提交，LAN 本 best-effort）。密文从
  /// artifact 流式读取分块，绝不整文件进内存。
  Future<void> pushOperation(
    SyncOperation op, {
    Map<String, dynamic>? response,
  }) async {
    if (!_enabled || _disposed || _userId == null) return;
    try {
      if (op.kind == SyncOperationKind.delete ||
          op.kind == SyncOperationKind.restore) {
        await _pushOpOperation(op, response: response);
        return;
      }
      if (op.kind == SyncOperationKind.file) {
        await _pushFileOperation(op);
        return;
      }
      await _ensureConnectedPeers();
      final row = _toServerRow(op);
      if (row == null) return;
      if (_registerHistoryId(row['history_id'])) return; // 已推过，去重
      _updateLatestRow(row);
      final sourceDevice = row['source_device'] as String? ?? '';
      final historyId = row['history_id'] as String? ?? '';
      final kind = op.kind == SyncOperationKind.image ? 'image' : 'text';
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      for (final peerId in _transport.verifiedPeerIds) {
        if (peerId == sourceDevice) continue; // 不向来源设备回推
        // 旧 peer（无 acks）：Phase 2.2 写后即返回，不落 outbox。
        if (!_transport.supportsAcks(peerId)) {
          try {
            await _transport.push(peerId, row);
            _diagnostics.pushSent++;
          } catch (e) {
            debugPrint('[LAN] push to $peerId failed: $e');
          }
          continue;
        }
        // 新 peer：先持久化 outbox（crash-safe），再 push。
        final entry = LanOutboxEntry(
          userId: _userId!,
          peerId: peerId,
          historyId: historyId,
          kind: kind,
          row: row,
          enqueuedAtMs: nowMs,
        );
        await _safeOutboxPut(entry);
        final LanPushResult result;
        try {
          result = await _transport.push(peerId, row);
          _diagnostics.pushSent++;
        } catch (e) {
          debugPrint('[LAN] push to $peerId failed: $e');
          _registerPending(entry);
          continue;
        }
        if (result == LanPushResult.delivered) {
          await _safeOutboxRemove(entry); // remove-on-ack
        } else {
          _registerPending(entry); // pending/noSession → 待确认重试
        }
      }
    } catch (e) {
      debugPrint('[LAN] pushOperation failed: $e');
    }
  }

  /// 文件接力推送：守卫（阈值/artifact）→ 行生成 → 去重 → 不回推 → pushFile。
  Future<void> _pushFileOperation(SyncOperation op) async {
    final size = (op.payload['fileSize'] as num?)?.toInt() ?? 0;
    if (size <= 0 || size > LanConstants.lanMaxFileBytes) return;
    final artifactId = op.artifactId ?? op.operationId;
    final encPath = await _fileStore.loadEncryptedPath(artifactId);
    if (encPath == null) return; // artifact 已清理 → Cloud-only
    await _ensureConnectedPeers();
    final row = _toFileServerRow(op);
    if (row == null) return;
    if (_registerHistoryId(row['history_id'])) return; // 已推过，去重
    _updateLatestRow(row);
    final encSize = await File(encPath).length();
    final sourceDevice = row['source_device'] as String? ?? '';
    final historyId = row['history_id'] as String? ?? '';
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    for (final peerId in _transport.verifiedPeerIds) {
      if (peerId == sourceDevice) continue; // 不向来源设备回推
      if (!_transport.supportsAcks(peerId)) {
        // 旧 peer：Phase 2.2 写后即返回，不落 outbox。
        try {
          await _transport.pushFile(
            peerId,
            row,
            encryptedPath: encPath,
            encSize: encSize.toInt(),
          );
          _diagnostics.pushSent++;
        } catch (e) {
          debugPrint('[LAN] pushFile to $peerId failed: $e');
        }
        continue;
      }
      final entry = LanOutboxEntry(
        userId: _userId!,
        peerId: peerId,
        historyId: historyId,
        kind: 'file',
        row: row,
        artifactId: artifactId,
        encSize: encSize.toInt(),
        enqueuedAtMs: nowMs,
      );
      await _safeOutboxPut(entry);
      final LanPushResult result;
      try {
        result = await _transport.pushFile(
          peerId,
          row,
          encryptedPath: encPath,
          encSize: encSize.toInt(),
        );
        _diagnostics.pushSent++;
      } catch (e) {
        debugPrint('[LAN] pushFile to $peerId failed: $e');
        _registerPending(entry);
        continue;
      }
      if (result == LanPushResult.delivered) {
        await _safeOutboxRemove(entry); // remove-on-ack
      } else {
        _registerPending(entry);
      }
    }
  }

  /// delete/restore op 帧推送（best-effort，Cloud 500ms 是可靠性层）。
  ///
  /// - 帧：`{v, type:'op', op:{kind, operationId, entryId, row?}}`；
  ///   row 仅 restore 携带（服务端 commit 响应行，server-shape；file 行
  ///   content=''，无明文文件名——LAN 红线保持）；
  /// - 只对 supportsOps 的 peer 发（旧 peer 未知帧会断链自愈）；
  /// - 不进 LAN outbox、不等 ack（fire-once；对端离线由 Cloud 游标兜底）；
  /// - 不回推来源设备（payload.sourceDevice == peerId 跳过）。
  /// LAN restore row 清洗（白名单）：与 `_toFileServerRow` 同构的 LAN
  /// server-shape——零 userId、零明文 file_name、零 mime_type、零 file_key、
  /// 零 enc_file_name、零服务端内部状态列（deleted_at/restored_at/pinned 等）。
  /// 保留：id/history_id、type、content（密文）、hash、source_*、timestamp，
  /// file 行额外保留 file_size，image 行额外保留 thumb/width/height/format。
  /// 接收端 file 行缺 file_name/enc_file_name 时按既有占位 'file' 展示，
  /// 历史 refresh 自然修正（与 sync_service.dart 的 enc_file_name 回退同模式）。
  Map<String, dynamic> _sanitizeRestoreRow(Map<String, dynamic> row) {
    final type = row['type'] as String? ?? 'text';
    final sanitized = <String, dynamic>{
      if (row['id'] != null) 'id': row['id'],
      if (row['history_id'] != null) 'history_id': row['history_id'],
      'type': type,
      if (row['content'] != null) 'content': row['content'],
      if (row['hash'] != null) 'hash': row['hash'],
      if (row['source_device'] != null) 'source_device': row['source_device'],
      if (row['source_device_name'] != null)
        'source_device_name': row['source_device_name'],
      if (row['source_platform'] != null)
        'source_platform': row['source_platform'],
      if (row['timestamp'] != null) 'timestamp': row['timestamp'],
    };
    if (type == 'file') {
      if (row['file_size'] != null) sanitized['file_size'] = row['file_size'];
    } else if (type == 'image') {
      if (row['thumb'] != null) sanitized['thumb'] = row['thumb'];
      if (row['width'] != null) sanitized['width'] = row['width'];
      if (row['height'] != null) sanitized['height'] = row['height'];
      if (row['format'] != null) sanitized['format'] = row['format'];
    }
    return sanitized;
  }

  Future<void> _pushOpOperation(
    SyncOperation op, {
    Map<String, dynamic>? response,
  }) async {
    final entryId = op.payload['entryId'] as String?;
    if (entryId == null || entryId.isEmpty) return;
    await _ensureConnectedPeers();
    final kind = op.kind == SyncOperationKind.delete ? 'delete' : 'restore';
    final opFrame = <String, dynamic>{
      'kind': kind,
      'operationId': op.operationId,
      'entryId': entryId,
    };
    if (op.kind == SyncOperationKind.restore) {
      final row = response?['row'];
      if (row is Map<String, dynamic>) {
        // LAN 红线：绝不原样转发服务端 row（含 user_id/明文 file_name/
        // mime_type/file_key 等敏感字段），必须清洗为 LAN server-shape。
        opFrame['row'] = _sanitizeRestoreRow(row);
      }
    }
    if (_registerOpId(op.operationId)) return; // 已推过，去重
    final sourceDevice = op.payload['sourceDevice'] as String? ?? '';
    for (final peerId in _transport.verifiedPeerIds) {
      if (peerId == sourceDevice) continue; // 不回推来源设备
      if (!_transport.supportsOps(peerId)) continue; // 旧 peer 不发 op 帧
      try {
        await _transport.pushOp(peerId, opFrame);
        _diagnostics.pushSent++;
      } catch (e) {
        debugPrint('[LAN] pushOp to $peerId failed: $e');
      }
    }
  }

  /// 收到 peer `op` 帧：去重（_knownOpIds ≤200）→ Provider 回调应用。
  /// 语义与 Cloud 统一（同一 opId/entryId 幂等应用）；异常只日志，绝不 rethrow。
  void _handleOpReceived(Map<String, dynamic> frame) {
    if (!_enabled || _disposed) return;
    try {
      final op = frame['op'];
      if (op is! Map<String, dynamic>) return;
      final kind = op['kind'];
      final operationId = op['operationId'];
      final entryId = op['entryId'];
      if (operationId is! String || entryId is! String) return;
      if (_registerOpId(operationId)) return; // 重复 op 帧不重复应用
      if (kind == 'delete') {
        onDeleteOpReceived?.call(entryId);
      } else if (kind == 'restore') {
        final row = op['row'];
        if (row is Map<String, dynamic>) {
          onRestoreOpReceived?.call(Map<String, dynamic>.from(row));
        }
      }
    } catch (e) {
      debugPrint('[LAN] op frame apply failed: $e');
    }
  }

  /// 返回 true 表示该 operationId 已见过（重复）；新 id 会被登记（≤200）。
  bool _registerOpId(String operationId) {
    if (operationId.isEmpty) return true;
    if (_knownOpIds.contains(operationId)) return true;
    _knownOpIds.add(operationId);
    while (_knownOpIds.length > _maxKnownOpIds) {
      _knownOpIds.remove(_knownOpIds.first);
    }
    return false;
  }

  /// 收到 peer push 帧：去重 → 更新缓存 → 通知 Provider 立即下载。
  void _handlePushReceived(Map<String, dynamic> row) {
    if (!_enabled || _disposed) return;
    _diagnostics.pushReceived++;
    final duplicate = _registerHistoryId(row['history_id']);
    _updateLatestRow(row);
    if (duplicate) return; // 重复 push 不重复通知
    _pushPending = true;
    onPushReceived?.call();
  }

  /// 收到 peer 文件 push：`.enc` 已由 transport 原子落盘后才回调。
  /// 去重 → 更新缓存 → 置 _pushPending（下一次 fetch 命中本地文件行）。
  void _handleFilePushReceived(Map<String, dynamic> row, String encPath) {
    if (!_enabled || _disposed) return;
    _diagnostics.pushReceived++;
    final duplicate = _registerHistoryId(row['history_id']);
    _updateLatestRow(row);
    if (duplicate) return; // 重复 push 不重复通知
    _pushPending = true;
    onPushReceived?.call();
  }

  /// 返回 true 表示该 historyId 已见过（重复）；新 id 会被登记（≤200）。
  bool _registerHistoryId(Object? historyId) {
    if (historyId is! String || historyId.isEmpty) return false;
    if (_knownHistoryIds.contains(historyId)) return true;
    _knownHistoryIds.add(historyId);
    while (_knownHistoryIds.length > _maxKnownHistoryIds) {
      _knownHistoryIds.remove(_knownHistoryIds.first);
    }
    return false;
  }

  /// 按 timestamp 更新本机缓存（仅更新更新的行）。
  void _updateLatestRow(Map<String, dynamic> row) {
    final existing = _latestRow;
    if (existing == null) {
      _latestRow = row;
      return;
    }
    final newTs = (row['timestamp'] as num?)?.toInt() ?? 0;
    final oldTs = (existing['timestamp'] as num?)?.toInt() ?? 0;
    if (newTs >= oldTs) {
      _latestRow = row;
    }
  }

  /// 删除/恢复永不走 LAN：返回/缓存的 LAN 行恒带空 `_deletedIds/_restoredEntries`。
  Map<String, dynamic> _sanitizeLanRow(Map<String, dynamic> row) {
    return <String, dynamic>{
      ...row,
      '_deletedIds': <String>[],
      '_restoredEntries': <Map<String, dynamic>>[],
    };
  }

  /// camelCase 同步 payload → server-shape row（snake_case + `_deletedIds`/
  /// `_restoredEntries`），与 `getClipboardWithDeletedIds` 返回同构。
  Map<String, dynamic>? _toServerRow(SyncOperation op) {
    final payload = op.payload;
    final row = <String, dynamic>{
      'history_id': op.operationId,
      'type': op.kind == SyncOperationKind.text ? 'text' : 'image',
      'content': payload['content'],
      'hash': payload['hash'],
      'source_device': payload['sourceDevice'],
      'source_device_name': payload['sourceDeviceName'],
      'source_platform': payload['sourcePlatform'],
      'timestamp': payload['timestamp'],
      '_deletedIds': <String>[],
      '_restoredEntries': <Map<String, dynamic>>[],
    };
    if (op.kind == SyncOperationKind.image) {
      row['thumb'] = payload['thumb'];
      row['width'] = payload['width'];
      row['height'] = payload['height'];
      row['format'] = payload['format'];
    }
    return row;
  }

  /// file payload → server-shape 文件行。与 `_toServerRow` 同构（恒带空
  /// 删除/恢复数组），且**不含**明文 `file_name`/`mime_type`（红线）；
  /// `enc_file_name` 取自 `prepareFile` 已加密的 `encFileName`（manager
  /// 没有数据 key，绝不在本层加密）。`content` 为密文 marker（解码器在
  /// 分支前无条件读 content，缺失会抛 DecryptionException 静默回 Cloud）。
  Map<String, dynamic>? _toFileServerRow(SyncOperation op) {
    final payload = op.payload;
    final marker = payload['marker'];
    if (marker is! String || marker.isEmpty) return null;
    return <String, dynamic>{
      'history_id': op.operationId,
      'type': 'file',
      'content': marker,
      'hash': payload['hash'],
      'enc_file_name': payload['encFileName'],
      'file_size': payload['fileSize'],
      'source_device': payload['sourceDevice'],
      'source_device_name': payload['sourceDeviceName'],
      'source_platform': payload['sourcePlatform'],
      'timestamp': payload['timestamp'],
      '_deletedIds': <String>[],
      '_restoredEntries': <Map<String, dynamic>>[],
    };
  }
}

/// 待确认表条目：outbox 条目引用 + 下次重试时间（内存态）。
class _PendingAckEntry {
  _PendingAckEntry({required this.entry, required this.nextAttemptAtMs});

  final LanOutboxEntry entry;
  int nextAttemptAtMs;
}
