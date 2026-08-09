import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:clipflow/l10n/app_strings.dart';
import 'package:clipflow/models/device.dart';
import 'package:clipflow/providers/auth_provider.dart';
import 'package:clipflow/providers/clipboard_provider.dart';
import 'package:clipflow/providers/settings_provider.dart';
import 'package:clipflow/repositories/local_storage.dart';
import 'package:clipflow/screens/settings_screen.dart';
import 'package:clipflow/screens/backup/cloud_pull_screen.dart';
import 'package:clipflow/screens/unlock_screen.dart';
import 'package:clipflow/services/app_info.dart';

/// 设备管理区块在测试中避免真实网络请求（fetchDevices 直接返回空列表）。
class FakeAuthProvider extends AuthProvider {
  @override
  Future<List<Device>> fetchDevices() async => [];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget buildApp(LocalStorage storage) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<AuthProvider>(
          create: (_) => FakeAuthProvider(),
        ),
        ChangeNotifierProvider(create: (_) => ClipboardProvider()),
        ChangeNotifierProvider(create: (_) => SettingsProvider()),
        Provider<AppInfo>.value(
          value: const AppInfo(version: 'test', buildNumber: '1'),
        ),
      ],
      child: MaterialApp(
        title: 'ClipFlow Test',
        routes: {
          '/unlock': (context) => const UnlockScreen(),
        },
        home: const SettingsScreen(),
      ),
    );
  }

  Future<void> useTallViewport(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  testWidgets('设置页「账户与数据」显示切换账号入口，点击后弹出警告对话框', (tester) async {
    await useTallViewport(tester);
    SharedPreferences.setMockInitialValues({});
    final storage = LocalStorage(await SharedPreferences.getInstance());

    await tester.pumpWidget(buildApp(storage));
    await tester.pumpAndSettle();

    // 入口存在（含副标题）
    expect(find.text(AppStrings.settingsSwitchAccountTitle), findsOneWidget);
    expect(find.text(AppStrings.settingsSwitchAccountSubtitle), findsOneWidget);

    // 点击入口 → 警告对话框：标题/正文/取消/确认按钮文案正确
    await tester.tap(find.text(AppStrings.settingsSwitchAccountTitle));
    await tester.pumpAndSettle();

    final dialog = find.byType(AlertDialog);
    expect(dialog, findsOneWidget);
    // 对话框标题与入口标题同为「切换账号」，断言限定在对话框内
    expect(
      find.descendant(
        of: dialog,
        matching: find.text(AppStrings.switchAccountDialogTitle),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: dialog,
        matching: find.text(AppStrings.switchAccountDialogBody),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: dialog,
        matching: find.text(AppStrings.commonCancel),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: dialog,
        matching: find.text(AppStrings.switchAccountDialogConfirmAction),
      ),
      findsOneWidget,
    );
  });

  testWidgets('确认切换后清空账户身份并导航回解锁页（保留设备信息与设置）', (tester) async {
    await useTallViewport(tester);
    SharedPreferences.setMockInitialValues({
      'user_id': 'user_test',
      'encryption_salt': 'abcd',
      'device_id': 'device-test',
      'device_name': 'Test Mac',
      'auto_sync': true,
    });
    final storage = LocalStorage(await SharedPreferences.getInstance());
    expect(storage.userId, 'user_test');

    await tester.pumpWidget(buildApp(storage));
    await tester.pumpAndSettle();

    await tester.tap(find.text(AppStrings.settingsSwitchAccountTitle));
    await tester.pumpAndSettle();
    await tester.tap(find.text(AppStrings.switchAccountDialogConfirmAction));
    await tester.pumpAndSettle();

    // 导航回解锁页
    expect(find.byType(UnlockScreen), findsOneWidget);
    expect(find.byType(SettingsScreen), findsNothing);

    // 账户身份与本地缓存被清；设备信息保留
    expect(storage.userId, isNull);
    expect(storage.encryptionSalt, isNull);
    expect(storage.deviceId, 'device-test');
    expect(storage.deviceName, 'Test Mac');
    expect(storage.autoSync, isTrue);
  });

  testWidgets('点击取消不切换账户，不导航', (tester) async {
    await useTallViewport(tester);
    SharedPreferences.setMockInitialValues({
      'user_id': 'user_test',
      'encryption_salt': 'abcd',
    });
    final storage = LocalStorage(await SharedPreferences.getInstance());

    await tester.pumpWidget(buildApp(storage));
    await tester.pumpAndSettle();

    await tester.tap(find.text(AppStrings.settingsSwitchAccountTitle));
    await tester.pumpAndSettle();
    await tester.tap(find.text(AppStrings.commonCancel));
    await tester.pumpAndSettle();

    expect(find.byType(UnlockScreen), findsNothing);
    expect(storage.userId, 'user_test');
    expect(storage.encryptionSalt, 'abcd');
  });
  testWidgets('设置页「账户与数据」显示「从云端拉取」入口，点击进入云拉取页', (tester) async {
    await useTallViewport(tester);
    SharedPreferences.setMockInitialValues({});
    final storage = LocalStorage(await SharedPreferences.getInstance());

    await tester.pumpWidget(buildApp(storage));
    await tester.pumpAndSettle();

    // 入口存在（含副标题）
    expect(find.text(AppStrings.cloudPullTitle), findsOneWidget);
    expect(find.text(AppStrings.cloudPullSubtitle), findsOneWidget);

    // 点击入口 → CloudPullScreen
    await tester.tap(find.text(AppStrings.cloudPullTitle));
    await tester.pumpAndSettle();
    expect(find.byType(CloudPullScreen), findsOneWidget);
  });
  testWidgets('关于页连点版本号 7 次触发一次崩溃异常（崩溃上报测试钩子）', (tester) async {
    await useTallViewport(tester);
    SharedPreferences.setMockInitialValues({});
    final storage = LocalStorage(await SharedPreferences.getInstance());

    await tester.pumpWidget(buildApp(storage));
    await tester.pumpAndSettle();

    final versionTile = find.widgetWithText(ListTile, AppStrings.aboutVersion);
    await tester.scrollUntilVisible(versionTile, 200,
        scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();

    for (var i = 0; i < 7; i++) {
      await tester.tap(versionTile);
      await tester.pump();
    }

    final thrown = tester.takeException();
    expect(thrown, isA<StateError>());
    expect((thrown as StateError).message,
        contains('Manual crash trigger'));
  });

  testWidgets('设置页「通用」区显示局域网加速开关，关闭后持久化', (tester) async {
    await useTallViewport(tester);
    SharedPreferences.setMockInitialValues({});
    final storage = LocalStorage(await SharedPreferences.getInstance());

    await tester.pumpWidget(buildApp(storage));
    await tester.pumpAndSettle();

    // 开关存在且默认开启
    expect(find.text(AppStrings.lanAccelerationTitle), findsOneWidget);
    expect(find.text(AppStrings.lanAccelerationSubtitle), findsOneWidget);
    final tileFinder = find.ancestor(
      of: find.text(AppStrings.lanAccelerationTitle),
      matching: find.byType(SwitchListTile),
    );
    expect(tester.widget<SwitchListTile>(tileFinder).value, isTrue);

    // 关闭 → 树内 SettingsProvider 状态翻转（持久化由 provider/local_storage 单测覆盖）
    await tester.tap(find.text(AppStrings.lanAccelerationTitle));
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(tileFinder).value, isFalse);
  });
}
