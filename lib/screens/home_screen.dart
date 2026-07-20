import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/clipboard_provider.dart';
import '../widgets/clipboard_item.dart';
import '../widgets/merge_bar.dart';
import 'trash_screen.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          if (Platform.isAndroid) _buildSyncStatusBar(context),
          Expanded(
            child: Stack(
              children: [
                CustomScrollView(
                  slivers: [
                    SliverAppBar(
                      pinned: true,
                      centerTitle: true,
                      title: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            padding: const EdgeInsets.all(6),
                            decoration: BoxDecoration(
                              color: Theme.of(context).colorScheme.primaryContainer,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Icon(
                              Icons.content_paste,
                              size: 20,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                          ),
                          const SizedBox(width: 10),
                          const Text('ClipFlow'),
                          const SizedBox(width: 8),
                          Consumer<ClipboardProvider>(
                            builder: (context, provider, _) {
                              final status = provider.syncStatus;
                              return Container(
                                width: 8,
                                height: 8,
                                decoration: BoxDecoration(
                                  color: status.color,
                                  shape: BoxShape.circle,
                                  boxShadow: [
                                    BoxShadow(
                                      color: status.color.withOpacity(0.5),
                                      blurRadius: 4,
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                        ],
                      ),
                      actions: [
                        Consumer<ClipboardProvider>(
                          builder: (context, provider, _) {
                            return IconButton(
                              icon: Icon(
                                provider.isMergeMode ? Icons.check : Icons.merge_type,
                                color: provider.isMergeMode
                                    ? Theme.of(context).colorScheme.primary
                                    : null,
                              ),
                              onPressed: () {
                                if (provider.isMergeMode) {
                                  provider.exitMergeMode();
                                } else {
                                  provider.enterMergeMode();
                                }
                              },
                              tooltip: provider.isMergeMode ? '完成选择' : '多选拼接',
                            );
                          },
                        ),
                        IconButton(
                          icon: const Icon(Icons.refresh_rounded),
                          onPressed: () => context.read<ClipboardProvider>().refresh(),
                          tooltip: '刷新',
                        ),
                        IconButton(
                          icon: const Icon(Icons.settings_rounded),
                          onPressed: () => Navigator.pushNamed(context, '/settings'),
                          tooltip: '设置',
                        ),
                      ],
                    ),
                    Consumer<ClipboardProvider>(
                      builder: (context, provider, _) {
                        final history = provider.history;

                        if (history.isEmpty) {
                          return SliverFillRemaining(
                            child: Center(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.content_paste_search,
                                    size: 80,
                                    color: Theme.of(context).colorScheme.outlineVariant,
                                  ),
                                  const SizedBox(height: 16),
                                  Text(
                                    '暂无剪切板记录',
                                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                      color: Theme.of(context).colorScheme.outline,
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    '复制内容后自动同步',
                                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                      color: Theme.of(context).colorScheme.outlineVariant,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        }

                        return SliverList(
                          delegate: SliverChildBuilderDelegate(
                            (context, index) {
                              final entry = history[index];
                              final isSelected = provider.selectedIds.contains(entry.id);
                              final orderList = provider.selectedIds.toList();
                              final order = isSelected ? orderList.indexOf(entry.id) + 1 : null;

                              return ClipboardItem(
                                entry: entry,
                                isMergeMode: provider.isMergeMode,
                                isSelected: isSelected,
                                selectionOrder: order,
                                onTap: provider.isMergeMode
                                    ? () => provider.toggleSelection(entry.id)
                                    : null,
                                onCopy: () => provider.copyEntry(entry.id),
                                onPin: () => provider.togglePin(entry.id),
                                onDelete: () {
                                  showDialog(
                                    context: context,
                                    builder: (ctx) => AlertDialog(
                                      title: const Text('删除'),
                                      content: const Text('确定要删除这条记录吗？'),
                                      actions: [
                                        TextButton(
                                          onPressed: () => Navigator.pop(ctx),
                                          child: const Text('取消'),
                                        ),
                                        TextButton(
                                          onPressed: () {
                                            provider.removeEntry(entry.id);
                                            Navigator.pop(ctx);
                                          },
                                          child: const Text('删除', style: TextStyle(color: Colors.red)),
                                        ),
                                      ],
                                    ),
                                  );
                                },
                              );
                            },
                            childCount: history.length,
                          ),
                        );
                      },
                    ),
                  ],
                ),
                // 垃圾箱入口按钮
                Positioned(
                  left: 16,
                  bottom: 16,
                  child: FloatingActionButton(
                    heroTag: 'trash',
                    mini: true,
                    backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const TrashScreen()),
                    ),
                    child: Icon(Icons.delete_outline, color: Theme.of(context).colorScheme.outline),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      bottomNavigationBar: const MergeBar(),
    );
  }

  Widget _buildSyncStatusBar(BuildContext context) {
    final provider = ClipboardProvider.of(context);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: Theme.of(context).colorScheme.surfaceContainerHighest.withOpacity(0.3),
      child: Row(
        children: [
          // Connection status dot
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: provider.serverConnected ? Colors.green : Colors.red,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            provider.serverConnected ? '已连接' : '未连接',
            style: TextStyle(
              fontSize: 12,
              color: provider.serverConnected ? Colors.green.shade700 : Colors.red.shade700,
            ),
          ),
          const Spacer(),
          // Last sync time
          if (provider.lastSyncTime != null) ...[
            Icon(Icons.access_time, size: 14, color: Colors.grey.shade600),
            const SizedBox(width: 4),
            Text(
              _formatSyncTime(provider.lastSyncTime!),
              style: TextStyle(
                fontSize: 12,
                color: Colors.grey.shade600,
              ),
            ),
          ],
        ],
      ),
    );
  }

  String _formatSyncTime(DateTime time) {
    final now = DateTime.now();
    final diff = now.difference(time);

    if (diff.inMinutes < 1) return '刚刚同步';
    if (diff.inMinutes < 60) return '${diff.inMinutes}分钟前';
    if (diff.inHours < 24) return '${diff.inHours}小时前';
    return '${diff.inDays}天前';
  }
}
