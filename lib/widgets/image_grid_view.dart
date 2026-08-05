import 'package:flutter/material.dart';
import '../models/clipboard_entry.dart';
import '../screens/image_preview_screen.dart';

class ImageGridView extends StatelessWidget {
  final List<ClipboardEntry> entries;

  const ImageGridView({super.key, required this.entries});

  String _formatAbsoluteTime(DateTime time) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final entryDay = DateTime(time.year, time.month, time.day);
    final timeStr = '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';

    if (entryDay == today) return timeStr;
    if (entryDay == today.subtract(const Duration(days: 1))) return '昨天 $timeStr';
    return '${time.month}月${time.day}日 $timeStr';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (entries.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.image_outlined, size: 64,
              color: theme.colorScheme.outlineVariant),
            const SizedBox(height: 12),
            Text(
              '暂无图片记录',
              style: theme.textTheme.titleMedium?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '复制图片后自动同步到这里',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.outlineVariant,
              ),
            ),
          ],
        ),
      );
    }

    return GridView.builder(
      padding: const EdgeInsets.all(8),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: _getCrossAxisCount(context),
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
      ),
      itemCount: entries.length,
      itemBuilder: (context, index) {
        final entry = entries[index];
        return _ImageGridItem(
          entry: entry,
          timeLabel: _formatAbsoluteTime(entry.timestamp),
          onTap: () => _openPreview(context, entry),
        );
      },
    );
  }

  int _getCrossAxisCount(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    if (width > 900) return 4;
    if (width > 600) return 3;
    return 2;
  }

  void _openPreview(BuildContext context, ClipboardEntry entry) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ImagePreviewScreen(entryId: entry.id),
      ),
    );
  }
}

class _ImageGridItem extends StatelessWidget {
  final ClipboardEntry entry;
  final String timeLabel;
  final VoidCallback onTap;

  const _ImageGridItem({
    required this.entry,
    required this.timeLabel,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Container(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (entry.imageThumbBytes != null)
                Image.memory(
                  entry.imageThumbBytes!,
                  fit: BoxFit.cover,
                  errorBuilder: (context, error, stackTrace) => Center(
                    child: Icon(
                      Icons.broken_image_outlined,
                      size: 40,
                      color: Theme.of(context).colorScheme.outlineVariant,
                    ),
                  ),
                )
              else
                Center(
                  child: Icon(
                    Icons.image,
                    size: 40,
                    color: Theme.of(context).colorScheme.outlineVariant,
                  ),
                ),
              // Time label
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.bottomCenter,
                      end: Alignment.topCenter,
                      colors: [
                        Colors.black.withValues(alpha: 0.6),
                        Colors.transparent,
                      ],
                    ),
                  ),
                  child: Text(
                    timeLabel,
                    style: const TextStyle(fontSize: 11, color: Colors.white),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
              // Pin badge
              if (entry.isPinned)
                Positioned(
                  top: 6,
                  left: 6,
                  child: Container(
                    padding: const EdgeInsets.all(3),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.5),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.push_pin, size: 12, color: Colors.orange),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
