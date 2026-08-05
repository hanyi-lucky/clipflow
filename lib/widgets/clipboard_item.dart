import 'package:flutter/material.dart';
import '../models/clipboard_entry.dart';

class ClipboardItem extends StatefulWidget {
  final ClipboardEntry entry;
  final bool isMergeMode;
  final bool isSelected;
  final int? selectionOrder;
  final VoidCallback? onTap;
  final VoidCallback? onCopy;
  final VoidCallback? onPin;
  final VoidCallback? onDelete;
  final String? searchQuery;

  const ClipboardItem({
    super.key,
    required this.entry,
    this.isMergeMode = false,
    this.isSelected = false,
    this.selectionOrder,
    this.onTap,
    this.onCopy,
    this.onPin,
    this.onDelete,
    this.searchQuery,
  });

  @override
  State<ClipboardItem> createState() => _ClipboardItemState();
}

class _ClipboardItemState extends State<ClipboardItem> {
  bool _isExpanded = false;

  String _formatTime(DateTime time) {
    final now = DateTime.now();
    final diff = now.difference(time);
    if (diff.inSeconds < 60) return '${diff.inSeconds}秒前';
    if (diff.inMinutes < 60) return '${diff.inMinutes}分钟前';
    if (diff.inHours < 24) return '${diff.inHours}小时前';
    return '${diff.inDays}天前';
  }

  IconData _getDeviceIcon(String platform) {
    switch (platform.toLowerCase()) {
      case 'macos': return Icons.laptop_mac;
      case 'windows': return Icons.laptop;
      case 'android': return Icons.phone_android;
      case 'ios': return Icons.phone_iphone;
      default: return Icons.device_unknown;
    }
  }

  Widget _buildContent(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final content = widget.entry.content;
    final query = widget.searchQuery?.toLowerCase();

    // 图片行：缩略图块 + 尺寸角标，不参与文本高亮
    if (widget.entry.type == ContentType.image) {
      final thumb = widget.entry.imageThumbBytes;
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: isDark
              ? Colors.white.withValues(alpha: 0.05)
              : Colors.black.withValues(alpha: 0.03),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: thumb != null
                  ? Image.memory(
                      thumb,
                      width: 72,
                      height: 72,
                      fit: BoxFit.cover,
                      errorBuilder: (context, error, stackTrace) =>
                          _imagePlaceholder(theme),
                    )
                  : _imagePlaceholder(theme),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '图片',
                    style: theme.textTheme.titleSmall,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${widget.entry.imageWidth ?? '-'} × '
                    '${widget.entry.imageHeight ?? '-'}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.outline,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    // Build text spans with optional highlight
    TextSpan buildHighlightedText() {
      if (query == null || query.isEmpty) {
        return TextSpan(
          text: content,
          style: theme.textTheme.bodyMedium?.copyWith(height: 1.5),
        );
      }

      final spans = <TextSpan>[];
      final lowerContent = content.toLowerCase();
      int start = 0;

      while (true) {
        final index = lowerContent.indexOf(query, start);
        if (index == -1) {
          if (start < content.length) {
            spans.add(TextSpan(
              text: content.substring(start),
              style: theme.textTheme.bodyMedium?.copyWith(height: 1.5),
            ));
          }
          break;
        }
        if (index > start) {
          spans.add(TextSpan(
            text: content.substring(start, index),
            style: theme.textTheme.bodyMedium?.copyWith(height: 1.5),
          ));
        }
        spans.add(TextSpan(
          text: content.substring(index, index + query.length),
          style: theme.textTheme.bodyMedium?.copyWith(
            height: 1.5,
            backgroundColor: theme.colorScheme.primary.withOpacity(0.25),
            color: theme.colorScheme.primary,
          ),
        ));
        start = index + query.length;
      }

      return TextSpan(children: spans);
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: isDark
            ? Colors.white.withOpacity(0.05)
            : Colors.black.withOpacity(0.03),
        borderRadius: BorderRadius.circular(8),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Check if content exceeds 3 lines
          final textSpan = buildHighlightedText();
          final textPainter = TextPainter(
            text: textSpan,
            maxLines: 3,
            textDirection: TextDirection.ltr,
            textScaler: MediaQuery.textScalerOf(context),
          )..layout(maxWidth: constraints.maxWidth);

          final isOverflow = textPainter.didExceedMaxLines;

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              RichText(
                text: textSpan,
                maxLines: _isExpanded ? null : 3,
                overflow: _isExpanded ? TextOverflow.visible : TextOverflow.ellipsis,
              ),
              if (isOverflow)
                GestureDetector(
                  onTap: () => setState(() => _isExpanded = !_isExpanded),
                  child: Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      _isExpanded ? '折叠 ▲' : '展开 ▼',
                      style: TextStyle(
                        fontSize: 12,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _imagePlaceholder(ThemeData theme) {
    return Container(
      width: 72,
      height: 72,
      color: theme.colorScheme.surfaceContainerHighest,
      child: Icon(
        Icons.image_outlined,
        size: 32,
        color: theme.colorScheme.outlineVariant,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      child: InkWell(
        onTap: widget.onTap,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  if (widget.isMergeMode)
                    Checkbox(
                      value: widget.isSelected,
                      onChanged: (_) => widget.onTap?.call(),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(4),
                      ),
                    )
                  else if (widget.selectionOrder != null)
                    Container(
                      width: 22,
                      height: 22,
                      margin: const EdgeInsets.only(right: 8),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primary,
                        shape: BoxShape.circle,
                      ),
                      child: Center(
                        child: Text(
                          '${widget.selectionOrder}',
                          style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600),
                        ),
                      ),
                    ),
                  Icon(
                    _getDeviceIcon(widget.entry.sourcePlatform),
                    size: 16,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${widget.entry.sourceDeviceName} · ${_formatTime(widget.entry.timestamp)}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.outline,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (widget.entry.isPinned)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.orange.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.push_pin, size: 12, color: Colors.orange),
                          SizedBox(width: 2),
                          Text('置顶', style: TextStyle(fontSize: 10, color: Colors.orange)),
                        ],
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 10),
              _buildContent(context),
              if (!widget.isMergeMode) ...[
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    _ActionChip(
                      icon: widget.entry.isPinned ? Icons.push_pin : Icons.push_pin_outlined,
                      label: widget.entry.isPinned ? '取消置顶' : '置顶',
                      onTap: widget.onPin,
                    ),
                    const SizedBox(width: 4),
                    _ActionChip(
                      icon: Icons.copy_rounded,
                      label: '复制',
                      onTap: widget.onCopy,
                    ),
                    const SizedBox(width: 4),
                    _ActionChip(
                      icon: Icons.delete_outline_rounded,
                      label: '删除',
                      onTap: widget.onDelete,
                      isDestructive: true,
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _ActionChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool isDestructive;

  const _ActionChip({
    required this.icon,
    required this.label,
    this.onTap,
    this.isDestructive = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = isDestructive ? Colors.red : theme.colorScheme.outline;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 3),
            Text(label, style: TextStyle(fontSize: 12, color: color)),
          ],
        ),
      ),
    );
  }
}
