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
}
