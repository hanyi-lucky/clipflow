import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:clipflow/core/clipboard_channel_constants.dart';
import 'package:clipflow/models/clipboard_entry.dart';
import 'package:clipflow/providers/clipboard_provider.dart';
import 'package:clipflow/repositories/cloud_repository.dart';
import 'package:clipflow/repositories/local_image_store.dart';
import 'package:clipflow/repositories/local_outbox_store.dart';
import 'package:clipflow/repositories/local_storage.dart';
import 'package:clipflow/services/cloudbase_service.dart';
import 'package:clipflow/services/encryption_service.dart';

class FakeCloudRepo extends CloudRepository {
  FakeCloudRepo() : super(CloudBaseService());

  List<Map<String, dynamic>> history = [];
  Map<String, dynamic>? contentOverride;
  Map<String, dynamic>? currentClipboard;
  int addHistoryEntryCalls = 0;

  @override
  Future<List<Map<String, dynamic>>> getHistoryEntries({int limit = 100}) async =>
      history;

  @override
  Future<Map<String, dynamic>?> getCurrentClipboardWithDeletions() async {
    if (currentClipboard == null) return null;
    return {...currentClipboard!};
  }

  @override
  Future<Map<String, dynamic>?> getHistoryEntryContent(String entryId) async =>
      contentOverride;

  @override
  Future<void> deleteHistoryEntry(String entryId) async {}

  @override
  Future<void> updateHistoryEntry(String entryId, Map<String, dynamic> data) async {}

  @override
  Future<void> restoreHistoryEntry(String entryId) async {}

  @override
  Future<List<Map<String, dynamic>>> getTrashEntries() async => [];

  @override
  Future<String?> getSalt() async => null;

  @override
  Future<void> setSalt(String salt) async {}

  @override
  Future<void> setCurrentClipboard(Map<String, dynamic> data) async {}

  @override
  Future<void> addHistoryEntry(Map<String, dynamic> data) async {
    addHistoryEntryCalls++;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const password = 'provider-image-test';
  final salt = List<int>.generate(32, (i) => i % 256);

  late EncryptionService encryption;
  late Uint8List key;
  late FakeCloudRepo repo;
  late LocalStorage storage;
  late LocalImageStore imageStore;
  late Directory tempDir;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    encryption = EncryptionService();
    key = await encryption.deriveKey(password, salt);
    repo = FakeCloudRepo();
    storage = LocalStorage(await SharedPreferences.getInstance());
    tempDir = await Directory.systemTemp.createTemp('clipflow_provider_img_');
    imageStore = LocalImageStore(directoryPath: tempDir.path);
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel(AppChannelNames.clipboard),
      null,
    );
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  Uint8List encodePng(int width, int height) {
    final image = img.Image(width: width, height: height, numChannels: 3);
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        image.setPixelRgba(x, y, 80, 160, 240, 255);
      }
    }
    return Uint8List.fromList(img.encodePng(image));
  }

  /// mock 原生图片通道：默认 hasImage=false（不触发上传，避免轮询污染
  /// 下载/恢复断言）；detectImage=true 时返回重编码字节触发上传。
  void mockImageChannel({
    required Uint8List readBackBytes,
    bool detectImage = false,
  }) {
    var imageDetectionsLeft = detectImage ? 1 : 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel(AppChannelNames.clipboard),
      (call) async {
        if (call.method == AppChannelMethods.hasImage) {
          return imageDetectionsLeft > 0;
        }
        if (call.method == AppChannelMethods.getImage) {
          if (imageDetectionsLeft <= 0) return null;
          imageDetectionsLeft--;
          return {
            'bytes': readBackBytes,
            'format': 'png',
            'width': 120,
            'height': 90,
          };
        }
        if (call.method == AppChannelMethods.setImage) return true;
        return null;
      },
    );
  }

  Map<String, dynamic> clipboardImageRow({
    required String id,
    required String content,
    required String thumb,
    String hash = 'stable-hash',
    String sourceDevice = 'device-b',
    String sourceDeviceName = 'Phone B',
    String sourcePlatform = 'android',
    int timestamp = 1700000000000,
    int width = 120,
    int height = 90,
    String format = 'png',
  }) {
    return {
      'id': 'clip-$id',
      'user_id': 'user_x',
      'content': content,
      'thumb': thumb,
      'hash': hash,
      'source_device': sourceDevice,
      'source_device_name': sourceDeviceName,
      'source_platform': sourcePlatform,
      'timestamp': timestamp,
      'type': 'image',
      'width': width,
      'height': height,
      'format': format,
      'history_id': id,
    };
  }

  Future<ClipboardProvider> createProvider() async {
    final provider = ClipboardProvider(
      imageStore: imageStore,
      outbox: LocalOutboxStore(directoryPath: tempDir.path),
    );
    await provider.initialize(
      storage: storage,
      cloudRepo: repo,
      deviceId: 'device-test',
      deviceName: 'Test Mac',
      encryptionKey: key,
    );
    return provider;
  }

  Future<void> waitForHistory(ClipboardProvider provider, int count) async {
    for (var i = 0; i < 120; i++) {
      if (provider.history.length >= count) return;
      await Future.delayed(const Duration(milliseconds: 50));
    }
    fail('history did not reach $count entries');
  }

  /// 等待 sync loop 异步链结束，避免 dispose 后定时器/异步任务报错
  Future<void> settle() =>
      Future.delayed(const Duration(milliseconds: 200));

  Future<void> waitFor(
    bool Function() condition, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (condition()) return;
      await Future.delayed(const Duration(milliseconds: 30));
    }
    fail('condition not met within $timeout');
  }

  /// 等待全图密文缓存落盘（恢复条目先 addEntry 后 save，断言前必须轮询）。
  ///
  /// [LocalImageStore.save] 直接截断重写目标文件，并发 [load] 可能读到
  /// 半写/空内容，因此必须等到非空（且与期望值一致时）才返回。
  Future<String> waitForImageCache(String entryId, {String? expected}) async {
    for (var i = 0; i < 120; i++) {
      final cached = await imageStore.load(entryId);
      if (cached != null &&
          cached.isNotEmpty &&
          (expected == null || cached == expected)) {
        return cached;
      }
      await Future.delayed(const Duration(milliseconds: 50));
    }
    fail('image cache for $entryId never appeared');
  }

  Map<String, dynamic> imageRow(
    String id,
    String thumbBase64, {
    int width = 100,
    int height = 80,
  }) {
    return {
      'id': id,
      'content': '',
      'thumb': thumbBase64,
      'hash': 'hash-$id',
      'width': width,
      'height': height,
      'format': 'jpeg',
      'type': 'image',
      'source_device': 'device-a',
      'source_device_name': 'Mac A',
      'source_platform': 'macos',
      'timestamp': 1700000000000,
      'pinned': 0,
    };
  }

  Map<String, dynamic> textRow(String id, String contentBase64) {
    return {
      'id': id,
      'content': contentBase64,
      'type': 'text',
      'source_device': 'device-a',
      'source_device_name': 'Mac A',
      'source_platform': 'macos',
      'timestamp': 1700000001000,
      'pinned': 0,
    };
  }

  group('ClipboardProvider image integration', () {
    test('loads image entries with decrypted thumbnails from server', () async {
      final thumb1 = Uint8List.fromList([1, 2, 3]);
      final thumb2 = Uint8List.fromList([4, 5, 6]);
      final thumbEnc1 = await encryption.encryptBytes(thumb1, key);
      final thumbEnc2 = await encryption.encryptBytes(thumb2, key);
      final textEnc = await encryption.encrypt('hello provider', key);
      repo.history = [
        imageRow('img-1', thumbEnc1.toBase64()),
        imageRow('img-2', thumbEnc2.toBase64(), width: 640, height: 480),
        textRow('txt-1', textEnc.toBase64()),
      ];

      final provider = await createProvider();
      await waitForHistory(provider, 3);

      final images = provider.history.where((e) => e.type == ContentType.image).toList();
      final texts = provider.history.where((e) => e.type == ContentType.text).toList();
      expect(images, hasLength(2));
      expect(texts, hasLength(1));
      expect(
        provider.history.firstWhere((e) => e.id == 'img-1').imageThumbBytes,
        equals(thumb1),
      );
      expect(
        provider.history.firstWhere((e) => e.id == 'img-2').imageThumbBytes,
        equals(thumb2),
      );
      expect(
        provider.history.firstWhere((e) => e.id == 'img-2').imageWidth,
        equals(640),
      );
      expect(
        provider.history.firstWhere((e) => e.id == 'txt-1').content,
        equals('hello provider'),
      );

      provider.dispose();
    });

    test('mergePreview excludes image entries', () async {
      final thumbEnc = await encryption.encryptBytes(
        Uint8List.fromList([9, 9]),
        key,
      );
      final textEnc = await encryption.encrypt('merge me', key);
      repo.history = [
        imageRow('img-1', thumbEnc.toBase64()),
        textRow('txt-1', textEnc.toBase64()),
      ];

      final provider = await createProvider();
      await waitForHistory(provider, 2);

      provider.enterMergeMode();
      final imageId = provider.history
          .firstWhere((e) => e.type == ContentType.image)
          .id;
      final textId = provider.history
          .firstWhere((e) => e.type == ContentType.text)
          .id;
      provider.toggleSelection(imageId);
      provider.toggleSelection(textId);

      expect(
        provider.selectedEntries.every((e) => e.type == ContentType.text),
        isTrue,
      );
      expect(provider.mergePreview, equals('merge me'));

      provider.dispose();
    });

    test('removeEntry deletes local image cache file', () async {
      final thumbEnc = await encryption.encryptBytes(
        Uint8List.fromList([7, 8]),
        key,
      );
      repo.history = [imageRow('img-1', thumbEnc.toBase64())];
      await imageStore.save('img-1', 'FULL_CIPHER');

      final provider = await createProvider();
      await waitForHistory(provider, 1);

      await provider.removeEntry('img-1');

      expect(await imageStore.load('img-1'), isNull);
      provider.dispose();
    });

    test('loadFullImageBytes fetches from server and caches locally', () async {
      final thumbEnc = await encryption.encryptBytes(
        Uint8List.fromList([1, 1]),
        key,
      );
      final fullBytes = Uint8List.fromList(List.generate(2048, (i) => i % 251));
      final fullEnc = await encryption.encryptBytes(fullBytes, key);
      repo.history = [imageRow('img-1', thumbEnc.toBase64())];
      repo.contentOverride = {
        'id': 'img-1',
        'content': fullEnc.toBase64(),
        'type': 'image',
      };

      final provider = await createProvider();
      await waitForHistory(provider, 1);

      final bytes = await provider.loadFullImageBytes('img-1');

      expect(bytes, equals(fullBytes));
      expect(await imageStore.load('img-1'), equals(fullEnc.toBase64()));
      provider.dispose();
    });

    test('downloaded image write-back does not echo into re-upload', () async {
      final sourceImage = encodePng(120, 90);
      final thumbBytes = Uint8List.fromList([31, 32, 33]);
      final fullEnc = await encryption.encryptBytes(sourceImage, key);
      final thumbEnc = await encryption.encryptBytes(thumbBytes, key);

      // 模拟 macOS/Android 重编码：解码后重编码为 PNG，字节必然不同
      final decoded = img.decodeImage(sourceImage)!;
      final reencoded = Uint8List.fromList(img.encodePng(decoded));
      mockImageChannel(readBackBytes: reencoded);

      repo.currentClipboard = clipboardImageRow(
        id: 'hist-echo-1',
        content: fullEnc.toBase64(),
        thumb: thumbEnc.toBase64(),
      );

      final provider = await createProvider();
      await waitForHistory(provider, 1);

      // 下载条目使用服务器 history_id 且全图密文按该 ID 落盘
      expect(provider.history.first.id, equals('hist-echo-1'));
      expect(await imageStore.load('hist-echo-1'), isNotNull);

      // 等待多个轮询周期：回读字节不得触发再上传
      await Future.delayed(const Duration(milliseconds: 1200));
      expect(repo.addHistoryEntryCalls, equals(0));

      await settle();
      provider.dispose();
    });

    test('restored image entry appears with thumbnail and cached full image', () async {
      final thumbBytes = Uint8List.fromList([41, 42, 43]);
      final fullBytes = Uint8List.fromList(List.generate(2048, (i) => i % 251));
      final thumbEnc = await encryption.encryptBytes(thumbBytes, key);
      final fullEnc = await encryption.encryptBytes(fullBytes, key);

      repo.currentClipboard = {
        'id': 'clip-own',
        'user_id': 'user_x',
        'content': 'OWN_CIPHER',
        'hash': 'HASH_OWN',
        'source_device': 'device-test',
        'source_device_name': 'Test Mac',
        'source_platform': 'macos',
        'timestamp': 1700000000000,
        'type': 'text',
        '_deletedIds': <String>[],
        '_restoredEntries': <Map<String, dynamic>>[
          {
            'id': 'hist-restore-1',
            'content': fullEnc.toBase64(),
            'thumb': thumbEnc.toBase64(),
            'hash': 'HASH_RESTORE_1',
            'type': 'image',
            'width': 640,
            'height': 480,
            'format': 'jpeg',
            'source_device': 'device-b',
            'source_device_name': 'Phone B',
            'source_platform': 'android',
            'timestamp': 1700000001000,
          },
        ],
      };

      final provider = await createProvider();
      await waitForHistory(provider, 1);

      final restored =
          provider.history.firstWhere((e) => e.id == 'hist-restore-1');
      expect(restored.type, equals(ContentType.image));
      expect(restored.imageThumbBytes, equals(thumbBytes));
      expect(restored.imageWidth, equals(640));
      expect(restored.imageHeight, equals(480));
      expect(restored.imageFormat, equals('jpeg'));
      // 恢复条目先入史后落盘：缓存出现后再断言，避免异步竞态
      expect(await waitForImageCache('hist-restore-1'), equals(fullEnc.toBase64()));

      await settle();
      provider.dispose();
    });

    test('restored text entry still works (no regression)', () async {
      final textEnc = await encryption.encrypt('restored text', key);
      repo.currentClipboard = {
        'id': 'clip-own',
        'user_id': 'user_x',
        'content': 'OWN_CIPHER',
        'hash': 'HASH_OWN',
        'source_device': 'device-test',
        'source_device_name': 'Test Mac',
        'source_platform': 'macos',
        'timestamp': 1700000000000,
        'type': 'text',
        '_deletedIds': <String>[],
        '_restoredEntries': <Map<String, dynamic>>[
          {
            'id': 'hist-restore-text-1',
            'content': textEnc.toBase64(),
            'type': 'text',
            'source_device': 'device-b',
            'source_device_name': 'Phone B',
            'source_platform': 'android',
            'timestamp': 1700000001000,
          },
        ],
      };

      final provider = await createProvider();
      await waitForHistory(provider, 1);

      expect(
        provider.history
            .firstWhere((e) => e.id == 'hist-restore-text-1')
            .content,
        equals('restored text'),
      );

      await settle();
      provider.dispose();
    });

    test('refresh does not duplicate image entry with server id', () async {
      final thumbBytes = Uint8List.fromList([51, 52, 53]);
      final fullBytes = Uint8List.fromList(List.generate(4096, (i) => i % 251));
      final thumbEnc = await encryption.encryptBytes(thumbBytes, key);
      final fullEnc = await encryption.encryptBytes(fullBytes, key);
      final decoded = img.decodeImage(encodePng(120, 90))!;
      final reencoded = Uint8List.fromList(img.encodePng(decoded));
      mockImageChannel(readBackBytes: reencoded);

      repo.history = [
        imageRow('hist-refresh-1', thumbEnc.toBase64(), width: 120, height: 90),
      ];
      repo.currentClipboard = clipboardImageRow(
        id: 'hist-refresh-1',
        content: fullEnc.toBase64(),
        thumb: thumbEnc.toBase64(),
      );

      final provider = await createProvider();
      await waitForHistory(provider, 1);

      await provider.refresh();

      // 全量加载 + 下载写回后，同一服务器 ID 只保留一条
      expect(
        provider.history.where((e) => e.id == 'hist-refresh-1'),
        hasLength(1),
      );
      expect(
        await waitForImageCache('hist-refresh-1', expected: fullEnc.toBase64()),
        equals(fullEnc.toBase64()),
      );

      await settle();
      provider.dispose();
    });

    test('text upload success receipt backfills decrypted history', () async {
      // 平台剪切板一次性提供文本：轮询后续读到 null，不再重置 500ms debounce
      var textArmed = true;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.getData' && textArmed) {
          textArmed = false;
          return <String, Object?>{'text': 'receipt text'};
        }
        return null;
      });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null);
      });

      final provider = await createProvider();
      await provider.debugFileCheck();

      // drain 发送成功后，回执把解密文本补进本地历史
      await waitFor(
        () => provider.history.any(
          (e) => e.type == ContentType.text && e.content == 'receipt text',
        ),
      );
      final entry =
          provider.history.firstWhere((e) => e.type == ContentType.text);
      expect(entry.content, 'receipt text');
      expect(entry.id, isNotEmpty);

      await settle();
      provider.dispose();
    });

    test('image upload success receipt backfills history and image cache',
        () async {
      final decoded = img.decodeImage(encodePng(120, 90))!;
      final reencoded = Uint8List.fromList(img.encodePng(decoded));
      // detectImage=true：检测到图片 → 压缩上传 → drain 成功 → 回执补史 +
      // 全图密文按 operationId 落盘
      mockImageChannel(readBackBytes: reencoded, detectImage: true);

      final provider = await createProvider();
      await provider.debugFileCheck();

      await waitFor(() => provider.history.any((e) => e.type == ContentType.image));
      final entry =
          provider.history.firstWhere((e) => e.type == ContentType.image);
      expect(entry.imageThumbBytes, isNotNull);
      expect(entry.stableHash, isNotEmpty);
      final cached = await waitForImageCache(entry.id);
      expect(cached, isNotEmpty);

      await settle();
      provider.dispose();
    });
  });
}
