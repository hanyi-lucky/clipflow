import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/settings_provider.dart';
import '../providers/clipboard_provider.dart';
import '../widgets/device_management_section.dart';

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
        return await ClipboardProvider.of(
          context,
          listen: false,
        ).checkNotificationPermission();
      },
      checkBatteryOptimization: () async {
        return await ClipboardProvider.of(
          context,
          listen: false,
        ).checkBatteryOptimization();
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
                _buildThemeTile(
                  context,
                  settings,
                  ThemeMode.system,
                  '跟随系统',
                  Icons.brightness_auto,
                ),
                _buildThemeTile(
                  context,
                  settings,
                  ThemeMode.light,
                  '浅色模式',
                  Icons.light_mode,
                ),
                _buildThemeTile(
                  context,
                  settings,
                  ThemeMode.dark,
                  '深色模式',
                  Icons.dark_mode,
                ),
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
                            ? () => settings.setHistoryLimit(
                                settings.historyLimit - 10,
                              )
                            : null,
                      ),
                      IconButton(
                        icon: const Icon(Icons.add_circle_outline),
                        onPressed: settings.historyLimit < 100
                            ? () => settings.setHistoryLimit(
                                settings.historyLimit + 10,
                              )
                            : null,
                      ),
                    ],
                  ),
                ),
              ]),
              _buildSection(context, '设备管理', [
                const DeviceManagementSection(),
              ]),
              if (Platform.isAndroid) ...[
                _buildSection(context, '同步设置', [
                  Card(
                    child: Column(
                      children: [
                        SwitchListTile(
                          title: const Text('后台自动同步'),
                          subtitle: const Text(
                            'Android 10+ 后台读取剪贴板受限，Android 16+ 仅打开 App 时可同步',
                          ),
                          value: settings.backgroundSync,
                          onChanged: (v) async {
                            await settings.setBackgroundSync(v);
                            if (v) {
                              ClipboardProvider.of(
                                context,
                                listen: false,
                              ).resumeSync();
                            } else {
                              ClipboardProvider.of(
                                context,
                                listen: false,
                              ).stopSync();
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
                          subtitle: const Text('显示常驻通知，点击打开 App 并立即同步'),
                          value: settings.notificationSync,
                          onChanged: (v) async {
                            await settings.setNotificationSync(v);
                            if (v) {
                              ClipboardProvider.of(
                                context,
                                listen: false,
                              ).startSyncService();
                            } else {
                              ClipboardProvider.of(
                                context,
                                listen: false,
                              ).stopSyncService();
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
                            onTap: () =>
                                settings.requestNotificationPermission(),
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
                          title: const Text('应用详情设置'),
                          subtitle: const Text('管理通知、电池优化等系统权限'),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => settings.openAppSettingsPage(),
                        ),
                      ],
                    ),
                  ),
                ]),
              ],
              _buildSection(context, '兼容性', [_buildCompatibilityTile(context)]),
              _buildSection(context, '关于', [
                const ListTile(
                  title: Text('版本'),
                  subtitle: Text('1.4.0'),
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
          ? Icon(
              Icons.check_circle,
              color: Theme.of(context).colorScheme.primary,
            )
          : null,
      onTap: () => settings.setThemeMode(mode),
    );
  }

  Widget _buildCompatibilityTile(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.description_outlined),
      title: const Text('图片与文件格式兼容性'),
      onTap: () => _showCompatibilityDialog(context),
    );
  }

  Future<void> _showCompatibilityDialog(BuildContext context) {
    return showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('图片与文件格式兼容性'),
          surfaceTintColor: Colors.transparent,
          content: SizedBox(
            width: double.maxFinite,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  _compatibilityItem(
                    dialogContext,
                    '图片',
                    '支持剪贴板图片 PNG/JPEG/GIF/TIFF/BMP/WebP/HEIC；'
                        '统一转 PNG/JPEG，长边超 2048 压缩、JPEG q80、'
                        '含透明转 PNG；单张上限 5MB。',
                  ),
                  _compatibilityItem(
                    dialogContext,
                      '文件',
                      'macOS 经 Finder 复制任意文件（file-url）；'
                          'Android 经文件管理器复制（content://，无需存储权限）；'
                          'Windows 剪贴板文件（CF_HDROP，已真机验证）；'
                          '单文件 ≤50MB；一次复制多文件只同步第一个；'
                          '文件夹同步不支持。',
                  ),
                  _compatibilityItem(
                    dialogContext,
                    '常见文件格式',
                    '文本（txt/md/csv/json）、文档（pdf/doc/docx）、'
                        '表格（xls/xlsx）、演示（ppt/pptx）、'
                        '压缩（zip/7z/rar/tar/gz）、'
                        '音视频（mp3/wav/mp4/mov/mkv）、'
                        '代码（dart/swift/kt/cpp/h/py/js/ts/html/css）等；'
                        '未识别扩展名按通用文件处理。',
                  ),
                  _compatibilityItem(
                    dialogContext,
                    '平台差异',
                    'macOS/Windows 500ms 轮询检测；'
                        'Android 由前台服务 + 原生剪贴板监听，'
                        '但 Android 10+ 后台读取剪贴板受限、Android 16+ 仅前台触发；'
                        '删除记录在垃圾箱保留 24 小时，跨设备删除/恢复同步窗口 30 秒，'
                        '“倾倒垃圾桶”可彻底删除本地/服务器/磁盘数据。',
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('知道了'),
            ),
          ],
        );
      },
    );
  }

  Widget _compatibilityItem(BuildContext context, String title, String body) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: colorScheme.primary,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            body,
            style: TextStyle(color: colorScheme.onSurfaceVariant, height: 1.4),
          ),
        ],
      ),
    );
  }

  Widget _buildSection(
    BuildContext context,
    String title,
    List<Widget> children,
  ) {
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
