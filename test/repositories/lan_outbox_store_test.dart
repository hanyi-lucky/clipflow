import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:clipflow/repositories/lan_outbox_store.dart';

LanOutboxEntry _entry({
  required String userId,
  required String peerId,
  required String historyId,
  String kind = 'text',
  int attempts = 0,
}) {
  return LanOutboxEntry(
    userId: userId,
    peerId: peerId,
    historyId: historyId,
    kind: kind,
    row: <String, dynamic>{
      'history_id': historyId,
      'type': kind,
      'content': 'encrypted',
      'source_device': 'device-a',
      'source_device_name': 'Mac A',
      'source_platform': 'macos',
      'timestamp': 100,
    },
    enqueuedAtMs: 1700000000000,
    attempts: attempts,
  );
}

void main() {
  late Directory tempDir;
  late LanOutboxStore store;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('lan_outbox_');
    store = LanOutboxStore(directoryPath: tempDir.path);
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('put + loadActive 往返：字段完整保留', () async {
    final entry = _entry(
      userId: 'user_a',
      peerId: 'peer-1',
      historyId: 'h-1',
      kind: 'file',
      attempts: 2,
    );
    await store.put(entry);

    final loaded = await store.loadActive('user_a');
    expect(loaded, hasLength(1));
    final e = loaded.single;
    expect(e.userId, 'user_a');
    expect(e.peerId, 'peer-1');
    expect(e.historyId, 'h-1');
    expect(e.kind, 'file');
    expect(e.row['history_id'], 'h-1');
    expect(e.enqueuedAtMs, 1700000000000);
    expect(e.attempts, 2);
  });

  test('目录结构为 clipflow_lan_outbox/<userId>/<peerId>/<historyId>.json', () async {
    await store.put(_entry(userId: 'user_x', peerId: 'peer-y', historyId: 'h-9'));
    final file = File(
      '${tempDir.path}/clipflow_lan_outbox/user_x/peer-y/h-9.json',
    );
    expect(file.existsSync(), isTrue);
    // 与云 outbox 目录完全隔离
    expect(
      Directory('${tempDir.path}/clipflow_outbox').existsSync(),
      isFalse,
    );
  });

  test('per-user 隔离：A 的条目不会被 B 加载', () async {
    await store.put(_entry(userId: 'user_a', peerId: 'peer-1', historyId: 'h-a'));
    await store.put(_entry(userId: 'user_b', peerId: 'peer-1', historyId: 'h-b'));

    final a = await store.loadActive('user_a');
    final b = await store.loadActive('user_b');
    expect(a.map((e) => e.historyId), ['h-a']);
    expect(b.map((e) => e.historyId), ['h-b']);
  });

  test('remove 只删指定 (peer, historyId) 条目', () async {
    await store.put(_entry(userId: 'user_a', peerId: 'peer-1', historyId: 'h-1'));
    await store.put(_entry(userId: 'user_a', peerId: 'peer-1', historyId: 'h-2'));
    await store.put(_entry(userId: 'user_a', peerId: 'peer-2', historyId: 'h-1'));

    await store.remove('user_a', 'peer-1', 'h-1');

    final loaded = await store.loadActive('user_a');
    expect(loaded.map((e) => '${e.peerId}/${e.historyId}'),
        ['peer-1/h-2', 'peer-2/h-1']);
  });

  test('损坏 JSON 条目被跳过，不阻断其他条目', () async {
    await store.put(_entry(userId: 'user_a', peerId: 'peer-1', historyId: 'h-good'));
    final corrupt = File(
      '${tempDir.path}/clipflow_lan_outbox/user_a/peer-1/h-bad.json',
    )..writeAsStringSync('{ not valid json');

    final loaded = await store.loadActive('user_a');
    expect(loaded.map((e) => e.historyId), ['h-good']);
    expect(corrupt.existsSync(), isTrue, reason: '损坏条目保留文件，仅跳过');
  });

  test('clearPersistedOutbox 只清本用户目录，不触碰云 outbox/其他用户', () async {
    await store.put(_entry(userId: 'user_a', peerId: 'peer-1', historyId: 'h-a1'));
    await store.put(_entry(userId: 'user_b', peerId: 'peer-1', historyId: 'h-b1'));
    // 模拟云 outbox 目录：不得被 LAN 清理波及
    final cloudDir = Directory('${tempDir.path}/clipflow_outbox/user_a')
      ..createSync(recursive: true);
    final cloudFile = File('${cloudDir.path}/op.json')
      ..writeAsStringSync(jsonEncode(<String, dynamic>{'keep': true}));

    await store.clearPersistedOutbox('user_a');

    expect(await store.loadActive('user_a'), isEmpty);
    expect(await store.loadActive('user_b'), hasLength(1));
    expect(cloudFile.existsSync(), isTrue, reason: '云 outbox 不得被误删');
  });
}
