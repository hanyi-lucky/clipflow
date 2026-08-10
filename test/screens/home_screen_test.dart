import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:clipflow/l10n/app_strings.dart';
import 'package:clipflow/providers/clipboard_provider.dart';
import 'package:clipflow/repositories/local_storage.dart';
import 'package:clipflow/screens/home_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget buildHome(ClipboardProvider provider) {
    return ChangeNotifierProvider<ClipboardProvider>.value(
      value: provider,
      child: MaterialApp(home: HomeScreen()),
    );
  }

  Future<void> useTallViewport(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  testWidgets('LAN-only 降级时首页显示「内容仅在本地」横幅', (tester) async {
    await useTallViewport(tester);
    SharedPreferences.setMockInitialValues({});
    final provider = ClipboardProvider();
    addTearDown(provider.dispose);
    // 无 peer（测试环境无 manager）→ lanOnlyDegraded = true
    await provider.setLanOnlyMode(true);
    expect(provider.lanOnlyDegraded, isTrue);

    await tester.pumpWidget(buildHome(provider));
    await tester.pumpAndSettle();

    // 横幅文案（Sliver 布局：向下滚动后可见）
    await tester.scrollUntilVisible(
      find.text(AppStrings.lanOnlyLocalOnlyBanner),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(
      find.text(AppStrings.lanOnlyLocalOnlyBanner),
      findsOneWidget,
    );
    expect(
      find.text(AppStrings.lanOnlyLocalOnlyBannerHint),
      findsOneWidget,
    );
  });

  testWidgets('LAN-only 关闭（或 peer 存在）时不显示横幅', (tester) async {
    await useTallViewport(tester);
    SharedPreferences.setMockInitialValues({});
    final provider = ClipboardProvider();
    addTearDown(provider.dispose);
    // lanOnly 关闭 → 不降级
    await provider.setLanOnlyMode(true);
    await provider.setLanOnlyMode(false);
    expect(provider.lanOnlyDegraded, isFalse);

    await tester.pumpWidget(buildHome(provider));
    await tester.pumpAndSettle();

    expect(
      find.text(AppStrings.lanOnlyLocalOnlyBanner),
      findsNothing,
    );
  });
}
