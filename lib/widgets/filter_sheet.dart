import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/clipboard_provider.dart';

class FilterSheet extends StatelessWidget {
  const FilterSheet({super.key});

  @override
  Widget build(BuildContext context) {
    final provider = Provider.of<ClipboardProvider>(context);
    final theme = Theme.of(context);

    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Handle bar
          Center(
            child: Container(
              width: 32,
              height: 4,
              decoration: BoxDecoration(
                color: theme.colorScheme.outline.withOpacity(0.3),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            '筛选设备',
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: 12),
          // Device filter chips
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilterChip(
                label: const Text('全部设备'),
                selected: provider.activeDeviceFilter == null,
                onSelected: (_) {
                  provider.setDeviceFilter(null);
                  Navigator.pop(context);
                },
              ),
              ...provider.availableDevices.map((device) => FilterChip(
                label: Text(device),
                selected: provider.activeDeviceFilter == device,
                onSelected: (_) {
                  provider.setDeviceFilter(
                    provider.activeDeviceFilter == device ? null : device,
                  );
                  Navigator.pop(context);
                },
              )),
            ],
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}
