import 'package:flutter_test/flutter_test.dart';
import 'package:clipflow/models/sync_operation.dart';

void main() {
  test('serializes and restores an operation without losing metadata', () {
    final operation = SyncOperation(
      operationId: 'op-1',
      userId: 'user-1',
      kind: SyncOperationKind.text,
      state: SyncOperationState.pending,
      dedupeKey: 'hash-1',
      createdAtMs: 100,
      updatedAtMs: 110,
      attemptCount: 2,
      nextAttemptAtMs: 200,
      payload: {'content': 'ciphertext', 'historyId': 'op-1'},
      artifactId: null,
      lastError: null,
    );

    final restored = SyncOperation.fromJson(operation.toJson());

    expect(restored.operationId, operation.operationId);
    expect(restored.userId, operation.userId);
    expect(restored.kind, operation.kind);
    expect(restored.state, operation.state);
    expect(restored.payload, operation.payload);
    expect(restored.toJson(), operation.toJson());
  });

  test('rejects an operation with an unknown state', () {
    expect(
      () => SyncOperation.fromJson({
        'schemaVersion': 1,
        'operationId': 'op-1',
        'userId': 'user-1',
        'kind': 'text',
        'state': 'unknown',
        'dedupeKey': 'hash-1',
        'createdAtMs': 100,
        'updatedAtMs': 100,
        'attemptCount': 0,
        'nextAttemptAtMs': 0,
        'payload': <String, dynamic>{},
        'artifactId': null,
        'lastError': null,
      }),
      throwsA(isA<SyncOperationFormatException>()),
    );
  });
  test('delete kind round-trips with schemaVersion 1', () {
    final operation = SyncOperation(
      operationId: 'del:entry-1',
      userId: 'user-1',
      kind: SyncOperationKind.delete,
      state: SyncOperationState.pending,
      dedupeKey: 'del:entry-1',
      createdAtMs: 100,
      updatedAtMs: 100,
      attemptCount: 0,
      nextAttemptAtMs: 100,
      payload: {'entryId': 'entry-1'},
    );

    final restored = SyncOperation.fromJson(operation.toJson());

    expect(restored.kind, SyncOperationKind.delete);
    expect(restored.operationId, 'del:entry-1');
    expect(restored.dedupeKey, 'del:entry-1');
    expect(restored.payload['entryId'], 'entry-1');
    expect(restored.toJson()['schemaVersion'], 1);
  });

  test('restore kind round-trips with schemaVersion 1', () {
    final operation = SyncOperation(
      operationId: 'rest:entry-2',
      userId: 'user-1',
      kind: SyncOperationKind.restore,
      state: SyncOperationState.pending,
      dedupeKey: 'rest:entry-2',
      createdAtMs: 100,
      updatedAtMs: 100,
      attemptCount: 0,
      nextAttemptAtMs: 100,
      payload: {'entryId': 'entry-2'},
    );

    final restored = SyncOperation.fromJson(operation.toJson());

    expect(restored.kind, SyncOperationKind.restore);
    expect(restored.operationId, 'rest:entry-2');
    expect(restored.toJson()['schemaVersion'], 1);
  });

  test('legacy schemaVersion 1 json with delete kind is accepted', () {
    final restored = SyncOperation.fromJson({
      'schemaVersion': 1,
      'operationId': 'del:legacy-1',
      'userId': 'user-1',
      'kind': 'delete',
      'state': 'pending',
      'dedupeKey': 'del:legacy-1',
      'createdAtMs': 100,
      'updatedAtMs': 100,
      'attemptCount': 0,
      'nextAttemptAtMs': 100,
      'payload': <String, dynamic>{'entryId': 'legacy-1'},
      'artifactId': null,
      'lastError': null,
    });

    expect(restored.kind, SyncOperationKind.delete);
  });

}
