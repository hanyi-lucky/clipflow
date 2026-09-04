import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/clipboard_entry.dart';
import '../providers/clipboard_provider.dart';
import '../widgets/clipboard_item.dart';
import '../l10n/app_strings.dart';

class TrashScreen extends StatefulWidget {
  const TrashScreen({super.key});

  @override
  State<TrashScreen> createState() => _TrashScreenState();
}

class _TrashScreenState extends State<TrashScreen> {
  List<Map<String, dynamic>> _trashEntries = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadTrash();
  }

  Future<void> _loadTrash() async {
    final provider = context.read<ClipboardProvider>();
    final entries = await provider.getTrashEntries();
    if (mounted) {
      setState(() {
        _trashEntries = entries;
        _isLoading = false;
      });
    }
  }

  String _formatDeletedTime(int deletedAt) {
    final deletedTime = DateTime.fromMillisecondsSinceEpoch(deletedAt);
    final now = DateTime.now();
    final diff = now.difference(deletedTime);

    if (diff.inMinutes < 1) return AppStrings.trashDeletedJustNow;
    if (diff.inMinutes < 60) {
      return AppStrings.trashDeletedMinutesAgo(diff.inMinutes);
    }
    if (diff.inHours < 24) {
      return AppStrings.trashDeletedHoursAgo(diff.inHours);
    }
    return AppStrings.trashDeletedDaysAgo(diff.inDays);
  }

  String _formatRemainingTime(int deletedAt) {
    final deletedTime = DateTime.fromMillisecondsSinceEpoch(deletedAt);
    final expireTime = deletedTime.add(const Duration(hours: 24));
    final now = DateTime.now();
    final remaining = expireTime.difference(now);

    if (remaining.isNegative) return AppStrings.trashExpiringSoon;
    if (remaining.inHours > 0) {
      return AppStrings.trashRemainingHoursMinutes(
        remaining.inHours,
        remaining.inMinutes % 60,
      );
    }
    return AppStrings.trashRemainingMinutes(remaining.inMinutes);
  }

  String _getContentPreview(String content) {
    return content.length > 100 ? '${content.substring(0, 100)}...' : content;
  }

  Widget _buildTrashPreview(Map<String, dynamic> entry, ThemeData theme) {
    if (entry['type'] == ContentType.file.name) {
      final fileName = entry['file_name'] as String? ?? AppStrings.fileNameUntitled;
      final fileSize = (entry['file_size'] as num?)?.toInt();
      final mimeType = entry['mime_type'] as String?;
      final metaLabel = (mimeType?.trim().isNotEmpty ?? false)
          ? mimeType!
          : AppStrings.fileGenericLabel;
      return Row(
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
                  fileName,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall,
                ),
                const SizedBox(height: 2),
                Text(
                  metaLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.outline,
                  ),
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
      );
    }

    if (entry['type'] == ContentType.image.name) {
      final thumb = entry['imageThumbBytes'] as Uint8List?;
      final width = entry['imageWidth'] as int?;
      final height = entry['imageHeight'] as int?;
      return Row(
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
                Text(AppStrings.imageLabel, style: theme.textTheme.titleSmall),
                if (width != null && height != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    '$width × $height',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.outline,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      );
    }

    return Text(
      _getContentPreview(entry['content'] as String? ?? ''),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: theme.textTheme.bodyMedium?.copyWith(
        height: 1.5,
        color: theme.colorScheme.outline,
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

    return Scaffold(
      appBar: AppBar(
        title: const Text(AppStrings.trashTitle),
        centerTitle: true,
        actions: [
          if (_trashEntries.isNotEmpty) ...[
            IconButton(
              icon: const Icon(Icons.delete_sweep),
              onPressed: _emptyTrash,
              tooltip: AppStrings.emptyTrashTitle,
            ),
            IconButton(
              icon: const Icon(Icons.refresh_rounded),
              onPressed: () {
                setState(() => _isLoading = true);
                _loadTrash();
              },
              tooltip: AppStrings.commonRefresh,
            ),
          ],
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _trashEntries.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.delete_sweep_outlined,
                    size: 80,
                    color: theme.colorScheme.outlineVariant,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    AppStrings.trashEmpty,
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: theme.colorScheme.outline,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    AppStrings.trashEmptyHint,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.outlineVariant,
                    ),
                  ),
                ],
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: _trashEntries.length,
              itemBuilder: (context, index) {
                final entry = _trashEntries[index];
                final deletedAt = entry['deleted_at'] as int? ?? 0;

                return Card(
                  margin: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 4,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(
                              Icons.delete_outline,
                              size: 16,
                              color: theme.colorScheme.error,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                _formatDeletedTime(deletedAt),
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.outline,
                                ),
                              ),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color:
                                    theme.colorScheme.surfaceContainerHighest,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Text(
                                _formatRemainingTime(deletedAt),
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.outline,
                                  fontSize: 11,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: theme.brightness == Brightness.dark
                                ? Colors.white.withOpacity(0.05)
                                : Colors.black.withOpacity(0.03),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: _buildTrashPreview(entry, theme),
                        ),
                        const SizedBox(height: 8),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            _TrashActionChip(
                              icon: Icons.restore_rounded,
                              label: AppStrings.commonRestore,
                              onTap: () => _restoreEntry(entry['id'] as String),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
    );
  }

  Future<void> _emptyTrash() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        surfaceTintColor: Colors.transparent,
        title: const Text(AppStrings.emptyTrashTitle),
        content: const Text(AppStrings.emptyTrashConfirmBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text(AppStrings.commonCancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(AppStrings.dumpAction, style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      final provider = context.read<ClipboardProvider>();
      try {
        final deleted = await provider.emptyTrash();
        if (!mounted) return;
        await _loadTrash();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(AppStrings.trashDumpedCount(deleted)),
              duration: const Duration(seconds: 2),
            ),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(AppStrings.trashDumpFailed('$e')),
              duration: const Duration(seconds: 2),
            ),
          );
        }
      }
    }
  }

  Future<void> _restoreEntry(String id) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        surfaceTintColor: Colors.transparent,
        title: const Text(AppStrings.restoreEntryTitle),
        content: const Text(AppStrings.restoreEntryConfirmBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text(AppStrings.commonCancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(AppStrings.commonRestore, style: TextStyle(color: Colors.green)),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      final provider = context.read<ClipboardProvider>();
      await provider.restoreEntry(id);
      // 重新加载垃圾箱
      await _loadTrash();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(AppStrings.restoreSuccess),
            duration: Duration(seconds: 2),
          ),
        );
      }
    }
  }
}

class _TrashActionChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  const _TrashActionChip({required this.icon, required this.label, this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: Colors.green),
            const SizedBox(width: 3),
            Text(
              label,
              style: const TextStyle(fontSize: 12, color: Colors.green),
            ),
          ],
        ),
      ),
    );
  }
}
