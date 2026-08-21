import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart' as ph;
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../providers/settings_provider.dart';
import '../l10n/app_strings.dart';
import '../providers/clipboard_provider.dart';
import '../repositories/local_storage.dart';
import '../services/app_info.dart';
import '../services/lan_diagnostics.dart';
import '../widgets/device_management_section.dart';
import 'backup/export_backup_screen.dart';
import 'backup/import_backup_screen.dart';
import 'backup/cloud_pull_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  /// 崩溃上报真机测试触发：关于页连点版本号 7 次抛一次异常（隐藏测试钩子）。
  int _versionTapCount = 0;
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
      appBar: AppBar(title: const Text(AppStrings.settingsTitle)),
      body: Consumer<SettingsProvider>(
        builder: (context, settings, _) {
          return ListView(
            children: [
              _buildSection(context, AppStrings.settingsAppearanceSection, [
                _buildThemeTile(
                  context,
                  settings,
                  ThemeMode.system,
                  AppStrings.themeFollowSystem,
                  Icons.brightness_auto,
                ),
                _buildThemeTile(
                  context,
                  settings,
                  ThemeMode.light,
                  AppStrings.themeLight,
                  Icons.light_mode,
                ),
                _buildThemeTile(
                  context,
                  settings,
                  ThemeMode.dark,
                  AppStrings.themeDark,
                  Icons.dark_mode,
                ),
              ]),
              _buildSection(context, AppStrings.settingsGeneralSection, [
                SwitchListTile(
                  title: const Text(AppStrings.autoSyncTitle),
                  subtitle: const Text(AppStrings.autoSyncSubtitle),
                  value: settings.autoSync,
                  onChanged: (v) => settings.setAutoSync(v),
                ),
                const Divider(height: 1, indent: 16),
                SwitchListTile(
                  title: const Text(AppStrings.lanAccelerationTitle),
                  subtitle: const Text(AppStrings.lanAccelerationSubtitle),
                  value: settings.lanAcceleration,
                  secondary: const Icon(Icons.wifi_tethering),
                  onChanged: (v) async {
                    // Android 13+ 开启前先请求 NEARBY_WIFI_DEVICES；
                    // 拒绝 → 置回 false 并提示（LAN 降级，不阻塞 Cloud）。
                    if (v && Platform.isAndroid) {
                      final status =
                          await ph.Permission.nearbyWifiDevices.request();
                      if (!status.isGranted) {
                        await settings.setLanAcceleration(false);
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(AppStrings.lanPermissionDenied),
                            ),
                          );
                        }
                        return;
                      }
                    }
                    // 级联（不变式 lanOnly ⇒ lanAcceleration）：关闭
                    // lanAcceleration 同时清除 lanOnly（settings_screen 唯一级联点）。
                    if (!v && settings.lanOnlyMode) {
                      await settings.setLanOnlyMode(false);
                      await ClipboardProvider.of(
                        context,
                        listen: false,
                      ).setLanOnlyMode(false);
                    }
                    await settings.setLanAcceleration(v);
                    await ClipboardProvider.of(
                      context,
                      listen: false,
                    ).setLanAcceleration(v);
                  },
                ),
                const Divider(height: 1, indent: 16),
                SwitchListTile(
                  title: const Text(AppStrings.lanOnlyTitle),
                  subtitle: const Text(AppStrings.lanOnlySubtitle),
                  value: settings.lanOnlyMode,
                  secondary: const Icon(Icons.lan_outlined),
                  onChanged: (v) async {
                    // Android 13+ 开启前先请求 NEARBY_WIFI_DEVICES；
                    // 拒绝 → 置回 false 并提示（LAN 降级，不阻塞 Cloud）。
                    if (v && Platform.isAndroid) {
                      final status =
                          await ph.Permission.nearbyWifiDevices.request();
                      if (!status.isGranted) {
                        await settings.setLanOnlyMode(false);
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(AppStrings.lanPermissionDenied),
                            ),
                          );
                        }
                        return;
                      }
                    }
                    // 级联（不变式 lanOnly ⇒ lanAcceleration）：开启
                    // lanOnly 前先确保 lanAcceleration 开启（manager 生命周期归它）。
                    if (v && !settings.lanAcceleration) {
                      await settings.setLanAcceleration(true);
                      await ClipboardProvider.of(
                        context,
                        listen: false,
                      ).setLanAcceleration(true);
                    }
                    await settings.setLanOnlyMode(v);
                    await ClipboardProvider.of(
                      context,
                      listen: false,
                    ).setLanOnlyMode(v);
                    if (v && context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            '${AppStrings.lanOnlyExperimentalHint}\n'
                            '${AppStrings.lanOnlyEnabledSnackBar}',
                          ),
                        ),
                      );
                    }
                  },
                ),
                ListTile(
                  title: const Text(AppStrings.historyLimitTitle),
                  subtitle: Text(AppStrings.historyLimitCount(settings.historyLimit)),
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
              _buildSection(context, AppStrings.settingsDevicesSection, [
                const DeviceManagementSection(),
              ]),
              _buildSection(context, AppStrings.settingsAccountSection, [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                  child: Text(
                    AppStrings.changePasswordHint,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.save_alt),
                  title: const Text(AppStrings.exportBackupTitle),
                  subtitle: const Text(AppStrings.exportBackupSubtitle),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => const ExportBackupScreen(),
                      ),
                    );
                  },
                ),
                const Divider(height: 1, indent: 16),
                ListTile(
                  leading: const Icon(Icons.upload_file),
                  title: const Text(AppStrings.importBackupTitle),
                  subtitle: const Text(AppStrings.importBackupSubtitle),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => const ImportBackupScreen(),
                      ),
                    );
                  },
                ),
                const Divider(height: 1, indent: 16),
                ListTile(
                  leading: const Icon(Icons.cloud_download_outlined),
                  title: const Text(AppStrings.cloudPullTitle),
                  subtitle: const Text(AppStrings.cloudPullSubtitle),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => const CloudPullScreen(),
                      ),
                    );
                  },
                ),
                const Divider(height: 1, indent: 16),
                ListTile(
                  leading: const Icon(Icons.info_outline),
                  title: const Text(AppStrings.changePasswordInfoTitle),
                  subtitle: const Text(AppStrings.changePasswordInfoSubtitle),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _showChangePasswordDialog(context),
                ),
                const Divider(height: 1, indent: 16),
                ListTile(
                  leading: const Icon(Icons.switch_account_outlined),
                  title: const Text(AppStrings.settingsSwitchAccountTitle),
                  subtitle: const Text(AppStrings.settingsSwitchAccountSubtitle),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: _confirmSwitchAccount,
                ),
              ]),
              if (Platform.isAndroid) ...[
                _buildSection(context, AppStrings.settingsSyncSection, [
                  Card(
                    child: Column(
                      children: [
                        SwitchListTile(
                          title: const Text(AppStrings.backgroundSyncTitle),
                          subtitle: const Text(
                            AppStrings.backgroundSyncSubtitle,
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
                          title: const Text(AppStrings.autoSyncOnResumeTitle),
                          subtitle: const Text(AppStrings.autoSyncOnResumeSubtitle),
                          value: settings.autoSyncOnResume,
                          onChanged: (v) => settings.setAutoSyncOnResume(v),
                          secondary: const Icon(Icons.open_in_browser),
                        ),
                        const Divider(height: 1, indent: 16),
                        SwitchListTile(
                          title: const Text(AppStrings.notificationSyncTitle),
                          subtitle: const Text(AppStrings.notificationSyncSubtitle),
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
                _buildSection(context, AppStrings.settingsPermissionSection, [
                  Card(
                    child: Column(
                      children: [
                        ListTile(
                          leading: const Icon(Icons.notifications),
                          title: const Text(AppStrings.notificationPermissionTitle),
                          trailing: _buildPermissionStatus(
                            settings.notificationPermissionGranted,
                            onTap: () =>
                                settings.requestNotificationPermission(),
                          ),
                        ),
                        const Divider(height: 1, indent: 16),
                        ListTile(
                          leading: const Icon(Icons.battery_saver),
                          title: const Text(AppStrings.batteryOptimizationTitle),
                          subtitle: const Text(AppStrings.batteryOptimizationSubtitle),
                          trailing: _buildPermissionStatus(
                            !settings.batteryOptimized,
                            grantedLabel: AppStrings.batteryOptimizationOff,
                            deniedLabel: AppStrings.batteryOptimizationOn,
                            onTap: () => settings.openBatterySettings(),
                          ),
                        ),
                        const Divider(height: 1, indent: 16),
                        ListTile(
                          leading: const Icon(Icons.run_circle),
                          title: const Text(AppStrings.appSettingsTitle),
                          subtitle: const Text(AppStrings.appSettingsSubtitle),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => settings.openAppSettingsPage(),
                        ),
                      ],
                    ),
                  ),
                ]),
              ],
              _buildSection(context, AppStrings.settingsCompatibilitySection, [_buildCompatibilityTile(context)]),
              _buildSection(context, AppStrings.settingsDiagnosticsSection, [
                _buildDiagnosticsSection(context),
              ]),
              _buildSection(context, AppStrings.settingsAboutSection, [
                ListTile(
                  title: const Text(AppStrings.aboutVersion),
                  subtitle: Text(context.watch<AppInfo>().fullVersion),
                  leading: const Icon(Icons.info_outline),
                  onTap: () {
                    // 隐藏测试钩子：连点 7 次触发一次崩溃（供崩溃上报验收）。
                    _versionTapCount++;
                    if (_versionTapCount >= 7) {
                      _versionTapCount = 0;
                      throw StateError(
                          'Manual crash trigger (tap version 7 times)');
                    }
                  },
                ),
                ListTile(
                  title: const Text(AppStrings.aboutLicense),
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

  /// 「诊断（局域网）」调试区：显示计数 + fallback 原因 + 手动清零。
  /// 「诊断（局域网）」调试区：显示计数 + fallback 原因 + 手动清零。
  Widget _buildDiagnosticsSection(BuildContext context) {
    return Consumer<ClipboardProvider>(
      builder: (context, provider, _) {
        final diagnostics = provider.lanDiagnostics;
        final rows = <Widget>[];
        if (diagnostics == null) {
          rows.add(ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text(AppStrings.diagnosticsLanDisabled),
          ));
        } else {
          rows.addAll([
            _diagRow(AppStrings.diagnosticsDiscovered, diagnostics.discovered),
            _diagRow(
              AppStrings.diagnosticsHandshakeSuccess,
              diagnostics.handshakeSuccess,
            ),
            _diagRow(
              AppStrings.diagnosticsHandshakeRejected,
              diagnostics.handshakeRejected,
            ),
            _diagRow(
              AppStrings.diagnosticsLanFetchHit,
              diagnostics.lanFetchHit,
            ),
            _diagRow(
              AppStrings.diagnosticsLanFetchMiss,
              diagnostics.lanFetchMiss,
            ),
            _diagRow(AppStrings.diagnosticsPushSent, diagnostics.pushSent),
            _diagRow(
              AppStrings.diagnosticsPushReceived,
              diagnostics.pushReceived,
            ),
            _diagRow(AppStrings.diagnosticsAckSent, diagnostics.ackSent),
            _diagRow(AppStrings.diagnosticsAckReceived, diagnostics.ackReceived),
            _diagRow(
              AppStrings.diagnosticsSessionDropped,
              diagnostics.sessionDropped,
            ),
          ]);
          final fallback = diagnostics.fallbackSnapshot;
          if (fallback.isNotEmpty) {
            rows.add(const Divider(height: 1, indent: 16));
            rows.add(
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
                child: Text(
                  AppStrings.diagnosticsFallbackTitle,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            );
            fallback.forEach((reason, count) {
              rows.add(_diagRow(_fallbackLabel(reason), count));
            });
          }
        }
        return Column(
          children: [
            ...rows,
            const Divider(height: 1, indent: 16),
            ListTile(
              leading: const Icon(Icons.refresh),
              title: const Text(AppStrings.diagnosticsReset),
              onTap: provider.resetLanDiagnostics,
            ),
          ],
        );
      },
    );
  }


  Widget _diagRow(String label, int value) {
    return ListTile(
      dense: true,
      title: Text(label),
      trailing: Text(
        '$value',
        style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()]),
      ),
    );
  }

  String _fallbackLabel(LanFallbackReason reason) {
    switch (reason) {
      case LanFallbackReason.lanDisabled:
        return AppStrings.diagnosticsFallbackLanDisabled;
      case LanFallbackReason.noPeer:
        return AppStrings.diagnosticsFallbackNoPeer;
      case LanFallbackReason.handshakeRejected:
        return AppStrings.diagnosticsFallbackHandshakeRejected;
      case LanFallbackReason.fetchTimeout:
        return AppStrings.diagnosticsFallbackFetchTimeout;
      case LanFallbackReason.fetchError:
        return AppStrings.diagnosticsFallbackFetchError;
      case LanFallbackReason.duplicate:
        return AppStrings.diagnosticsFallbackDuplicate;
      case LanFallbackReason.decodeFailed:
        return AppStrings.diagnosticsFallbackDecodeFailed;
      case LanFallbackReason.localMissingEnc:
        return AppStrings.diagnosticsFallbackLocalMissingEnc;
      case LanFallbackReason.artifactMismatch:
        return AppStrings.diagnosticsFallbackArtifactMismatch;
      case LanFallbackReason.overLimit:
        return AppStrings.diagnosticsFallbackOverLimit;
    }
  }

  Widget _buildCompatibilityTile(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.description_outlined),
      title: const Text(AppStrings.compatibilityTitle),
      onTap: () => _showCompatibilityDialog(context),
    );
  }

  Future<void> _showChangePasswordDialog(BuildContext context) {
    return showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text(AppStrings.changePasswordDialogTitle),
          surfaceTintColor: Colors.transparent,
          content: SizedBox(
            width: double.maxFinite,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  AppStrings.changePasswordDialogBody,
                  style: TextStyle(
                    color: Theme.of(dialogContext).colorScheme.onSurfaceVariant,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 12),
                _compatibilityItem(dialogContext, AppStrings.changePasswordStepsTitle, AppStrings.changePasswordStepsBody),
                _compatibilityItem(dialogContext, AppStrings.changePasswordNoteTitle, AppStrings.changePasswordNoteBody),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text(AppStrings.commonGotIt),
            ),
          ],
        );
      },
    );
  }

  Future<void> _showCompatibilityDialog(BuildContext context) {
    return showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text(AppStrings.compatibilityTitle),
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
                    AppStrings.compatibilityImageTitle,
                    AppStrings.compatibilityImageBody,
                  ),
                  _compatibilityItem(
                    dialogContext,
                    AppStrings.compatibilityFileTitle,
                    AppStrings.compatibilityFileBody,
                  ),
                  _compatibilityItem(
                    dialogContext,
                    AppStrings.compatibilityFormatsTitle,
                    AppStrings.compatibilityFormatsBody,
                  ),
                  _compatibilityItem(
                    dialogContext,
                    AppStrings.compatibilityPlatformTitle,
                    AppStrings.compatibilityPlatformBody,
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text(AppStrings.commonGotIt),
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

  /// 切换账号：警告对话框确认后清账户身份（token + 本地缓存），
  /// 保留设备信息与设置，然后回到解锁页（不杀进程）。
  Future<void> _confirmSwitchAccount() async {
    final auth = context.read<AuthProvider>();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text(AppStrings.switchAccountDialogTitle),
          surfaceTintColor: Colors.transparent,
          content: const Text(AppStrings.switchAccountDialogBody),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text(AppStrings.commonCancel),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text(AppStrings.switchAccountDialogConfirmAction),
            ),
          ],
        );
      },
    );
    if (confirmed != true) return;
    if (!mounted) return;

    final storage = await LocalStorage.create();
    await auth.signOut();
    await context.read<ClipboardProvider>().resetAccountSync();
    await storage.clearAccountIdentity();
    if (!mounted) return;
    Navigator.of(context).pushNamedAndRemoveUntil(
      '/unlock',
      (route) => false,
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

  Widget _buildPermissionStatus(
    bool granted, {
    String grantedLabel = AppStrings.permissionGranted,
    String deniedLabel = AppStrings.permissionDenied,
    VoidCallback? onTap,
  }) {
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
              granted ? grantedLabel : deniedLabel,
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
