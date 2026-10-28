import 'dart:convert';
import 'dart:io';

import 'package:clipflow/models/sync_operation.dart';
import 'package:clipflow/repositories/local_outbox_store.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

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
    return File(
      '${userDirectory(op.userId).path}/${canonicalName(op.operationId)}',
    );
  }

  Future<File> writeManifest(
    String fileName,
    SyncOperation op, {
    String? directoryUserId,
  }) async {
    final dir = userDirectory(directoryUserId ?? op.userId);
    await dir.create(recursive: true);
    final file = File('${dir.path}/$fileName');
    await file.writeAsString(jsonEncode(op.toJson()), flush: true);
    return file;
  }

  List<String> fileNameList({String userId = 'user-1'}) {
    return userDirectory(userId)
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

  test('put stores the canonical hash filename without leaking operation id',
      () async {
    await store.put(
      operation(
        id: 'del:entry-1',
        kind: SyncOperationKind.delete,
        payload: const {'entryId': 'entry-1'},
      ),
    );

    final manifest = canonicalFile(operation(id: 'del:entry-1'));
    expect(manifest.existsSync(), isTrue);
    expect(fileNameList(), [canonicalName('del:entry-1')]);
    expect(fileNameList().single, isNot(contains('del:entry-1')));

    final decoded =
        jsonDecode(await manifest.readAsString()) as Map<String, dynamic>;
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

  test('persists sending state as pending after load', () async {
    await store.put(operation(state: SyncOperationState.sending));

    final active = await store.loadActive('user-1');

    expect(active, hasLength(1));
    expect(active.single.state, SyncOperationState.pending);
    final persisted = jsonDecode(
      await canonicalFile(active.single).readAsString(),
    ) as Map<String, dynamic>;
    expect(persisted['state'], 'pending');
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
    expect(fileNameList(), [canonicalName(pending.operationId)]);
  });

  test('migrates a UUID legacy file and removes legacy source after readback',
      () async {
    final legacyOp = operation(id: '0f5bb4d8-1111-4444-8888-123456789abc');
    final legacy = await writeManifest('${legacyOp.operationId}.json', legacyOp);

    final active = await store.loadActive('user-1');

    expect(active.single.operationId, legacyOp.operationId);
    expect(canonicalFile(legacyOp).existsSync(), isTrue);
    expect(legacy.existsSync(), isFalse);
  });

  test('migrates del: and rest: ids from generic legacy filenames', () async {
    final deleteOp = operation(
      id: 'del:entry-7',
      kind: SyncOperationKind.delete,
      payload: const {'entryId': 'entry-7'},
    );
    final restoreOp = operation(
      id: 'rest:entry-7',
      kind: SyncOperationKind.restore,
      payload: const {'entryId': 'entry-7'},
    );
    final deleteLegacy = await writeManifest('legacy-delete.json', deleteOp);
    final restoreLegacy = await writeManifest('legacy-restore.json', restoreOp);

    final active = await store.loadActive('user-1');

    expect(
      active.map((item) => item.operationId),
      containsAll(<String>['del:entry-7', 'rest:entry-7']),
    );
    expect(canonicalFile(deleteOp).existsSync(), isTrue);
    expect(canonicalFile(restoreOp).existsSync(), isTrue);
    expect(deleteLegacy.existsSync(), isFalse);
    expect(restoreLegacy.existsSync(), isFalse);
  });

  test('identifies manifests by content and ignores foreign user records',
      () async {
    await writeManifest(
      'v2-foreign.json',
      operation(id: 'foreign-op', userId: 'user-2'),
      directoryUserId: 'user-1',
    );
    await writeManifest('legacy-unknown-name.json', operation(id: 'local-op'));

    final active = await store.loadActive('user-1');

    expect(active.map((item) => item.operationId), ['local-op']);
    expect(File('${userDirectory().path}/v2-foreign.json').existsSync(), isTrue);
  });

  test('canonical wins over legacy and temp while retaining canonical bytes',
      () async {
    final op = operation();
    final canonical = await writeManifest(
      canonicalName(op.operationId),
      op.copyWith(updatedAtMs: 100),
    );
    final legacy = await writeManifest(
      '${op.operationId}.json',
      op.copyWith(updatedAtMs: 200),
    );
    final temp = await writeManifest(
      '${canonicalName(op.operationId)}.tmp',
      op.copyWith(updatedAtMs: 300),
    );
    final canonicalBytes = await canonical.readAsString();

    final active = await store.loadActive('user-1');

    expect(active, hasLength(1));
    expect(active.single.updatedAtMs, 100);
    expect(canonical.existsSync(), isTrue);
    expect(await canonical.readAsString(), canonicalBytes);
    expect(legacy.existsSync(), isFalse);
    expect(temp.existsSync(), isFalse);
    expect(fileNameList(), [canonicalName(op.operationId)]);
  });

  test('recovers a valid temp-only manifest and returns it only once',
      () async {
    final op = operation(id: 'temp-only');
    final temp = await writeManifest('${canonicalName(op.operationId)}.tmp', op);

    final first = await store.loadActive('user-1');
    final second = await store.loadActive('user-1');

    expect(first.single.operationId, 'temp-only');
    expect(second, hasLength(1));
    expect(canonicalFile(op).existsSync(), isTrue);
    expect(temp.existsSync(), isFalse);
  });

  test('preserves partial canonical temp without promoting or returning it',
      () async {
    final op = operation(id: 'partial-temp');
    final partial =
        await writeManifest('${canonicalName(op.operationId)}.tmp', op);
    await partial.writeAsString('{"operationId":');

    final first = await store.loadActive('user-1');
    final second = await store.loadActive('user-1');

    expect(first, isEmpty);
    expect(second, isEmpty);
    expect(partial.existsSync(), isTrue);
    expect(canonicalFile(op).existsSync(), isFalse);
  });

  test('partial canonical temp does not shadow valid canonical', () async {
    final op = operation(id: 'partial-with-canonical');
    final canonical = await writeManifest(canonicalName(op.operationId), op);
    final partial =
        await writeManifest('${canonicalName(op.operationId)}.tmp', op);
    await partial.writeAsString('{not-json');
    final canonicalBytes = await canonical.readAsString();

    final first = await store.loadActive('user-1');
    final second = await store.loadActive('user-1');

    expect(first.single.operationId, op.operationId);
    expect(second.single.operationId, op.operationId);
    expect(await canonical.readAsString(), canonicalBytes);
    expect(partial.existsSync(), isTrue);
  });

  test('corrupt canonical falls back to a valid legacy record', () async {
    final op = operation(id: 'fallback');
    final canonical = await writeManifest(canonicalName(op.operationId), op);
    final legacy = await writeManifest('${op.operationId}.json', op);
    await canonical.writeAsString('{not-json');

    final active = await store.loadActive('user-1');

    expect(active.single.operationId, 'fallback');
    expect(legacy.existsSync(), isFalse);
    expect(canonicalFile(op).existsSync(), isTrue);
    final canonicalDecoded =
        jsonDecode(await canonicalFile(op).readAsString()) as Map<String, dynamic>;
    expect(canonicalDecoded['operationId'], 'fallback');
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
    expect(canonicalFile(op).existsSync(), isFalse);

    final second = await LocalOutboxStore(directoryPath: directory.path)
        .loadActive('user-1');
    expect(second.single.operationId, 'rename-failure');
    expect(legacy.existsSync(), isFalse);
    expect(canonicalFile(op).existsSync(), isTrue);
  });

  for (final occupantFirst in <bool>[true, false]) {
    test(
      'misplaced canonical-shaped occupant blocks promotion regardless of '
      'creation order (${occupantFirst ? 'occupant' : 'legacy'} first)',
      () async {
        final first = operation(id: 'first-op');
        final second = operation(id: 'second-op');
        // A deterministic SHA-256 collision cannot be constructed practically.
        // Simulate second-op's target containing first-op while second-op only
        // has a generic legacy copy.
        final artifacts = <(String, SyncOperation)>[
          if (occupantFirst) ...[
            (canonicalName(second.operationId), first),
            ('legacy-second.json', second),
          ] else ...[
            ('legacy-second.json', second),
            (canonicalName(second.operationId), first),
          ],
        ];
        for (final (name, op) in artifacts) {
          await writeManifest(name, op);
        }
        final occupant = File(
          '${userDirectory().path}/${canonicalName(second.operationId)}',
        );
        final legacySecond = File(
          '${userDirectory().path}/legacy-second.json',
        );

        final firstLoad = await store.loadActive('user-1');
        final secondLoad = await store.loadActive('user-1');

        for (final active in [firstLoad, secondLoad]) {
          expect(
            active.where((item) => item.operationId == first.operationId),
            hasLength(1),
          );
          expect(
            active.where((item) => item.operationId == second.operationId),
            hasLength(1),
          );
        }
        expect(
          (jsonDecode(await occupant.readAsString())
              as Map<String, dynamic>)['operationId'],
          first.operationId,
        );
        expect(occupant.existsSync(), isTrue);
        expect(legacySecond.existsSync(), isTrue);
        expect(
          File('${userDirectory().path}/${canonicalName(first.operationId)}')
              .existsSync(),
          isFalse,
        );
      },
    );
  }

  test('put refuses to overwrite a canonical path owned by another opId',
      () async {
    final first = operation(id: 'first-op');
    final second = operation(id: 'second-op');
    final occupant = await writeManifest(
      canonicalName(second.operationId),
      first,
    );

    await expectLater(store.put(second), throwsA(isA<FileSystemException>()));

    expect(occupant.existsSync(), isTrue);
    final decoded =
        jsonDecode(await occupant.readAsString()) as Map<String, dynamic>;
    expect(decoded['operationId'], first.operationId);
    final active = await store.loadActive('user-1');
    expect(active.map((item) => item.operationId), [first.operationId]);
  });

  test('remove clears canonical and legacy copies matching manifest content',
      () async {
    final op = operation();
    await store.put(op);
    final legacy = await writeManifest('${op.operationId}.json', op);

    await store.remove('user-1', op.operationId);

    expect(canonicalFile(op).existsSync(), isFalse);
    expect(legacy.existsSync(), isFalse);
    expect(fileNameList(), isEmpty);
  });

  test('remove clears a legacy-only artifact', () async {
    final op = operation(id: 'legacy-remove');
    final legacy = await writeManifest('${op.operationId}.json', op);

    await store.remove('user-1', op.operationId);

    expect(legacy.existsSync(), isFalse);
  });

  test('remove clears a temp-only artifact', () async {
    final op = operation(id: 'temp-remove');
    final temp = await writeManifest('${canonicalName(op.operationId)}.tmp', op);

    await store.remove('user-1', op.operationId);

    expect(temp.existsSync(), isFalse);
  });

  test('remove ignores a matching opId owned by another user', () async {
    final foreign = operation(id: 'shared-op', userId: 'user-2');
    final foreignFile = await writeManifest(
      canonicalName(foreign.operationId),
      foreign,
      directoryUserId: 'user-1',
    );

    await store.remove('user-1', foreign.operationId);

    expect(foreignFile.existsSync(), isTrue);
  });

  test('remove does not delete a path whose manifest has another opId',
      () async {
    final first = operation(id: 'first-op');
    final second = operation(id: 'second-op');
    final occupant = await writeManifest(canonicalName(first.operationId), second);

    await store.remove('user-1', first.operationId);

    expect(occupant.existsSync(), isTrue);
    expect((await store.loadActive('user-1')).single.operationId, 'second-op');
  });

  test('clearUser deduplicates ids and removes only that user directory',
      () async {
    await store.put(operation(id: 'one', artifactId: 'artifact-1'));
    await store.put(operation(id: 'two', artifactId: 'artifact-1'));
    await writeManifest(
      'legacy-three.json',
      operation(id: 'three', artifactId: 'artifact-1'),
    );
    await writeManifest(
      'temp-four.tmp',
      operation(id: 'four', artifactId: 'artifact-1'),
    );
    await writeManifest(
      'foreign-in-user-dir.json',
      operation(
        id: 'foreign',
        userId: 'user-2',
        artifactId: 'artifact-2',
      ),
      directoryUserId: 'user-1',
    );
    await File('${userDirectory().path}/bad.json').writeAsString('{not-json');
    await store.put(
      operation(
        id: 'other',
        userId: 'user-2',
        artifactId: 'artifact-2',
      ),
    );

    final artifacts = await store.clearUser('user-1');

    expect(artifacts, ['artifact-1']);
    expect(userDirectory().existsSync(), isFalse);
    expect(await store.loadActive('user-2'), hasLength(1));
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

  test('findActiveByDedupeKey migrates and returns legacy operations', () async {
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

  test('deletes malformed manifests without hiding valid operations', () async {
    final userOne = userDirectory();
    await userOne.create(recursive: true);
    final bad = File('${userOne.path}/bad.json');
    await bad.writeAsString('{not-json');
    await store.put(operation());

    final active = await store.loadActive('user-1');

    expect(active.map((item) => item.operationId), ['op-1']);
    expect(bad.existsSync(), isFalse);
  });

  test('restores a sending canonical to pending when the rewrite rename fails',
      () async {
    final op = operation(id: 'sending-failure', state: SyncOperationState.sending);
    final canonical = await writeManifest(canonicalName(op.operationId), op);
    final failingStore = LocalOutboxStore(
      directoryPath: directory.path,
      rename: (source, target) async {
        throw const FileSystemException('rename failed');
      },
    );

    final active = await failingStore.loadActive('user-1');

    expect(active.single.operationId, op.operationId);
    expect(active.single.state, SyncOperationState.pending);
    expect(canonical.existsSync(), isTrue);
  });

  test('keeps canonical when deleting a legacy copy fails', () async {
    final op = operation(id: 'remove-failure');
    await store.put(op);
    final canonical = canonicalFile(op);
    final legacy = await writeManifest('${op.operationId}.json', op);
    final failingStore = LocalOutboxStore(
      directoryPath: directory.path,
      deleteFile: (file) async {
        if (file.path == legacy.path) {
          throw const FileSystemException('delete failed');
        }
        await file.delete();
      },
    );

    await expectLater(
      failingStore.remove('user-1', op.operationId),
      throwsA(isA<FileSystemException>()),
    );

    expect(canonical.existsSync(), isTrue);
    expect(legacy.existsSync(), isTrue);
  });

  test('writes a JSON manifest containing no plaintext outside payload contract',
      () async {
    await store.put(operation());

    final manifest = canonicalFile(operation());
    final decoded =
        jsonDecode(await manifest.readAsString()) as Map<String, dynamic>;

    expect(decoded['operationId'], 'op-1');
    expect(decoded['payload']['content'], 'encrypted');
  });
}
