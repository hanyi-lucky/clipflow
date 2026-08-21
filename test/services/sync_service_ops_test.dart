import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:clipflow/models/sync_changes_page.dart';
import 'package:clipflow/repositories/cloud_repository.dart';
import 'package:clipflow/services/cloudbase_service.dart';
import 'package:clipflow/services/encryption_service.dart';
import 'package:clipflow/services/sync_service.dart';

class _OpsRepository extends CloudRepository {
  _OpsRepository() : super(CloudBaseService());
}

void main() {
  late EncryptionService encryption;
  late Uint8List key;
  late SyncService service;

  setUp(() async {
    encryption = EncryptionService();
    key = await encryption.deriveKey(
      'ops-test-password',
      List<int>.generate(32, (index) => index),
    );
    service = SyncService(
      repo: _OpsRepository(),
      encryption: encryption,
      deviceId: 'device-local',
      deviceName: 'Local',
      devicePlatform: 'macos',
      key: key,
    );
  });

  SyncChangesPage makePage({int cursor = 5, bool hasMore = false}) =>
      SyncChangesPage.fromJson({
        'cursor': cursor,
        'hasMore': hasMore,
        'changes': [
          {'seq': 1, 'operationId': 'del:e1', 'kind': 'delete', 'entryId': 'e1'},
          {
            'seq': 2,
            'operationId': 'rest:e2',
            'kind': 'restore',
            'entryId': 'e2',
            'row': {
              'id': 'e2',
              'content': 'cipher-e2',
              'type': 'text',
              'timestamp': 1000,
            },
          },
        ],
      });

  test('prepareDelete/prepareRestore 周期计数：restore 观察后 opId 递增周期后缀（第二次删除/恢复 opId 唯一）', () {
    expect(service.prepareDelete('e1').dedupeKey, 'del:e1');
    expect(service.prepareRestore('e1').dedupeKey, 'rest:e1');

    service.markRestoreObserved('e1');
    expect(service.prepareDelete('e1').dedupeKey, 'del:e1#1');
    expect(service.prepareRestore('e1').dedupeKey, 'rest:e1#1');

    service.markRestoreObserved('e1');
    expect(service.prepareDelete('e1').dedupeKey, 'del:e1#2');
    expect(service.prepareRestore('e1').dedupeKey, 'rest:e1#2');

    // 其他条目不受影响
    expect(service.prepareDelete('other').dedupeKey, 'del:other');
    expect(service.prepareRestore('other').dedupeKey, 'rest:other');
  });

  test('decodeCurrentClipboard converts an ops page to deletions + restorations and exposes the cursor', () async {
    final result = await service.decodeCurrentClipboard(null, opsPage: makePage());

    expect(result, isNotNull);
    expect(result!.deletedIds, ['e1']);
    expect(result.restoredEntries, hasLength(1));
    expect(result.restoredEntries.single['id'], 'e2');
    expect(result.syncCursor, 5);
    expect(result.hasContent, isFalse);
  });

  test('empty clipboard with non-empty ops returns an empty result, not null', () async {
    final result = await service.decodeCurrentClipboard(null, opsPage: makePage());

    expect(result, isNotNull);
    expect(result!.hasContent, isFalse);
    expect(result.deletedIds, isNotEmpty);
    expect(result.syncCursor, 5);
  });

  test('restore op with row null is skipped without crashing', () async {
    final page = SyncChangesPage.fromJson({
      'cursor': 6,
      'hasMore': false,
      'changes': [
        {
          'seq': 3,
          'operationId': 'rest:gone',
          'kind': 'restore',
          'entryId': 'gone',
          'row': null,
        },
      ],
    });

    final result = await service.decodeCurrentClipboard(null, opsPage: page);

    expect(result, isNotNull);
    expect(result!.restoredEntries, isEmpty);
    expect(result.deletedIds, isEmpty);
    expect(result.syncCursor, 6);
  });

  test('legacy path without ops page reads _deletedIds/_restoredEntries', () async {
    final result = await service.decodeCurrentClipboard({
      'content': 'ignored-empty',
      'source_device': 'device-local',
      'source_device_name': 'Local',
      'source_platform': 'macos',
      'timestamp': 0,
      'type': 'text',
      '_deletedIds': <String>['legacy-del'],
      '_restoredEntries': <Map<String, dynamic>>[
        {'id': 'legacy-rest', 'type': 'text'},
      ],
    });

    expect(result, isNotNull);
    expect(result!.deletedIds, ['legacy-del']);
    expect(result.restoredEntries, hasLength(1));
    expect(result.syncCursor, isNull);
  });

  test('null clipboard without ops returns null (legacy NOT_FOUND)', () async {
    final result = await service.decodeCurrentClipboard(null);

    expect(result, isNull);
  });
}
