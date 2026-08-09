import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;

import '../core/constants.dart';
import '../models/sync_operation.dart';
import '../repositories/cloud_repository.dart';
import '../services/cloudbase_service.dart';
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
/// 红线：LAN 报文不携带 userId/密码/token/K_lan/salt/指纹/文件名/明文；
/// 对外方法绝不把网络错误抛给调用方（内部 catch + debugPrint）。
class LanSyncManager {
  LanSyncManager({
    CloudRepository? cloudRepository,
    LanDiscoveryService? discovery,
    LanTransport? transport,
    LanHandshakeService? handshakeService,
    @visibleForTesting Duration fetchTimeout = LanConstants.lanFetchTimeout,
  })  : _fetchTimeout = fetchTimeout,
        _discovery = discovery ?? LanDiscoveryService(),
        _transport = transport ??
            LanTransport(
              handshakeService: handshakeService ??
                  LanHandshakeService(
                    cloudRepository: cloudRepository ??
                        CloudRepository(CloudBaseService()),
                  ),
            ) {
    _transport.latestRowProvider = () => _latestRow;
    _transport.onPushReceived = _handlePushReceived;
  }

  final LanDiscoveryService _discovery;
  final LanTransport _transport;
  final Duration _fetchTimeout;

  bool _enabled = false;
  bool _disposed = false;
  String? _userId;
  String? _deviceId;
  Uint8List? _accountKey;

  /// 本机最新 row（server-shape，仅密文行）：可应答 peers 的 latestRequest。
  Map<String, dynamic>? _latestRow;

  /// historyId 去重（≤200，防 push/fetch 重复缓存）。
  final Set<String> _knownHistoryIds = {};
  static const int _maxKnownHistoryIds = 200;

  int _roundRobinIndex = 0;

  /// 刚收到 push 且尚未被下载消费：下一次 fetch 直接命中本机缓存。
  bool _pushPending = false;

  /// Provider 注册：收到 push 帧后触发一次立即下载。
  void Function()? onPushReceived;

  bool get isEnabled => _enabled;

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
        caps: 't/i',
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
  }

  /// 拉取最新 row：刚收到 push → 命中本机缓存；否则 round-robin 向
  /// verified peers（≤4）发起 300ms 超时 fetch。无可用 peer → null。
  Future<Map<String, dynamic>?> fetchLatestContent() async {
    if (!_enabled || _disposed || _userId == null) return null;
    // 刚收到 push：直接命中本机缓存（LAN 加速，不再走一轮网络）。
    if (_pushPending && _latestRow != null) {
      _pushPending = false;
      return _sanitizeLanRow(_latestRow!);
    }
    await _ensureConnectedPeers();
    final peerIds = _transport.verifiedPeerIds;
    if (peerIds.isEmpty) return null;
    var tried = 0;
    for (var i = 0; i < peerIds.length && tried < LanConstants.maxVerifiedPeers; i++) {
      final peerId = peerIds[(_roundRobinIndex + i) % peerIds.length];
      tried++;
      Map<String, dynamic>? row;
      try {
        row = await _transport.fetchLatest(peerId).timeout(
              _fetchTimeout,
              onTimeout: () {
                // 超时：会话可能处于脏状态，丢弃让下一轮重连。
                _transport.dropSession(peerId);
                return null;
              },
            );
      } catch (e) {
        _transport.dropSession(peerId);
        row = null;
      }
      if (row == null) continue;
      final duplicate = _registerHistoryId(row['history_id']);
      _updateLatestRow(row);
      if (duplicate) continue; // 已见过的行，不重复返回
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
        _discovery.markHandshakeRejected(peer.deviceId);
      } catch (e) {
        debugPrint('[LAN] connect to ${peer.deviceId} failed: $e');
      }
    }
  }

  /// 发送侧接力推送（挂 coordinator durable success 点之后调用）。
  /// 仅 text/image；同 historyId 去重；不向来源设备回推；异常只日志。
  Future<void> pushOperation(SyncOperation op) async {
    if (!_enabled || _disposed || _userId == null) return;
    if (op.kind != SyncOperationKind.text &&
        op.kind != SyncOperationKind.image) {
      return;
    }
    try {
      await _ensureConnectedPeers();
      final row = _toServerRow(op);
      if (row == null) return;
      if (_registerHistoryId(row['history_id'])) return; // 已推过，去重
      _updateLatestRow(row);
      final sourceDevice = row['source_device'] as String? ?? '';
      for (final peerId in _transport.verifiedPeerIds) {
        if (peerId == sourceDevice) continue; // 不向来源设备回推
        try {
          await _transport.push(peerId, row);
        } catch (e) {
          debugPrint('[LAN] push to $peerId failed: $e');
        }
      }
    } catch (e) {
      debugPrint('[LAN] pushOperation failed: $e');
    }
  }

  /// 收到 peer push 帧：去重 → 更新缓存 → 通知 Provider 立即下载。
  void _handlePushReceived(Map<String, dynamic> row) {
    if (!_enabled || _disposed) return;
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
}
