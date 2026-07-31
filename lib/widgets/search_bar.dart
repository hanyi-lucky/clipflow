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

  /// 清空搜索并取消焦点（供外部调用）
  void clearAndUnfocus() {
    _controller.clear();
    _focusNode.unfocus();
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
        return '文本';
      case ContentType.image:
        return '图片';
      case ContentType.file:
        return '文件';
      default:
        return '全部';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<ClipboardProvider>(
      builder: (context, provider, _) {
        if (provider.isMergeMode) return const SizedBox.shrink();

        // 同步：当 provider.searchQuery 被外部清空时，同步清空输入框
        if (provider.searchQuery.isEmpty && _controller.text.isNotEmpty) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _controller.clear();
            _focusNode.unfocus();
          });
        }

        final theme = Theme.of(context);
        final cs = theme.colorScheme;

        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Row(
            children: [
              // 搜索框
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    color: cs.surfaceContainerHighest.withOpacity(0.5),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  child: Row(
                    children: [
                      Icon(Icons.search_rounded, size: 20, color: cs.onSurfaceVariant),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextField(
                          controller: _controller,
                          focusNode: _focusNode,
                          decoration: InputDecoration(
                            hintText: '搜索历史记录',
                            hintStyle: TextStyle(
                              color: cs.onSurfaceVariant.withOpacity(0.6),
                              fontSize: 15,
                            ),
                            border: InputBorder.none,
                            enabledBorder: InputBorder.none,
                            focusedBorder: InputBorder.none,
                            disabledBorder: InputBorder.none,
                            errorBorder: InputBorder.none,
                            focusedErrorBorder: InputBorder.none,
                            filled: false,
                            isDense: true,
                            contentPadding: const EdgeInsets.symmetric(vertical: 12),
                          ),
                          style: theme.textTheme.bodyMedium?.copyWith(fontSize: 15),
                          onChanged: (value) => provider.setSearchQuery(value),
                        ),
                      ),
                      if (provider.hasActiveFilters || _controller.text.isNotEmpty)
                        GestureDetector(
                          onTap: () {
                            _controller.clear();
                            provider.clearFilters();
                            _focusNode.unfocus();
                          },
                          child: Icon(Icons.close_rounded, size: 18, color: cs.onSurfaceVariant),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              // 筛选 chips
              _FilterChip(
                label: _typeFilterLabel(provider.activeTypeFilter),
                icon: Icons.category_outlined,
                isSelected: provider.activeTypeFilter != null,
                onTap: () => _showTypeMenu(context, provider),
              ),
              const SizedBox(width: 6),
              _FilterChip(
                label: provider.activeDeviceFilter ?? '设备',
                icon: Icons.devices_outlined,
                isSelected: provider.activeDeviceFilter != null,
                onTap: _showFilterSheet,
              ),
            ],
          ),
        );
      },
    );
  }

  void _showTypeMenu(BuildContext context, ClipboardProvider provider) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => Container(
        decoration: BoxDecoration(
          color: cs.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
        ),
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 36, height: 4,
                decoration: BoxDecoration(
                  color: cs.outlineVariant,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text('内容类型', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: 12),
            _TypeOption(
              label: '全部',
              icon: Icons.all_inclusive_rounded,
              isSelected: provider.activeTypeFilter == null,
              onTap: () { provider.setTypeFilter(null); Navigator.pop(context); },
            ),
            _TypeOption(
              label: '文本',
              icon: Icons.text_fields_rounded,
              isSelected: provider.activeTypeFilter == ContentType.text,
              onTap: () { provider.setTypeFilter(ContentType.text); Navigator.pop(context); },
            ),
            _TypeOption(
              label: '图片',
              icon: Icons.image_outlined,
              isSelected: false,
              enabled: false,
              trailing: Icon(Icons.lock_outline, size: 16, color: cs.outline),
              onTap: () {},
            ),
            _TypeOption(
              label: '文件',
              icon: Icons.insert_drive_file_outlined,
              isSelected: false,
              enabled: false,
              trailing: Icon(Icons.lock_outline, size: 16, color: cs.outline),
              onTap: () {},
            ),
          ],
        ),
      ),
    );
  }
}

class _FilterChip extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool isSelected;
  final VoidCallback onTap;

  const _FilterChip({
    required this.label,
    required this.icon,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Material(
      color: isSelected
          ? cs.primaryContainer
          : cs.surfaceContainerHighest.withOpacity(0.5),
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 16,
                color: isSelected ? cs.onPrimaryContainer : cs.onSurfaceVariant,
              ),
              const SizedBox(width: 4),
              Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: isSelected ? FontWeight.w500 : FontWeight.normal,
                  color: isSelected ? cs.onPrimaryContainer : cs.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: 2),
              Icon(
                Icons.keyboard_arrow_down_rounded,
                size: 16,
                color: isSelected ? cs.onPrimaryContainer : cs.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TypeOption extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool isSelected;
  final bool enabled;
  final Widget? trailing;
  final VoidCallback onTap;

  const _TypeOption({
    required this.label,
    required this.icon,
    required this.isSelected,
    this.enabled = true,
    this.trailing,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: enabled ? onTap : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
        child: Row(
          children: [
            Icon(
              icon,
              size: 20,
              color: !enabled
                  ? cs.outline.withOpacity(0.4)
                  : isSelected
                      ? cs.primary
                      : cs.onSurfaceVariant,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                label,
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: !enabled
                      ? cs.outline.withOpacity(0.4)
                      : isSelected
                          ? cs.primary
                          : null,
                  fontWeight: isSelected ? FontWeight.w600 : null,
                ),
              ),
            ),
            if (trailing != null) trailing!,
            if (isSelected && trailing == null)
              Icon(Icons.check_rounded, size: 20, color: cs.primary),
          ],
        ),
      ),
    );
  }
}
