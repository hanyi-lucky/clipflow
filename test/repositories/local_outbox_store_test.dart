import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:clipflow/models/sync_operation.dart';
import 'package:clipflow/repositories/local_outbox_store.dart';

SyncOperation operation({
  String id = 'op-1',
  String userId = 'user-1',
  SyncOperationKind kind = SyncOperationKind.text,
  SyncOperationState state = SyncOperationState.pending,
  String dedupeKey = 'hash-1',
  String? artifactId,
  Map<String, dynamic> payload = const {'content': 'encrypted'},
  int updatedAtMs = 100,
}) {
  return SyncOperation(
    operationId: id,
    userId: userId,
    kind: kind,
    state: state,
    dedupeKey: dedupeKey,
    createdAtMs: 100,
    updatedAtMs: updatedAtMs,
    attemptCount: 0,
    nextAttemptAtMs: 0,
    payload: payload,
    artifactId: artifactId,
  );
}

String canonicalName(String operationId) {
  return 'v2-${sha256.convert(utf8.encode(operationId))}.json';
}

void main() {
  late Directory directory;
  late LocalOutboxStore store;

  Directory userDirectory([String userId = 'user-1']) {
    return Directory('${directory.path}/clipflow_outbox/$userId');
  }

  File canonicalFile(SyncOperation op) {
    return File('${userDirectory(op.userId).path}/${canonicalName(op.operationId)}');
  }

  Future<File> writeManifest(
    String fileName,
    SyncOperation op, {
    String userId = 'user-1',
  }) async {
    final dir = userDirectory(userId);
    await dir.create(recursive: true);
    final file = File('${dir.path}/$fileName');
    await file.writeAsString(jsonEncode(op.toJson()), flush: true);
    return file;
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('clipflow-outbox-test-');
    store = LocalOutboxStore(directoryPath: directory.path);
  });

  tearDown(() async {
    if (directory.existsSync()) await directory.delete(recursive: true);
  });

  test('put stores the canonical hash filename without leaking the operation id',
      () async {
    await store.put(
      operation(
        id: 'del:entry-1',
        kind: SyncOperationKind.delete,
        payload: const {'entryId': 'entry-1'},
      ),
    );

    expect(canonicalFile(operation(id: 'del:entry-1')).existsSync(), isTrue);
    final files = userDirectory()
        .listSync()
        .whereType<File>()
        .map((file) => file.uri.pathSegments.last)
        .toList();
    expect(files, [canonicalName('del:entry-1')]);
    expect(files.single,
        isNot(contains('del:entry-1')));

    final decoded = jsonDecode(
      await canonicalFile(operation(id: 'del:entry-1')).readAsString(),
    ) as Map<String, dynamic>;
    expect(decoded['operationId'], 'del:entry-1');
  });

  test('round-trips text, image, file, delete and restore operations', () async {
    final operations = [
      operation(id: 'text-1', payload: const {'content': 'text'}),
      operation(
        id: 'image-1',
        kind: SyncOperationKind.image,
        payload: const {'content': 'image', 'thumb': 'thumb'},
      ),
      operation(
        id: 'file-1',
        kind: SyncOperationKind.file,
        payload: const {'artifactPath': 'artifact.bin'},
      ),
      operation(
        id: 'del:entry-1',
        kind: SyncOperationKind.delete,
        payload: const {'entryId': 'entry-1'},
      ),
      operation(
        id: 'rest:entry-2',
        kind: SyncOperationKind.restore,
        payload: const {'entryId': 'entry-2'},
      ),
    ];
    for (final item in operations) {
      await store.put(item);
    }

    final active = await store.loadActive('user-1');

    expect(
      active.map((item) => item.operationId),
      containsAll(operations.map((item) => item.operationId)),
    );
    for (final expected in operations) {
      final actual = active.singleWhere(
        (item) => item.operationId == expected.operationId,
      );
      expect(actual.kind, expected.kind);
      expect(actual.payload, expected.payload);
    }
  });

  test('persists an operation and restores sending as pending', () async {
    await store.put(operation(state: SyncOperationState.sending));

    final active = await store.loadActive('user-1');

    expect(active, hasLength(1));
    expect(active.single.state, SyncOperationState.pending);
    expect(
      (jsonDecode(await canonicalFile(active.single).readAsString())
          as Map<String, dynamic>)['state'],
      'pending',
    );
  });

  test('update atomically replaces the same canonical manifest', () async {
    final pending = operation();
    await store.put(pending);
    await store.update(
      pending.copyWith(
        state: SyncOperationState.retryable,
        updatedAtMs: 200,
        lastError: 'offline',
      ),
    );

    final active = await store.loadActive('user-1');

    expect(active, hasLength(1));
    expect(active.single.state, SyncOperationState.retryable);
    expect(active.single.lastError, 'offline');
    expect(canonicalFile(active.single).existsSync(), isTrue);
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
    final userOne = userDirectory();
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
    await store.put(
      operation(id: 'op-2', userId: 'user-2', artifactId: 'artifact-2'),
    );

    final artifacts = await store.clearUser('user-1');

    expect(artifacts, contains('artifact-1'));
    expect(await store.loadActive('user-1'), isEmpty);
    expect(await store.loadActive('user-2'), hasLength(1));
  });

  test('writes a JSON manifest containing no plaintext outside payload contract',
      () async {
    await store.put(operation());

    final manifest = canonicalFile(operation());
    final decoded = jsonDecode(await manifest.readAsString()) as Map<String, dynamic>;

    expect(decoded['operationId'], 'op-1');
    expect(decoded['payload']['content'], 'encrypted');
  });
}
