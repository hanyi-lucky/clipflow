import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:clipflow/repositories/local_storage.dart';

void main() {
  test('clearAccountIdentity：清除账户身份与本地缓存，保留设备信息与设置', () async {
    SharedPreferences.setMockInitialValues({
      'user_id': 'user_old',
      'encryption_salt': '0011',
      'clipboard_history': '[]',
      'deleted_entry_ids': <String>['id1'],
      'last_sync_timestamp': 1,
      'last_content_hash': 'h',
      'monitor_last_hash': 'h',
      'monitor_last_sync_time': 1,
      'monitor_ignore_hashes': <String>['a'],
      'monitor_ignore_file_hashes': <String>['b'],
      'monitor_last_file_signatures': '{}',
      'device_id': 'dev-1',
      'device_name': 'Mac',
      'auto_sync': true,
      'history_limit': 100,
      'theme_mode': 'dark',
    });
    final storage = LocalStorage(await SharedPreferences.getInstance());

    await storage.clearAccountIdentity();

    // 账户身份与本地缓存全部清除
    expect(storage.userId, isNull);
    expect(storage.encryptionSalt, isNull);
    expect(storage.historyJson, isNull);
    expect(storage.deletedEntryIds, isEmpty);
    expect(storage.lastSyncTimestamp, isNull);
    expect(storage.lastContentHash, isNull);
    expect(storage.monitorLastHash, isNull);
    expect(storage.monitorLastSyncTimeMs, isNull);
    expect(storage.monitorIgnoreHashes, isEmpty);
    expect(storage.monitorIgnoreFileHashes, isEmpty);
    expect(storage.monitorLastFileSignatures, isEmpty);

    // 设备信息与设备设置保留（不属于账户数据）
    expect(storage.deviceId, 'dev-1');
    expect(storage.deviceName, 'Mac');
    expect(storage.autoSync, isTrue);
    expect(storage.historyLimit, 100);
    expect(storage.themeMode, ThemeMode.dark);
  });
}
