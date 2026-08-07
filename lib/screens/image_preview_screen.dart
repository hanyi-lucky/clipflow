import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../providers/clipboard_provider.dart';
import '../l10n/app_strings.dart';

/// 全屏图片查看器：加载态 / 错误态 / InteractiveViewer / 复制
class ImagePreviewScreen extends StatefulWidget {
  final String entryId;

  const ImagePreviewScreen({super.key, required this.entryId});

  @override
  State<ImagePreviewScreen> createState() => _ImagePreviewScreenState();
}

class _ImagePreviewScreenState extends State<ImagePreviewScreen> {
  late Future<Uint8List?> _future;

  @override
  void initState() {
    super.initState();
    _future = ClipboardProvider.of(context, listen: false)
        .loadFullImageBytes(widget.entryId);
  }

  Future<void> _copyToClipboard() async {
    final provider = ClipboardProvider.of(context, listen: false);
    await provider.copyEntry(widget.entryId);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text(AppStrings.copiedToClipboard)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text(AppStrings.imagePreviewTitle),
        actions: [
          IconButton(
            icon: const Icon(Icons.copy_rounded),
            tooltip: AppStrings.commonCopy,
            onPressed: _copyToClipboard,
          ),
        ],
      ),
      body: FutureBuilder<Uint8List?>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(
              child: CircularProgressIndicator(color: Colors.white70),
            );
          }

          final bytes = snapshot.data;
          if (bytes == null || bytes.isEmpty) {
            return const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.broken_image_outlined, size: 64, color: Colors.white30),
                  SizedBox(height: 12),
                  Text(
                    AppStrings.imageDecryptFailed,
                    style: TextStyle(color: Colors.white70),
                  ),
                ],
              ),
            );
          }

          return InteractiveViewer(
            maxScale: 5,
            child: Center(
              child: Image.memory(
                bytes,
                fit: BoxFit.contain,
                errorBuilder: (context, error, stackTrace) => const Center(
                  child: Text(
                    AppStrings.imageLoadFailed,
                    style: TextStyle(color: Colors.white70),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
