import 'dart:convert';
import 'dart:io' show Platform;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'pinned_client.dart';

import 'app_info.dart';
import 'cloudbase_service.dart';
import 'device_identity_service.dart';

/// 崩溃报告白名单模型：仅异常元信息（类型/消息/栈/平台/机型/版本/设备/时间），
/// 绝不采集剪贴板明文、密码或文件内容。
class CrashReport {
  final String exceptionType;
  final String message;
  final String stack;
  final String platform;
  final String? deviceModel;
  final String appVersion;
  final String? deviceId;
  final int reportedAt;

  const CrashReport({
    required this.exceptionType,
    required this.message,
    required this.stack,
    required this.platform,
    this.deviceModel,
    required this.appVersion,
    this.deviceId,
    required this.reportedAt,
  });

  Map<String, dynamic> toJson() => {
    'exceptionType': exceptionType,
    'message': message,
    'stack': stack,
    'platform': platform,
    if (deviceModel != null) 'deviceModel': deviceModel,
    'appVersion': appVersion,
    if (deviceId != null) 'deviceId': deviceId,
    'reportedAt': reportedAt,
  };
}

/// 崩溃上报会话级去重/限频：sha256 指纹 60s 去重 + 5 次/分钟 + 20 次/会话。
/// 纯内存态，App 重启清零（与 AuthGuard 同语义，明确接受）。
class CrashReportPolicy {
  final Duration dedupWindow;
  final int maxPerMinute;
  final int maxPerSession;
  final DateTime Function() now;

  final Map<String, DateTime> _lastSentByFingerprint = {};
  final List<DateTime> _minuteWindow = [];
  int _sessionCount = 0;

  CrashReportPolicy({
    this.dedupWindow = const Duration(seconds: 60),
    this.maxPerMinute = 5,
    this.maxPerSession = 20,
    DateTime Function()? now,
  }) : now = now ?? DateTime.now;

  /// 返回是否允许上报；允许时记账（去重/限频）。窗口外自动滑动恢复。
  bool allow(String fingerprint) {
    final current = now();
    final last = _lastSentByFingerprint[fingerprint];
    if (last != null && current.difference(last) < dedupWindow) return false;

    _minuteWindow.removeWhere(
      (t) => current.difference(t) >= const Duration(minutes: 1),
    );
    if (_minuteWindow.length >= maxPerMinute) return false;
    if (_sessionCount >= maxPerSession) return false;

    _lastSentByFingerprint[fingerprint] = current;
    _minuteWindow.add(current);
    _sessionCount++;
    return true;
  }
}

/// 全局崩溃收集器：捕获未处理异常 → 构造白名单报告 → 异步上报（静默）。
/// 三钩子（FlutterError / PlatformDispatcher / runZonedGuarded）由 main() 装配，
/// 上报本身 5s 超时 + catch-all，绝不抛入主流程。
class CrashReporter {
  static CrashReporter? _instance;

  /// 全局单例（main() 使用）；测试请用 [CrashReporter.forTest]。
  static CrashReporter get instance => _instance ??= CrashReporter();

  final http.Client _client;
  final CrashReportPolicy _policy;
  final Duration sendTimeout;

  AppInfo? _appInfo;
  DeviceIdentity? _device;
  String? Function()? _authTokenProvider;
  String? _deviceId;

  CrashReporter({
    http.Client? client,
    CrashReportPolicy? policy,
    this.sendTimeout = const Duration(seconds: 5),
  }) : _client = client ?? createPinnedHttpClient(),
       _policy = policy ?? CrashReportPolicy();

  /// 测试专用构造：注入 mock client / policy，不影响全局单例。
  @visibleForTesting
  CrashReporter.forTest({http.Client? client, CrashReportPolicy? policy})
    : this(client: client, policy: policy);

  /// 装配元信息（版本/机型）。机型可经 [cacheDeviceModel] 异步预热。
  void init({AppInfo? appInfo, DeviceIdentity? device}) {
    _appInfo = appInfo;
    _device = device;
  }

  /// 登录态 token 提供方：崩溃发生时实时取当前 token（可空 → 匿名上报）。
  void setAuthTokenProvider(String? Function() provider) {
    _authTokenProvider = provider;
  }

  /// 当前设备 ID（登录注册后才有；可空）。
  void setDeviceId(String? deviceId) {
    _deviceId = deviceId;
  }

  /// 异步预热机型信息，不阻塞启动；首次崩溃时可能为 null（服务端接受）。
  Future<void> cacheDeviceModel() async {
    try {
      _device ??= await loadDeviceIdentity();
    } catch (_) {
      // 静默：机型缺失不阻塞崩溃上报
    }
  }

  /// 安装全局错误捕获：框架错误（FlutterError）与引擎错误（PlatformDispatcher）。
  /// 先上报、后保持默认行为（红屏照常 / PlatformDispatcher 返回 false）。
  void installGlobalHandlers() {
    FlutterError.onError = (details) {
      report(details.exception, details.stack);
      FlutterError.presentError(details);
    };
    PlatformDispatcher.instance.onError = (error, stack) {
      report(error, stack);
      return false;
    };
  }

  /// 上报一次崩溃。去重/限频丢弃或发送失败均返回 false（静默）。
  Future<bool> report(Object error, StackTrace? stack) async {
    final fingerprint = _fingerprint(error, stack);
    if (!_policy.allow(fingerprint)) return false;
    final report = _buildReport(error, stack);
    try {
      await _send(report).timeout(sendTimeout);
      return true;
    } catch (_) {
      return false;
    }
  }

  String _fingerprint(Object error, StackTrace? stack) {
    final raw = '${error.runtimeType}|${error.toString()}|${stack?.toString() ?? ''}';
    return sha256.convert(utf8.encode(raw)).toString().substring(0, 16);
  }

  CrashReport _buildReport(Object error, StackTrace? stack) {
    final message = error.toString();
    return CrashReport(
      exceptionType: error.runtimeType.toString(),
      message: message.length > 5000 ? message.substring(0, 5000) : message,
      stack: stack?.toString() ?? '',
      platform: Platform.operatingSystem,
      deviceModel: _device?.model,
      appVersion: _appInfo?.fullVersion ?? 'unknown',
      deviceId: _deviceId,
      reportedAt: DateTime.now().millisecondsSinceEpoch,
    );
  }

  Future<void> _send(CrashReport report) async {
    final token = _authTokenProvider?.call();
    await _client.post(
      Uri.parse('${CloudBaseService.baseUrl}/crash'),
      headers: {
        'Content-Type': 'application/json',
        if (token != null && token.isNotEmpty)
          'Authorization': 'Bearer $token',
      },
      body: jsonEncode(report.toJson()),
    );
  }
}
