import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:provider/provider.dart';
import 'package:clipflow/providers/clipboard_provider.dart';
import 'package:clipflow/screens/image_preview_screen.dart';

class _StubClipboardProvider extends ClipboardProvider {
  final Uint8List? imageBytes;
  bool copied = false;

  _StubClipboardProvider(this.imageBytes);

  @override
  Future<Uint8List?> loadFullImageBytes(String entryId) async => imageBytes;

  @override
  Future<void> copyEntry(String id) async {
    copied = true;
  }
}

void main() {
  Uint8List pngBytes() {
    final image = img.Image(width: 8, height: 8, numChannels: 3);
    for (var y = 0; y < image.height; y++) {
      for (var x = 0; x < image.width; x++) {
        image.setPixelRgba(x, y, 100, 150, 200, 255);
      }
    }
    return Uint8List.fromList(img.encodePng(image));
  }

  Widget buildApp(ClipboardProvider provider) {
    return ChangeNotifierProvider.value(
      value: provider,
      child: const MaterialApp(
        home: ImagePreviewScreen(entryId: 'img-1'),
      ),
    );
  }

  testWidgets('shows loaded image with InteractiveViewer', (tester) async {
    final provider = _StubClipboardProvider(pngBytes());

    await tester.pumpWidget(buildApp(provider));
    await tester.pumpAndSettle();

    expect(find.byType(InteractiveViewer), findsOneWidget);
    expect(find.byType(Image), findsOneWidget);
  });

  testWidgets('shows decryption failed placeholder when bytes unavailable',
      (tester) async {
    final provider = _StubClipboardProvider(null);

    await tester.pumpWidget(buildApp(provider));
    await tester.pumpAndSettle();

    expect(find.text('图片解密失败'), findsOneWidget);
  });

  testWidgets('copy button copies image back to clipboard', (tester) async {
    final provider = _StubClipboardProvider(pngBytes());

    await tester.pumpWidget(buildApp(provider));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.copy_rounded));
    await tester.pump();

    expect(provider.copied, isTrue);
  });
}
