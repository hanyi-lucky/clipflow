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

/// 模拟 CloudBaseService._callApi 的 401 自动重登录 + 同 body 重放：
/// 首次内部 HTTP 尝试返回 401（token 失效），随后重登录并用同一
/// operation 重放成功。对 coordinator 而言 send 只有一次调用且成功
/// （重放成功即 send 正常返回），回执必须在 send 返回后触发且不产生
/// 新 operationId、不重复入队。
class _ReplayingTransport implements SyncTransport {
  final List<SyncOperation> sent = [];
  int internalAttempts = 0;

  @override
  Future<void> send(SyncOperation operation) async {
    sent.add(operation);
    internalAttempts++;
    // 重放成功：send 正常返回，coordinator 视为一次成功发送。
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

    await expectLater(
      coordinator.uploadContent('retry-me'),
      throwsA(isA<SocketException>()),
    );
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

    await expectLater(
      coordinator.uploadContent('same'),
      throwsA(isA<SocketException>()),
    );
    final first = (await outbox.loadActive('user-1')).single.operationId;
    final second = await coordinator.uploadContent('same');

    final active = await outbox.loadActive('user-1');
    expect(second, first);
    expect(active, hasLength(1));
    expect(active.single.operationId, first);
    expect(transport.sent, hasLength(1));
  });

  test('invokes onOperationSucceeded once after a successful send', () async {
    final transport = _RecordingTransport();
    final succeeded = <SyncOperation>[];
    final coordinator = SyncCoordinator(
      userId: 'user-1',
      syncService: syncService,
      transport: transport,
      outbox: outbox,
      fileStore: fileStore,
      onOperationSucceeded: (op) async => succeeded.add(op),
    );

    final operationId = await coordinator.uploadContent('hello-receipt');

    expect(succeeded, hasLength(1));
    expect(succeeded.single.operationId, operationId);
    expect(succeeded.single.kind, SyncOperationKind.text);
    expect(await outbox.loadActive('user-1'), isEmpty);
  });

  test('does not invoke onOperationSucceeded when the send fails', () async {
    final transport = _RecordingTransport(failuresRemaining: 999);
    final succeeded = <SyncOperation>[];
    final coordinator = SyncCoordinator(
      userId: 'user-1',
      syncService: syncService,
      transport: transport,
      outbox: outbox,
      fileStore: fileStore,
      onOperationSucceeded: (op) async => succeeded.add(op),
    );

    await expectLater(
      coordinator.uploadContent('fail-receipt'),
      throwsA(isA<SocketException>()),
    );

    expect(succeeded, isEmpty);
    expect(await outbox.loadActive('user-1'), hasLength(1));
  });

  test('a throwing success callback does not re-enqueue or duplicate send',
      () async {
    final transport = _RecordingTransport();
    final coordinator = SyncCoordinator(
      userId: 'user-1',
      syncService: syncService,
      transport: transport,
      outbox: outbox,
      fileStore: fileStore,
      onOperationSucceeded: (op) async => throw Exception('ui boom'),
    );

    await coordinator.uploadContent('boom-receipt');

    // manifest 已删除，回调异常不能把已成功的操作写回 outbox
    expect(await outbox.loadActive('user-1'), isEmpty);
    expect(transport.sent, hasLength(1));

    await coordinator.drainOnce();
    expect(transport.sent, hasLength(1));
  });

  test('invokes onOperationSucceeded once after a retry succeeds', () async {
    final transport = _RecordingTransport(failuresRemaining: 1);
    var now = DateTime.fromMillisecondsSinceEpoch(1000);
    final succeeded = <SyncOperation>[];
    final coordinator = SyncCoordinator(
      userId: 'user-1',
      syncService: syncService,
      transport: transport,
      outbox: outbox,
      fileStore: fileStore,
      now: () => now,
      retryBaseDelay: const Duration(milliseconds: 10),
      onOperationSucceeded: (op) async => succeeded.add(op),
    );

    await expectLater(
      coordinator.uploadContent('retry-receipt'),
      throwsA(isA<SocketException>()),
    );
    expect(succeeded, isEmpty);

    final operationId = (await outbox.loadActive('user-1')).single.operationId;
    now = now.add(const Duration(milliseconds: 10));
    await coordinator.drainOnce();

    expect(succeeded, hasLength(1));
    expect(succeeded.single.operationId, operationId);
    expect(await outbox.loadActive('user-1'), isEmpty);
  });

  test('401 replay success triggers the receipt without a new operation id',
      () async {
    final transport = _ReplayingTransport();
    final succeeded = <SyncOperation>[];
    final coordinator = SyncCoordinator(
      userId: 'user-1',
      syncService: syncService,
      transport: transport,
      outbox: outbox,
      fileStore: fileStore,
      onOperationSucceeded: (op) async => succeeded.add(op),
    );

    final operationId = await coordinator.uploadContent('replay-receipt');

    // send 只被调用一次（401 重放在 transport 内部完成并成功）
    expect(transport.sent, hasLength(1));
    expect(succeeded, hasLength(1));
    expect(succeeded.single.operationId, operationId);
    expect(transport.sent.single.operationId, operationId);
    expect(await outbox.loadActive('user-1'), isEmpty);
  });
}
