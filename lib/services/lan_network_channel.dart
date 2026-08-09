import 'package:flutter/services.dart';

/// LAN 网络原生通道错误。
///
/// [code] 取值：`permissionDenied`（Android 13+ 缺 NEARBY_WIFI_DEVICES 权限）、
/// `badArgs`、`registerFailed`、`browseFailed`、`unsupported`、其他原生错误码。
class LanNetworkException implements Exception {
  LanNetworkException(this.code, this.message);

  final String code;
  final String message;

  bool get isPermissionDenied => code == 'permissionDenied';

  @override
  String toString() => 'LanNetworkException($code): $message';
}

/// `clipflow/lan_network` MethodChannel 薄封装（macOS NSNetService /
/// Android NsdManager 的 Dart 侧视图）。
///
/// - 方法：`advertise` / `browse` / `stopAll` / `isSupported`
/// - 发现结果经 EventChannel `clipflow/lan_network_events` 推送
///   `{name, host, port, txt:{proto, device, caps}}`。
/// - 平台不实现时（MissingPluginException）按「不支持」处理（静默禁用，
///   Cloud-only 行为与现状一致）。
class LanNetworkChannel {
  LanNetworkChannel({MethodChannel? methodChannel, EventChannel? eventChannel})
      : methodChannel = methodChannel ?? const MethodChannel('clipflow/lan_network'),
        eventChannel = eventChannel ?? const EventChannel('clipflow/lan_network_events');

  final MethodChannel methodChannel;
  final EventChannel eventChannel;

  /// 平台是否支持原生 mDNS（macOS/Android true，其余 false）。
  Future<bool> isSupported() async {
    try {
      return await methodChannel.invokeMethod<bool>('isSupported') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException catch (e) {
      throw LanNetworkException(e.code, e.message ?? 'isSupported failed');
    }
  }

  /// 广播 `_clipflow._tcp` 服务。TXT 白名单：proto/port/device/caps——
  /// 禁止 userId/密码/token/K_lan/salt/证书指纹/文件名/明文/deviceName。
  Future<void> advertise({
    required String serviceType,
    required String deviceId,
    required String caps,
    required int port,
  }) async {
    try {
      await methodChannel.invokeMethod<void>('advertise', <String, dynamic>{
        'serviceType': serviceType,
        'deviceId': deviceId,
        'caps': caps,
        'port': port,
      });
    } on MissingPluginException {
      throw LanNetworkException('unsupported', 'LAN network plugin not available');
    } on PlatformException catch (e) {
      throw _mapPlatformError(e);
    }
  }

  /// 浏览 `_clipflow._tcp` 服务，发现结果经 [discoveryEvents] 推送。
  Future<void> browse({required String serviceType}) async {
    try {
      await methodChannel.invokeMethod<void>('browse', <String, dynamic>{
        'serviceType': serviceType,
      });
    } on MissingPluginException {
      throw LanNetworkException('unsupported', 'LAN network plugin not available');
    } on PlatformException catch (e) {
      throw _mapPlatformError(e);
    }
  }

  /// 停止广播与浏览（清空原生状态）。
  Future<void> stopAll() async {
    try {
      await methodChannel.invokeMethod<void>('stopAll');
    } on MissingPluginException {
      // 未实现视为已停止
    } on PlatformException catch (e) {
      throw _mapPlatformError(e);
    }
  }

  /// 发现结果事件流（`{name, host, port, txt}`）。
  Stream<Map<String, dynamic>> get discoveryEvents {
    return eventChannel.receiveBroadcastStream().map((event) {
      if (event is Map) return Map<String, dynamic>.from(event);
      return const <String, dynamic>{};
    });
  }

  LanNetworkException _mapPlatformError(PlatformException e) {
    if (e.code == 'permissionDenied') {
      return LanNetworkException('permissionDenied', e.message ?? 'LAN permission denied');
    }
    return LanNetworkException(e.code, e.message ?? 'LAN channel error');
  }
}
