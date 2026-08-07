import 'dart:async';

import 'package:flutter/material.dart';
import 'app.dart';
import 'providers/auth_provider.dart';
import 'providers/clipboard_provider.dart';
import 'providers/settings_provider.dart';
import 'services/app_info.dart';
import 'services/crash_reporter.dart';
import 'services/pinned_client.dart';
import 'package:provider/provider.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 版本/机型一次性加载，供设置页与崩溃上报共用
  final appInfo = await AppInfo.load();
  final crashReporter = CrashReporter.instance..init(appInfo: appInfo);
  unawaited(crashReporter.cacheDeviceModel());
  // 全局错误捕获：先上报、后保持默认行为（红屏照常 / PlatformDispatcher 返回 false）
  crashReporter.installGlobalHandlers();
  runZonedGuarded(
    () => runApp(
      MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => AuthProvider()),
          ChangeNotifierProvider(create: (_) => SettingsProvider()),
          ChangeNotifierProvider(create: (_) => ClipboardProvider()),
          Provider<AppInfo>.value(value: appInfo),
        ],
        child: const _ClipFlowBootstrap(),
      ),
    ),
    (error, stack) => crashReporter.report(error, stack),
  );
}

/// Wires cross-provider references that can't be done in MultiProvider alone.
/// StatefulWidget 化：崩溃上报的登录归属（token/deviceId）在 initState 装配、
/// 监听 AuthProvider 变化，dispose 移除，避免重复挂监听。
class _ClipFlowBootstrap extends StatefulWidget {
  const _ClipFlowBootstrap();

  @override
  State<_ClipFlowBootstrap> createState() => _ClipFlowBootstrapState();
}

class _ClipFlowBootstrapState extends State<_ClipFlowBootstrap> {
  AuthProvider? _auth;

  @override
  void initState() {
    super.initState();
    // Connect ClipboardProvider to SettingsProvider after both are created
    final clipboard = context.read<ClipboardProvider>();
    final settings = context.read<SettingsProvider>();
    clipboard.setSettingsProvider(settings);
    // 崩溃上报登录归属：token 实时取（匿名兜底），deviceId 随登录态更新
    final auth = context.read<AuthProvider>();
    _auth = auth;
    final crash = CrashReporter.instance;
    crash.setAuthTokenProvider(() => auth.authToken);
    auth.addListener(_onAuthChanged);
    _onAuthChanged();
  }

  void _onAuthChanged() {
    CrashReporter.instance.setDeviceId(_auth?.currentDeviceIdOrNull);
  }

  @override
  void dispose() {
    _auth?.removeListener(_onAuthChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return const ClipFlowApp();
  }
}
