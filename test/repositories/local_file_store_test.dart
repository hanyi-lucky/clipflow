import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:clipflow/models/file_download_progress.dart';
import 'package:clipflow/repositories/local_file_store.dart';

void main() {
  late Directory tempDir;
  late LocalFileStore store;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('clipflow_file_store_');
    store = LocalFileStore(directoryPath: tempDir.path);
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  Stream<List<int>> chunkedStream(List<int> bytes, {int chunk = 7}) async* {
    for (var i = 0; i < bytes.length; i += chunk) {
      yield bytes.sublist(
        i,
        i + chunk > bytes.length ? bytes.length : i + chunk,
      );
    }
  }

  group('LocalFileStore', () {
    test('saveEncryptedFromStream writes cache file and reports progress',
        () async {
      final bytes = List<int>.generate(100, (i) => i % 256);
      final received = <int>[];

      final path = await store.saveEncryptedFromStream(
        entryId: 'entry-1',
        stream: chunkedStream(bytes),
        onProgress: received.add,
      );

      expect(path, contains('entry-1.enc'));
      expect(File(path!).readAsBytesSync(), equals(bytes));
      expect(received, isNotEmpty);
      expect(received.last, equals(100));
    });

    test('loadEncryptedPath returns path only when cache exists', () async {
      expect(await store.loadEncryptedPath('missing'), isNull);

      await store.saveEncryptedFromStream(
        entryId: 'entry-2',
        stream: Stream.value([1, 2, 3]),
      );

      final path = await store.loadEncryptedPath('entry-2');
      expect(path, isNotNull);
      expect(File(path!).readAsBytesSync(), equals([1, 2, 3]));
    });

    test('saveEncryptedFromStream cancels, discards stream and removes .part',
        () async {
      final token = FileTransferCancelToken();
      final controller = StreamController<List<int>>();
      final future = store.saveEncryptedFromStream(
        entryId: 'entry-cancel',
        stream: controller.stream,
        cancelToken: token,
      );

      token.cancel();
      controller.add([1, 2, 3]);
      await controller.close();

      final result = await future;
      expect(result, isNull);
      expect(await store.loadEncryptedPath('entry-cancel'), isNull);
      final tmpDir = Directory('${tempDir.path}/${LocalFileStore.tmpDirName}');
      expect(
        tmpDir
            .listSync()
            .whereType<File>()
            .where((f) => f.uri.pathSegments.last.startsWith('entry-cancel_')),
        isEmpty,
      );
    });

    test('savePlaintextFromStream writes sanitized plaintext cache', () async {
      final path = await store.savePlaintextFromStream(
        entryId: 'entry-3',
        fileName: 'my file.txt',
        stream: Stream.value([10, 20, 30]),
      );

      expect(path, contains('entry-3_my file.txt'));
      expect(File(path).readAsBytesSync(), equals([10, 20, 30]));
    });

    test('sanitizes path separators and traversal names', () async {
      final path = await store.savePlaintextFromStream(
        entryId: 'entry-4',
        fileName: '../../evil/name.txt',
        stream: Stream.value([1]),
      );

      expect(path, contains('entry-4_.._.._evil_name.txt'));
      expect(path, isNot(contains('../')));
    });

    test('importEncryptedFile copies temp file into encrypted cache',
        () async {
      final source = File('${tempDir.path}/source.enc');
      source.writeAsBytesSync([5, 6, 7, 8]);

      final target = await store.importEncryptedFile('entry-5', source.path);

      expect(target, contains('entry-5.enc'));
      expect(File(target).readAsBytesSync(), equals([5, 6, 7, 8]));
    });

    test('deleteEntry removes encrypted and plaintext caches', () async {
      await store.saveEncryptedFromStream(
        entryId: 'entry-6',
        stream: Stream.value([1, 2]),
      );
      await store.savePlaintextFromStream(
        entryId: 'entry-6',
        fileName: 'a.txt',
        stream: Stream.value([3, 4]),
      );

      await store.deleteEntry('entry-6');

      expect(await store.loadEncryptedPath('entry-6'), isNull);
      final plainDir = Directory('${tempDir.path}/${LocalFileStore.plainDirName}');
      expect(
        plainDir
            .listSync()
            .whereType<File>()
            .where((f) => f.uri.pathSegments.last.startsWith('entry-6_')),
        isEmpty,
      );
    });

    test('cleanupOrphans removes files not in keep set', () async {
      await store.saveEncryptedFromStream(
        entryId: 'keep',
        stream: Stream.value([1]),
      );
      await store.saveEncryptedFromStream(
        entryId: 'orphan',
        stream: Stream.value([2]),
      );
      await store.savePlaintextFromStream(
        entryId: 'keep',
        fileName: 'k.txt',
        stream: Stream.value([3]),
      );
      await store.savePlaintextFromStream(
        entryId: 'orphan',
        fileName: 'o.txt',
        stream: Stream.value([4]),
      );

      await store.cleanupOrphans({'keep'});

      expect(await store.loadEncryptedPath('keep'), isNotNull);
      expect(await store.loadEncryptedPath('orphan'), isNull);
      final plainDir = Directory('${tempDir.path}/${LocalFileStore.plainDirName}');
      expect(
        plainDir
            .listSync()
            .whereType<File>()
            .map((f) => f.uri.pathSegments.last)
            .toList(),
        equals(['keep_k.txt']),
      );
    });

    test('enforceCacheLimit evicts oldest files and respects protected ids',
        () async {
      await store.saveEncryptedFromStream(
        entryId: 'old',
        stream: Stream.value(List.filled(30, 1)),
      );
      await store.saveEncryptedFromStream(
        entryId: 'new',
        stream: Stream.value(List.filled(30, 1)),
      );
      final oldFile = File((await store.loadEncryptedPath('old'))!);
      final newFile = File((await store.loadEncryptedPath('new'))!);
      oldFile.setLastModifiedSync(
        DateTime.now().subtract(const Duration(minutes: 10)),
      );
      newFile.setLastModifiedSync(DateTime.now());

      await store.enforceCacheLimit(35, protectedIds: {'new'});

      expect(await store.loadEncryptedPath('old'), isNull);
      expect(await store.loadEncryptedPath('new'), isNotNull);
    });

    test('clearAll removes encrypted, plaintext and temp files', () async {
      await store.saveEncryptedFromStream(
        entryId: 'entry-9',
        stream: Stream.value([1]),
      );
      await store.savePlaintextFromStream(
        entryId: 'entry-9',
        fileName: 'a.txt',
        stream: Stream.value([2]),
      );
      final tempPath = await store.newTempPath('.part');
      File(tempPath).writeAsBytesSync([3]);

      await store.clearAll();

      expect(await store.loadEncryptedPath('entry-9'), isNull);
      final plainDir = Directory('${tempDir.path}/${LocalFileStore.plainDirName}');
      expect(plainDir.listSync().whereType<File>(), isEmpty);
      final tmpDir = Directory('${tempDir.path}/${LocalFileStore.tmpDirName}');
      expect(tmpDir.listSync().whereType<File>(), isEmpty);
    });
  });
}
