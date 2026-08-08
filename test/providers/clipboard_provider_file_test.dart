import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:clipflow/core/clipboard_channel_constants.dart';
import 'package:clipflow/models/clipboard_entry.dart';
import 'package:clipflow/models/file_download_progress.dart';
import 'package:clipflow/providers/clipboard_provider.dart';
import 'package:clipflow/repositories/cloud_repository.dart';
import 'package:clipflow/repositories/local_file_store.dart';
import 'package:clipflow/repositories/local_outbox_store.dart';
import 'package:clipflow/repositories/local_storage.dart';
import 'package:clipflow/services/cloudbase_service.dart';
import 'package:clipflow/services/encryption_service.dart';

class FileProviderFakeRepo extends CloudRepository {
  FileProviderFakeRepo() : super(CloudBaseService());

  Map<String, dynamic>? currentClipboard;
  final List<Map<String, dynamic>> uploadCalls = [];
  final List<Map<String, dynamic>> imageUploads = [];
  final List<String> downloadCalls = [];
  List<int>? downloadBytes;
  Stream<List<int>>? controlledDownloadStream;
  int controlledContentLength = 0;
  bool failDownloads = false;
  bool failOnceThenSucceed = false;
  int downloadAttempts = 0;
  bool failUploadOnce = false;
  int uploadAttempts = 0;

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
    uploadAttempts++;
    uploadCalls.add({
      'historyId': historyId,
      'plaintextHash': plaintextHash,
      'fileName': fileName,
      'fileSize': fileSize,
      'mimeType': mimeType,
      'marker': marker,
    });
    if (failUploadOnce && uploadAttempts == 1) {
      throw Exception('upload failed once');
    }
  }

  @override
  Future<Map<String, dynamic>?> getCurrentClipboardWithDeletions() async {
    if (currentClipboard == null) return null;
    return {
      ...currentClipboard!,
      '_deletedIds': <String>[],
      '_restoredEntries': <Map<String, dynamic>>[],
    };
  }

  @override
  Future<http.StreamedResponse> downloadFile(String entryId) async {
    downloadCalls.add(entryId);
    downloadAttempts++;
    if (failDownloads) {
      throw Exception('download failed');
    }
    if (failOnceThenSucceed && downloadAttempts == 1) {
      throw Exception('download failed once');
    }
    if (controlledDownloadStream != null) {
      return http.StreamedResponse(
        controlledDownloadStream!,
        HttpStatus.ok,
        contentLength: controlledContentLength,
      );
    }
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
  Future<void> setCurrentClipboard(Map<String, dynamic> data) async {
    if (data['type'] == 'image') {
      imageUploads.add(data);
    }
  }

  @override
  Future<List<Map<String, dynamic>>> getHistoryEntries({
    int limit = 100,
  }) async => [];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(AppChannelNames.clipboard);
  const password = 'provider-file-test';
  final salt = List<int>.generate(32, (i) => i % 256);

  late EncryptionService encryption;
  late Uint8List key;
  late FileProviderFakeRepo repo;
  late LocalStorage storage;
  late LocalFileStore fileStore;
  late Directory tempDir;

  /// 轮询 `_checkClipboard` 每 500ms 重复检测同一文件并重置 500ms debounce，
  /// 与上传测试形成相位锁定（`_uploadFile` 永不触发）。armed 一次性检测让
  /// debounce 稳定触发，poll 后续检测被忽略；echo 用例在变更 mtime 后重新
  /// arm，验证「签名变化仍不重复上传」。
  var filesArmed = true;

  setUp(() async {
    filesArmed = true;
    SharedPreferences.setMockInitialValues({});
    encryption = EncryptionService();
    key = await encryption.deriveKey(password, salt);
    repo = FileProviderFakeRepo();
    storage = LocalStorage(await SharedPreferences.getInstance());
    tempDir = await Directory.systemTemp.createTemp('clipflow_provider_file_');
    fileStore = LocalFileStore(directoryPath: tempDir.path);
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  void mockFileChannel({
    bool hasFiles = false,
    List<Map<String, Object>>? files,
    bool setFilesResult = true,
    Completer<bool>? setFilesCompleter,
    List<Map<String, Object>>? readBackFiles,
    void Function()? onSetFiles,
    bool hasImage = false,
    Uint8List? imageBytes,
  }) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          switch (call.method) {
            case AppChannelMethods.hasImage:
              return hasImage;
            case AppChannelMethods.hasFiles:
              return hasFiles && filesArmed;
            case AppChannelMethods.getFiles:
              if (!filesArmed) return null;
              filesArmed = false;
              return readBackFiles ?? files;
            case AppChannelMethods.setFiles:
              onSetFiles?.call();
              if (setFilesCompleter != null) return setFilesCompleter.future;
              return setFilesResult;
            case AppChannelMethods.getImage:
              if (!hasImage || imageBytes == null) return null;
              return <String, Object?>{
                'bytes': imageBytes,
                'format': 'png',
                'width': 8,
                'height': 8,
              };
          }
          return null;
        });
  }

  Future<ClipboardProvider> createProvider({
    Duration retryBaseDelay = const Duration(milliseconds: 500),
  }) async {
    final provider = ClipboardProvider(
      fileStore: fileStore,
      outbox: LocalOutboxStore(directoryPath: tempDir.path),
      retryBaseDelay: retryBaseDelay,
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
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (condition()) return;
      await Future.delayed(const Duration(milliseconds: 30));
    }
    fail('condition not met within $timeout');
  }

  /// 等待下载/重试异步链收尾，避免 dispose 后仍有回调触发。
  Future<void> settle() => Future.delayed(const Duration(milliseconds: 100));

  Map<String, dynamic> fileRow({
    required String id,
    required String fileName,
    required int fileSize,
    required String fileHash,
    int timestamp = 1700000000000,
    String sourceDevice = 'device-remote',
  }) {
    return {
      'id': 'clip-$id',
      'user_id': 'user_x',
      'content': 'marker-ciphertext',
      'hash': fileHash,
      'source_device': sourceDevice,
      'source_device_name': 'Phone B',
      'source_platform': 'android',
      'timestamp': timestamp,
      'type': 'file',
      'file_name': fileName,
      'file_size': fileSize,
      'mime_type': 'application/pdf',
      'file_key': 'uuid-$id',
      'history_id': id,
    };
  }

  group('ClipboardProvider file upload', () {
    test(
      'detected clipboard file is hashed, encrypted and uploaded once',
      () async {
        final sourceBytes = List<int>.generate(8192, (i) => i % 251);
        final sourceFile = File('${tempDir.path}/报告.pdf');
        sourceFile.writeAsBytesSync(sourceBytes);
        mockFileChannel(
          hasFiles: true,
          files: [
            {
              'path': sourceFile.path,
              'name': '报告.pdf',
              'mimeType': 'application/pdf',
              'size': sourceBytes.length,
              'lastModified': 1700000000000,
              'temp': false,
            },
          ],
        );

        final provider = await createProvider();
        await provider.debugFileCheck();

        await waitFor(() => repo.uploadCalls.isNotEmpty);

        expect(repo.uploadCalls, hasLength(1));
        final call = repo.uploadCalls.first;
        expect(call['fileName'], '报告.pdf');
        expect(call['fileSize'], sourceBytes.length);
        expect(call['mimeType'], 'application/pdf');
        expect(call['plaintextHash'], isNotEmpty);
        final marker = call['marker'] as String;
        final decryptedMarker = await encryption.decrypt(
          EncryptedData.fromBase64(marker),
          key,
        );
        expect(decryptedMarker, isEmpty);

        await waitFor(
          () => provider.history.any(
            (e) => e.type == ContentType.file && e.fileName == '报告.pdf',
          ),
        );
        final entry = provider.history.firstWhere(
          (e) => e.type == ContentType.file,
        );
        expect(entry.fileSize, sourceBytes.length);
        expect(entry.mimeType, 'application/pdf');

        await settle();
        provider.dispose();
      },
    );

    test(
      'upload failure does not record signature and same file can retry',
      () async {
        final sourceBytes = List<int>.generate(8192, (i) => i % 251);
        final sourceFile = File('${tempDir.path}/retry.pdf');
        sourceFile.writeAsBytesSync(sourceBytes);
        sourceFile.setLastModifiedSync(
          DateTime.fromMillisecondsSinceEpoch(1700000000000),
        );
        mockFileChannel(
          hasFiles: true,
          files: [
            {
              'path': sourceFile.path,
              'name': 'retry.pdf',
              'mimeType': 'application/pdf',
              'size': sourceBytes.length,
              'lastModified': 1700000000000,
              'temp': false,
            },
          ],
        );

        repo.failUploadOnce = true;
        final provider = await createProvider();

        await provider.debugFileCheck();
        await waitFor(() => repo.uploadCalls.length == 1);

        await provider.debugFileCheck();
        await waitFor(
          () =>
              repo.uploadCalls.length == 2 &&
              provider.history.any(
                (e) => e.type == ContentType.file && e.fileName == 'retry.pdf',
              ),
        );

        expect(repo.uploadCalls, hasLength(2));
        final entry = provider.history.firstWhere(
          (e) => e.type == ContentType.file,
        );
        expect(entry.fileName, 'retry.pdf');
        expect(entry.fileSize, sourceBytes.length);

        await settle();
        provider.dispose();
      },
    );

    test('ignored file hash (download echo) is not uploaded', () async {
      final sourceBytes = List<int>.generate(4096, (i) => i);
      final sourceFile = File('${tempDir.path}/echo.bin');
      sourceFile.writeAsBytesSync(sourceBytes);
      sourceFile.setLastModifiedSync(
        DateTime.fromMillisecondsSinceEpoch(1700000000000),
      );
      mockFileChannel(
        hasFiles: true,
        files: [
          {
            'path': sourceFile.path,
            'name': 'echo.bin',
            'mimeType': 'application/octet-stream',
            'size': sourceBytes.length,
            'lastModified': 1700000000000,
            'temp': false,
          },
        ],
      );

      final provider = await createProvider();
      await provider.debugFileCheck();
      await waitFor(() => repo.uploadCalls.isNotEmpty);
      final uploadedHash = repo.uploadCalls.first['plaintextHash'] as String;
      provider.monitorAddIgnoreFileHash(uploadedHash);

      // 同内容但剪贴板签名变化（如 mtime 变化）时，仍不能重复上传
      sourceFile.setLastModifiedSync(
        DateTime.fromMillisecondsSinceEpoch(1700000001000),
      );
      filesArmed = true;
      await provider.debugFileCheck();
      await Future.delayed(const Duration(milliseconds: 700));

      expect(repo.uploadCalls, hasLength(1));
      await settle();
      provider.dispose();
    });
  });

  group('ClipboardProvider file download', () {
    test(
      'downloads stream, decrypts, writes clipboard and completes progress',
      () async {
        final plaintext = List<int>.generate(60000, (i) => (i * 3) % 251);
        final encrypted = await encryption.encryptBytes(
          Uint8List.fromList(plaintext),
          key,
        );
        repo.downloadBytes = encrypted.toBytes();
        final fileHash = 'file-hash-download-1';
        mockFileChannel(
          hasFiles: false,
          setFilesResult: true,
          readBackFiles: [
            {
              'path': '/tmp/downloaded.pdf',
              'name': 'downloaded.pdf',
              'size': plaintext.length,
              'lastModified': 1700000000000,
              'temp': false,
            },
          ],
        );
        repo.currentClipboard = fileRow(
          id: 'hist-dl-1',
          fileName: 'downloaded.pdf',
          fileSize: plaintext.length,
          fileHash: fileHash,
        );

        final provider = await createProvider();

        await waitFor(
          () =>
              provider.fileDownloadProgress('hist-dl-1')?.status ==
              FileTransferStatus.completed,
        );

        final progress = provider.fileDownloadProgress('hist-dl-1')!;
        expect(progress.fileName, 'downloaded.pdf');
        expect(progress.receivedBytes, greaterThan(0));
        expect(repo.downloadCalls, contains('hist-dl-1'));
        expect(
          provider.history.any(
            (e) => e.id == 'hist-dl-1' && e.type == ContentType.file,
          ),
          isTrue,
        );
        final entry = provider.history.firstWhere((e) => e.id == 'hist-dl-1');
        expect(entry.fileName, 'downloaded.pdf');
        expect(entry.fileHash, fileHash);

        await settle();
        provider.dispose();
      },
    );

    test(
      'downloaded image-named file write-back does not echo as image upload',
      () async {
        final plaintext = List<int>.generate(64, (i) => i % 251);
        final encrypted = await encryption.encryptBytes(
          Uint8List.fromList(plaintext),
          key,
        );
        final image = img.Image(width: 8, height: 8, numChannels: 3);
        for (var y = 0; y < image.height; y++) {
          for (var x = 0; x < image.width; x++) {
            image.setPixelRgba(x, y, 80, 120, 200, 255);
          }
        }
        final pngBytes = Uint8List.fromList(img.encodePng(image));
        repo.downloadBytes = encrypted.toBytes();
        repo.currentClipboard = fileRow(
          id: 'hist-echo-1',
          fileName: 'photo.png',
          fileSize: plaintext.length,
          fileHash: 'file-hash-echo',
        );
        mockFileChannel(
          hasFiles: false,
          setFilesResult: true,
          readBackFiles: [
            {
              'path': '/tmp/photo.png',
              'name': 'photo.png',
              'size': plaintext.length,
              'lastModified': 1700000000000,
              'temp': false,
            },
          ],
          hasImage: true,
          imageBytes: pngBytes,
        );

        final provider = await createProvider();
        await waitFor(
          () =>
              provider.fileDownloadProgress('hist-echo-1')?.status ==
              FileTransferStatus.completed,
        );

        // 文件写回后模拟一次轮询：图片分支应命中忽略表，不再重复上传
        await provider.debugFileCheck();
        await Future.delayed(const Duration(milliseconds: 700));

        expect(repo.imageUploads, isEmpty);
        expect(
          provider.history.where((e) => e.type == ContentType.image),
          isEmpty,
        );

        await settle();
        provider.dispose();
      },
    );

    test(
      'failed download does not advance received timestamp and retries',
      () async {
        final plaintext = List<int>.generate(2048, (i) => i % 256);
        final encrypted = await encryption.encryptBytes(
          Uint8List.fromList(plaintext),
          key,
        );
        repo.downloadBytes = encrypted.toBytes();
        repo.failDownloads = true;
        mockFileChannel(hasFiles: false);
        repo.currentClipboard = fileRow(
          id: 'hist-fail-1',
          fileName: 'fail.bin',
          fileSize: plaintext.length,
          fileHash: 'file-hash-fail',
        );

        final provider = await createProvider(
          retryBaseDelay: const Duration(milliseconds: 10),
        );

        await waitFor(
          () =>
              provider.fileDownloadProgress('hist-fail-1')?.status ==
              FileTransferStatus.failed,
        );

        final progress = provider.fileDownloadProgress('hist-fail-1')!;
        expect(progress.retryCount, greaterThanOrEqualTo(3));
        expect(provider.history.any((e) => e.id == 'hist-fail-1'), isFalse);
        expect(repo.downloadCalls.length, greaterThanOrEqualTo(3));

        await settle();
        provider.dispose();
      },
    );

    test('retryFileDownload recovers after transient failure', () async {
      final plaintext = List<int>.generate(4096, (i) => i % 256);
      final encrypted = await encryption.encryptBytes(
        Uint8List.fromList(plaintext),
        key,
      );
      repo.downloadBytes = encrypted.toBytes();
      repo.failOnceThenSucceed = true;
      mockFileChannel(
        hasFiles: false,
        setFilesResult: true,
        readBackFiles: [
          {
            'path': '/tmp/recovered.txt',
            'name': 'recovered.txt',
            'size': plaintext.length,
            'lastModified': 1700000000000,
            'temp': false,
          },
        ],
      );
      repo.currentClipboard = fileRow(
        id: 'hist-recover-1',
        fileName: 'recovered.txt',
        fileSize: plaintext.length,
        fileHash: 'file-hash-recover',
      );

      final provider = await createProvider(
        retryBaseDelay: const Duration(milliseconds: 10),
      );

      await waitFor(
        () =>
            provider.fileDownloadProgress('hist-recover-1')?.status ==
            FileTransferStatus.completed,
      );

      expect(repo.downloadCalls.length, greaterThanOrEqualTo(2));
      final progress = provider.fileDownloadProgress('hist-recover-1')!;
      expect(progress.status, FileTransferStatus.completed);

      await settle();
      provider.dispose();
    });

    test(
      'orphan cleanup keeps in-flight download cache during refresh',
      () async {
        final plaintext = List<int>.generate(8192, (i) => i % 251);
        final encrypted = await encryption.encryptBytes(
          Uint8List.fromList(plaintext),
          key,
        );
        repo.downloadBytes = encrypted.toBytes();
        final setFilesCompleter = Completer<bool>();
        mockFileChannel(hasFiles: false, setFilesCompleter: setFilesCompleter);
        repo.currentClipboard = fileRow(
          id: 'hist-race-1',
          fileName: 'race.bin',
          fileSize: plaintext.length,
          fileHash: 'file-hash-race',
        );

        final provider = await createProvider();

        // 下载停在 processing（密文已落盘、历史尚未入史），等待 setFiles。
        await waitFor(
          () =>
              provider.fileDownloadProgress('hist-race-1')?.status ==
              FileTransferStatus.processing,
        );
        expect(await fileStore.loadEncryptedPath('hist-race-1'), isNotNull);

        // 下载进行中触发 refresh：_loadHistoryFromServer 会跑 cleanupOrphans。
        await provider.refresh();

        expect(
          await fileStore.loadEncryptedPath('hist-race-1'),
          isNotNull,
          reason: '进行中的下载缓存不应被孤儿清理误删',
        );
        expect(
          provider.fileDownloadProgress('hist-race-1')?.status,
          FileTransferStatus.processing,
        );

        setFilesCompleter.complete(true);
        await waitFor(
          () =>
              provider.fileDownloadProgress('hist-race-1')?.status ==
              FileTransferStatus.completed,
        );

        expect(
          provider.history.any(
            (e) => e.id == 'hist-race-1' && e.type == ContentType.file,
          ),
          isTrue,
        );
        expect(await fileStore.loadEncryptedPath('hist-race-1'), isNotNull);

        await settle();
        provider.dispose();
      },
    );

    test(
      'cancel aborts download without setFiles, history or timestamp',
      () async {
        final plaintext = List<int>.generate(4096, (i) => i % 251);
        final encrypted = await encryption.encryptBytes(
          Uint8List.fromList(plaintext),
          key,
        );
        final controller = StreamController<List<int>>();
        repo.controlledDownloadStream = controller.stream;
        repo.controlledContentLength = encrypted.toBytes().length;
        var setFilesCalls = 0;
        mockFileChannel(hasFiles: false, onSetFiles: () => setFilesCalls++);
        repo.currentClipboard = fileRow(
          id: 'hist-cancel-1',
          fileName: 'cancel.bin',
          fileSize: plaintext.length,
          fileHash: 'file-hash-cancel',
        );

        final provider = await createProvider();

        await waitFor(
          () =>
              provider.fileDownloadProgress('hist-cancel-1')?.status ==
              FileTransferStatus.downloading,
        );

        await provider.cancelFileDownload('hist-cancel-1');
        expect(
          provider.fileDownloadProgress('hist-cancel-1')?.status,
          FileTransferStatus.cancelled,
        );

        // 放行流：取消令牌应在下一个数据块处丢弃剩余流并删除 .part。
        controller.add(Uint8List.fromList(encrypted.toBytes()));
        await controller.close();
        await settle();

        expect(setFilesCalls, 0);
        expect(provider.history.any((e) => e.id == 'hist-cancel-1'), isFalse);
        expect(
          provider.fileDownloadProgress('hist-cancel-1')?.status,
          FileTransferStatus.cancelled,
        );
        expect(await fileStore.loadEncryptedPath('hist-cancel-1'), isNull);
        final tmpDir = Directory(
          '${tempDir.path}/${LocalFileStore.tmpDirName}',
        );
        expect(
          tmpDir.listSync().whereType<File>().where(
            (f) => f.uri.pathSegments.last.startsWith('hist-cancel-1_'),
          ),
          isEmpty,
        );

        // 取消不推进时间戳，但 cancelled 条目也不会被轮询自动重启。
        final callsBeforePoll = repo.downloadCalls.length;
        await Future.delayed(const Duration(milliseconds: 700));
        expect(repo.downloadCalls.length, callsBeforePoll);

        await settle();
        provider.dispose();
      },
    );

    test('cancel during retry backoff suppresses automatic retry', () async {
      final plaintext = List<int>.generate(2048, (i) => i % 256);
      final encrypted = await encryption.encryptBytes(
        Uint8List.fromList(plaintext),
        key,
      );
      repo.downloadBytes = encrypted.toBytes();
      repo.failDownloads = true;
      mockFileChannel(hasFiles: false);
      repo.currentClipboard = fileRow(
        id: 'hist-cancel-retry-1',
        fileName: 'retry-cancel.bin',
        fileSize: plaintext.length,
        fileHash: 'file-hash-retry-cancel',
      );

      final provider = await createProvider(
        retryBaseDelay: const Duration(milliseconds: 150),
      );

      await waitFor(
        () =>
            repo.downloadCalls.isNotEmpty &&
            provider.fileDownloadProgress('hist-cancel-retry-1')?.status ==
                FileTransferStatus.pending,
      );

      await provider.cancelFileDownload('hist-cancel-retry-1');
      expect(
        provider.fileDownloadProgress('hist-cancel-retry-1')?.status,
        FileTransferStatus.cancelled,
      );

      final callsAfterCancel = repo.downloadCalls.length;
      await Future.delayed(const Duration(milliseconds: 400));
      expect(repo.downloadCalls.length, callsAfterCancel);

      await settle();
      provider.dispose();
    });

    test(
      'retryFileDownload is rejected while another download is active',
      () async {
        final plaintext = List<int>.generate(8192, (i) => i % 251);
        final encrypted = await encryption.encryptBytes(
          Uint8List.fromList(plaintext),
          key,
        );
        repo.downloadBytes = encrypted.toBytes();
        repo.failDownloads = true;
        mockFileChannel(hasFiles: false);
        repo.currentClipboard = fileRow(
          id: 'hist-retry-blocked-1',
          fileName: 'blocked.bin',
          fileSize: plaintext.length,
          fileHash: 'file-hash-blocked',
        );

        final provider = await createProvider(
          retryBaseDelay: const Duration(milliseconds: 10),
        );

        await waitFor(
          () =>
              provider.fileDownloadProgress('hist-retry-blocked-1')?.status ==
              FileTransferStatus.failed,
        );
        // 阻止轮询自动重启该条目，保留 cancelled 状态供手动重试。
        await provider.cancelFileDownload('hist-retry-blocked-1');

        final setFilesCompleter = Completer<bool>();
        mockFileChannel(hasFiles: false, setFilesCompleter: setFilesCompleter);
        repo.failDownloads = false;
        repo.currentClipboard = fileRow(
          id: 'hist-active-1',
          fileName: 'active.bin',
          fileSize: plaintext.length,
          fileHash: 'file-hash-active',
          timestamp: 1700000001000,
        );

        await waitFor(
          () =>
              provider.fileDownloadProgress('hist-active-1')?.status ==
              FileTransferStatus.processing,
        );

        final callsBeforeRetry = repo.downloadCalls.length;
        await provider.retryFileDownload('hist-retry-blocked-1');
        expect(repo.downloadCalls.length, callsBeforeRetry);
        expect(
          provider.fileDownloadProgress('hist-active-1')?.status,
          FileTransferStatus.processing,
        );

        setFilesCompleter.complete(true);
        await waitFor(
          () =>
              provider.fileDownloadProgress('hist-active-1')?.status ==
              FileTransferStatus.completed,
        );

        await settle();
        provider.dispose();
      },
    );

    test('manual retry preserves original file metadata', () async {
      final plaintext = List<int>.generate(6000, (i) => (i * 7) % 251);
      final encrypted = await encryption.encryptBytes(
        Uint8List.fromList(plaintext),
        key,
      );
      final ciphertextBytes = encrypted.toBytes();
      repo.downloadBytes = ciphertextBytes;
      repo.failDownloads = true;
      mockFileChannel(
        hasFiles: false,
        setFilesResult: true,
        readBackFiles: [
          {
            'path': '/tmp/meta.pdf',
            'name': 'meta.pdf',
            'size': plaintext.length,
            'lastModified': 1700000000000,
            'temp': false,
          },
        ],
      );
      repo.currentClipboard = fileRow(
        id: 'hist-meta-1',
        fileName: 'meta.pdf',
        fileSize: plaintext.length,
        fileHash: 'file-hash-meta',
      );

      final provider = await createProvider(
        retryBaseDelay: const Duration(milliseconds: 10),
      );

      await waitFor(
        () =>
            provider.fileDownloadProgress('hist-meta-1')?.status ==
            FileTransferStatus.failed,
      );

      repo.failDownloads = false;
      await provider.retryFileDownload('hist-meta-1');

      await waitFor(
        () =>
            provider.fileDownloadProgress('hist-meta-1')?.status ==
            FileTransferStatus.completed,
      );

      final entry = provider.history.firstWhere((e) => e.id == 'hist-meta-1');
      expect(entry.fileName, 'meta.pdf');
      expect(entry.fileSize, plaintext.length);
      expect(entry.fileHash, 'file-hash-meta');
      expect(entry.mimeType, 'application/pdf');
      expect(entry.sourceDeviceName, 'Phone B');
      final progress = provider.fileDownloadProgress('hist-meta-1')!;
      expect(progress.totalBytes, ciphertextBytes.length);
      expect(progress.totalBytes, isNot(plaintext.length));

      await settle();
      provider.dispose();
    });
  });
}
