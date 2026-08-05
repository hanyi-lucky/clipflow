import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:clipflow/models/clipboard_entry.dart';
import 'package:clipflow/models/file_download_progress.dart';
import 'package:clipflow/providers/clipboard_provider.dart';
import 'package:clipflow/widgets/clipboard_item.dart';
import 'package:clipflow/widgets/search_bar.dart';

ClipboardEntry _fileEntry({
  String id = 'file-1',
  String? fileName = 'report.pdf',
  int? fileSize = 2048,
  String? mimeType = 'application/pdf',
}) {
  return ClipboardEntry(
    id: id,
    content: '',
    sourceDeviceId: 'd1',
    sourceDeviceName: 'Mac',
    timestamp: DateTime(2026, 1, 1),
    type: ContentType.file,
    fileName: fileName,
    fileSize: fileSize,
    mimeType: mimeType,
  );
}

Widget _wrap(Widget child) {
  return MaterialApp(home: Scaffold(body: child));
}

void main() {
  test('formatFileSize covers B, KB and MB', () {
    expect(formatFileSize(null), '未知大小');
    expect(formatFileSize(0), '0 B');
    expect(formatFileSize(2048), '2.0 KB');
    expect(formatFileSize(5 * 1024 * 1024), '5.0 MB');
  });

  testWidgets('file row shows name, size, MIME and PDF icon', (tester) async {
    await tester.pumpWidget(_wrap(ClipboardItem(entry: _fileEntry())));

    expect(find.text('report.pdf'), findsOneWidget);
    expect(find.text('application/pdf'), findsOneWidget);
    expect(find.text('2.0 KB'), findsOneWidget);
    expect(find.byIcon(Icons.picture_as_pdf_outlined), findsOneWidget);
  });

  testWidgets('file icons map by extension and MIME', (tester) async {
    final cases = <(String, String?, IconData)>[
      ('notes.docx', null, Icons.description_outlined),
      ('data.xlsx', null, Icons.table_chart_outlined),
      ('deck.pptx', null, Icons.slideshow_outlined),
      ('bundle.zip', null, Icons.folder_zip_outlined),
      ('song.mp3', null, Icons.audio_file_outlined),
      ('movie.mp4', null, Icons.video_file_outlined),
      ('main.dart', null, Icons.code_rounded),
      ('photo.png', null, Icons.image_outlined),
      ('unknown.bin', null, Icons.insert_drive_file_outlined),
      ('no-extension', 'application/pdf', Icons.picture_as_pdf_outlined),
    ];

    for (final c in cases) {
      await tester.pumpWidget(
        _wrap(
          ClipboardItem(
            entry: _fileEntry(fileName: c.$1, mimeType: c.$2, fileSize: null),
          ),
        ),
      );
      expect(
        find.byIcon(c.$3),
        findsOneWidget,
        reason: '${c.$1} should use ${c.$3}',
      );
    }
  });

  testWidgets('downloading shows progress bar and cancel button', (
    tester,
  ) async {
    var cancelled = false;
    final progress = FileDownloadProgress(
      entryId: 'file-1',
      fileName: 'report.pdf',
      totalBytes: 100,
      receivedBytes: 40,
      status: FileTransferStatus.downloading,
    );

    await tester.pumpWidget(
      _wrap(
        ClipboardItem(
          entry: _fileEntry(),
          fileDownloadProgress: progress,
          onCancelDownload: () => cancelled = true,
        ),
      ),
    );

    final indicator = tester.widget<LinearProgressIndicator>(
      find.byType(LinearProgressIndicator),
    );
    expect(indicator.value, closeTo(0.4, 0.001));
    expect(find.textContaining('下载中 40 B / 100 B'), findsOneWidget);

    await tester.tap(find.byTooltip('取消下载'));
    expect(cancelled, isTrue);
  });

  testWidgets('failed shows error and retry button', (tester) async {
    var retried = false;
    final progress = FileDownloadProgress(
      entryId: 'file-1',
      fileName: 'report.pdf',
      status: FileTransferStatus.failed,
      error: '网络连接失败',
    );

    await tester.pumpWidget(
      _wrap(
        ClipboardItem(
          entry: _fileEntry(),
          fileDownloadProgress: progress,
          onRetryDownload: () => retried = true,
        ),
      ),
    );

    expect(find.text('网络连接失败'), findsOneWidget);
    await tester.tap(find.byTooltip('重试下载'));
    expect(retried, isTrue);
  });

  testWidgets('cancelled shows retry action', (tester) async {
    final progress = FileDownloadProgress(
      entryId: 'file-1',
      fileName: 'report.pdf',
      status: FileTransferStatus.cancelled,
      error: '已取消',
    );

    await tester.pumpWidget(
      _wrap(
        ClipboardItem(
          entry: _fileEntry(),
          fileDownloadProgress: progress,
          onRetryDownload: () {},
        ),
      ),
    );

    expect(find.text('已取消'), findsOneWidget);
    expect(find.byTooltip('重试下载'), findsOneWidget);
  });

  testWidgets('processing shows progress state', (tester) async {
    final progress = FileDownloadProgress(
      entryId: 'file-1',
      fileName: 'report.pdf',
      status: FileTransferStatus.processing,
    );

    await tester.pumpWidget(
      _wrap(ClipboardItem(entry: _fileEntry(), fileDownloadProgress: progress)),
    );

    expect(find.text('处理中'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('completed hides progress UI', (tester) async {
    final progress = FileDownloadProgress(
      entryId: 'file-1',
      fileName: 'report.pdf',
      totalBytes: 100,
      receivedBytes: 100,
      status: FileTransferStatus.completed,
    );

    await tester.pumpWidget(
      _wrap(ClipboardItem(entry: _fileEntry(), fileDownloadProgress: progress)),
    );

    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.byTooltip('取消下载'), findsNothing);
    expect(find.byTooltip('重试下载'), findsNothing);
  });

  testWidgets('cancel and retry buttons hidden without callbacks', (
    tester,
  ) async {
    final progress = FileDownloadProgress(
      entryId: 'file-1',
      fileName: 'report.pdf',
      totalBytes: 100,
      receivedBytes: 40,
      status: FileTransferStatus.downloading,
    );

    await tester.pumpWidget(
      _wrap(ClipboardItem(entry: _fileEntry(), fileDownloadProgress: progress)),
    );

    expect(find.byTooltip('取消下载'), findsNothing);
    expect(find.byTooltip('重试下载'), findsNothing);
  });

  testWidgets('text entry keeps plain content rendering', (tester) async {
    final entry = ClipboardEntry(
      id: 'text-1',
      content: 'Hello world',
      sourceDeviceId: 'd1',
      sourceDeviceName: 'Mac',
      timestamp: DateTime(2026, 1, 1),
      type: ContentType.text,
    );

    await tester.pumpWidget(_wrap(ClipboardItem(entry: entry)));

    expect(find.text('Hello world', findRichText: true), findsOneWidget);
    expect(find.byIcon(Icons.insert_drive_file_outlined), findsNothing);
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });

  testWidgets('search bar file option is enabled and applies file filter', (
    tester,
  ) async {
    final provider = ClipboardProvider();
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: provider,
        child: const MaterialApp(home: Scaffold(body: HistorySearchBar())),
      ),
    );

    expect(provider.activeTypeFilter, isNull);

    await tester.tap(find.byIcon(Icons.category_outlined));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(InkWell, '文件'));
    await tester.pumpAndSettle();

    expect(provider.activeTypeFilter, ContentType.file);
    expect(find.text('文件'), findsOneWidget);

    provider.dispose();
  });
}
