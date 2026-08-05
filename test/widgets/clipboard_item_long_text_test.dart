import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:clipflow/models/clipboard_entry.dart';
import 'package:clipflow/widgets/clipboard_item.dart';

Widget _wrap(Widget child) {
  return MaterialApp(home: Scaffold(body: child));
}

ClipboardEntry _textEntry(String content) {
  return ClipboardEntry(
    id: 'text-long',
    content: content,
    sourceDeviceId: 'd1',
    sourceDeviceName: 'Mac',
    timestamp: DateTime(2026, 1, 1),
    type: ContentType.text,
  );
}

void main() {
  testWidgets('long text renders 500-char preview and expands to full content',
      (tester) async {
    final full = 'L' * 600;

    await tester.pumpWidget(_wrap(ClipboardItem(entry: _textEntry(full))));

    expect(find.text('L' * 500, findRichText: true), findsOneWidget);
    expect(find.text('展开 ▼'), findsOneWidget);

    await tester.tap(find.text('展开 ▼'));
    await tester.pump();

    expect(find.text(full, findRichText: true), findsOneWidget);
    expect(find.text('折叠 ▲'), findsOneWidget);
  });

  testWidgets('short text renders fully without preview toggle', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap(ClipboardItem(entry: _textEntry('short'))));

    expect(find.text('short', findRichText: true), findsOneWidget);
    expect(find.text('展开 ▼'), findsNothing);
  });
}
