import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:clipflow/models/clipboard_file.dart';
import 'package:clipflow/repositories/local_storage.dart';
import 'package:clipflow/services/clipboard_monitor.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  ClipboardFile file({
    String path = '/tmp/design.pdf',
    int? size = 2048,
    int? lastModified = 1700000000000,
  }) {
    return ClipboardFile(
      path: path,
      name: 'design.pdf',
      mimeType: 'application/pdf',
      size: size,
      lastModified: lastModified,
    );
  }

  group('ClipboardMonitor 文件在途签名守卫', () {
    test('连续 tick 相同文件不重复触发 onFilesChanged（不重置 debounce 的根因）', () async {
      final events = <List<ClipboardFile>>[];
      final monitor = ClipboardMonitor(onChanged: (_) {});
      monitor.onFilesChanged = events.add;

      final files = [file()];
      await monitor.syncClipboard(preReadFiles: files);
      expect(events, hasLength(1));

      // 上传仍在途（recordFileSignature 尚未调用）：下一 tick 不再触发
      await monitor.syncClipboard(preReadFiles: files);
      expect(events, hasLength(1));
    });

    test('clearFileSignature（失败）后下一 tick 重新触发，可重试', () async {
      final events = <List<ClipboardFile>>[];
      final monitor = ClipboardMonitor(onChanged: (_) {});
      monitor.onFilesChanged = events.add;

      final files = [file()];
      await monitor.syncClipboard(preReadFiles: files);
      expect(events, hasLength(1));

      // 上传失败：清除签名与在途标记 → 下一 tick 重新检测
      monitor.clearFileSignature(files.first);
      await monitor.syncClipboard(preReadFiles: files);
      expect(events, hasLength(2));
    });

    test('recordFileSignature（成功）后不再触发（已有语义不变）', () async {
      final events = <List<ClipboardFile>>[];
      final monitor = ClipboardMonitor(onChanged: (_) {});
      monitor.onFilesChanged = events.add;

      final files = [file()];
      await monitor.syncClipboard(preReadFiles: files);
      expect(events, hasLength(1));

      // 上传成功：记录签名 → 后续 tick 被 isFileSignatureHandled 短路
      monitor.recordFileSignature(files.first);
      await monitor.syncClipboard(preReadFiles: files);
      expect(events, hasLength(1));
    });

    test('不同文件签名不互相抑制（仍可触发）', () async {
      final events = <List<ClipboardFile>>[];
      final monitor = ClipboardMonitor(onChanged: (_) {});
      monitor.onFilesChanged = events.add;

      await monitor.syncClipboard(preReadFiles: [file(path: '/tmp/a.pdf')]);
      // 同路径但 size/mtime 变化 = 新签名 → 重新触发
      await monitor.syncClipboard(
        preReadFiles: [file(path: '/tmp/a.pdf', size: 4096)],
      );
      expect(events, hasLength(2));
    });

    test('loadState 清空在途集合（重启不残留）', () async {
      SharedPreferences.setMockInitialValues({});
      final storage = LocalStorage(await SharedPreferences.getInstance());
      final events = <List<ClipboardFile>>[];
      final monitor = ClipboardMonitor(
        onChanged: (_) {},
        storage: storage,
      );
      monitor.onFilesChanged = events.add;

      final files = [file()];
      await monitor.syncClipboard(preReadFiles: files);
      expect(events, hasLength(1));

      // 模拟重启：loadState 后旧在途签名不残留 → 同一文件可再次触发
      monitor.loadState();
      await monitor.syncClipboard(preReadFiles: files);
      expect(events, hasLength(2));
    });

    test('Android onClipboardFilesChanged 通道同样受在途守卫约束', () async {
      final events = <List<ClipboardFile>>[];
      final monitor = ClipboardMonitor(onChanged: (_) {});
      monitor.onFilesChanged = events.add;

      final raw = <Map<String, dynamic>>[
        <String, dynamic>{
          'path': '/content://media/external/file/1',
          'name': 'a.png',
          'size': 1024,
          'lastModified': 1700000000000,
        },
      ];
      await monitor.debugHandleAndroidMethodCall(
        MethodCall('onClipboardFilesChanged', raw),
      );
      expect(events, hasLength(1));

      await monitor.debugHandleAndroidMethodCall(
        MethodCall('onClipboardFilesChanged', raw),
      );
      expect(events, hasLength(1));
    });
  });
}
