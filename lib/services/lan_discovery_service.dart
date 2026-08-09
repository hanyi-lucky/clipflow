import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;

import '../core/constants.dart';
import 'lan_diagnostics.dart';
import 'lan_network_channel.dart';

/// mDNS 发现的单个候选设备。
///
/// 只含设备级信息（deviceId/host/port/能力位），**不含任何账户信息**
/// （userId/密码/token/K_lan/salt/指纹等一律不落此模型）。
class LanPeer {
  LanPeer({
    required this.deviceId,
    required this.host,
    required this.port,
    this.protoVersion = LanConstants.lanProtoVersion,
    this.capabilities = '',
    required this.lastSeenAt,
  });

  final String deviceId;
  final String host;
  final int port;
  final int protoVersion;

  /// 能力位原文（如 `t/i` = 文本/图片）。仅作展示/未来分流用，不参与认证。
  final String capabilities;
  final DateTime lastSeenAt;
}

/// 原生 mDNS 发现封装（macOS NSNetService / Android NsdManager 的 Dart 侧视图）。
///
/// - 维护 `Map<deviceId, LanPeer>` 缓存；>30s 未刷新自动过期剔除；
/// - 错账户/版本不匹配的 peer 进入 60s 黑名单冷却；
/// - 不持任何账户信息，账户过滤只发生在握手内（决策 1/3）。
class LanDiscoveryService {
  LanDiscoveryService({
    LanNetworkChannel? channel,
    LanDiagnostics? diagnostics,
    DateTime Function()? now,
  })  : _channel = channel ?? LanNetworkChannel(),
        _diagnostics = diagnostics,
        _now = now ?? DateTime.now;

  final LanNetworkChannel _channel;
  final LanDiagnostics? _diagnostics;
  final DateTime Function() _now;
  final Map<String, LanPeer> _peers = {};
  final Map<String, DateTime> _blacklistUntil = {};
  StreamSubscription<Map<String, dynamic>>? _subscription;
  String? _ownDeviceId;

  /// 开始广播 + 浏览。平台不支持 / 权限缺失 → false（调用方按「禁用」处理，
  /// 不抛给用户）。
  Future<bool> start({
    required String deviceId,
    required String caps,
    required int port,
  }) async {
    _ownDeviceId = deviceId;
    try {
      if (!await _channel.isSupported()) return false;
      await _channel.advertise(
        serviceType: LanConstants.lanServiceType,
        deviceId: deviceId,
        caps: caps,
        port: port,
      );
      _subscription = _channel.discoveryEvents.listen(handleDiscoveryEvent);
      await _channel.browse(serviceType: LanConstants.lanServiceType);
      return true;
    } on LanNetworkException catch (e) {
      debugPrint('[LAN-DISCOVERY] start disabled: ${e.code}');
      await _subscription?.cancel();
      _subscription = null;
      return false;
    }
  }

  /// 停止广播/浏览并清空本地缓存。
  Future<void> stop() async {
    await _subscription?.cancel();
    _subscription = null;
    _peers.clear();
    _blacklistUntil.clear();
    _ownDeviceId = null;
    try {
      await _channel.stopAll();
    } catch (e) {
      debugPrint('[LAN-DISCOVERY] stopAll error: $e');
    }
  }

  /// 处理一条原生发现事件（测试可直接注入，生产由 EventChannel 驱动）。
  ///
  /// TXT 白名单：proto/device/caps；其余字段一律忽略。
  @visibleForTesting
  void handleDiscoveryEvent(Map<String, dynamic> event) {
    final txt = event['txt'];
    if (txt is! Map) return;
    final deviceId = txt['device'];
    if (deviceId is! String || deviceId.isEmpty) return;
    if (deviceId == _ownDeviceId) return; // 跳过自己的广告
    final host = event['host'];
    final port = event['port'];
    if (host is! String || port is! int) return;
    final proto = int.tryParse('${txt['proto']}') ??
        LanConstants.lanProtoVersion;
    if (proto != LanConstants.lanProtoVersion) {
      // 版本不匹配 → 黑名单冷却，避免反复握手
      _blacklistUntil[deviceId] =
          _now().add(LanConstants.lanBlacklistCooldown);
      return;
    }
    final capsRaw = txt['caps'] as String? ?? '';
    if (!_peers.containsKey(deviceId)) {
      _diagnostics?.discovered++; // 新去重设备
    }
    _peers[deviceId] = LanPeer(
      deviceId: deviceId,
      host: host,
      port: port,
      protoVersion: proto,
      capabilities: capsRaw,
      lastSeenAt: _now(),
    );
  }

  /// 当前候选列表：未过期且不在黑名单冷却期内的 peer，按最近活跃排序。
  List<LanPeer> get candidates {
    _pruneExpired();
    final now = _now();
    final result = <LanPeer>[];
    for (final peer in _peers.values) {
      final until = _blacklistUntil[peer.deviceId];
      if (until != null && now.isBefore(until)) continue;
      result.add(peer);
    }
    result.sort((a, b) => b.lastSeenAt.compareTo(a.lastSeenAt));
    return result;
  }

  /// 握手被拒（错账户/票据拒绝等）→ 60s 黑名单冷却。
  void markHandshakeRejected(String deviceId) {
    _blacklistUntil[deviceId] =
        _now().add(LanConstants.lanBlacklistCooldown);
  }

  void _pruneExpired() {
    final cutoff = _now().subtract(LanConstants.lanDiscoveryExpiry);
    _peers.removeWhere((_, peer) => peer.lastSeenAt.isBefore(cutoff));
  }
}
