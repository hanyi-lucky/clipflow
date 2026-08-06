import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:clipflow/core/exceptions.dart';
import 'package:clipflow/core/hex_utils.dart';
import 'package:clipflow/models/backup_manifest.dart';
import 'package:clipflow/models/clipboard_entry.dart';
import 'package:clipflow/repositories/cloud_repository.dart';
import 'package:clipflow/repositories/local_file_store.dart';
import 'package:clipflow/repositories/local_image_store.dart';
import 'package:clipflow/repositories/local_storage.dart';
import 'package:clipflow/services/backup_service.dart';
import 'package:clipflow/services/cloudbase_service.dart';
import 'package:clipflow/services/encryption_service.dart';
import 'package:clipflow/services/history_service.dart';

/// 模拟服务端仓库：列表 / content / 文件流 / salt
class FakeBackupRepo extends CloudRepository {
  FakeBackupRepo() : super(CloudBaseService());

  List<Map<String, dynamic>> history = [];
  Map<String, String> contents = {}; // id -> 全量密文（文本/图片）
  Map<String, List<int>> fileContents = {}; // id -> 文件密文字节
  String? salt;
  int contentFallbackCalls = 0;

  @override
  Future<List<Map<String, dynamic>>> getHistoryEntries({int limit = 100}) async {
    return List.from(history);
  }

  @override
  Future<Map<String, dynamic>?> getHistoryEntryContent(String entryId) async {
    final c = contents[entryId];
    if (c == null) return null;
    contentFallbackCalls++;
    return {'content': c};
  }

  @override
  Future<http.StreamedResponse> downloadFile(String entryId) async {
    final bytes = fileContents[entryId];
    if (bytes == null) {
      return http.StreamedResponse(const Stream.empty(), 404);
    }
    return http.StreamedResponse(
      http.ByteStream.fromBytes(bytes),
      200,
    );
  }

  @override
  Future<String?> getSalt() async => salt;
}

void main() {
  const password = 'backup-test-password';
  final saltHex = '00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff';
  final salt = hexToBytes(saltHex);

  late EncryptionService encryption;
  late Uint8List key;
  late FakeBackupRepo repo;
  late LocalStorage storage;
  late LocalImageStore imageStore;
  late LocalFileStore fileStore;
  late HistoryService history;
  late Directory tempDir;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    encryption = EncryptionService();
    key = await encryption.deriveKey(password, salt);
    repo = FakeBackupRepo();
    storage = LocalStorage(await SharedPreferences.getInstance());
    await storage.setEncryptionSalt(saltHex);
    tempDir = await Directory.systemTemp.createTemp('clipflow_backup_');
    imageStore = LocalImageStore(directoryPath: tempDir.path);
    fileStore = LocalFileStore(directoryPath: tempDir.path);
    history = HistoryService(maxEntries: 100);
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  BackupService buildService() {
    return BackupService(
      cloudRepo: repo,
      storage: storage,
      imageStore: imageStore,
      fileStore: fileStore,
      historyService: history,
      encryption: encryption,
    );
  }

  Map<String, dynamic> serverRow({
    required String id,
    required String type,
    int? timestamp,
    String content = '',
    String? thumb,
    Map<String, dynamic>? extra,
  }) {
    return {
      'id': id,
      'type': type,
      'content': content,
      'source_device': 'd1',
      'source_device_name': 'Mac',
      'source_platform': 'macos',
      'timestamp': timestamp ?? 1700000000000,
      'pinned': 0,
      if (thumb != null) 'thumb': thumb,
      ...?extra,
    };
  }

  test('buildExport：文本本地明文重加密 + 图片本地密文 + 文件本地密文', () async {
    // 文本：本地历史存明文
    const textPlain = 'hello backup text';
    final textEntry = ClipboardEntry(
      id: 't1',
      content: textPlain,
      sourceDeviceId: 'd1',
      sourceDeviceName: 'Mac',
      sourcePlatform: 'macos',
      timestamp: DateTime.fromMillisecondsSinceEpoch(1),
      type: ContentType.text,
    );
    history.addEntry(textEntry);
    repo.history = [serverRow(id: 't1', type: 'text', content: 'TRUNCATED')];

    // 图片：本地缓存全图密文
    final imageBytes = Uint8List.fromList(List.generate(64, (i) => i));
    final imageCipher = await encryption.encryptBytes(imageBytes, key);
    await imageStore.save('i1', imageCipher.toBase64());
    repo.history.add(serverRow(
      id: 'i1', type: 'image', thumb: 'THUMB', timestamp: 2,
      extra: {'width': 100, 'height': 50, 'format': 'jpeg', 'hash': 'ih'},
    ));

    // 文件：本地 .enc 密文缓存
    final fileBytes = Uint8List.fromList(List.generate(256, (i) => i % 251));
    final fileCipher = await encryption.encryptBytes(fileBytes, key);
    final encDir = Directory('${tempDir.path}/clipflow_files_enc');
    encDir.createSync(recursive: true);
    File('${encDir.path}/f1.enc').writeAsBytesSync(
      base64Decode(fileCipher.toBase64()),
    );
    repo.history.add(serverRow(
      id: 'f1', type: 'file', timestamp: 3,
      extra: {
        'file_name': 'a.pdf', 'file_size': 100,
        'mime_type': 'application/pdf', 'hash': 'fh',
      },
    ));

    final manifest = await buildService().buildExport(
      deviceName: 'MacBook Pro · macOS',
      encryptionKey: key,
    );

    expect(manifest.saltHex, saltHex);
    expect(manifest.sourceDevice, 'MacBook Pro · macOS');
    expect(manifest.entries.length, 3);

    final textEntryOut = manifest.entries.firstWhere((e) => e.id == 't1');
    expect(textEntryOut.type, 'text');
    final decryptedText = await encryption.decrypt(
      EncryptedData.fromBase64(textEntryOut.content),
      key,
    );
    expect(decryptedText, textPlain);

    final imageEntryOut = manifest.entries.firstWhere((e) => e.id == 'i1');
    expect(imageEntryOut.thumb, 'THUMB');
    expect(imageEntryOut.width, 100);
    expect(imageEntryOut.height, 50);
    expect(imageEntryOut.format, 'jpeg');
    expect(imageEntryOut.stableHash, 'ih');
    final decryptedImage = await encryption.decryptBytes(
      EncryptedData.fromBase64(imageEntryOut.content),
      key,
    );
    expect(decryptedImage, imageBytes);

    final fileEntryOut = manifest.entries.firstWhere((e) => e.id == 'f1');
    expect(fileEntryOut.fileName, 'a.pdf');
    expect(fileEntryOut.fileSize, 100);
    expect(fileEntryOut.mimeType, 'application/pdf');
    expect(fileEntryOut.fileHash, 'fh');
    final fileCiphertext = base64Decode(fileEntryOut.fileCiphertextBase64!);
    final decryptedFile = await encryption.decryptBytes(
      EncryptedData.fromBytes(Uint8List.fromList(fileCiphertext)),
      key,
    );
    expect(decryptedFile, fileBytes);
    // marker 非空（EncryptedData 兼容）
    expect(fileEntryOut.content, isNotEmpty);
  });

  test('buildExport：本地缺失时走服务端 /content 与文件流兜底', () async {
    // 文本 t2 不在本地历史 → /content
    repo.history = [serverRow(id: 't2', type: 'text', content: 'TRUNC')];
    final textCipher = (await encryption.encrypt('server text', key)).toBase64();
    repo.contents['t2'] = textCipher;

    // 图片 i2 本地无缓存 → /content
    repo.history.add(serverRow(
      id: 'i2', type: 'image', thumb: 'T2', timestamp: 2,
      extra: {'width': 10, 'height': 20, 'format': 'png', 'hash': 'ih2'},
    ));
    final imgCipher = (await encryption.encryptBytes(
      Uint8List.fromList([9, 9, 9]), key,
    )).toBase64();
    repo.contents['i2'] = imgCipher;

    // 文件 f2 本地无 .enc → 文件流下载
    repo.history.add(serverRow(
      id: 'f2', type: 'file', timestamp: 3,
      extra: {
        'file_name': 'b.bin', 'file_size': 10,
        'mime_type': 'application/octet-stream', 'hash': 'fh2',
      },
    ));
    final fileCipherBytes = (await encryption.encryptBytes(
      Uint8List.fromList([1, 2, 3, 4]), key,
    )).toBytes();
    repo.fileContents['f2'] = fileCipherBytes;

    final manifest = await buildService().buildExport(
      deviceName: 'dev',
      encryptionKey: key,
    );

    expect(manifest.entries.length, 3);
    final textOut = manifest.entries.firstWhere((e) => e.id == 't2');
    expect(
      await encryption.decrypt(EncryptedData.fromBase64(textOut.content), key),
      'server text',
    );
    final imageOut = manifest.entries.firstWhere((e) => e.id == 'i2');
    expect(
      await encryption.decryptBytes(EncryptedData.fromBase64(imageOut.content), key),
      Uint8List.fromList([9, 9, 9]),
    );
    final fileOut = manifest.entries.firstWhere((e) => e.id == 'f2');
    expect(
      await encryption.decryptBytes(
        EncryptedData.fromBytes(Uint8List.fromList(base64Decode(fileOut.fileCiphertextBase64!))),
        key,
      ),
      Uint8List.fromList([1, 2, 3, 4]),
    );
    expect(repo.contentFallbackCalls, greaterThanOrEqualTo(2));
  });

  test('buildExport：salt 本地缺失时从服务端兜底', () async {
    SharedPreferences.setMockInitialValues({});
    final freshStorage = LocalStorage(await SharedPreferences.getInstance());
    repo.salt = saltHex;
    repo.history = [serverRow(id: 't3', type: 'text', content: 'X')];
    history.addEntry(ClipboardEntry(
      id: 't3', content: 'local', sourceDeviceId: 'd1',
      sourceDeviceName: 'Mac', timestamp: DateTime.fromMillisecondsSinceEpoch(1),
      type: ContentType.text,
    ));

    final service = BackupService(
      cloudRepo: repo,
      storage: freshStorage,
      imageStore: imageStore,
      fileStore: fileStore,
      historyService: history,
      encryption: encryption,
    );
    final manifest = await service.buildExport(deviceName: 'd', encryptionKey: key);
    expect(manifest.saltHex, saltHex);
  });

  group('BackupService importBackup', () {
    const oldPassword = 'old-password';
    final oldSaltHex = saltHex;
    final newSaltHex = saltHex; // 换密码不改 salt（salt 属于账户）

    late EncryptionService encryption;
    late Uint8List oldKey;
    late Uint8List newKey;
    late FakeImportRepo repo;
    late LocalStorage storage;
    late LocalImageStore imageStore;
    late LocalFileStore fileStore;
    late HistoryService history;
    late Directory tempDir;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      encryption = EncryptionService();
      oldKey = await encryption.deriveKey(oldPassword, hexToBytes(oldSaltHex));
      newKey = await encryption.deriveKey('new-password', hexToBytes(newSaltHex));
      repo = FakeImportRepo();
      storage = LocalStorage(await SharedPreferences.getInstance());
      tempDir = await Directory.systemTemp.createTemp('clipflow_import_');
      imageStore = LocalImageStore(directoryPath: tempDir.path);
      fileStore = LocalFileStore(directoryPath: tempDir.path);
      history = HistoryService(maxEntries: 100);
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    BackupService buildService() => BackupService(
          cloudRepo: repo,
          storage: storage,
          imageStore: imageStore,
          fileStore: fileStore,
          historyService: history,
          encryption: encryption,
        );

    Future<BackupManifest> buildManifest() async {
      final textCipher = (await encryption.encrypt('import text', oldKey)).toBase64();
      final imageCipher = (await encryption.encryptBytes(
        Uint8List.fromList(List.generate(32, (i) => i)), oldKey,
      )).toBase64();
      final thumbCipher = (await encryption.encryptBytes(
        Uint8List.fromList([7, 7, 7]), oldKey,
      )).toBase64();
      final fileCipherBytes = (await encryption.encryptBytes(
        Uint8List.fromList(List.generate(128, (i) => i % 250)), oldKey,
      )).toBytes();

      return BackupManifest(
        exportedAt: DateTime.now(),
        sourceDevice: 'old-device',
        saltHex: oldSaltHex,
        entries: [
          BackupEntry(
            id: 'import-text-1', type: 'text', timestamp: 111,
            sourceDeviceId: 'sd', sourceDeviceName: 'Old', sourcePlatform: 'macos',
            pinned: true, content: textCipher,
          ),
          BackupEntry(
            id: 'import-img-1', type: 'image', timestamp: 222,
            sourceDeviceId: 'sd', sourceDeviceName: 'Old', sourcePlatform: 'macos',
            pinned: false, content: imageCipher, thumb: thumbCipher,
            width: 10, height: 20, format: 'png', stableHash: 'ih',
          ),
          BackupEntry(
            id: 'import-file-1', type: 'file', timestamp: 333,
            sourceDeviceId: 'sd', sourceDeviceName: 'Old', sourcePlatform: 'macos',
            pinned: false, content: 'MARKER', fileName: 'doc.pdf', fileSize: 500,
            mimeType: 'application/pdf', fileHash: 'fh',
            fileCiphertextBase64: base64Encode(fileCipherBytes),
          ),
        ],
      );
    }

    test('导入：旧密钥解密 → 新密钥重加密，保留原 ID/timestamp，pinned PATCH 恢复', () async {
      final manifest = await buildManifest();
      final result = await buildService().importBackup(
        manifest: manifest,
        oldPassword: oldPassword,
        newKey: newKey,
        deviceId: 'new-dev',
        deviceName: 'New Mac',
        devicePlatform: 'macos',
      );

      expect(result.imported, 3);
      expect(result.failed, 0);
      expect(repo.uploadedHistory.length, 2); // text + image（file 走上传流，不入 history JSON）

      final textRow = repo.uploadedHistory.firstWhere((r) => r['historyId'] == 'import-text-1');
      expect(textRow['timestamp'], 111);
      expect(
        await encryption.decrypt(
          EncryptedData.fromBase64(textRow['content'] as String),
          newKey,
        ),
        'import text',
      );
      // 用旧密钥解密新密文必然失败（确保确实重加密了）
      expect(
        () => encryption.decrypt(
          EncryptedData.fromBase64(textRow['content'] as String),
          oldKey,
        ),
        throwsA(isA<Exception>()),
      );

      final imgRow = repo.uploadedHistory.firstWhere((r) => r['historyId'] == 'import-img-1');
      expect(imgRow['timestamp'], 222);
      expect(
        await encryption.decryptBytes(
          EncryptedData.fromBase64(imgRow['content'] as String),
          newKey,
        ),
        Uint8List.fromList(List.generate(32, (i) => i)),
      );
      expect(
        await encryption.decryptBytes(
          EncryptedData.fromBase64(imgRow['thumb'] as String),
          newKey,
        ),
        Uint8List.fromList([7, 7, 7]),
      );

      final fileRow = repo.uploadedFiles.firstWhere((r) => r['historyId'] == 'import-file-1');
      expect(fileRow['timestamp'], 333);
      expect(fileRow['fileName'], 'doc.pdf');
      expect(fileRow['fileSize'], 500);
      expect(fileRow['plaintextHash'], 'fh');
      expect(
        await encryption.decryptBytes(
          EncryptedData.fromBytes(Uint8List.fromList(fileRow['bytes'] as List<int>)),
          newKey,
        ),
        Uint8List.fromList(List.generate(128, (i) => i % 250)),
      );
      // 临时密文文件上传后已清理
      expect(await File(fileRow['encryptedPath'] as String).exists(), isFalse);

      // pinned 恢复
      expect(repo.patchedPinned, contains('import-text-1'));
      expect(repo.patchedPinned, isNot(contains('import-img-1')));
    });

    test('导入：旧密码错误 → 首条解密失败抛 DecryptionException 且不上传', () async {
      final manifest = await buildManifest();
      expect(
        () => buildService().importBackup(
          manifest: manifest,
          oldPassword: 'wrong-password',
          newKey: newKey,
          deviceId: 'd',
          deviceName: 'n',
          devicePlatform: 'p',
        ),
        throwsA(isA<DecryptionException>()),
      );
      expect(repo.uploadedHistory, isEmpty);
      expect(repo.uploadedFiles, isEmpty);
    });

    test('导入：端到端 buildExport → 换密钥 importBackup → 三类条目解密一致', () async {
      // 构造服务端仓库（同 FakeBackupRepo）
      final server = FakeBackupRepo();
      server.salt = saltHex;
      final textPlain = 'end-to-end text';
      final imageBytes = Uint8List.fromList(List.generate(64, (i) => i * 2));
      final thumbBytes = Uint8List.fromList(List.generate(8, (i) => i + 1));
      final fileBytes = Uint8List.fromList(List.generate(200, (i) => i % 249));
      server.history = [
        {
          'id': 'e2e-text', 'type': 'text', 'content': 'TRUNC',
          'source_device': 'd1', 'source_device_name': 'Old', 'source_platform': 'macos',
          'timestamp': 1, 'pinned': 0,
        },
        {
          'id': 'e2e-img', 'type': 'image', 'content': '',
          'source_device': 'd1', 'source_device_name': 'Old', 'source_platform': 'macos',
          'timestamp': 2, 'pinned': 0,
          'thumb': (await encryption.encryptBytes(thumbBytes, oldKey)).toBase64(),
          'width': 8, 'height': 9, 'format': 'jpeg', 'hash': 'e2e-ih',
        },
        {
          'id': 'e2e-file', 'type': 'file', 'content': '',
          'source_device': 'd1', 'source_device_name': 'Old', 'source_platform': 'macos',
          'timestamp': 3, 'pinned': 0,
          'file_name': 'e.bin', 'file_size': 200, 'mime_type': 'application/octet-stream',
          'hash': 'e2e-fh',
        },
      ];
      history.addEntry(ClipboardEntry(
        id: 'e2e-text', content: textPlain, sourceDeviceId: 'd1',
        sourceDeviceName: 'Old', timestamp: DateTime.fromMillisecondsSinceEpoch(1),
        type: ContentType.text,
      ));
      final imageCipher = (await encryption.encryptBytes(imageBytes, oldKey)).toBase64();
      server.contents['e2e-img'] = imageCipher;
      final fileCipherBytes = (await encryption.encryptBytes(fileBytes, oldKey)).toBytes();
      server.fileContents['e2e-file'] = fileCipherBytes;

      final exportService = BackupService(
        cloudRepo: server,
        storage: storage,
        imageStore: imageStore,
        fileStore: fileStore,
        historyService: history,
        encryption: encryption,
      );
      final manifest = await exportService.buildExport(
        deviceName: 'old',
        encryptionKey: oldKey,
      );
      expect(manifest.entries.length, 3);

      // 换新密钥导入到新账户
      final result = await buildService().importBackup(
        manifest: manifest,
        oldPassword: oldPassword,
        newKey: newKey,
        deviceId: 'new-dev',
        deviceName: 'New',
        devicePlatform: 'macos',
      );
      expect(result.imported, 3);
      expect(result.failed, 0);

      // 用新密钥解密上传内容，断言与原始明文一致
      final textRow = repo.uploadedHistory.firstWhere((r) => r['historyId'] == 'e2e-text');
      expect(
        await encryption.decrypt(EncryptedData.fromBase64(textRow['content'] as String), newKey),
        textPlain,
      );
      final imgRow = repo.uploadedHistory.firstWhere((r) => r['historyId'] == 'e2e-img');
      expect(
        await encryption.decryptBytes(EncryptedData.fromBase64(imgRow['content'] as String), newKey),
        imageBytes,
      );
      expect(
        await encryption.decryptBytes(EncryptedData.fromBase64(imgRow['thumb'] as String), newKey),
        thumbBytes,
      );
      final fileRow = repo.uploadedFiles.firstWhere((r) => r['historyId'] == 'e2e-file');
      expect(
        await encryption.decryptBytes(
          EncryptedData.fromBytes(Uint8List.fromList(fileRow['bytes'] as List<int>)),
          newKey,
        ),
        fileBytes,
      );
    });
  });

}

// ==================== 导入（迁移码） ====================

class FakeImportRepo extends CloudRepository {
  FakeImportRepo() : super(CloudBaseService());

  final List<Map<String, dynamic>> uploadedClipboard = [];
  final List<Map<String, dynamic>> uploadedHistory = [];
  final List<Map<String, dynamic>> uploadedFiles = [];
  final List<String> patchedPinned = [];

  @override
  Future<void> setCurrentClipboard(Map<String, dynamic> data) async {
    uploadedClipboard.add(data);
  }

  @override
  Future<void> addHistoryEntry(Map<String, dynamic> data) async {
    uploadedHistory.add(data);
  }

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
    // 服务清理临时文件前先捕获字节，供测试验证
    final bytes = await File(encryptedPath).readAsBytes();
    uploadedFiles.add({
      'encryptedPath': encryptedPath,
      'bytes': bytes,
      'historyId': historyId,
      'plaintextHash': plaintextHash,
      'fileName': fileName,
      'fileSize': fileSize,
      'mimeType': mimeType,
      'marker': marker,
      'timestamp': timestamp,
    });
  }

  @override
  Future<void> updateHistoryEntry(String entryId, Map<String, dynamic> data) async {
    if (data['pinned'] == true) patchedPinned.add(entryId);
  }
}

