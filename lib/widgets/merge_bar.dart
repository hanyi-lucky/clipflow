import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/clipboard_provider.dart';
import '../l10n/app_strings.dart';

class MergeBar extends StatelessWidget {
  const MergeBar({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<ClipboardProvider>(
      builder: (context, provider, _) {
        if (!provider.isMergeMode) return const SizedBox.shrink();

        final theme = Theme.of(context);

        return Container(
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            border: Border(
              top: BorderSide(color: theme.dividerColor.withOpacity(0.3)),
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.05),
                blurRadius: 10,
                offset: const Offset(0, -2),
              ),
            ],
          ),
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Icon(Icons.tune_rounded, size: 18, color: theme.colorScheme.outline),
                  const SizedBox(width: 8),
                  Text(AppStrings.mergeSeparatorLabel, style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w500,
                  )),
                  const SizedBox(width: 8),
                  SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(value: '\n', label: Text(AppStrings.separatorNewline)),
                      ButtonSegment(value: ',', label: Text(AppStrings.separatorComma)),
                      ButtonSegment(value: ';', label: Text(AppStrings.separatorSemicolon)),
                      ButtonSegment(value: ' ', label: Text(AppStrings.separatorSpace)),
                    ],
                    selected: {provider.mergeSeparator},
                    onSelectionChanged: (v) {
                      if (v.isNotEmpty) provider.setSeparator(v.first);
                    },
                    showSelectedIcon: false,
                    style: ButtonStyle(
                      visualDensity: VisualDensity.compact,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      textStyle: WidgetStatePropertyAll(
                        theme.textTheme.labelSmall,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                constraints: const BoxConstraints(maxHeight: 72),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest.withOpacity(0.5),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: provider.mergePreview.isEmpty
                    ? Center(
                        child: Text(
                          AppStrings.mergePreviewEmpty,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.outline,
                          ),
                        ),
                      )
                    : SingleChildScrollView(
                        child: Text(
                          provider.mergePreview,
                          style: theme.textTheme.bodySmall?.copyWith(height: 1.5),
                        ),
                      ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                height: 44,
                child: ElevatedButton.icon(
                  icon: const Icon(Icons.copy_rounded, size: 18),
                  label: Text(AppStrings.mergeCopyCount(provider.selectedIds.length)),
                  onPressed: provider.selectedIds.isEmpty
                      ? null
                      : () => provider.copyMerged(),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
