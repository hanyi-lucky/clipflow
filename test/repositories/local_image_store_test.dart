import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:clipflow/repositories/local_image_store.dart';

void main() {
  late Directory tempDir;
  late LocalImageStore store;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('clipflow_image_store_');
    store = LocalImageStore(directoryPath: tempDir.path);
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('LocalImageStore', () {
    test('save and load round-trip full image ciphertext', () async {
      await store.save('entry-1', 'FULL_CIPHER_BASE64');

      final loaded = await store.load('entry-1');

      expect(loaded, equals('FULL_CIPHER_BASE64'));
    });

    test('load returns null for missing entry', () async {
      expect(await store.load('missing-entry'), isNull);
    });

    test('delete removes cached file', () async {
      await store.save('entry-1', 'CIPHER');
      await store.delete('entry-1');

      expect(await store.load('entry-1'), isNull);
    });

    test('save overwrites existing entry', () async {
      await store.save('entry-1', 'FIRST');
      await store.save('entry-1', 'SECOND');

      expect(await store.load('entry-1'), equals('SECOND'));
    });

    test('clearAll removes all cached files', () async {
      await store.save('a', 'A');
      await store.save('b', 'B');
      await store.clearAll();

      expect(await store.load('a'), isNull);
      expect(await store.load('b'), isNull);
    });

    test('cleanupOrphans keeps only given entry ids', () async {
      await store.save('keep-1', 'KEEP');
      await store.save('keep-2', 'KEEP');
      await store.save('orphan-1', 'ORPHAN');

      await store.cleanupOrphans({'keep-1', 'keep-2'});

      expect(await store.load('keep-1'), equals('KEEP'));
      expect(await store.load('keep-2'), equals('KEEP'));
      expect(await store.load('orphan-1'), isNull);
    });
  });
}
