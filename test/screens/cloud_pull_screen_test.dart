import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:clipflow/l10n/app_strings.dart';
import 'package:clipflow/providers/auth_provider.dart';
import 'package:clipflow/providers/clipboard_provider.dart';
import 'package:clipflow/providers/settings_provider.dart';
import 'package:clipflow/screens/backup/cloud_pull_screen.dart';
import 'package:clipflow/services/app_info.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget buildApp() {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<AuthProvider>(create: (_) => AuthProvider()),
        ChangeNotifierProvider(create: (_) => ClipboardProvider()),
        ChangeNotifierProvider(create: (_) => SettingsProvider()),
        Provider<AppInfo>.value(
          value: const AppInfo(version: 'test', buildNumber: '1'),
        ),
      ],
      child: const MaterialApp(home: CloudPullScreen()),
    );
  }

  Future<void> useTallViewport(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  testWidgets('云拉取页渲染引导 + 旧密码输入；无会话密钥时开始按钮禁用', (tester) async {
    await useTallViewport(tester);

    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    expect(find.text(AppStrings.cloudPullTitle), findsOneWidget);
    expect(find.text(AppStrings.cloudPullGuideTitle), findsOneWidget);
    expect(find.text(AppStrings.cloudPullGuideBody), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);

    // 未解锁（encryptionKey == null / userId 空）→ 开始按钮禁用
    FilledButton buttonOf() => tester.widget<FilledButton>(
          find.ancestor(
            of: find.text(AppStrings.cloudPullStartAction),
            matching: find.byType(FilledButton),
          ),
        );
    expect(buttonOf().onPressed, isNull);

    // 输入旧密码后仍禁用（缺少会话密钥守卫）
    await tester.enterText(find.byType(TextField), 'old-password');
    await tester.pump();
    expect(buttonOf().onPressed, isNull);
  });
}
