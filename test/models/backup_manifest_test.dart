import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:clipflow/models/backup_manifest.dart';

void main() {
  group('BackupManifest', () {
    test('文本条目 JSON roundtrip', () {
      final manifest = BackupManifest(
        exportedAt: DateTime.parse('2026-08-07T12:00:00+08:00'),
        sourceDevice: 'MacBook Pro · macOS',
        saltHex: '3f2a',
        entries: [
          BackupEntry(
            id: 'e1',
            type: 'text',
            timestamp: 1700000000000,
            sourceDeviceId: 'd1',
            sourceDeviceName: 'Mac',
            sourcePlatform: 'macos',
            pinned: false,
            content: 'ABC+DEF==',
          ),
        ],
      );
      final restored = BackupManifest.fromJson(
        jsonDecode(jsonEncode(manifest.toJson())) as Map<String, dynamic>,
      );
      expect(restored.format, 'clipflow-backup');
      expect(restored.version, 1);
      expect(restored.saltHex, '3f2a');
      expect(restored.exportedAt, DateTime.parse('2026-08-07T12:00:00+08:00'));
      expect(restored.entries.single.content, 'ABC+DEF==');
      expect(restored.entries.single.type, 'text');
      expect(restored.entries.single.sourceDeviceId, 'd1');
      expect(restored.entries.single.timestamp, 1700000000000);
    });

    test('图片/文件条目 roundtrip 保留全部字段', () {
      final manifest = BackupManifest(
        exportedAt: DateTime.now(),
        sourceDevice: 'dev',
        saltHex: 'aa',
        entries: [
          BackupEntry(
            id: 'i1', type: 'image', timestamp: 1,
            sourceDeviceId: 'd', sourceDeviceName: 'n', sourcePlatform: 'p',
            pinned: false, content: 'C', thumb: 'T', width: 100, height: 50,
            format: 'jpeg', stableHash: 'h',
          ),
          BackupEntry(
            id: 'f1', type: 'file', timestamp: 2,
            sourceDeviceId: 'd', sourceDeviceName: 'n', sourcePlatform: 'p',
            pinned: true, content: 'M', fileName: 'a.pdf', fileSize: 100,
            mimeType: 'application/pdf', fileHash: 'fh', fileCiphertextBase64: 'BIG',
          ),
        ],
      );
      final restored = BackupManifest.fromJson(
        jsonDecode(jsonEncode(manifest.toJson())) as Map<String, dynamic>,
      );
      final image = restored.entries.firstWhere((e) => e.id == 'i1');
      expect(image.thumb, 'T');
      expect(image.width, 100);
      expect(image.height, 50);
      expect(image.format, 'jpeg');
      expect(image.stableHash, 'h');
      final file = restored.entries.firstWhere((e) => e.id == 'f1');
      expect(file.pinned, isTrue);
      expect(file.fileName, 'a.pdf');
      expect(file.fileSize, 100);
      expect(file.mimeType, 'application/pdf');
      expect(file.fileHash, 'fh');
      expect(file.fileCiphertextBase64, 'BIG');
    });

    test('fromJson 拒绝非 clipflow-backup 格式', () {
      expect(
        () => BackupManifest.fromJson({'format': 'other', 'version': 1}),
        throwsFormatException,
      );
    });

    test('fromJson 拒绝不支持版本', () {
      expect(
        () => BackupManifest.fromJson({'format': 'clipflow-backup', 'version': 99}),
        throwsFormatException,
      );
    });

    test('estimateBytes 累计密文体积并含元数据开销', () {
      final manifest = BackupManifest(
        exportedAt: DateTime.now(),
        sourceDevice: 'd',
        saltHex: 's',
        entries: [
          BackupEntry(
            id: 'a', type: 'text', timestamp: 1,
            sourceDeviceId: 'd', sourceDeviceName: 'n', sourcePlatform: 'p',
            pinned: false, content: '12345',
          ),
          BackupEntry(
            id: 'b', type: 'file', timestamp: 2,
            sourceDeviceId: 'd', sourceDeviceName: 'n', sourcePlatform: 'p',
            pinned: false, content: 'M', fileCiphertextBase64: 'X' * 100,
          ),
        ],
      );
      expect(manifest.estimateBytes(), greaterThan(110));
    });
  });
}
