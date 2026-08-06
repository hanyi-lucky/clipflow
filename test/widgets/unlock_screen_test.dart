import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:clipflow/app.dart';
import 'package:clipflow/providers/auth_provider.dart';
import 'package:clipflow/providers/clipboard_provider.dart';
import 'package:clipflow/providers/settings_provider.dart';
import 'package:clipflow/repositories/local_storage.dart';

Widget _buildApp(AuthProvider auth, SettingsProvider settings) {
  return MultiProvider(
    providers: [
      ChangeNotifierProvider.value(value: auth),
      ChangeNotifierProvider.value(value: settings),
      ChangeNotifierProvider(create: (_) => ClipboardProvider()),
    ],
    child: const ClipFlowApp(),
  );
}

void main() {
  testWidgets('首次设密码：输入弱密码显示非阻断警告条', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final storage = await LocalStorage.create();
    final auth = AuthProvider();
    final settings = SettingsProvider();
    await auth.initialize(storage);
    await settings.initialize(storage);

    await tester.pumpWidget(_buildApp(auth, settings));
    await tester.pumpAndSettle();

    expect(find.text('设置主密码'), findsOneWidget);
    expect(find.textContaining('此密码过于简单'), findsNothing);

    await tester.enterText(find.byType(TextField), '123456');
    await tester.pump();

    expect(find.textContaining('此密码过于简单'), findsOneWidget);
  });

  testWidgets('首次设密码：输入强密码不显示警告条', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final storage = await LocalStorage.create();
    final auth = AuthProvider();
    final settings = SettingsProvider();
    await auth.initialize(storage);
    await settings.initialize(storage);

    await tester.pumpWidget(_buildApp(auth, settings));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'Tr0ub4dor&3!xK');
    await tester.pump();

    expect(find.textContaining('此密码过于简单'), findsNothing);
  });

  testWidgets('本地密码错误判定：连续 5 次错误后本地锁定', (tester) async {
    // 预置 userId 标记（模拟升级存量用户），无 salt → 首次设密码 UI
    SharedPreferences.setMockInitialValues({'user_id': 'user_stored'});
    final storage = await LocalStorage.create();
    final auth = AuthProvider();
    final settings = SettingsProvider();
    await auth.initialize(storage);
    await settings.initialize(storage);

    await tester.pumpWidget(_buildApp(auth, settings));
    await tester.pumpAndSettle();

    for (var i = 0; i < 5; i++) {
      await tester.enterText(find.byType(TextField), 'wrong-password-$i');
      await tester.tap(find.text('创建并开始'));
      await tester.pump();
      // 前 5 次：密码错误提示（本地判定拦截，不发 /auth）
      expect(find.textContaining('密码错误'), findsWidgets);
    }

    // 第 6 次尝试被本地锁定：提示「尝试过于频繁」
    await tester.enterText(find.byType(TextField), 'wrong-password-5');
    await tester.tap(find.text('创建并开始'));
    await tester.pump();
    expect(find.textContaining('尝试过于频繁'), findsOneWidget);
  });

  testWidgets('切换到其他账户：确认后清除本机账户标记，可输入新密码不再判错', (tester) async {
    // 预置本机账户标记（模拟已用旧密码解锁过的设备）
    SharedPreferences.setMockInitialValues({'user_id': 'user_old'});
    final storage = await LocalStorage.create();
    final auth = AuthProvider();
    final settings = SettingsProvider();
    await auth.initialize(storage);
    await settings.initialize(storage);

    await tester.pumpWidget(_buildApp(auth, settings));
    await tester.pumpAndSettle();

    // 已有本机账户标记 → 显示「切换到其他账户」入口
    expect(find.text('切换到其他账户'), findsOneWidget);

    // 点击 → 出现确认对话框
    await tester.tap(find.text('切换到其他账户'));
    await tester.pumpAndSettle();
    expect(find.textContaining('切换账户将清除'), findsOneWidget);

    // 确认 → 清除本机账户标记，回到「设置主密码」首次设密码界面
    await tester.tap(find.text('继续切换'));
    await tester.pumpAndSettle();
    expect(storage.userId, isNull);
    expect(find.text('设置主密码'), findsOneWidget);

    // 输入新密码：不再被本地判定拦截（环境无网络 → 显示「解锁失败」，而非「密码错误」）
    await tester.enterText(find.byType(TextField), 'new-password');
    await tester.tap(find.text('创建并开始'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.textContaining('密码错误'), findsNothing);
    expect(find.textContaining('解锁失败'), findsOneWidget);
  });
}
