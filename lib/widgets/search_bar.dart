import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/clipboard_provider.dart';
import '../models/clipboard_entry.dart';
import 'filter_sheet.dart';

class HistorySearchBar extends StatefulWidget {
  const HistorySearchBar({super.key});

  @override
  State<HistorySearchBar> createState() => _HistorySearchBarState();
}

class _HistorySearchBarState extends State<HistorySearchBar> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _showFilterSheet() {
    showModalBottomSheet(
      context: context,
      builder: (_) => const FilterSheet(),
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
    );
  }

  String _typeFilterLabel(ContentType? type) {
    switch (type) {
      case ContentType.text:
        return '▼ 文本';
      case ContentType.image:
        return '▼ 图片';
      case ContentType.file:
        return '▼ 文件';
      default:
        return '▼ 全部';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<ClipboardProvider>(
      builder: (context, provider, _) {
        if (provider.isMergeMode) return const SizedBox.shrink();

        final theme = Theme.of(context);

        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            border: Border(
              bottom: BorderSide(
                color: theme.dividerColor.withOpacity(0.2),
              ),
            ),
          ),
          child: Row(
            children: [
              Icon(Icons.search, size: 20, color: theme.colorScheme.outline),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _controller,
                  focusNode: _focusNode,
                  decoration: InputDecoration(
                    hintText: '搜索历史...',
                    hintStyle: TextStyle(color: theme.colorScheme.outline),
                    border: InputBorder.none,
                    isDense: true,
                    contentPadding: EdgeInsets.zero,
                  ),
                  style: theme.textTheme.bodyMedium,
                  onChanged: (value) => provider.setSearchQuery(value),
                ),
              ),
              if (provider.hasActiveFilters || _controller.text.isNotEmpty)
                IconButton(
                  icon: Icon(Icons.close, size: 18, color: theme.colorScheme.outline),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                  onPressed: () {
                    _controller.clear();
                    provider.clearFilters();
                    _focusNode.unfocus();
                  },
                ),
              const SizedBox(width: 4),
              // Type filter dropdown
              PopupMenuButton<ContentType?>(
                onSelected: (type) => provider.setTypeFilter(type),
                itemBuilder: (context) => [
                  const PopupMenuItem(value: null, child: Text('全部')),
                  const PopupMenuItem(value: ContentType.text, child: Text('文本')),
                  PopupMenuItem(
                    value: ContentType.image,
                    enabled: false,
                    child: Row(
                      children: [
                        const Text('图片'),
                        const SizedBox(width: 4),
                        Icon(Icons.lock, size: 14, color: theme.colorScheme.outline),
                      ],
                    ),
                  ),
                  PopupMenuItem(
                    value: ContentType.file,
                    enabled: false,
                    child: Row(
                      children: [
                        const Text('文件'),
                        const SizedBox(width: 4),
                        Icon(Icons.lock, size: 14, color: theme.colorScheme.outline),
                      ],
                    ),
                  ),
                ],
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  decoration: BoxDecoration(
                    color: provider.activeTypeFilter != null
                        ? theme.colorScheme.primaryContainer
                        : theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    _typeFilterLabel(provider.activeTypeFilter),
                    style: TextStyle(
                      fontSize: 12,
                      color: provider.activeTypeFilter != null
                          ? theme.colorScheme.onPrimaryContainer
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 4),
              // Device filter button
              IconButton(
                icon: Icon(
                  Icons.tune_rounded,
                  size: 20,
                  color: provider.activeDeviceFilter != null
                      ? theme.colorScheme.primary
                      : theme.colorScheme.outline,
                ),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                onPressed: _showFilterSheet,
                tooltip: '筛选设备',
              ),
            ],
          ),
        );
      },
    );
  }
}
