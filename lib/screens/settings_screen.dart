import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/settings_provider.dart';
import '../providers/clipboard_provider.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  @override
  void initState() {
    super.initState();
    // Check permissions when settings page opens
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkPermissions();
    });
  }

  Future<void> _checkPermissions() async {
    final settings = context.read<SettingsProvider>();
    await settings.checkPermissions(
      checkNotificationPermission: () async {
        return await ClipboardProvider.of(context, listen: false).checkNotificationPermission();
      },
      checkBatteryOptimization: () async {
        return await ClipboardProvider.of(context, listen: false).checkBatteryOptimization();
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: Consumer<SettingsProvider>(
        builder: (context, settings, _) {
          return ListView(
            children: [
              _buildSection(context, '外观', [
                _buildThemeTile(context, settings, ThemeMode.system, '跟随系统', Icons.brightness_auto),
                _buildThemeTile(context, settings, ThemeMode.light, '浅色模式', Icons.light_mode),
                _buildThemeTile(context, settings, ThemeMode.dark, '深色模式', Icons.dark_mode),
              ]),
              _buildSection(context, '通用', [
                SwitchListTile(
                  title: const Text('自动同步'),
                  subtitle: const Text('检测到新内容时自动同步到云端'),
                  value: settings.autoSync,
                  onChanged: (v) => settings.setAutoSync(v),
                ),
                ListTile(
                  title: const Text('历史记录保留'),
                  subtitle: Text('${settings.historyLimit}条'),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.remove_circle_outline),
                        onPressed: settings.historyLimit > 10
                            ? () => settings.setHistoryLimit(settings.historyLimit - 10)
                            : null,
                      ),
                      IconButton(
                        icon: const Icon(Icons.add_circle_outline),
                        onPressed: settings.historyLimit < 500
                            ? () => settings.setHistoryLimit(settings.historyLimit + 10)
                            : null,
                      ),
                    ],
                  ),
                ),
              ]),
              if (Platform.isAndroid) ...[
                _buildSection(context, '同步设置', [
                  Card(
                    child: Column(
                      children: [
                        SwitchListTile(
                          title: const Text('后台自动同步'),
                          subtitle: const Text('低版本Android有效，高版本可能受限'),
                          value: settings.backgroundSync,
                          onChanged: (v) async {
                            await settings.setBackgroundSync(v);
                            if (v) {
                              ClipboardProvider.of(context, listen: false).resumeSync();
                            } else {
                              ClipboardProvider.of(context, listen: false).stopSync();
                            }
                          },
                          secondary: const Icon(Icons.sync_disabled),
                        ),
                        const Divider(height: 1, indent: 16),
                        SwitchListTile(
                          title: const Text('App打开自动同步'),
                          subtitle: const Text('进入前台时自动检查并同步'),
                          value: settings.autoSyncOnResume,
                          onChanged: (v) => settings.setAutoSyncOnResume(v),
                          secondary: const Icon(Icons.open_in_browser),
                        ),
                        const Divider(height: 1, indent: 16),
                        SwitchListTile(
                          title: const Text('通知栏同步'),
                          subtitle: const Text('显示常驻通知，可手动触发同步'),
                          value: settings.notificationSync,
                          onChanged: (v) async {
                            await settings.setNotificationSync(v);
                            if (v) {
                              ClipboardProvider.of(context, listen: false).startSyncService();
                            } else {
                              ClipboardProvider.of(context, listen: false).stopSyncService();
                            }
                          },
                          secondary: const Icon(Icons.notifications_active),
                        ),
                      ],
                    ),
                  ),
                ]),
                _buildSection(context, '权限状态', [
                  Card(
                    child: Column(
                      children: [
                        ListTile(
                          leading: const Icon(Icons.notifications),
                          title: const Text('通知权限'),
                          trailing: _buildPermissionStatus(
                            settings.notificationPermissionGranted,
                            onTap: () => settings.requestNotificationPermission(),
                          ),
                        ),
                        const Divider(height: 1, indent: 16),
                        ListTile(
                          leading: const Icon(Icons.battery_saver),
                          title: const Text('电池优化'),
                          subtitle: const Text('关闭电池优化可提高后台同步稳定性'),
                          trailing: _buildPermissionStatus(
                            !settings.batteryOptimized,
                            onTap: () => settings.openBatterySettings(),
                          ),
                        ),
                        const Divider(height: 1, indent: 16),
                        ListTile(
                          leading: const Icon(Icons.run_circle),
                          title: const Text('后台运行'),
                          trailing: _buildPermissionStatus(
                            true,
                            onTap: () => settings.openAppSettingsPage(),
                          ),
                        ),
                      ],
                    ),
                  ),
                ]),
              ],
              _buildSection(context, '关于', [
                const ListTile(
                  title: Text('版本'),
                  subtitle: Text('1.0.0'),
                  leading: Icon(Icons.info_outline),
                ),
                ListTile(
                  title: const Text('开源协议'),
                  subtitle: const Text('MIT License'),
                  leading: const Icon(Icons.code),
                ),
              ]),
              const SizedBox(height: 32),
            ],
          );
        },
      ),
    );
  }

  Widget _buildThemeTile(
    BuildContext context,
    SettingsProvider settings,
    ThemeMode mode,
    String label,
    IconData icon,
  ) {
    final isSelected = settings.themeMode == mode;
    return ListTile(
      leading: Icon(icon),
      title: Text(label),
      trailing: isSelected
          ? Icon(Icons.check_circle, color: Theme.of(context).colorScheme.primary)
          : null,
      onTap: () => settings.setThemeMode(mode),
    );
  }

  Widget _buildSection(BuildContext context, String title, List<Widget> children) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
          child: Text(
            title,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        ...children,
        const Divider(height: 1),
      ],
    );
  }

  Widget _buildPermissionStatus(bool granted, {VoidCallback? onTap}) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: granted ? Colors.green.shade50 : Colors.orange.shade50,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: granted ? Colors.green.shade200 : Colors.orange.shade200,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              granted ? Icons.check_circle : Icons.warning,
              size: 16,
              color: granted ? Colors.green.shade700 : Colors.orange.shade700,
            ),
            const SizedBox(width: 4),
            Text(
              granted ? '已授予' : '未授予',
              style: TextStyle(
                fontSize: 12,
                color: granted ? Colors.green.shade700 : Colors.orange.shade700,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
