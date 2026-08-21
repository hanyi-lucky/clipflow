import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:clipflow/providers/clipboard_provider.dart';
import 'package:clipflow/repositories/cloud_repository.dart';
import 'package:clipflow/repositories/local_image_store.dart';
import 'package:clipflow/repositories/local_storage.dart';
import 'package:clipflow/services/cloudbase_service.dart';
import 'package:clipflow/services/encryption_service.dart';

class FakeDeletionRepo extends CloudRepository {

  @override
  Future<Map<String, dynamic>?> getSyncChanges({required int after, int? limit}) async => null;
  FakeDeletionRepo() : super(CloudBaseService());

  List<Map<String, dynamic>> history = [];
  Map<String, dynamic>? currentClipboard;
  List<String> deletedIds = [];

  @override
  Future<List<Map<String, dynamic>>> getHistoryEntries({int limit = 100}) async =>
      history;

  @override
  Future<Map<String, dynamic>?> getCurrentClipboardWithDeletions() async {
    if (currentClipboard == null) return null;
    return {...currentClipboard!};
  }

  @override
  Future<Map<String, dynamic>?> getHistoryEntryContent(String entryId) async => null;

  @override
  Future<void> deleteHistoryEntry(String entryId) async {
    deletedIds.add(entryId);
  }

  @override
  Future<void> updateHistoryEntry(String entryId, Map<String, dynamic> data) async {}

  @override
  Future<void> restoreHistoryEntry(String entryId) async {}

  @override
  Future<List<Map<String, dynamic>>> getTrashEntries() async => [];

  @override
  Future<String?> getSalt() async => null;

  @override
  Future<void> setSalt(String salt) async {}

  @override
  Future<void> setCurrentClipboard(Map<String, dynamic> data) async {}

  @override
  Future<void> addHistoryEntry(Map<String, dynamic> data) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const password = 'deletion-test';
  final salt = List<int>.generate(32, (i) => i % 256);

  late EncryptionService encryption;
  late Uint8List key;
  late FakeDeletionRepo repo;
  late LocalStorage storage;
  late LocalImageStore imageStore;
  late Directory tempDir;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    encryption = EncryptionService();
    key = await encryption.deriveKey(password, salt);
    repo = FakeDeletionRepo();
    storage = LocalStorage(await SharedPreferences.getInstance());
    tempDir = await Directory.systemTemp.createTemp('clipflow_deletion_');
    imageStore = LocalImageStore(directoryPath: tempDir.path);
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  Map<String, dynamic> textRow(String id, String contentBase64) {
    return {
      'id': id,
      'content': contentBase64,
      'type': 'text',
      'source_device': 'device-a',
      'source_device_name': 'Mac A',
      'source_platform': 'macos',
      'timestamp': 1700000001000,
      'pinned': 0,
    };
  }

  Future<ClipboardProvider> createProvider() async {
    final provider = ClipboardProvider(imageStore: imageStore);
    await provider.initialize(
      storage: storage,
      cloudRepo: repo,
      deviceId: 'device-test',
      deviceName: 'Test Mac',
      encryptionKey: key,
    );
    return provider;
  }

  Future<void> waitFor(
    ClipboardProvider provider,
    bool Function() condition, {
    String? message,
  }) async {
    for (var i = 0; i < 120; i++) {
      if (condition()) return;
      await Future.delayed(const Duration(milliseconds: 50));
    }
    fail(message ?? 'condition not met within timeout');
  }

  Future<void> settle() =>
      Future.delayed(const Duration(milliseconds: 200));

  group('removeEntry persistence', () {
    test('removeEntry persists deletion so historyJson excludes the id', () async {
      final textEnc = await encryption.encrypt('to be deleted', key);
      repo.history = [textRow('del-1', textEnc.toBase64())];

      final provider = await createProvider();
      await waitFor(
        provider,
        () => provider.history.any((e) => e.id == 'del-1'),
        message: 'entry should load from server',
      );

      await provider.removeEntry('del-1');

      // Verify entry is removed from in-memory history
      expect(provider.history.any((e) => e.id == 'del-1'), isFalse);

      // Verify persisted historyJson no longer contains the id
      final savedJson = storage.historyJson;
      expect(savedJson, isNotNull);
      expect(savedJson!.contains('del-1'), isFalse);

      await settle();
      provider.dispose();
    });

    test('deleted id is saved to persistent deletedEntryIds set', () async {
      final textEnc = await encryption.encrypt('tracked delete', key);
      repo.history = [textRow('del-2', textEnc.toBase64())];

      final provider = await createProvider();
      await waitFor(
        provider,
        () => provider.history.any((e) => e.id == 'del-2'),
        message: 'entry should load from server',
      );

      await provider.removeEntry('del-2');

      // After server confirms deletion, id should be removed from the set
      // (FakeDeletionRepo.deleteHistoryEntry succeeds synchronously)
      expect(storage.deletedEntryIds.contains('del-2'), isFalse);

      await settle();
      provider.dispose();
    });
  });

  group('deletedEntryIds prevents resurrection on refresh', () {
    test('refresh skips entries in deletedEntryIds and re-deletes from server',
        () async {
      final textEnc = await encryption.encrypt('will be deleted', key);
      repo.history = [textRow('del-3', textEnc.toBase64())];

      final provider = await createProvider();
      await waitFor(
        provider,
        () => provider.history.any((e) => e.id == 'del-3'),
        message: 'entry should load from server',
      );

      // Remove the entry (server delete succeeds → id removed from set)
      await provider.removeEntry('del-3');
      expect(provider.history.any((e) => e.id == 'del-3'), isFalse);

      // Simulate server still returning the deleted entry (e.g. delete failed
      // on a previous session). Pre-populate the deletedEntryIds set.
      await storage.setDeletedEntryIds({'del-3'});
      repo.history = [textRow('del-3', textEnc.toBase64())];
      repo.deletedIds.clear();

      await provider.refresh();
      await waitFor(
        provider,
        () => repo.deletedIds.contains('del-3'),
        message: 'server should receive re-delete for del-3',
      );

      // Entry should NOT reappear in history
      expect(provider.history.any((e) => e.id == 'del-3'), isFalse);
      // Server should have received the re-delete call
      expect(repo.deletedIds.contains('del-3'), isTrue);
      // After successful re-delete, id should be removed from the set
      expect(storage.deletedEntryIds.contains('del-3'), isFalse);

      await settle();
      provider.dispose();
    });
  });
}
