import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/clipboard_provider.dart';
import '../l10n/app_strings.dart';

class StatusIndicator extends StatelessWidget {
  const StatusIndicator({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<ClipboardProvider>(
      builder: (context, provider, _) {
        final status = provider.syncStatus;
        final theme = Theme.of(context);

        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: status.color.withOpacity(0.08),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: status.color.withOpacity(0.15),
              width: 1,
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: status.color,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: status.color.withOpacity(0.4),
                      blurRadius: 4,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Text(
                status.label,
                style: TextStyle(
                  color: status.color,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const Spacer(),
              if (status == SyncStatus.error && provider.errorMessage != null)
                TextButton.icon(
                  onPressed: () => provider.refresh(),
                  icon: const Icon(Icons.refresh_rounded, size: 16),
                  label: const Text(AppStrings.commonRetry, style: TextStyle(fontSize: 13)),
                  style: TextButton.styleFrom(
                    foregroundColor: status.color,
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}
