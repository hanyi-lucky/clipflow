import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:clipflow/models/sync_operation.dart';
import 'package:clipflow/repositories/local_outbox_store.dart';

SyncOperation operation({
  String id = 'op-1',
  String userId = 'user-1',
  SyncOperationState state = SyncOperationState.pending,
  String dedupeKey = 'hash-1',
  String? artifactId,
}) {
  return SyncOperation(
    operationId: id,
    userId: userId,
    kind: SyncOperationKind.text,
    state: state,
    dedupeKey: dedupeKey,
    createdAtMs: 100,
    updatedAtMs: 100,
    attemptCount: 0,
    nextAttemptAtMs: 0,
    payload: const {'content': 'encrypted'},
    artifactId: artifactId,
  );
}

void main() {
  late Directory directory;
  late LocalOutboxStore store;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('clipflow-outbox-test-');
    store = LocalOutboxStore(directoryPath: directory.path);
  });

  tearDown(() async {
    if (directory.existsSync()) await directory.delete(recursive: true);
  });

  test('persists an operation and restores sending as pending', () async {
    await store.put(operation(state: SyncOperationState.sending));

    final active = await store.loadActive('user-1');

    expect(active, hasLength(1));
    expect(active.single.state, SyncOperationState.pending);
  });

  test('finds an active operation by user, kind and dedupe key', () async {
    await store.put(operation());
    await store.put(operation(id: 'dead', state: SyncOperationState.dead));

    final found = await store.findActiveByDedupeKey(
      'user-1',
      SyncOperationKind.text,
      'hash-1',
    );

    expect(found?.operationId, 'op-1');
  });

  test('isolates operations by user and ignores one corrupt manifest', () async {
    final userOne = Directory('${directory.path}/user-1');
    await userOne.create(recursive: true);
    await File('${userOne.path}/bad.json').writeAsString('{not-json');
    await store.put(operation());
    await store.put(operation(id: 'op-2', userId: 'user-2'));

    final active = await store.loadActive('user-1');

    expect(active.map((item) => item.operationId), contains('op-1'));
    expect(active.map((item) => item.operationId), isNot(contains('op-2')));
    expect(File('${userOne.path}/bad.json').existsSync(), isFalse);
  });

  test('clearUser returns artifact ids and does not clear another user', () async {
    await store.put(operation(artifactId: 'artifact-1'));
    await store.put(operation(id: 'op-2', userId: 'user-2', artifactId: 'artifact-2'));

    final artifacts = await store.clearUser('user-1');

    expect(artifacts, contains('artifact-1'));
    expect(await store.loadActive('user-1'), isEmpty);
    expect(await store.loadActive('user-2'), hasLength(1));
  });

  test('writes a JSON manifest containing no plaintext outside payload contract', () async {
    await store.put(operation());

    final manifest = File('${directory.path}/user-1/op-1.json');
    final decoded = jsonDecode(await manifest.readAsString()) as Map<String, dynamic>;

    expect(decoded['operationId'], 'op-1');
    expect(decoded['payload']['content'], 'encrypted');
  });
}
