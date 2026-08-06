import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../providers/clipboard_provider.dart';
import '../models/device.dart';

class DeviceManagementSection extends StatefulWidget {
  const DeviceManagementSection({super.key});

  @override
  State<DeviceManagementSection> createState() => _DeviceManagementSectionState();
}

class _DeviceManagementSectionState extends State<DeviceManagementSection> {
  List<Device> _devices = [];
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadDevices();
  }

  Future<void> _loadDevices() async {
    try {
      final auth = context.read<AuthProvider>();
      final devices = await auth.fetchDevices();
      if (mounted) {
        setState(() {
          _devices = devices;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final currentDeviceId = auth.isAuthenticated ? auth.currentDevice.id : null;

    if (_isLoading) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(16.0),
          child: CircularProgressIndicator(),
        ),
      );
    }

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '加载失败',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: () {
                  setState(() {
                    _isLoading = true;
                    _error = null;
                  });
                  _loadDevices();
                },
                child: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }

    if (_devices.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(16.0),
          child: Text('暂无设备'),
        ),
      );
    }

    return Card(
      child: Column(
        children: [
          for (int i = 0; i < _devices.length; i++) ...[
            _buildDeviceTile(context, _devices[i], currentDeviceId),
            if (i < _devices.length - 1) const Divider(height: 1, indent: 16),
          ],
        ],
      ),
    );
  }

  Widget _buildDeviceTile(
    BuildContext context,
    Device device,
    String? currentDeviceId,
  ) {
    final isCurrentDevice = device.id == currentDeviceId;
    final colorScheme = Theme.of(context).colorScheme;

    return ListTile(
      leading: Icon(
        _getPlatformIcon(device.platform),
        color: colorScheme.onSurfaceVariant,
      ),
      title: Row(
        children: [
          Expanded(
            child: Text(
              device.name,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (isCurrentDevice) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                '当前设备',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: colorScheme.onPrimaryContainer,
                ),
              ),
            ),
          ],
        ],
      ),
      subtitle: Text(
        '${device.platform} · ${_formatLastSeen(device.lastSeen)}',
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          color: colorScheme.onSurfaceVariant,
        ),
      ),
      trailing: PopupMenuButton<String>(
        onSelected: (value) => _handleAction(context, value, device),
        itemBuilder: (context) => [
          const PopupMenuItem(
            value: 'rename',
            child: Text('重命名'),
          ),
          const PopupMenuItem(
            value: 'remove',
            child: Text('移除'),
          ),
        ],
      ),
    );
  }

  Future<void> _handleAction(
    BuildContext context,
    String action,
    Device device,
  ) async {
    switch (action) {
      case 'rename':
        await _showRenameDialog(context, device);
        break;
      case 'remove':
        await _showRemoveConfirmation(context, device);
        break;
    }
  }

  Future<void> _showRenameDialog(BuildContext context, Device device) async {
    final controller = TextEditingController(text: device.name);
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('重命名设备'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '设备名称',
            hintText: '例如：Android · Xiaomi 15',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );

    if (result != null && result.trim().isNotEmpty && result != device.name) {
      try {
        final auth = context.read<AuthProvider>();
        final clipboard = context.read<ClipboardProvider>();

        await auth.renameDevice(device.id, result.trim());

        // 如果是当前设备，同时更新 ClipboardProvider
        if (auth.currentDevice.id == device.id) {
          clipboard.updateDeviceName(result.trim());
        }

        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('设备已重命名')),
        );

        await _loadDevices();
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('重命名失败：$e')),
          );
        }
      }
    }
  }

  Future<void> _showRemoveConfirmation(
    BuildContext context,
    Device device,
  ) async {
    final auth = context.read<AuthProvider>();
    final isCurrentDevice = device.id == auth.currentDevice.id;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('移除设备'),
        content: Text(
          isCurrentDevice
              ? '移除当前设备后，该设备的 token 将立即失效，无法继续同步。确定要移除吗？'
              : '确定要移除设备「${device.name}」吗？该设备的 token 将立即失效。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('移除'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        await auth.removeDevice(device.id);

        if (mounted) {
          if (isCurrentDevice) {
            // 当前设备被移除，退出登录
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('当前设备已移除，正在退出登录...')),
            );
            // 导航到解锁页面
            Navigator.of(context).pushNamedAndRemoveUntil(
              '/unlock',
              (route) => false,
            );
          } else {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('设备已移除')),
            );
            await _loadDevices();
          }
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('移除失败：$e')),
          );
        }
      }
    }
  }

  IconData _getPlatformIcon(String platform) {
    switch (platform) {
      case 'android':
        return Icons.android;
      case 'ios':
        return Icons.phone_iphone;
      case 'macos':
        return Icons.laptop_mac;
      case 'windows':
        return Icons.computer;
      default:
        return Icons.device_unknown;
    }
  }

  String _formatLastSeen(DateTime lastSeen) {
    final now = DateTime.now();
    final diff = now.difference(lastSeen);

    if (diff.inMinutes < 1) {
      return '刚刚在线';
    } else if (diff.inHours < 1) {
      return '${diff.inMinutes}分钟前';
    } else if (diff.inDays < 1) {
      return '${diff.inHours}小时前';
    } else if (diff.inDays < 7) {
      return '${diff.inDays}天前';
    } else {
      // 手动格式化日期，避免依赖 intl 包
      final month = lastSeen.month.toString().padLeft(2, '0');
      final day = lastSeen.day.toString().padLeft(2, '0');
      final hour = lastSeen.hour.toString().padLeft(2, '0');
      final minute = lastSeen.minute.toString().padLeft(2, '0');
      return '$month/$day $hour:$minute';
    }
  }
}
