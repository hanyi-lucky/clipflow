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
}
