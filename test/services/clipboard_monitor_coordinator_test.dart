import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:clipflow/models/sync_operation.dart';
import 'package:clipflow/repositories/cloud_repository.dart';
import 'package:clipflow/repositories/local_file_store.dart';
import 'package:clipflow/repositories/local_outbox_store.dart';
import 'package:clipflow/services/clipboard_monitor.dart';
import 'package:clipflow/services/cloudbase_service.dart';
import 'package:clipflow/services/encryption_service.dart';
import 'package:clipflow/services/sync_coordinator.dart';
import 'package:clipflow/services/sync_service.dart';
import 'package:clipflow/services/sync_transport.dart';

class _Transport implements SyncTransport {
  final List<SyncOperation> sent = [];

  @override
  Future<Map<String, dynamic>?> send(SyncOperation operation) async {
    sent.add(operation);
    return null;
  }

  @override
  Future<Map<String, dynamic>?> fetchCurrentClipboardWithDeletions() async => null;

  @override
  Future<Map<String, dynamic>?> fetchSyncChanges({required int after}) async => null;

  @override
  Future<void> close() async {}
}

void main() {
  test('monitor uploads text through the injected coordinator', () async {
    final directory = await Directory.systemTemp.createTemp('clipflow-monitor-');
    addTearDown(() => directory.delete(recursive: true));
    final encryption = EncryptionService();
    final key = await encryption.deriveKey(
      'monitor-password',
      List<int>.generate(32, (index) => index),
    );
    final transport = _Transport();
    final coordinator = SyncCoordinator(
      userId: 'user-1',
      syncService: SyncService(
        repo: CloudRepository(CloudBaseService()),
        encryption: encryption,
        deviceId: 'device-a',
        deviceName: 'Mac A',
        devicePlatform: 'macos',
        key: key,
      ),
      transport: transport,
      outbox: LocalOutboxStore(directoryPath: directory.path),
      fileStore: LocalFileStore(directoryPath: directory.path),
    );
    String? syncedId;
    final monitor = ClipboardMonitor(onChanged: (_) {});
    monitor.setSyncCoordinator(coordinator);
    monitor.onContentSynced = (content, id) => syncedId = id;
    addTearDown(monitor.dispose);

    await monitor.syncClipboard(preReadContent: 'from monitor');

    expect(transport.sent, hasLength(1));
    expect(syncedId, transport.sent.single.operationId);
    expect(transport.sent.single.payload['historyId'], syncedId);
  });
}
