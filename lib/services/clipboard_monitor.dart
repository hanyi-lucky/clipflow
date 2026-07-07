import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:crypto/crypto.dart';
import '../core/constants.dart';
import '../repositories/local_storage.dart';

typedef ClipboardChangeCallback = void Function(String content);

class ClipboardMonitor extends ChangeNotifier {
  Timer? _pollTimer;
  String _lastHash = '';
  bool _isPaused = false;
  final ClipboardChangeCallback onChanged;
  MethodChannel? _androidChannel;
  LocalStorage? _storage;

  // New sync state
  static const int _maxIgnoreHashes = 10;
  final Set<String> _ignoreHashes = {};
  DateTime? _lastSyncTime;
  bool _autoSyncOnResume = true;
  bool _notificationSync = true;
  bool _isSyncing = false;
  String _syncStatus = 'idle';

  // SyncService reference (set externally)
  dynamic _syncService;

  ClipboardMonitor({required this.onChanged, LocalStorage? storage}) {
    _storage = storage;
    if (Platform.isAndroid) {
      _androidChannel = const MethodChannel('clipflow/clipboard');
      _androidChannel!.setMethodCallHandler(_handleAndroidMethodCall);
    }
  }

  // -- Getters --
  bool get autoSyncOnResume => _autoSyncOnResume;
  bool get notificationSync => _notificationSync;
  String get lastHash => _lastHash;
  DateTime? get lastSyncTime => _lastSyncTime;
  Set<String> get ignoreHashes => Set.unmodifiable(_ignoreHashes);
  String get syncStatus => _syncStatus;
  bool get isSyncing => _isSyncing;

  // -- Setters --
  set autoSyncOnResume(bool value) {
    _autoSyncOnResume = value;
    notifyListeners();
  }

  set notificationSync(bool value) {
    _notificationSync = value;
    notifyListeners();
  }

  /// Set the SyncService reference for syncClipboard() to use
  void setSyncService(dynamic syncService) {
    _syncService = syncService;
  }

  /// Load persisted state from SharedPreferences
  void loadState() {
    _loadSyncState();
    _loadIgnoreHashes();
  }

  // -- Existing API (unchanged) --

  Future<void> start() async {
    if (Platform.isAndroid) {
      try {
        await _androidChannel?.invokeMethod('startListening');
      } catch (e) {
        debugPrint('[CLIP-MON] startListening ERROR: $e');
      }
    } else {
      _startPolling();
    }
  }

  Future<void> stop() async {
    if (Platform.isAndroid) {
      await _androidChannel?.invokeMethod('stopListening');
    } else {
      _stopPolling();
    }
  }

  void pause() {
    _isPaused = true;
  }

  void resume() {
    _isPaused = false;
  }

  // -- New sync API --

  /// Unified sync method: reads clipboard, checks for duplicates/ignored, uploads
  Future<void> syncClipboard() async {
    if (_isSyncing) return;
    _isSyncing = true;
    _syncStatus = 'syncing';
    notifyListeners();
    debugPrint('[SYNC] syncClipboard started, _syncService=${_syncService != null ? "set" : "NULL"}');

    try {
      final content = await Clipboard.getData(Clipboard.kTextPlain);
      debugPrint('[SYNC] Clipboard content: ${content?.text?.length ?? 0} chars');
      if (content?.text == null || content!.text!.isEmpty) {
        _syncStatus = 'idle';
        return;
      }

      final hash = sha256.convert(utf8.encode(content.text!)).toString();
      debugPrint('[SYNC] Hash: $hash, lastHash: $_lastHash');

      // Check ignoreHashes (one-time skip for content synced from other devices)
      if (_ignoreHashes.contains(hash)) {
        debugPrint('[SYNC] Hash in ignoreHashes, skipping');
        _ignoreHashes.remove(hash);
        _saveIgnoreHashes();
        _syncStatus = 'idle';
        return;
      }

      // Check duplicate
      if (hash == _lastHash) {
        debugPrint('[SYNC] Same hash, skipping');
        _syncStatus = 'idle';
        return;
      }

      // Upload
      if (_syncService != null) {
        debugPrint('[SYNC] Uploading...');
        final success = await _syncService.uploadContent(content.text!);
        debugPrint('[SYNC] Upload result: $success');
        if (success) {
          _lastHash = hash;
          _lastSyncTime = DateTime.now();
          _saveSyncState();
          _syncStatus = 'success';
        } else {
          _syncStatus = 'idle';
        }
      } else {
        debugPrint('[SYNC] _syncService is NULL, cannot upload');
        _syncStatus = 'idle';
      }
    } catch (e) {
      _syncStatus = 'error';
      debugPrint('[SYNC] Error: $e');
    } finally {
      _isSyncing = false;
      notifyListeners();
    }
  }

  /// Add a hash to the ignore list (content synced from other devices)
  void addIgnoreHash(String hash) {
    _ignoreHashes.add(hash);
    // Evict oldest if over limit
    while (_ignoreHashes.length > _maxIgnoreHashes) {
      _ignoreHashes.remove(_ignoreHashes.first);
    }
    _saveIgnoreHashes();
  }

  /// Check notification permission (Android only)
  Future<bool> checkNotificationPermission() async {
    if (!Platform.isAndroid) return true;
    try {
      final result = await _androidChannel?.invokeMethod<bool>('checkNotificationPermission');
      return result ?? false;
    } catch (e) {
      debugPrint('[CLIP-MON] checkNotificationPermission ERROR: $e');
      return false;
    }
  }

  /// Check battery optimization status (Android only)
  Future<bool> checkBatteryOptimization() async {
    if (!Platform.isAndroid) return true;
    try {
      final result = await _androidChannel?.invokeMethod<bool>('checkBatteryOptimization');
      return result ?? false;
    } catch (e) {
      debugPrint('[CLIP-MON] checkBatteryOptimization ERROR: $e');
      return false;
    }
  }

  // -- Internal methods --

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(AppConstants.pollInterval, (_) => _checkClipboard());
  }

  void _stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  Future<void> _checkClipboard() async {
    if (_isPaused) return;

    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      if (data?.text != null && data!.text!.isNotEmpty) {
        final hash = sha256.convert(utf8.encode(data.text!)).toString();
        if (hash != _lastHash) {
          _lastHash = hash;
          onChanged(data.text!);
        }
      }
    } catch (_) {
      // Clipboard access may fail; silently ignore
    }
  }

  Future<dynamic> _handleAndroidMethodCall(MethodCall call) async {
    switch (call.method) {
      case 'onClipboardChanged':
        final text = call.arguments as String?;
        if (text != null && text.isNotEmpty) {
          final hash = sha256.convert(utf8.encode(text)).toString();
          if (hash != _lastHash) {
            _lastHash = hash;
            onChanged(text);
          }
        }
        break;
      case 'syncClipboard':
        // Native layer passes clipboard content (Android 10+ can't read clipboard from background)
        final clipboardText = call.arguments as String?;
        if (clipboardText != null && clipboardText.isNotEmpty) {
          await syncClipboardWithContent(clipboardText);
        } else {
          // Fallback: try reading from Flutter (for foreground cases)
          await syncClipboard();
        }
        break;
    }
  }

  /// Sync with pre-read clipboard content (for Android notification button)
  Future<void> syncClipboardWithContent(String content) async {
    if (_isSyncing) return;
    _isSyncing = true;
    _syncStatus = 'syncing';
    notifyListeners();
    debugPrint('[SYNC] syncClipboardWithContent: ${content.length} chars');

    try {
      final hash = sha256.convert(utf8.encode(content)).toString();

      // Check ignoreHashes
      if (_ignoreHashes.contains(hash)) {
        debugPrint('[SYNC] Hash in ignoreHashes, skipping');
        _ignoreHashes.remove(hash);
        _saveIgnoreHashes();
        _syncStatus = 'idle';
        return;
      }

      // Check duplicate
      if (hash == _lastHash) {
        debugPrint('[SYNC] Same hash, skipping');
        _syncStatus = 'idle';
        return;
      }

      // Upload
      if (_syncService != null) {
        debugPrint('[SYNC] Uploading...');
        final success = await _syncService.uploadContent(content);
        debugPrint('[SYNC] Upload result: $success');
        if (success) {
          _lastHash = hash;
          _lastSyncTime = DateTime.now();
          _saveSyncState();
          _syncStatus = 'success';
        } else {
          _syncStatus = 'idle';
        }
      } else {
        debugPrint('[SYNC] _syncService is NULL');
        _syncStatus = 'idle';
      }
    } catch (e) {
      _syncStatus = 'error';
      debugPrint('[SYNC] Error: $e');
    } finally {
      _isSyncing = false;
      notifyListeners();
    }
  }

  // -- Persistence --

  void _saveSyncState() {
    _storage?.setMonitorLastHash(_lastHash);
    if (_lastSyncTime != null) {
      _storage?.setMonitorLastSyncTime(_lastSyncTime!.millisecondsSinceEpoch);
    }
  }

  void _loadSyncState() {
    if (_storage == null) return;
    final hash = _storage!.monitorLastHash;
    if (hash != null && hash.isNotEmpty) {
      _lastHash = hash;
    }
    final ms = _storage!.monitorLastSyncTimeMs;
    if (ms != null) {
      _lastSyncTime = DateTime.fromMillisecondsSinceEpoch(ms);
    }
    _autoSyncOnResume = _storage!.autoSyncOnResume;
    _notificationSync = _storage!.notificationSync;
  }

  void _saveIgnoreHashes() {
    _storage?.setMonitorIgnoreHashes(_ignoreHashes.toList());
  }

  void _loadIgnoreHashes() {
    if (_storage == null) return;
    final hashes = _storage!.monitorIgnoreHashes;
    _ignoreHashes.clear();
    _ignoreHashes.addAll(hashes.take(_maxIgnoreHashes));
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }
}
