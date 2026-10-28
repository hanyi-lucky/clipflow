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

  List<String> fileNameList() {
    return userDirectory()
        .listSync()
        .whereType<File>()
        .map((file) => file.uri.pathSegments.last)
        .toList()
      ..sort();
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

  test('migrates UUID legacy files and removes the source after readback',
      () async {
    final legacyOp = operation(id: '0f5bb4d8-1111-4444-8888-123456789abc');
    final legacy = await writeManifest('${legacyOp.operationId}.json', legacyOp);

    final active = await store.loadActive('user-1');

    expect(active.single.operationId, legacyOp.operationId);
    expect(canonicalFile(legacyOp).existsSync(), isTrue);
    expect(legacy.existsSync(), isFalse);
  });

  test('migrates a manifest whose filename is not its opId using manifest identity',
      () async {
    final legacyOp = operation(
      id: 'del:entry-7',
      kind: SyncOperationKind.delete,
      payload: const {'entryId': 'entry-7'},
    );
    final legacy = await writeManifest('legacy-delete.json', legacyOp);

    final active = await store.loadActive('user-1');

    expect(active.single.operationId, 'del:entry-7');
    expect(canonicalFile(legacyOp).existsSync(), isTrue);
    expect(legacy.existsSync(), isFalse);
  });

  test('skips manifest entries belonging to another user', () async {
    await writeManifest(
      'v2-foreign.json',
      operation(id: 'foreign-op', userId: 'user-2'),
    );

    expect(await store.loadActive('user-1'), isEmpty);
  });

  test('dual canonical and legacy records yield a single active operation',
      () async {
    final op = operation();
    await store.put(op);
    final legacy = await writeManifest('${op.operationId}.json', op);
    final canonical = canonicalFile(op);

    await canonical.writeAsString(
      jsonEncode(op.copyWith(updatedAtMs: 200).toJson()),
    );
    await legacy.writeAsString(jsonEncode(op.toJson()));

    final active = await store.loadActive('user-1');

    expect(active, hasLength(1));
    expect(active.single.updatedAtMs, 200);
    expect(canonical.existsSync(), isTrue);
    expect(legacy.existsSync(), isFalse);
    expect(fileNameList(), [canonicalName(op.operationId)]);
  });

  test('canonical record wins when a dual legacy copy is newer', () async {
    final op = operation();
    final canonicalOp = op.copyWith(updatedAtMs: 100);
    await store.put(canonicalOp);
    await writeManifest(
      '${op.operationId}.json',
      op.copyWith(updatedAtMs: 200),
    );

    final active = await store.loadActive('user-1');

    expect(active.single.updatedAtMs, 100);
  });

  test('recovers a temp-only manifest and returns it only once', () async {
    final op = operation(id: 'temp-only');
    final temp = await writeManifest('${canonicalName(op.operationId)}.tmp', op);

    final first = await store.loadActive('user-1');
    final second = await store.loadActive('user-1');

    expect(first.single.operationId, 'temp-only');
    expect(second, hasLength(1));
    expect(canonicalFile(op).existsSync(), isTrue);
    expect(temp.existsSync(), isFalse);
  });

  test('corrupt canonical falls back to a valid legacy record', () async {
    final op = operation(id: 'fallback');
    final canonical = await writeManifest(canonicalName(op.operationId), op);
    final legacy = await writeManifest('${op.operationId}.json', op);
    await canonical.writeAsString('{not-json');

    final active = await store.loadActive('user-1');

    expect(active.single.operationId, 'fallback');
    expect(canonical.existsSync(), isFalse);
    expect(legacy.existsSync(), isFalse);
    expect(canonicalFile(op).existsSync(), isTrue);
  });

  test('sweeps a temp copy when the canonical manifest is valid', () async {
    final op = operation();
    await store.put(op);
    final temp = await writeManifest('${canonicalName(op.operationId)}.tmp', op);

    final active = await store.loadActive('user-1');

    expect(active, hasLength(1));
    expect(temp.existsSync(), isFalse);
    expect(canonicalFile(op).existsSync(), isTrue);
  });

  test('keeps legacy source when canonical rename fails and retries next load',
      () async {
    final op = operation(id: 'rename-failure');
    final legacy = await writeManifest('${op.operationId}.json', op);
    var failed = false;
    final flakyStore = LocalOutboxStore(
      directoryPath: directory.path,
      rename: (source, target) async {
        if (!failed) {
          failed = true;
          throw const FileSystemException('rename failed');
        }
        await source.rename(target);
      },
    );

    final first = await flakyStore.loadActive('user-1');
    expect(first.single.operationId, 'rename-failure');
    expect(legacy.existsSync(), isTrue);

    final retry = LocalOutboxStore(directoryPath: directory.path);
    final second = await retry.loadActive('user-1');

    expect(second.single.operationId, 'rename-failure');
    expect(legacy.existsSync(), isFalse);
    expect(canonicalFile(op).existsSync(), isTrue);
  });

  test('preserves both operations when a hash path is occupied by another opId',
      () async {
    const firstId = 'first-op';
    const secondId = 'second-op';
    final first = operation(id: firstId);
    await store.put(first);
    final second = await writeManifest('legacy-second.json', operation(id: secondId));

    final active = await store.loadActive('user-1');

    expect(
      active.map((item) => item.operationId),
      containsAll(<String>[firstId, secondId]),
    );
    expect(canonicalFile(first).existsSync(), isTrue);
    expect(second.existsSync(), isTrue);
    expect(
      (jsonDecode(await canonicalFile(first).readAsString())
          as Map<String, dynamic>)['operationId'],
      firstId,
    );
  });

  test('remove deletes canonical and legacy artifacts for the same opId',
      () async {
    final op = operation();
    await store.put(op);
    final legacy = await writeManifest('${op.operationId}.json', op);
    await store.remove('user-1', op.operationId);

    expect(canonicalFile(op).existsSync(), isFalse);
    expect(legacy.existsSync(), isFalse);
    expect(fileNameList(), isEmpty);
  });

  test('remove does not delete another operation sharing a canonical path',
      () async {
    final first = operation(id: 'first-op');
    await store.put(first);
    final second = await writeManifest(
      canonicalName(first.operationId),
      operation(id: 'second-op'),
    );

    expect(canonicalFile(first).existsSync(), isTrue);
    await store.remove('user-1', first.operationId);

    expect(second.existsSync(), isTrue);
    expect((await store.loadActive('user-1')).single.operationId, 'second-op');
  });

  test('clearUser deduplicates artifact ids and isolates directories',
      () async {
    await store.put(operation(id: 'one', artifactId: 'artifact-1'));
    await store.put(operation(id: 'two', artifactId: 'artifact-1'));
    await writeManifest(
      '${canonicalName('legacy')}.json',
      operation(id: 'legacy', artifactId: 'artifact-1'),
    );
    await store.put(
      operation(id: 'other', userId: 'user-2', artifactId: 'artifact-2'),
    );
    await writeManifest(
      'legacy-delete.json',
      operation(
        id: 'del:old',
        kind: SyncOperationKind.delete,
        payload: const {'entryId': 'old'},
      ),
    );
    await writeManifest(
      '${canonicalName('temp-artifact')}.tmp',
      operation(id: 'temp-artifact', artifactId: 'artifact-1'),
    );

    final artifacts = await store.clearUser('user-1');

    expect(artifacts, ['artifact-1']);
    expect(userDirectory().existsSync(), isFalse);
    expect(await store.loadActive('user-2'), hasLength(1));
  });

  test('remove clears a temp-only artifact', () async {
    final op = operation(id: 'temp-remove');
    final temp = await writeManifest('${canonicalName(op.operationId)}.tmp', op);

    await store.remove('user-1', op.operationId);

    expect(temp.existsSync(), isFalse);
  });

  test('findActiveByDedupeKey returns canonical and legacy operations',
      () async {
    final legacy = operation(id: 'legacy-op');
    await writeManifest('${legacy.operationId}.json', legacy);

    final found = await store.findActiveByDedupeKey(
      'user-1',
      SyncOperationKind.text,
      legacy.dedupeKey,
    );

    expect(found?.operationId, 'legacy-op');
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

  test('ignores a corrupt manifest without hiding valid operations', () async {
    final userOne = userDirectory();
    await userOne.create(recursive: true);
    await File('${userOne.path}/bad.json').writeAsString('{not-json');
    await store.put(operation());

    final active = await store.loadActive('user-1');

    expect(active.map((item) => item.operationId), ['op-1']);
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
