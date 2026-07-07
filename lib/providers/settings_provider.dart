import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart' as ph;
import '../repositories/local_storage.dart';

class SettingsProvider extends ChangeNotifier {
  LocalStorage? _storage;

  bool _autoSync = true;
  int _historyLimit = 100;
  ThemeMode _themeMode = ThemeMode.system;

  // New sync mode settings
  bool _backgroundSync = true;
  bool _autoSyncOnResume = true;
  bool _notificationSync = true;
  bool _batteryOptimized = false;
  bool _notificationPermissionGranted = false;

  bool get autoSync => _autoSync;
  int get historyLimit => _historyLimit;
  ThemeMode get themeMode => _themeMode;

  bool get backgroundSync => _backgroundSync;
  bool get autoSyncOnResume => _autoSyncOnResume;
  bool get notificationSync => _notificationSync;
  bool get batteryOptimized => _batteryOptimized;
  bool get notificationPermissionGranted => _notificationPermissionGranted;

  Future<void> initialize(LocalStorage storage) async {
    _storage = storage;
    _autoSync = storage.autoSync;
    _historyLimit = storage.historyLimit;
    _themeMode = storage.themeMode;
    _backgroundSync = storage.backgroundSync;
    _autoSyncOnResume = storage.autoSyncOnResume;
    _notificationSync = storage.notificationSync;
    notifyListeners();
  }

  Future<void> setAutoSync(bool value) async {
    _autoSync = value;
    await _storage?.setAutoSync(value);
    notifyListeners();
  }

  Future<void> setHistoryLimit(int value) async {
    _historyLimit = value;
    await _storage?.setHistoryLimit(value);
    notifyListeners();
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    _themeMode = mode;
    await _storage?.setThemeMode(mode);
    notifyListeners();
  }

  Future<void> setBackgroundSync(bool value) async {
    _backgroundSync = value;
    await _storage?.setBackgroundSync(value);
    notifyListeners();
  }

  Future<void> setAutoSyncOnResume(bool value) async {
    _autoSyncOnResume = value;
    await _storage?.setAutoSyncOnResume(value);
    notifyListeners();
  }

  Future<void> setNotificationSync(bool value) async {
    _notificationSync = value;
    await _storage?.setNotificationSync(value);
    notifyListeners();
  }

  /// Refresh permission states from the platform (Android only)
  Future<void> checkPermissions({
    Future<bool> Function()? checkNotificationPermission,
    Future<bool> Function()? checkBatteryOptimization,
  }) async {
    if (!Platform.isAndroid) return;
    if (checkNotificationPermission != null) {
      _notificationPermissionGranted = await checkNotificationPermission();
    }
    if (checkBatteryOptimization != null) {
      _batteryOptimized = await checkBatteryOptimization();
    }
    notifyListeners();
  }

  /// Request notification permission and update state
  Future<void> requestNotificationPermission() async {
    if (!Platform.isAndroid) return;
    final status = await ph.Permission.notification.request();
    _notificationPermissionGranted = status.isGranted;
    notifyListeners();
  }

  /// Open battery optimization settings
  Future<void> openBatterySettings() async {
    if (!Platform.isAndroid) return;
    await ph.openAppSettings();
  }

  /// Open the app's system settings page
  Future<void> openAppSettingsPage() async {
    await ph.openAppSettings();
  }
}
