import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class LocalStorage {
  static const _keyUserId = 'user_id';
  static const _keyLastSyncTimestamp = 'last_sync_timestamp';
  static const _keyLastContentHash = 'last_content_hash';
  static const _keyDeviceId = 'device_id';
  static const _keyDeviceName = 'device_name';
  static const _keySalt = 'encryption_salt';
  static const _keyAutoSync = 'auto_sync';
  static const _keyHistoryLimit = 'history_limit';
  static const _keyHistory = 'clipboard_history';
  static const _keyThemeMode = 'theme_mode';
  static const _keyMonitorLastHash = 'monitor_last_hash';
  static const _keyMonitorLastSyncTime = 'monitor_last_sync_time';
  static const _keyMonitorIgnoreHashes = 'monitor_ignore_hashes';
  static const _keyBackgroundSync = 'background_sync';
  static const _keyAutoSyncOnResume = 'auto_sync_on_resume';
  static const _keyNotificationSync = 'notification_sync';
  static const _keyDeletedEntryIds = 'deleted_entry_ids';
  static const _keyMonitorIgnoreFileHashes = 'monitor_ignore_file_hashes';
  static const _keyMonitorLastFileSignatures = 'monitor_last_file_signatures';

  final SharedPreferences _prefs;

  LocalStorage(this._prefs);

  static Future<LocalStorage> create() async {
    final prefs = await SharedPreferences.getInstance();
    return LocalStorage(prefs);
  }

  // User identity (stable across sessions, shared across devices via same password)
  String? get userId => _prefs.getString(_keyUserId);

  Future<void> setUserId(String id) async {
    await _prefs.setString(_keyUserId, id);
  }

  /// 清除本机账户身份与相关本地缓存（「切换到其他账户」时调用）。
  ///
  /// 清除 userId 标记、加密盐、本地历史缓存、软删除 ID 与同步游标/去重状态，
  /// 避免旧账户数据污染新账户；设备信息（deviceId/deviceName）与设备设置保留。
  Future<void> clearAccountIdentity() async {
    await _prefs.remove(_keyUserId);
    await _prefs.remove(_keySalt);
    await _prefs.remove(_keyHistory);
    await _prefs.remove(_keyDeletedEntryIds);
    await _prefs.remove(_keyLastSyncTimestamp);
    await _prefs.remove(_keyLastContentHash);
    await _prefs.remove(_keyMonitorLastHash);
    await _prefs.remove(_keyMonitorLastSyncTime);
    await _prefs.remove(_keyMonitorIgnoreHashes);
    await _prefs.remove(_keyMonitorIgnoreFileHashes);
    await _prefs.remove(_keyMonitorLastFileSignatures);
  }

  // Sync state
  DateTime? get lastSyncTimestamp {
    final ms = _prefs.getInt(_keyLastSyncTimestamp);
    return ms != null ? DateTime.fromMillisecondsSinceEpoch(ms) : null;
  }

  Future<void> setLastSyncTimestamp(DateTime ts) async {
    await _prefs.setInt(_keyLastSyncTimestamp, ts.millisecondsSinceEpoch);
  }

  String? get lastContentHash => _prefs.getString(_keyLastContentHash);

  Future<void> setLastContentHash(String hash) async {
    await _prefs.setString(_keyLastContentHash, hash);
  }

  // Device identity
  String? get deviceId => _prefs.getString(_keyDeviceId);

  Future<void> setDeviceId(String id) async {
    await _prefs.setString(_keyDeviceId, id);
  }

  String? get deviceName => _prefs.getString(_keyDeviceName);

  Future<void> setDeviceName(String name) async {
    await _prefs.setString(_keyDeviceName, name);
  }

  // Encryption
  String? get encryptionSalt => _prefs.getString(_keySalt);

  Future<void> setEncryptionSalt(String salt) async {
    await _prefs.setString(_keySalt, salt);
  }

  // Settings
  bool get autoSync => _prefs.getBool(_keyAutoSync) ?? true;

  Future<void> setAutoSync(bool value) async {
    await _prefs.setBool(_keyAutoSync, value);
  }

  int get historyLimit => _prefs.getInt(_keyHistoryLimit) ?? 100;

  Future<void> setHistoryLimit(int value) async {
    await _prefs.setInt(_keyHistoryLimit, value);
  }

  // Theme
  ThemeMode get themeMode {
    final value = _prefs.getString(_keyThemeMode);
    switch (value) {
      case 'light':
        return ThemeMode.light;
      case 'dark':
        return ThemeMode.dark;
      default:
        return ThemeMode.system;
    }
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    await _prefs.setString(_keyThemeMode, mode.name);
  }

  // History
  String? get historyJson => _prefs.getString(_keyHistory);

  Future<void> setHistoryJson(String json) async {
    await _prefs.setString(_keyHistory, json);
  }

  // ClipboardMonitor sync state persistence
  String? get monitorLastHash => _prefs.getString(_keyMonitorLastHash);

  Future<void> setMonitorLastHash(String hash) async {
    await _prefs.setString(_keyMonitorLastHash, hash);
  }

  int? get monitorLastSyncTimeMs => _prefs.getInt(_keyMonitorLastSyncTime);

  Future<void> setMonitorLastSyncTime(int ms) async {
    await _prefs.setInt(_keyMonitorLastSyncTime, ms);
  }

  List<String> get monitorIgnoreHashes =>
      _prefs.getStringList(_keyMonitorIgnoreHashes) ?? [];

  Future<void> setMonitorIgnoreHashes(List<String> hashes) async {
    await _prefs.setStringList(_keyMonitorIgnoreHashes, hashes);
  }

  // New sync mode settings
  bool get backgroundSync => _prefs.getBool(_keyBackgroundSync) ?? true;

  Future<void> setBackgroundSync(bool value) async {
    await _prefs.setBool(_keyBackgroundSync, value);
  }

  bool get autoSyncOnResume => _prefs.getBool(_keyAutoSyncOnResume) ?? true;

  Future<void> setAutoSyncOnResume(bool value) async {
    await _prefs.setBool(_keyAutoSyncOnResume, value);
  }

  bool get notificationSync => _prefs.getBool(_keyNotificationSync) ?? true;

  Future<void> setNotificationSync(bool value) async {
    await _prefs.setBool(_keyNotificationSync, value);
  }

  // Deleted entry IDs (persisted to prevent resurrection after restart)
  Set<String> get deletedEntryIds =>
      Set<String>.from(_prefs.getStringList(_keyDeletedEntryIds) ?? []);

  Future<void> setDeletedEntryIds(Set<String> ids) async {
    await _prefs.setStringList(_keyDeletedEntryIds, ids.toList());
  }

  List<String> get monitorIgnoreFileHashes =>
      _prefs.getStringList(_keyMonitorIgnoreFileHashes) ?? [];

  Future<void> setMonitorIgnoreFileHashes(List<String> hashes) async {
    await _prefs.setStringList(_keyMonitorIgnoreFileHashes, hashes);
  }

  Map<String, String> get monitorLastFileSignatures {
    final raw = _prefs.getString(_keyMonitorLastFileSignatures);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      return decoded.map((k, v) => MapEntry('$k', '$v'));
    } catch (e) {
      return {};
    }
  }

  Future<void> setMonitorLastFileSignatures(Map<String, String> signatures) async {
    await _prefs.setString(
      _keyMonitorLastFileSignatures,
      jsonEncode(signatures),
    );
  }
}
