import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:clipflow/core/constants.dart';
import 'package:clipflow/repositories/local_file_store.dart';
import 'package:clipflow/services/lan_transport.dart';

/// 构造一个合法 file row（server-shape，含 enc_file_name 密文，无明文 file_name）。
Map<String, dynamic> _fileRow(String historyId) {
  return <String, dynamic>{
    'history_id': historyId,
    'type': 'file',
    'content': 'marker-ciphertext',
    'hash': 'hash-$historyId',
    'enc_file_name': 'encrypted-name',
    'file_size': 100,
    'source_device': 'device-a',
    'source_device_name': 'Mac A',
    'source_platform': 'macos',
    'timestamp': 1,
  };
}

void main() {
  late Directory tempDir;
  late LocalFileStore fileStore;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('lan_transport_file_');
    fileStore = LocalFileStore(directoryPath: tempDir.path);
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  Future<String?> saveSink({
    required String entryId,
    required Stream<List<int>> stream,
  }) {
    return fileStore.saveEncryptedFromStream(entryId: entryId, stream: stream);
  }

  Future<List<String>> tmpPartPaths() async {
    final dir = Directory('${tempDir.path}/${LocalFileStore.tmpDirName}');
    if (!await dir.exists()) return [];
    final names = <String>[];
    await for (final entity in dir.list()) {
      if (entity is File) names.add(entity.path);
    }
    return names;
  }

  group('LanFileReceiver reassembly', () {
    test('fileStart + 3×fileChunk → .enc 落盘 + onComplete(row, encPath)', () async {
      final bytes = Uint8List.fromList(
        List<int>.generate(25, (i) => (i * 7) % 256),
      );
      final row = _fileRow('recv-1');
      final completed = <String?>[];

      final receiver = LanFileReceiver(
        sink: saveSink,
        onComplete: (r, p) => completed.addAll([r['history_id'] as String, p]),
      );

      expect(
        receiver.handleFileStart(<String, dynamic>{
          'v': 1,
          'type': 'fileStart',
          'row': row,
          'encSize': 25,
          'chunkSize': 10,
          'total': 3,
        }),
        isTrue,
      );
      // chunk 0/1 满 10 字节，chunk 2 余 5 字节
      for (var seq = 0; seq < 3; seq++) {
        final start = seq * 10;
        final end = start + 10 > 25 ? 25 : start + 10;
        final chunk = Uint8List.fromList(bytes.sublist(start, end));
        expect(
          receiver.handleFileChunk(<String, dynamic>{
            'v': 1,
            'type': 'fileChunk',
            'historyId': 'recv-1',
            'seq': seq,
            'data': base64Url.encode(chunk),
          }),
          isTrue,
        );
      }

      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(completed, ['recv-1', isNotNull]);
      final path = completed[1];
      final landed = await fileStore.loadEncryptedPath('recv-1');
      expect(landed, path);
      expect(landed, isNotNull);
      expect(File(landed!).readAsBytesSync(), equals(bytes));
      expect(await tmpPartPaths(), isEmpty);
    });

    test('乱序 chunk（先 seq 1）→ 中止，不留 .enc/.part', () async {
      final receiver = LanFileReceiver(sink: saveSink);
      expect(
        receiver.handleFileStart(<String, dynamic>{
          'v': 1,
          'type': 'fileStart',
          'row': _fileRow('recv-2'),
          'encSize': 25,
          'chunkSize': 10,
          'total': 3,
        }),
        isTrue,
      );
      expect(
        receiver.handleFileChunk(<String, dynamic>{
          'v': 1,
          'type': 'fileChunk',
          'historyId': 'recv-2',
          'seq': 1,
          'data': base64Url.encode(List<int>.filled(10, 1)),
        }),
        isFalse,
      );

      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(await fileStore.loadEncryptedPath('recv-2'), isNull);
      expect(await tmpPartPaths(), isEmpty);
    });

    test('重复 chunk（seq 0 两次）→ 中止', () async {
      final receiver = LanFileReceiver(sink: saveSink);
      expect(
        receiver.handleFileStart(<String, dynamic>{
          'v': 1,
          'type': 'fileStart',
          'row': _fileRow('recv-3'),
          'encSize': 25,
          'chunkSize': 10,
          'total': 3,
        }),
        isTrue,
      );
      final chunk = <String, dynamic>{
        'v': 1,
        'type': 'fileChunk',
        'historyId': 'recv-3',
        'seq': 0,
        'data': base64Url.encode(List<int>.filled(10, 2)),
      };
      // 第一帧 seq 0 通过（未完成，total=3）
      expect(receiver.handleFileChunk(chunk), isTrue);
      // 传输进行中重复 seq 0 → 违规 → 中止
      expect(receiver.handleFileChunk(chunk), isFalse);

      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(await fileStore.loadEncryptedPath('recv-3'), isNull);
      expect(await tmpPartPaths(), isEmpty);
    });

    test('超量 chunk（超过 encSize 剩余）→ 中止', () async {
      final receiver = LanFileReceiver(sink: saveSink);
      expect(
        receiver.handleFileStart(<String, dynamic>{
          'v': 1,
          'type': 'fileStart',
          'row': _fileRow('recv-4'),
          'encSize': 10,
          'chunkSize': 10,
          'total': 1,
        }),
        isTrue,
      );
      // 发送 11 字节（> encSize 10）
      expect(
        receiver.handleFileChunk(<String, dynamic>{
          'v': 1,
          'type': 'fileChunk',
          'historyId': 'recv-4',
          'seq': 0,
          'data': base64Url.encode(List<int>.filled(11, 3)),
        }),
        isFalse,
      );

      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(await fileStore.loadEncryptedPath('recv-4'), isNull);
    });

    test('畸形 base64 → 中止', () async {
      final receiver = LanFileReceiver(sink: saveSink);
      expect(
        receiver.handleFileStart(<String, dynamic>{
          'v': 1,
          'type': 'fileStart',
          'row': _fileRow('recv-5'),
          'encSize': 10,
          'chunkSize': 10,
          'total': 1,
        }),
        isTrue,
      );
      expect(
        receiver.handleFileChunk(<String, dynamic>{
          'v': 1,
          'type': 'fileChunk',
          'historyId': 'recv-5',
          'seq': 0,
          'data': '!!!!not-base64!!!!',
        }),
        isFalse,
      );

      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(await fileStore.loadEncryptedPath('recv-5'), isNull);
    });

    test('不完整传输（中途 abort）→ 无 .enc、.part 清理', () async {
      final receiver = LanFileReceiver(sink: saveSink);
      expect(
        receiver.handleFileStart(<String, dynamic>{
          'v': 1,
          'type': 'fileStart',
          'row': _fileRow('recv-6'),
          'encSize': 25,
          'chunkSize': 10,
          'total': 3,
        }),
        isTrue,
      );
      expect(
        receiver.handleFileChunk(<String, dynamic>{
          'v': 1,
          'type': 'fileChunk',
          'historyId': 'recv-6',
          'seq': 0,
          'data': base64Url.encode(List<int>.filled(10, 5)),
        }),
        isTrue,
      );
      receiver.abort();

      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(await fileStore.loadEncryptedPath('recv-6'), isNull);
      expect(await tmpPartPaths(), isEmpty);
    });

    test('新 fileStart 抢占旧传输：旧 .part 清理，新 .enc 落盘', () async {
      final receiver = LanFileReceiver(sink: saveSink);
      expect(
        receiver.handleFileStart(<String, dynamic>{
          'v': 1,
          'type': 'fileStart',
          'row': _fileRow('recv-old'),
          'encSize': 25,
          'chunkSize': 10,
          'total': 3,
        }),
        isTrue,
      );
      expect(
        receiver.handleFileChunk(<String, dynamic>{
          'v': 1,
          'type': 'fileChunk',
          'historyId': 'recv-old',
          'seq': 0,
          'data': base64Url.encode(List<int>.filled(10, 6)),
        }),
        isTrue,
      );
      // 新 fileStart 抢占
      final newBytes = Uint8List.fromList(List<int>.generate(10, (i) => i));
      expect(
        receiver.handleFileStart(<String, dynamic>{
          'v': 1,
          'type': 'fileStart',
          'row': _fileRow('recv-new'),
          'encSize': 10,
          'chunkSize': 10,
          'total': 1,
        }),
        isTrue,
      );
      expect(
        receiver.handleFileChunk(<String, dynamic>{
          'v': 1,
          'type': 'fileChunk',
          'historyId': 'recv-new',
          'seq': 0,
          'data': base64Url.encode(newBytes),
        }),
        isTrue,
      );

      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(await fileStore.loadEncryptedPath('recv-old'), isNull);
      final landed = await fileStore.loadEncryptedPath('recv-new');
      expect(landed, isNotNull);
      expect(File(landed!).readAsBytesSync(), equals(newBytes));
      expect(await tmpPartPaths(), isEmpty);
    });

    test('fileStart 校验：type/encSize/total/chunkSize/historyId 违规全部拒绝', () {
      final receiver = LanFileReceiver(sink: saveSink);
      Map<String, dynamic> start({Object? row, Object? encSize, Object? total, Object? chunkSize}) {
        return <String, dynamic>{
          'v': 1,
          'type': 'fileStart',
          'row': row ?? _fileRow('v-1'),
          'encSize': encSize ?? 10,
          'chunkSize': chunkSize ?? 10,
          'total': total ?? 1,
        };
      }

      // 非 file 行
      expect(
        receiver.handleFileStart(start(row: {'history_id': 'v-2', 'type': 'text'})),
        isFalse,
      );
      // 缺 history_id
      expect(
        receiver.handleFileStart(start(row: {'type': 'file'})),
        isFalse,
      );
      // encSize 为 0
      expect(receiver.handleFileStart(start(encSize: 0)), isFalse);
      // encSize 超过 15MiB+1024
      expect(
        receiver.handleFileStart(start(encSize: LanConstants.lanMaxFileBytes + 1025)),
        isFalse,
      );
      // chunkSize 超过 lanFileChunkBytes
      expect(
        receiver.handleFileStart(start(chunkSize: LanConstants.lanFileChunkBytes + 1)),
        isFalse,
      );
      // total 与 ceil(encSize/chunkSize) 不匹配
      expect(receiver.handleFileStart(start(encSize: 25, chunkSize: 10, total: 2)), isFalse);
      // total 超过 lanMaxFileChunks
      expect(
        receiver.handleFileStart(
          start(
            encSize: LanConstants.lanFileChunkBytes * LanConstants.lanMaxFileChunks,
            chunkSize: LanConstants.lanFileChunkBytes,
            total: LanConstants.lanMaxFileChunks + 1,
          ),
        ),
        isFalse,
      );
      // 无 sink（未接线）
      final noSink = LanFileReceiver();
      expect(noSink.handleFileStart(start()), isFalse);
    });
  });

  group('writeFileFrames (initiator 帧序)', () {
    test('fileStart 在前 + N×fileChunk 帧序/base64 正确，可被 receiver 完整重组', () async {
      final cipherBytes = Uint8List.fromList(
        List<int>.generate(2 * 1024 * 1024 + 500 * 1024, (i) => (i * 31) % 256),
      );
      final encPath = '${tempDir.path}/src.enc';
      File(encPath).writeAsBytesSync(cipherBytes);

      final frames = <Map<String, dynamic>>[];
      final row = _fileRow('send-1');

      await writeFileFrames(
        write: frames.add,
        row: row,
        encryptedPath: encPath,
        encSize: cipherBytes.length,
      );

      // fileStart 帧字段
      expect(frames.first['type'], 'fileStart');
      expect(frames.first['row'], row);
      expect(frames.first['encSize'], cipherBytes.length);
      expect(frames.first['chunkSize'], LanConstants.lanFileChunkBytes);
      expect(frames.first['total'], 3);

      // chunk 帧序与 base64 内容
      final chunkFrames = frames.sublist(1);
      expect(chunkFrames, hasLength(3));
      final reassembled = <int>[];
      for (var i = 0; i < chunkFrames.length; i++) {
        expect(chunkFrames[i]['type'], 'fileChunk');
        expect(chunkFrames[i]['historyId'], 'send-1');
        expect(chunkFrames[i]['seq'], i);
        final decoded = base64Url.decode(chunkFrames[i]['data'] as String);
        expect(decoded.length, lessThanOrEqualTo(LanConstants.lanFileChunkBytes));
        reassembled.addAll(decoded);
      }
      expect(Uint8List.fromList(reassembled), equals(cipherBytes));

      // 直接把帧喂给 receiver：端到端 .enc 内容一致
      final receiver = LanFileReceiver(sink: saveSink);
      expect(receiver.handleFileStart(frames.first), isTrue);
      for (final frame in chunkFrames) {
        expect(receiver.handleFileChunk(frame), isTrue);
      }
      await Future<void>.delayed(const Duration(milliseconds: 80));
      final landed = await fileStore.loadEncryptedPath('send-1');
      expect(landed, isNotNull);
      expect(File(landed!).readAsBytesSync(), equals(cipherBytes));
    });
  });
}
