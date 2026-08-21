import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:clipflow/models/sync_operation.dart';
import 'package:clipflow/repositories/cloud_repository.dart';
import 'package:clipflow/repositories/local_file_store.dart';
import 'package:clipflow/services/cloud_sync_transport.dart';
import 'package:clipflow/services/cloudbase_service.dart';

class FakeCloudRepository extends CloudRepository {
  final List<Map<String, dynamic>> currentWrites = [];
  final List<Map<String, dynamic>> historyWrites = [];
  Map<String, dynamic>? fileUpload;
  final List<Map<String, dynamic>> commitCalls = [];
  final List<int> changesAfterCalls = [];
  Map<String, dynamic>? commitResponse;
  Map<String, dynamic>? changesResponse;

  FakeCloudRepository() : super(CloudBaseService());

  @override
  Future<Map<String, dynamic>> commitSyncOperation({
    required String operationId,
    required String kind,
    required String entryId,
    Map<String, dynamic>? payload,
  }) async {
    commitCalls.add({
      'operationId': operationId,
      'kind': kind,
      'entryId': entryId,
      'payload': payload,
    });
    return commitResponse ?? const <String, dynamic>{'seq': 1};
  }

  @override
  Future<Map<String, dynamic>?> getSyncChanges({required int after, int? limit}) async {
    changesAfterCalls.add(after);
    return changesResponse;
  }

  @override
  Future<void> setCurrentClipboard(Map<String, dynamic> data) async {
    currentWrites.add({...data});
  }

  @override
  Future<void> addHistoryEntry(Map<String, dynamic> data) async {
    historyWrites.add({...data});
  }

  @override
  Future<void> uploadFile({
    required String encryptedPath,
    required String historyId,
    required String plaintextHash,
    required String fileName,
    required int fileSize,
    required String mimeType,
    required String marker,
    required String sourceDevice,
    required String sourceDeviceName,
    required String sourcePlatform,
    required int timestamp,
  }) async {
    fileUpload = {
      'encryptedPath': encryptedPath,
      'historyId': historyId,
      'plaintextHash': plaintextHash,
      'fileName': fileName,
      'fileSize': fileSize,
      'mimeType': mimeType,
      'marker': marker,
      'sourceDevice': sourceDevice,
      'sourceDeviceName': sourceDeviceName,
      'sourcePlatform': sourcePlatform,
      'timestamp': timestamp,
    };
  }
}

SyncOperation textOperation() => SyncOperation(
      operationId: 'op-text',
      userId: 'user-1',
      kind: SyncOperationKind.text,
      state: SyncOperationState.sending,
      dedupeKey: 'hash-text',
      createdAtMs: 1,
      updatedAtMs: 1,
      attemptCount: 0,
      nextAttemptAtMs: 0,
      payload: {
        'content': 'encrypted-text',
        'hash': 'hash-text',
        'sourceDevice': 'device-a',
        'sourceDeviceName': 'Mac A',
        'sourcePlatform': 'macos',
        'timestamp': 1,
        'type': 'text',
        'historyId': 'op-text',
      },
    );

void main() {
  test('sends text current and history with the stable operation id', () async {
    final repo = FakeCloudRepository();
    final transport = CloudSyncTransport(
      repository: repo,
      fileStore: LocalFileStore(directoryPath: '/tmp/clipflow-test-files'),
    );

    await transport.send(textOperation());

    expect(repo.currentWrites.single['historyId'], 'op-text');
    expect(repo.historyWrites.single['historyId'], 'op-text');
    expect(repo.historyWrites.single['pinned'], false);
  });

  test('sends a file using its persisted artifact and operation id', () async {
    final directory = await Directory.systemTemp.createTemp('clipflow-file-');
    addTearDown(() => directory.delete(recursive: true));
    final fileStore = LocalFileStore(directoryPath: directory.path);
    final artifact = await fileStore.importEncryptedFile(
      'op-file',
      await _createFile(directory.path),
    );
    final repo = FakeCloudRepository();
    final transport = CloudSyncTransport(repository: repo, fileStore: fileStore);

    await transport.send(
      SyncOperation(
        operationId: 'op-file',
        userId: 'user-1',
        kind: SyncOperationKind.file,
        state: SyncOperationState.sending,
        dedupeKey: 'file:hash-file',
        createdAtMs: 1,
        updatedAtMs: 1,
        attemptCount: 0,
        nextAttemptAtMs: 0,
        payload: {
          'hash': 'hash-file',
          'fileName': 'a.txt',
          'fileSize': 3,
          'mimeType': 'text/plain',
          'marker': 'marker',
          'sourceDevice': 'device-a',
          'sourceDeviceName': 'Mac A',
          'sourcePlatform': 'macos',
          'timestamp': 1,
        },
        artifactId: 'op-file',
      ),
    );

    expect(repo.fileUpload?['encryptedPath'], artifact);
    expect(repo.fileUpload?['historyId'], 'op-file');
  });
  test('sends a delete via commitSyncOperation and returns the data', () async {
    final repo = FakeCloudRepository()
      ..commitResponse = {'seq': 7};
    final transport = CloudSyncTransport(
      repository: repo,
      fileStore: LocalFileStore(directoryPath: '/tmp/clipflow-test-files'),
    );

    final response = await transport.send(
      SyncOperation(
        operationId: 'del:entry-1',
        userId: 'user-1',
        kind: SyncOperationKind.delete,
        state: SyncOperationState.sending,
        dedupeKey: 'del:entry-1',
        createdAtMs: 1,
        updatedAtMs: 1,
        attemptCount: 0,
        nextAttemptAtMs: 0,
        payload: const {'entryId': 'entry-1'},
      ),
    );

    expect(repo.commitCalls.single['operationId'], 'del:entry-1');
    expect(repo.commitCalls.single['kind'], 'delete');
    expect(repo.commitCalls.single['entryId'], 'entry-1');
    expect(response, {'seq': 7});
  });

  test('sends a restore via commitSyncOperation and returns row data', () async {
    final repo = FakeCloudRepository()
      ..commitResponse = {
        'seq': 8,
        'row': {'id': 'entry-2', 'content': 'cipher', 'type': 'text'},
      };
    final transport = CloudSyncTransport(
      repository: repo,
      fileStore: LocalFileStore(directoryPath: '/tmp/clipflow-test-files'),
    );

    final response = await transport.send(
      SyncOperation(
        operationId: 'rest:entry-2',
        userId: 'user-1',
        kind: SyncOperationKind.restore,
        state: SyncOperationState.sending,
        dedupeKey: 'rest:entry-2',
        createdAtMs: 1,
        updatedAtMs: 1,
        attemptCount: 0,
        nextAttemptAtMs: 0,
        payload: const {'entryId': 'entry-2'},
      ),
    );

    expect(repo.commitCalls.single['kind'], 'restore');
    expect(response?['seq'], 8);
    expect(response?['row']?['id'], 'entry-2');
  });

  test('fetchSyncChanges delegates the after cursor and returns the page', () async {
    final repo = FakeCloudRepository()
      ..changesResponse = {
        'cursor': 9,
        'hasMore': false,
        'changes': <Map<String, dynamic>>[],
      };
    final transport = CloudSyncTransport(
      repository: repo,
      fileStore: LocalFileStore(directoryPath: '/tmp/clipflow-test-files'),
    );

    final page = await transport.fetchSyncChanges(after: 3);

    expect(repo.changesAfterCalls.single, 3);
    expect(page?['cursor'], 9);
    expect(page?['hasMore'], false);
  });

  test('fetchSyncChanges returns null for a legacy server (404 fallback)', () async {
    final repo = FakeCloudRepository()..changesResponse = null;
    final transport = CloudSyncTransport(
      repository: repo,
      fileStore: LocalFileStore(directoryPath: '/tmp/clipflow-test-files'),
    );

    final page = await transport.fetchSyncChanges(after: 0);

    expect(page, isNull);
  });
}

Future<String> _createFile(String directoryPath) async {
  final file = File('$directoryPath/source.enc');
  await file.writeAsBytes(Uint8List.fromList([1, 2, 3]));
  return file.path;
}
