import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:clipflow/providers/settings_provider.dart';
import 'package:clipflow/repositories/local_storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('lanAcceleration 默认开启，setLanAcceleration 持久化并 notify', () async {
    SharedPreferences.setMockInitialValues({});
    final storage = LocalStorage(await SharedPreferences.getInstance());
    final settings = SettingsProvider();
    var notified = 0;
    settings.addListener(() => notified++);

    await settings.initialize(storage);
    expect(settings.lanAcceleration, isTrue);

    await settings.setLanAcceleration(false);
    expect(settings.lanAcceleration, isFalse);
    expect(storage.lanAcceleration, isFalse);
    expect(notified, greaterThanOrEqualTo(1));

    await settings.setLanAcceleration(true);
    expect(settings.lanAcceleration, isTrue);
    expect(storage.lanAcceleration, isTrue);
  });

  test('lanOnlyMode 默认关闭，setLanOnlyMode 持久化并 notify，重载保持', () async {
    SharedPreferences.setMockInitialValues({});
    final storage = LocalStorage(await SharedPreferences.getInstance());
    final settings = SettingsProvider();
    var notified = 0;
    settings.addListener(() => notified++);

    await settings.initialize(storage);
    expect(settings.lanOnlyMode, isFalse);

    await settings.setLanOnlyMode(true);
    expect(settings.lanOnlyMode, isTrue);
    expect(storage.lanOnlyMode, isTrue);
    expect(notified, greaterThanOrEqualTo(1));

    // 重载保持
    final reloaded = SettingsProvider();
    await reloaded.initialize(storage);
    expect(reloaded.lanOnlyMode, isTrue);

    await settings.setLanOnlyMode(false);
    expect(settings.lanOnlyMode, isFalse);
    expect(storage.lanOnlyMode, isFalse);
  });
}
