import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/clipboard_provider.dart';

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

    if (diff.inMinutes < 1) return '刚刚删除';
    if (diff.inMinutes < 60) return '${diff.inMinutes}分钟前删除';
    if (diff.inHours < 24) return '${diff.inHours}小时前删除';
    return '${diff.inDays}天前删除';
  }

  String _formatRemainingTime(int deletedAt) {
    final deletedTime = DateTime.fromMillisecondsSinceEpoch(deletedAt);
    final expireTime = deletedTime.add(const Duration(hours: 24));
    final now = DateTime.now();
    final remaining = expireTime.difference(now);

    if (remaining.isNegative) return '即将清除';
    if (remaining.inHours > 0) {
      return '剩余 ${remaining.inHours} 小时 ${remaining.inMinutes % 60} 分钟';
    }
    return '剩余 ${remaining.inMinutes} 分钟';
  }

  String _getContentPreview(String content) {
    // 内容是加密的 base64，显示为"加密内容"
    if (content.length > 50 && RegExp(r'^[A-Za-z0-9+/=]+$').hasMatch(content)) {
      return '加密内容';
    }
    return content.length > 100 ? '${content.substring(0, 100)}...' : content;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('垃圾箱'),
        centerTitle: true,
        actions: [
          if (_trashEntries.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.refresh_rounded),
              onPressed: () {
                setState(() => _isLoading = true);
                _loadTrash();
              },
              tooltip: '刷新',
            ),
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
                        '垃圾箱为空',
                        style: theme.textTheme.titleMedium?.copyWith(
                          color: theme.colorScheme.outline,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '删除的记录将保留 24 小时',
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
                    final content = entry['content'] as String? ?? '';

                    return Card(
                      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
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
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: theme.colorScheme.surfaceContainerHighest,
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
                              child: Text(
                                _getContentPreview(content),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  height: 1.5,
                                  color: theme.colorScheme.outline,
                                ),
                              ),
                            ),
                            const SizedBox(height: 8),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.end,
                              children: [
                                _TrashActionChip(
                                  icon: Icons.restore_rounded,
                                  label: '恢复',
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

  Future<void> _restoreEntry(String id) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('恢复记录'),
        content: const Text('确定要恢复这条记录吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('恢复', style: TextStyle(color: Colors.green)),
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
            content: Text('已恢复'),
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

  const _TrashActionChip({
    required this.icon,
    required this.label,
    this.onTap,
  });

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
