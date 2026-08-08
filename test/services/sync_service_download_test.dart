import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:clipflow/repositories/cloud_repository.dart';
import 'package:clipflow/services/cloudbase_service.dart';
import 'package:clipflow/services/encryption_service.dart';
import 'package:clipflow/services/sync_service.dart';

class _DownloadRepository extends CloudRepository {
  Map<String, dynamic>? current;

  _DownloadRepository() : super(CloudBaseService());

  @override
  Future<Map<String, dynamic>?> getCurrentClipboardWithDeletions() async {
    return current;
  }
}

void main() {
  late EncryptionService encryption;
  late Uint8List key;
  late _DownloadRepository repository;
  late SyncService service;

  setUp(() async {
    encryption = EncryptionService();
    key = await encryption.deriveKey(
      'download-test-password',
      List<int>.generate(32, (index) => index),
    );
    repository = _DownloadRepository();
    service = SyncService(
      repo: repository,
      encryption: encryption,
      deviceId: 'device-local',
      deviceName: 'Local',
      devicePlatform: 'macos',
      key: key,
    );
    final encrypted = await encryption.encrypt('hello', key);
    repository.current = {
      'content': encrypted.toBase64(),
      'source_device': 'device-remote',
      'source_device_name': 'Remote',
      'source_platform': 'windows',
      'timestamp': 1000,
      'type': 'text',
      '_deletedIds': <String>[],
      '_restoredEntries': <Map<String, dynamic>>[],
    };
  });

  test('text download exposes server history_id', () async {
    repository.current!['history_id'] = 'server-history-1';

    final result = await service.downloadLatestContent();

    expect(result?.id, 'server-history-1');
  });

  test('legacy text download without history_id keeps null id', () async {
    final result = await service.downloadLatestContent();

    expect(result?.id, isNull);
  });
}
