import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:clipflow/providers/settings_provider.dart';
import 'package:clipflow/services/history_service.dart';
import 'package:clipflow/models/clipboard_entry.dart';
import 'package:clipflow/repositories/local_storage.dart';

/// Simulates the wiring between SettingsProvider and HistoryService
/// that ClipboardProvider.setSettingsProvider establishes.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('SettingsProvider.setHistoryLimit -> HistoryService.updateMaxEntries wiring', () async {
    SharedPreferences.setMockInitialValues({});
    final storage = LocalStorage(await SharedPreferences.getInstance());
    final settings = SettingsProvider();
    await settings.initialize(storage);

    final historyService = HistoryService(maxEntries: 100);

    // Simulate ClipboardProvider.setSettingsProvider wiring
    settings.addListener(() {
      historyService.updateMaxEntries(settings.historyLimit);
    });

    // Add 50 entries
    for (int i = 0; i < 50; i++) {
      historyService.addEntry(ClipboardEntry(
        id: 'w-$i', content: 'Wired $i', sourceDeviceId: 'd1',
        sourceDeviceName: 'Mac', timestamp: DateTime(2024, 1, i + 1),
        type: ContentType.text, isPinned: false,
      ));
    }
    expect(historyService.entries.length, 50);

    // Change historyLimit via SettingsProvider
    await settings.setHistoryLimit(20);

    // HistoryService should have been trimmed
    expect(historyService.entries.length, 20);
    expect(settings.historyLimit, 20);
  });

  test('increase historyLimit does not add entries', () async {
    SharedPreferences.setMockInitialValues({});
    final storage = LocalStorage(await SharedPreferences.getInstance());
    final settings = SettingsProvider();
    await settings.initialize(storage);

    final historyService = HistoryService(maxEntries: 10);

    settings.addListener(() {
      historyService.updateMaxEntries(settings.historyLimit);
    });

    for (int i = 0; i < 10; i++) {
      historyService.addEntry(ClipboardEntry(
        id: 'inc-$i', content: 'Inc $i', sourceDeviceId: 'd1',
        sourceDeviceName: 'Mac', timestamp: DateTime(2024, 1, i + 1),
        type: ContentType.text, isPinned: false,
      ));
    }
    expect(historyService.entries.length, 10);

    await settings.setHistoryLimit(50);
    expect(historyService.entries.length, 10); // no change
  });
}
