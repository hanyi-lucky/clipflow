import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:clipflow/core/clipboard_channel_constants.dart';
import 'package:clipflow/models/clipboard_entry.dart';
import 'package:clipflow/models/file_download_progress.dart';
import 'package:clipflow/models/sync_operation.dart';
import 'package:clipflow/providers/clipboard_provider.dart';
import 'package:clipflow/repositories/cloud_repository.dart';
import 'package:clipflow/repositories/local_file_store.dart';
import 'package:clipflow/repositories/local_storage.dart';
import 'package:clipflow/repositories/outbox_store.dart';
import 'package:clipflow/services/cloudbase_service.dart';
import 'package:clipflow/services/encryption_service.dart';
import 'package:clipflow/services/lan_sync_manager.dart';

/// 模拟服务器：LAN 文件测试只关心 downloadFile 是否被调用 + Cloud 兜底内容。
class _LanFileCloudRepo extends CloudRepository {
  _LanFileCloudRepo() : super(CloudBaseService());

  Map<String, dynamic>? currentClipboard;
  bool throwOnFetch = false;
  final List<String> downloadCalls = [];
  List<int>? downloadBytes;

  @override
  Future<List<Map<String, dynamic>>> getHistoryEntries({int limit = 100}) async => [];

  @override
  Future<Map<String, dynamic>?> getCurrentClipboardWithDeletions() async {
    if (throwOnFetch) {
      throw const SocketException('cloud down');
    }
    if (currentClipboard == null) return null;
    return {...currentClipboard!};
  }

  @override
  Future<http.StreamedResponse> downloadFile(String entryId) async {
    downloadCalls.add(entryId);
    final bytes = downloadBytes ?? <int>[];
    return http.StreamedResponse(
      Stream.value(Uint8List.fromList(bytes)),
      HttpStatus.ok,
      contentLength: bytes.length,
    );
  }

  @override
  Future<void> addHistoryEntry(Map<String, dynamic> data) async {}

  @override
  Future<void> setCurrentClipboard(Map<String, dynamic> data) async {}
}

/// fake LanSyncManager：文件行由测试注入；只负责 fetch 返回。
class _FakeLanFileManager extends LanSyncManager {
  _FakeLanFileManager() : super(cloudRepository: CloudRepository(CloudBaseService()));

  Map<String, dynamic>? lanRow;
  int startCalls = 0;
  int stopCalls = 0;

  @override
  Future<void> start({
    required String userId,
    required String deviceId,
    required Uint8List accountKey,
    bool enabled = true,
  }) async {
    startCalls++;
  }

  @override
  Future<Map<String, dynamic>?> fetchLatestContent() async {
    return lanRow;
  }

  @override
  Future<void> pushOperation(SyncOperation op) async {}

  @override
  Future<void> stop() async {
    stopCalls++;
  }
}

class _MemoryOutbox implements OutboxStore {
  final List<SyncOperation> ops = [];

  @override
  Future<List<SyncOperation>> loadActive(String userId) async =>
      ops.where((o) => o.userId == userId && o.isActive).toList();

  @override
  Future<void> put(SyncOperation operation) async {
    ops.add(operation);
  }

  @override
  Future<void> update(SyncOperation operation) async {
    final i = ops.indexWhere((o) => o.operationId == operation.operationId);
    if (i >= 0) ops[i] = operation;
  }

  @override
  Future<SyncOperation?> findActiveByDedupeKey(
    String userId,
    SyncOperationKind kind,
    String dedupeKey,
  ) async {
    for (final o in ops) {
      if (o.userId == userId &&
          o.kind == kind &&
          o.dedupeKey == dedupeKey &&
          o.isActive) {
        return o;
      }
    }
    return null;
  }

  @override
  Future<void> remove(String userId, String operationId) async {
    ops.removeWhere((o) => o.userId == userId && o.operationId == operationId);
  }

  @override
  Future<List<String>> clearUser(String userId) async {
    ops.removeWhere((o) => o.userId == userId);
    return [];
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(AppChannelNames.clipboard);
  const password = 'lan-file-test';
  final salt = List<int>.generate(32, (i) => i % 256);

  late EncryptionService encryption;
  late Uint8List key;
  late _LanFileCloudRepo repo;
  late LocalStorage storage;
  late LocalFileStore fileStore;
  late Directory tempDir;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    encryption = EncryptionService();
    key = await encryption.deriveKey(password, salt);
    repo = _LanFileCloudRepo();
    storage = LocalStorage(await SharedPreferences.getInstance());
    tempDir = await Directory.systemTemp.createTemp('clipflow_lan_file_');
    fileStore = LocalFileStore(directoryPath: tempDir.path);
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  void mockFileChannel({bool setFilesResult = true}) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          switch (call.method) {
            case AppChannelMethods.hasImage:
              return false;
            case AppChannelMethods.hasFiles:
              return false;
            case AppChannelMethods.getFiles:
              return null;
            case AppChannelMethods.setFiles:
              return setFilesResult;
            case AppChannelMethods.getImage:
              return null;
          }
          return null;
        });
  }

  /// 预置本地密文缓存：模拟 LAN 交付原子落盘的 `<historyId>.enc`。
  Future<void> seedEnc(String entryId, Uint8List ciphertext) async {
    final dir = Directory('${tempDir.path}/${LocalFileStore.encDirName}');
    await dir.create(recursive: true);
    await File('${dir.path}/$entryId.enc').writeAsBytes(ciphertext);
  }

  /// LAN 文件行：content=marker（密文占位）+ enc_file_name（密文）。
  Future<Map<String, dynamic>> fileRow({
    required String id,
    required String fileName,
    required int fileSize,
    required String fileHash,
  }) async {
    final marker = (await encryption.encrypt('', key)).toBase64();
    final encName = (await encryption.encrypt(fileName, key)).toBase64();
    return <String, dynamic>{
      'history_id': id,
      'type': 'file',
      'content': marker,
      'hash': fileHash,
      'enc_file_name': encName,
      'file_size': fileSize,
      'source_device': 'device-a',
      'source_device_name': 'Mac A',
      'source_platform': 'macos',
      'timestamp': 1700000001000,
      '_deletedIds': <String>[],
      '_restoredEntries': <Map<String, dynamic>>[],
    };
  }

  Future<ClipboardProvider> createProvider(_FakeLanFileManager? lanManager) async {
    final provider = ClipboardProvider(
      fileStore: fileStore,
      outbox: _MemoryOutbox(),
      lanSyncManager: lanManager,
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

  Future<void> waitFor(
    bool Function() condition, {
    String? message,
    String? debug,
  }) async {
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (DateTime.now().isBefore(deadline)) {
      if (condition()) return;
      await Future.delayed(const Duration(milliseconds: 30));
    }
    fail('${message ?? 'condition not met within timeout'} (${debug ?? ''})');
  }

  Future<void> settle() => Future.delayed(const Duration(milliseconds: 200));

  group('ClipboardProvider LAN file local-first', () {
    test('LAN 文件行 + 本地 .enc 已落盘 → 本地解密交付，不调 Cloud', () async {
      final plaintext = Uint8List.fromList(List<int>.generate(8192, (i) => i % 251));
      final encrypted = await encryption.encryptBytes(plaintext, key);
      final historyId = 'lan-file-1';
      mockFileChannel();

      final lanManager = _FakeLanFileManager();
      final row = await fileRow(
        id: historyId,
        fileName: '本地优先.pdf',
        fileSize: plaintext.length,
        fileHash: sha256.convert(plaintext).toString(),
      );

      final provider = await createProvider(lanManager);
      await settle(); // 初始化完成（含历史加载/孤儿清理）
      provider.stopSync();
      // LAN 交付在解锁后到达：先落盘 .enc，再注入文件行
      await seedEnc(historyId, encrypted.toBytes());
      lanManager.lanRow = row;
      await provider.triggerSync();

      await waitFor(
        () =>
            provider.fileDownloadProgress(historyId)?.status ==
            FileTransferStatus.completed,
        message: 'LAN local-first file download should complete',
      );

      // 本地优先：Cloud downloadFile 一次都不被调用
      expect(repo.downloadCalls, isEmpty);
      final entry = provider.history.firstWhere((e) => e.id == historyId);
      expect(entry.type, ContentType.file);
      expect(entry.fileName, '本地优先.pdf');
      expect(entry.fileSize, plaintext.length);
      expect(entry.fileHash, sha256.convert(plaintext).toString());
      // 密文缓存保留（LAN 交付落盘）
      expect(await fileStore.loadEncryptedPath(historyId), isNotNull);

      await settle();
      provider.dispose();
    });

    test('同 historyId 重复触发只下载一次（游标推进防重）', () async {
      final plaintext = Uint8List.fromList(List<int>.generate(4096, (i) => i % 251));
      final encrypted = await encryption.encryptBytes(plaintext, key);
      final historyId = 'lan-file-dedupe';
      mockFileChannel();

      final lanManager = _FakeLanFileManager();
      final row = await fileRow(
        id: historyId,
        fileName: 'dedupe.bin',
        fileSize: plaintext.length,
        fileHash: sha256.convert(plaintext).toString(),
      );

      final provider = await createProvider(lanManager);
      await settle();
      provider.stopSync();
      await seedEnc(historyId, encrypted.toBytes());
      lanManager.lanRow = row;
      await provider.triggerSync();

      await waitFor(
        () =>
            provider.fileDownloadProgress(historyId)?.status ==
            FileTransferStatus.completed,
      );
      await provider.triggerSync();
      await settle();

      expect(provider.history.where((e) => e.id == historyId), hasLength(1));
      expect(repo.downloadCalls, isEmpty);

      await settle();
      provider.dispose();
    });
  });

  group('ClipboardProvider LAN file Cloud fallback', () {
    test('无本地 .enc → 走 Cloud 下载同一 historyId', () async {
      final plaintext = Uint8List.fromList(List<int>.generate(8192, (i) => i % 251));
      final encrypted = await encryption.encryptBytes(plaintext, key);
      repo.downloadBytes = encrypted.toBytes();
      mockFileChannel();

      final historyId = 'lan-file-cloud';
      final lanManager = _FakeLanFileManager();
      final row = await fileRow(
        id: historyId,
        fileName: 'cloud-fallback.bin',
        fileSize: plaintext.length,
        fileHash: sha256.convert(plaintext).toString(),
      );

      final provider = await createProvider(lanManager);
      await settle();
      provider.stopSync();
      lanManager.lanRow = row;
      await provider.triggerSync();

      await waitFor(
        () =>
            provider.fileDownloadProgress(historyId)?.status ==
            FileTransferStatus.completed,
      );
      expect(repo.downloadCalls, contains(historyId));
      final entry = provider.history.firstWhere((e) => e.id == historyId);
      expect(entry.fileName, 'cloud-fallback.bin');

      await settle();
      provider.dispose();
    });

    test('本地 .enc 明文 hash 不匹配 → 删 .enc + 回 Cloud 同一 historyId', () async {
      final plaintext = Uint8List.fromList(List<int>.generate(8192, (i) => i % 251));
      final badPlaintext = Uint8List.fromList(List<int>.filled(8192, 0));
      final historyId = 'lan-file-badhash';
      // 预置错误的密文（明文不同 → 解密 hash 与行 hash 不匹配）
      final badEnc = await encryption.encryptBytes(badPlaintext, key);
      // Cloud 兜底返回正确的密文
      final goodEnc = await encryption.encryptBytes(plaintext, key);
      repo.downloadBytes = goodEnc.toBytes();
      mockFileChannel();

      final lanManager = _FakeLanFileManager();
      final row = await fileRow(
        id: historyId,
        fileName: 'badhash.bin',
        fileSize: plaintext.length,
        fileHash: sha256.convert(plaintext).toString(),
      );

      final provider = await createProvider(lanManager);
      await settle();
      provider.stopSync();
      // 预置错误的密文（明文不同 → 解密 hash 与行 hash 不匹配）
      await seedEnc(historyId, badEnc.toBytes());
      lanManager.lanRow = row;
      await provider.triggerSync();

      await waitFor(
        () =>
            provider.fileDownloadProgress(historyId)?.status ==
            FileTransferStatus.completed,
        message: 'hash mismatch should delete .enc and fall back to Cloud',
      );
      // 本地坏 .enc 被删除，Cloud 兜底下载同一 historyId 成功
      expect(repo.downloadCalls, contains(historyId));
      final landed = await fileStore.loadEncryptedPath(historyId);
      expect(landed, isNotNull);
      expect(File(landed!).readAsBytesSync(), equals(goodEnc.toBytes()));
      final entry = provider.history.firstWhere((e) => e.id == historyId);
      expect(entry.fileHash, sha256.convert(plaintext).toString());

      await settle();
      provider.dispose();
    });

    test('本地 .enc 解密失败（GCM tag 错）→ 删 .enc + 回 Cloud', () async {
      final plaintext = Uint8List.fromList(List<int>.generate(4096, (i) => i % 251));
      final historyId = 'lan-file-badtag';
      // 预置被篡改的密文：GCM tag 校验失败 → decryptFile 抛 EncryptionException
      final goodEnc = await encryption.encryptBytes(plaintext, key);
      final corrupted = Uint8List.fromList(goodEnc.toBytes());
      corrupted[corrupted.length - 1] = corrupted[corrupted.length - 1] ^ 0xFF;
      repo.downloadBytes = goodEnc.toBytes();
      mockFileChannel();

      final lanManager = _FakeLanFileManager();
      final row = await fileRow(
        id: historyId,
        fileName: 'badtag.bin',
        fileSize: plaintext.length,
        fileHash: sha256.convert(plaintext).toString(),
      );

      final provider = await createProvider(lanManager);
      await settle();
      provider.stopSync();
      // 预置被篡改的密文：GCM tag 校验失败 → decryptFile 抛 EncryptionException
      await seedEnc(historyId, corrupted);
      lanManager.lanRow = row;
      await provider.triggerSync();

      await waitFor(
        () =>
            provider.fileDownloadProgress(historyId)?.status ==
            FileTransferStatus.completed,
        message: 'decrypt failure should delete .enc and fall back to Cloud',
      );
      expect(repo.downloadCalls, contains(historyId));

      await settle();
      provider.dispose();
    });
  });

  group('ClipboardProvider LAN file resilience', () {
    test('LAN 已交付文件但 Cloud 拉取失败 → 保持 connected、不计失败', () async {
      final plaintext = Uint8List.fromList(List<int>.generate(8192, (i) => i % 251));
      final encrypted = await encryption.encryptBytes(plaintext, key);
      final historyId = 'lan-file-resilient';
      mockFileChannel();

      final lanManager = _FakeLanFileManager();
      final row = await fileRow(
        id: historyId,
        fileName: 'resilient.bin',
        fileSize: plaintext.length,
        fileHash: sha256.convert(plaintext).toString(),
      );

      final provider = await createProvider(lanManager);
      await settle(); // 首轮 Cloud 成功（空内容）→ serverConnected=true
      expect(provider.serverConnected, isTrue);
      expect(provider.consecutiveFailures, 0);

      // LAN 行在初始化之后注入：同一 tick 内 LAN 交付 + Cloud 失败
      await seedEnc(historyId, encrypted.toBytes());
      lanManager.lanRow = row;
      repo.throwOnFetch = true;
      provider.stopSync();
      await provider.triggerSync();

      await waitFor(
        () =>
            provider.fileDownloadProgress(historyId)?.status ==
            FileTransferStatus.completed,
        debug: 'status=${provider.fileDownloadProgress(historyId)?.status} '
            'error=${provider.fileDownloadProgress(historyId)?.error} '
            'downloadCalls=${repo.downloadCalls}',
      );
      expect(provider.serverConnected, isTrue);
      expect(provider.consecutiveFailures, 0);
      expect(provider.history.where((e) => e.id == historyId), hasLength(1));

      await settle();
      provider.dispose();
    });
  });
}
