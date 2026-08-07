import 'package:flutter/material.dart';
import '../models/clipboard_entry.dart';
import '../models/file_download_progress.dart';
import '../l10n/app_strings.dart';

const Set<String> _pdfExtensions = {'pdf'};
const Set<String> _docExtensions = {
  'doc', 'docx', 'rtf', 'odt', 'pages', 'txt', 'md', 'text',
};
const Set<String> _sheetExtensions = {
  'xls', 'xlsx', 'csv', 'ods', 'numbers',
};
const Set<String> _slideExtensions = {
  'ppt', 'pptx', 'odp', 'key',
};
const Set<String> _archiveExtensions = {
  'zip', 'rar', '7z', 'tar', 'gz', 'bz2', 'xz', 'tgz', 'iso',
};
const Set<String> _audioExtensions = {
  'mp3', 'wav', 'aac', 'flac', 'm4a', 'ogg', 'opus', 'wma',
};
const Set<String> _videoExtensions = {
  'mp4', 'mov', 'mkv', 'avi', 'webm', 'flv', 'wmv', 'm4v', 'mpg', 'mpeg',
};
const Set<String> _codeExtensions = {
  'dart', 'js', 'ts', 'py', 'java', 'c', 'cpp', 'h', 'hpp', 'swift', 'kt',
  'rb', 'go', 'rs', 'html', 'css', 'json', 'xml', 'yaml', 'yml', 'sh', 'bat',
  'ps1', 'sql', 'php', 'vue', 'jsx', 'tsx', 'lua', 'r',
};
const Set<String> _imageExtensions = {
  'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp', 'heic', 'heif', 'svg', 'tiff',
  'ico',
};

/// 按扩展名/MIME 映射文件类型图标，未知类型回退默认文件图标。
IconData fileTypeIcon(String? fileName, String? mimeType) {
  final name = fileName ?? '';
  final dot = name.lastIndexOf('.');
  final ext = dot >= 0 && dot < name.length - 1
      ? name.substring(dot + 1).toLowerCase()
      : '';
  final mime = mimeType?.toLowerCase() ?? '';

  if (_pdfExtensions.contains(ext) || mime.contains('pdf')) {
    return Icons.picture_as_pdf_outlined;
  }
  if (_docExtensions.contains(ext) ||
      mime.startsWith('text/') ||
      mime.contains('msword') ||
      mime.contains('wordprocessingml')) {
    return Icons.description_outlined;
  }
  if (_sheetExtensions.contains(ext) ||
      mime.contains('spreadsheetml') ||
      mime.contains('ms-excel') ||
      mime.contains('text/csv')) {
    return Icons.table_chart_outlined;
  }
  if (_slideExtensions.contains(ext) ||
      mime.contains('presentationml') ||
      mime.contains('ms-powerpoint')) {
    return Icons.slideshow_outlined;
  }
  if (_archiveExtensions.contains(ext) ||
      mime.contains('zip') ||
      mime.contains('x-rar') ||
      mime.contains('x-7z') ||
      mime.contains('x-tar') ||
      mime.contains('x-gzip') ||
      mime.contains('x-bzip')) {
    return Icons.folder_zip_outlined;
  }
  if (_audioExtensions.contains(ext) || mime.startsWith('audio/')) {
    return Icons.audio_file_outlined;
  }
  if (_videoExtensions.contains(ext) || mime.startsWith('video/')) {
    return Icons.video_file_outlined;
  }
  if (_codeExtensions.contains(ext) ||
      mime.contains('javascript') ||
      mime.contains('application/json') ||
      mime.contains('xml')) {
    return Icons.code_rounded;
  }
  if (_imageExtensions.contains(ext) || mime.startsWith('image/')) {
    return Icons.image_outlined;
  }
  return Icons.insert_drive_file_outlined;
}

String formatFileSize(int? bytes) {
  if (bytes == null || bytes < 0) return AppStrings.fileSizeUnknown;
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) {
    return '${(bytes / 1024).toStringAsFixed(1)} KB';
  }
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
}

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
  final FileDownloadProgress? fileDownloadProgress;
  final VoidCallback? onCancelDownload;
  final VoidCallback? onRetryDownload;

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
    this.fileDownloadProgress,
    this.onCancelDownload,
    this.onRetryDownload,
  });

  @override
  State<ClipboardItem> createState() => _ClipboardItemState();
}

class _ClipboardItemState extends State<ClipboardItem> {
  bool _isExpanded = false;

  String _formatTime(DateTime time) {
    final now = DateTime.now();
    final diff = now.difference(time);
    if (diff.inSeconds < 60) {
      return AppStrings.clipboardTimeSecondsAgo(diff.inSeconds);
    }
    if (diff.inMinutes < 60) {
      return AppStrings.clipboardTimeMinutesAgo(diff.inMinutes);
    }
    if (diff.inHours < 24) {
      return AppStrings.clipboardTimeHoursAgo(diff.inHours);
    }
    return AppStrings.clipboardTimeDaysAgo(diff.inDays);
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
    // 超长文本行只渲染前 500 字符预览，展开态才渲染完整内容（已受 50000 上限约束）
    final previewContent = content.length > 500
        ? content.substring(0, 500)
        : content;
    final displayContent = _isExpanded ? content : previewContent;
    final previewTruncated = !_isExpanded && content.length > 500;

    // 文件行：图标 + 文件名/大小/MIME + 下载进度，不进入图片网格
    if (widget.entry.type == ContentType.file) {
      return _FileEntryView(
        fileName: widget.entry.fileName,
        fileSize: widget.entry.fileSize,
        mimeType: widget.entry.mimeType,
        fileDownloadProgress: widget.fileDownloadProgress,
        onCancelDownload: widget.onCancelDownload,
        onRetryDownload: widget.onRetryDownload,
      );
    }

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
                    AppStrings.imageLabel,
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
          text: displayContent,
          style: theme.textTheme.bodyMedium?.copyWith(height: 1.5),
        );
      }

      final spans = <TextSpan>[];
      final lowerContent = displayContent.toLowerCase();
      int start = 0;

      while (true) {
        final index = lowerContent.indexOf(query, start);
        if (index == -1) {
          if (start < displayContent.length) {
            spans.add(TextSpan(
              text: displayContent.substring(start),
              style: theme.textTheme.bodyMedium?.copyWith(height: 1.5),
            ));
          }
          break;
        }
        if (index > start) {
          spans.add(TextSpan(
            text: displayContent.substring(start, index),
            style: theme.textTheme.bodyMedium?.copyWith(height: 1.5),
          ));
        }
        spans.add(TextSpan(
          text: displayContent.substring(index, index + query.length),
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
              if (isOverflow || previewTruncated)
                GestureDetector(
                  onTap: () => setState(() => _isExpanded = !_isExpanded),
                  child: Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      _isExpanded
                          ? AppStrings.collapseContent
                          : AppStrings.expandContent,
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
                      AppStrings.deviceTimeSubtitle(
                        widget.entry.sourceDeviceName,
                        _formatTime(widget.entry.timestamp),
                      ),
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
                          Text(
                            AppStrings.pinAction,
                            style: TextStyle(fontSize: 10, color: Colors.orange),
                          ),
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
                      label: widget.entry.isPinned
                          ? AppStrings.unpinAction
                          : AppStrings.pinAction,
                      onTap: widget.onPin,
                    ),
                    const SizedBox(width: 4),
                    _ActionChip(
                      icon: Icons.copy_rounded,
                      label: AppStrings.commonCopy,
                      onTap: widget.onCopy,
                    ),
                    const SizedBox(width: 4),
                    _ActionChip(
                      icon: Icons.delete_outline_rounded,
                      label: AppStrings.commonDelete,
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

class _FileEntryView extends StatelessWidget {
  final String? fileName;
  final int? fileSize;
  final String? mimeType;
  final FileDownloadProgress? fileDownloadProgress;
  final VoidCallback? onCancelDownload;
  final VoidCallback? onRetryDownload;

  const _FileEntryView({
    this.fileName,
    this.fileSize,
    this.mimeType,
    this.fileDownloadProgress,
    this.onCancelDownload,
    this.onRetryDownload,
  });

  bool _hasVisibleProgress(FileDownloadProgress? progress) {
    if (progress == null) return false;
    switch (progress.status) {
      case FileTransferStatus.downloading:
      case FileTransferStatus.processing:
      case FileTransferStatus.failed:
      case FileTransferStatus.cancelled:
        return true;
      case FileTransferStatus.pending:
      case FileTransferStatus.completed:
        return false;
    }
  }

  String _fileMetaLabel() {
    final mime = mimeType?.trim() ?? '';
    if (mime.isNotEmpty) return mime;
    final name = fileName ?? '';
    final dot = name.lastIndexOf('.');
    if (dot >= 0 && dot < name.length - 1) {
      return AppStrings.fileMetaExtension(
        name.substring(dot + 1).toUpperCase(),
      );
    }
    return AppStrings.fileGenericLabel;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final progress = fileDownloadProgress;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: isDark
            ? Colors.white.withValues(alpha: 0.05)
            : Colors.black.withValues(alpha: 0.03),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  fileTypeIcon(fileName, mimeType),
                  size: 22,
                  color: theme.colorScheme.primary,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      fileName ?? AppStrings.fileNameUntitled,
                      style: theme.textTheme.titleSmall,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _fileMetaLabel(),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.outline,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text(
                formatFileSize(fileSize),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
            ],
          ),
          if (_hasVisibleProgress(progress)) ...[
            const SizedBox(height: 10),
            _FileProgressSection(
              progress: progress!,
              onCancelDownload: onCancelDownload,
              onRetryDownload: onRetryDownload,
            ),
          ],
        ],
      ),
    );
  }
}

class _FileProgressSection extends StatelessWidget {
  final FileDownloadProgress progress;
  final VoidCallback? onCancelDownload;
  final VoidCallback? onRetryDownload;

  const _FileProgressSection({
    required this.progress,
    this.onCancelDownload,
    this.onRetryDownload,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    switch (progress.status) {
      case FileTransferStatus.downloading:
        final total = progress.totalBytes;
        final value = (total != null && total > 0)
            ? (progress.receivedBytes / total).clamp(0.0, 1.0).toDouble()
            : null;
        return Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  LinearProgressIndicator(
                    value: value,
                    minHeight: 4,
                    borderRadius: BorderRadius.circular(2),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    AppStrings.fileDownloading(
                      formatFileSize(progress.receivedBytes),
                      formatFileSize(total),
                    ),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            if (onCancelDownload != null)
              IconButton(
                onPressed: onCancelDownload,
                tooltip: AppStrings.cancelDownloadTooltip,
                visualDensity: VisualDensity.compact,
                icon: Icon(
                  Icons.close_rounded,
                  size: 18,
                  color: cs.onSurfaceVariant,
                ),
              ),
          ],
        );
      case FileTransferStatus.processing:
        return Row(
          children: [
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 10),
            Text(
              AppStrings.fileProcessing,
              style: theme.textTheme.bodySmall?.copyWith(
                color: cs.onSurfaceVariant,
              ),
            ),
          ],
        );
      case FileTransferStatus.failed:
        return Row(
          children: [
            Expanded(
              child: Text(
                progress.error ?? AppStrings.fileDownloadFailed,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(color: cs.error),
              ),
            ),
            if (onRetryDownload != null)
              IconButton(
                onPressed: onRetryDownload,
                tooltip: AppStrings.retryDownloadTooltip,
                visualDensity: VisualDensity.compact,
                icon: Icon(
                  Icons.refresh_rounded,
                  size: 18,
                  color: cs.primary,
                ),
              ),
          ],
        );
      case FileTransferStatus.cancelled:
        return Row(
          children: [
            Expanded(
              child: Text(
                progress.error ?? AppStrings.fileCancelled,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: cs.onSurfaceVariant,
                ),
              ),
            ),
            if (onRetryDownload != null)
              IconButton(
                onPressed: onRetryDownload,
                tooltip: AppStrings.retryDownloadTooltip,
                visualDensity: VisualDensity.compact,
                icon: Icon(
                  Icons.refresh_rounded,
                  size: 18,
                  color: cs.primary,
                ),
              ),
          ],
        );
      case FileTransferStatus.pending:
      case FileTransferStatus.completed:
        return const SizedBox.shrink();
    }
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
