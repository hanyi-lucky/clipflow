import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:clipflow/models/sync_operation.dart';
import 'package:clipflow/repositories/cloud_repository.dart';
import 'package:clipflow/repositories/local_file_store.dart';
import 'package:clipflow/repositories/local_outbox_store.dart';
import 'package:clipflow/services/cloudbase_service.dart';
import 'package:clipflow/services/encryption_service.dart';
import 'package:clipflow/services/sync_coordinator.dart';
import 'package:clipflow/services/sync_service.dart';
import 'package:clipflow/services/sync_transport.dart';

class _RecordingTransport implements SyncTransport {
  final List<SyncOperation> sent = [];
  int failuresRemaining;

  _RecordingTransport({this.failuresRemaining = 0});

  @override
  Future<void> send(SyncOperation operation) async {
    sent.add(operation);
    if (failuresRemaining > 0) {
      failuresRemaining--;
      throw const SocketException('offline');
    }
  }

  @override
  Future<Map<String, dynamic>?> fetchCurrentClipboardWithDeletions() async => null;

  @override
  Future<void> close() async {}
}

void main() {
  late Directory directory;
  late SyncService syncService;
  late LocalOutboxStore outbox;
  late LocalFileStore fileStore;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('clipflow-coordinator-');
    final encryption = EncryptionService();
    final key = await encryption.deriveKey(
      'coordinator-password',
      List<int>.generate(32, (index) => index),
    );
    syncService = SyncService(
      repo: CloudRepository(CloudBaseService()),
      encryption: encryption,
      deviceId: 'device-a',
      deviceName: 'Mac A',
      devicePlatform: 'macos',
      key: key,
    );
    outbox = LocalOutboxStore(directoryPath: directory.path);
    fileStore = LocalFileStore(directoryPath: directory.path);
  });

  tearDown(() async {
    if (directory.existsSync()) await directory.delete(recursive: true);
  });

  test('persists, sends and removes a text operation with one operation id', () async {
    final transport = _RecordingTransport();
    final coordinator = SyncCoordinator(
      userId: 'user-1',
      syncService: syncService,
      transport: transport,
      outbox: outbox,
      fileStore: fileStore,
    );

    final operationId = await coordinator.uploadContent('hello');

    expect(operationId, isNotNull);
    expect(transport.sent, hasLength(1));
    expect(transport.sent.single.operationId, operationId);
    expect(transport.sent.single.payload['historyId'], operationId);
    expect(await outbox.loadActive('user-1'), isEmpty);
  });

  test('keeps the same operation id when a retry succeeds', () async {
    final transport = _RecordingTransport(failuresRemaining: 1);
    var now = DateTime.fromMillisecondsSinceEpoch(1000);
    final coordinator = SyncCoordinator(
      userId: 'user-1',
      syncService: syncService,
      transport: transport,
      outbox: outbox,
      fileStore: fileStore,
      now: () => now,
      retryBaseDelay: const Duration(milliseconds: 10),
    );

    expect(() => coordinator.uploadContent('retry-me'), throwsA(isA<SocketException>()));
    final pending = await outbox.loadActive('user-1');
    expect(pending, hasLength(1));
    final operationId = pending.single.operationId;
    expect(pending.single.state, SyncOperationState.retryable);

    now = now.add(const Duration(milliseconds: 10));
    await coordinator.drainOnce();

    expect(transport.sent, hasLength(2));
    expect(transport.sent[1].operationId, operationId);
    expect(await outbox.loadActive('user-1'), isEmpty);
  });

  test('does not send an active duplicate for the same content hash', () async {
    final transport = _RecordingTransport(failuresRemaining: 1);
    final coordinator = SyncCoordinator(
      userId: 'user-1',
      syncService: syncService,
      transport: transport,
      outbox: outbox,
      fileStore: fileStore,
    );

    expect(() => coordinator.uploadContent('same'), throwsA(isA<SocketException>()));
    final first = (await outbox.loadActive('user-1')).single.operationId;
    final second = await coordinator.uploadContent('same');

    final active = await outbox.loadActive('user-1');
    expect(second, first);
    expect(active, hasLength(1));
    expect(active.single.operationId, first);
    expect(transport.sent, hasLength(1));
  });
}
