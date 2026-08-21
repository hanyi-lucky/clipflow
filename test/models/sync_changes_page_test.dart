import 'package:flutter_test/flutter_test.dart';
import 'package:clipflow/models/sync_changes_page.dart';

void main() {
  test('SyncChangesPage.fromJson parses cursor, hasMore and changes', () {
    final page = SyncChangesPage.fromJson({
      'cursor': 42,
      'hasMore': false,
      'changes': [
        {
          'seq': 1,
          'operationId': 'del:entry-1',
          'kind': 'delete',
          'entryId': 'entry-1',
        },
        {
          'seq': 2,
          'operationId': 'rest:entry-2',
          'kind': 'restore',
          'entryId': 'entry-2',
          'row': {'id': 'entry-2', 'content': 'cipher', 'type': 'text'},
        },
      ],
    });

    expect(page.cursor, 42);
    expect(page.hasMore, false);
    expect(page.changes, hasLength(2));
    expect(page.changes[0].kind, 'delete');
    expect(page.changes[0].operationId, 'del:entry-1');
    expect(page.changes[0].entryId, 'entry-1');
    expect(page.changes[0].row, isNull);
    expect(page.changes[1].kind, 'restore');
    expect(page.changes[1].row?['id'], 'entry-2');
  });

  test('SyncChangesPage.fromJson tolerates row null for restore ops', () {
    final page = SyncChangesPage.fromJson({
      'cursor': 5,
      'hasMore': true,
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

    expect(page.changes.single.row, isNull);
    expect(page.changes.single.kind, 'restore');
  });

  test('SyncChangesPage.empty yields cursor 0 with no changes', () {
    final page = SyncChangesPage.empty();

    expect(page.cursor, 0);
    expect(page.hasMore, false);
    expect(page.changes, isEmpty);
  });
}
