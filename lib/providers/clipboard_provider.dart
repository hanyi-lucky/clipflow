import 'dart:async';
import 'dart:io' show Platform;
import 'dart:ui' show AppExitResponse, ViewFocusEvent;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';
import '../models/clipboard_entry.dart';
import '../services/sync_service.dart';
import '../services/encryption_service.dart';
import '../services/history_service.dart';
import '../services/clipboard_monitor.dart';
import '../repositories/local_storage.dart';
import '../repositories/cloud_repository.dart';
import '../core/constants.dart';
import 'settings_provider.dart';

/// Mixin providing default no-op implementations for WidgetsBindingObserver.
/// Only override didChangeAppLifecycleState in ClipboardProvider.
mixin _DefaultWidgetsBindingObserver implements WidgetsBindingObserver {
  @override void didChangeAccessibilityFeatures() {}
  @override void didChangeAppLifecycleState(AppLifecycleState state) {}
  @override void didChangeLocales(List<Locale>? locales) {}
  @override void didChangeMetrics() {}
  @override void didChangePlatformBrightness() {}
  @override void didChangeTextScaleFactor() {}
  @override void didChangeViewFocus(ViewFocusEvent event) {}
  @override void didHaveMemoryPressure() {}
  @override Future<bool> didPopRoute() async => false;
  @override Future<bool> didPushRoute(String route) async => false;
  @override Future<bool> didPushRouteInformation(RouteInformation routeInformation) async => false;
  @override Future<AppExitResponse> didRequestAppExit() async => AppExitResponse.exit;
  @override bool handleStartBackGesture(PredictiveBackEvent backEvent) => false;
  @override void handleUpdateBackGestureProgress(PredictiveBackEvent backEvent) {}
  @override void handleCommitBackGesture() {}
  @override void handleCancelBackGesture() {}
  @override void handleStatusBarTap() {}
}

enum SyncStatus {
  connected('已连接', Colors.green),
  syncing('同步中...', Colors.orange),
  error('同步失败', Colors.red),
  disconnected('未连接', Colors.grey),
  paused('已暂停同步', Colors.blueGrey);

  final String label;
  final Color color;
  const SyncStatus(this.label, this.color);
}

class ClipboardProvider extends ChangeNotifier with _DefaultWidgetsBindingObserver {
  /// Convenience method to access ClipboardProvider from the widget tree
  static ClipboardProvider of(BuildContext context, {bool listen = true}) {
    return Provider.of<ClipboardProvider>(context, listen: listen);
  }
  final HistoryService _historyService = HistoryService(maxEntries: AppConstants.maxHistoryEntries);
  final EncryptionService _encryption = EncryptionService();

  ClipboardMonitor? _monitor;
  SyncService? _syncService;
  CloudRepository? _cloudRepo;
  LocalStorage? _storage;
  SettingsProvider? _settingsProvider;

  SyncStatus _syncStatus = SyncStatus.disconnected;
  String? _errorMessage;
  bool _isMergeMode = false;
  final Set<String> _selectedIds = {};
  String _mergeSeparator = '\n';
  Timer? _uploadDebounce;
  Timer? _syncTimer;
  bool _serverConnected = false;

  List<ClipboardEntry> get history => _historyService.entries;
  SyncStatus get syncStatus => _syncStatus;
  String? get errorMessage => _errorMessage;
  bool get isMergeMode => _isMergeMode;
  Set<String> get selectedIds => Set.unmodifiable(_selectedIds);
  String get mergeSeparator => _mergeSeparator;
  bool get serverConnected => _serverConnected;

  // Proxy getters to ClipboardMonitor
  String get monitorSyncStatus => _monitor?.syncStatus ?? 'idle';
  DateTime? get monitorLastSyncTime => _monitor?.lastSyncTime;

  /// Last sync time for UI display (exposed for HomeScreen status bar)
  DateTime? get lastSyncTime => _monitor?.lastSyncTime;

  List<ClipboardEntry> get selectedEntries {
    final entries = _historyService.entries.where((e) => _selectedIds.contains(e.id)).toList();
    entries.sort((a, b) {
      final orderA = _selectedIds.toList().indexOf(a.id);
      final orderB = _selectedIds.toList().indexOf(b.id);
      return orderA.compareTo(orderB);
    });
    return entries;
  }

  String get mergePreview =>
      selectedEntries.map((e) => e.content).join(_mergeSeparator);

  /// Set the SettingsProvider reference for lifecycle-aware sync decisions
  void setSettingsProvider(SettingsProvider settings) {
    _settingsProvider = settings;
  }

  Future<void> initialize({
    required LocalStorage storage,
    required CloudRepository cloudRepo,
    required String deviceId,
    required String deviceName,
    required Uint8List encryptionKey,
  }) async {
    _storage = storage;
    _cloudRepo = cloudRepo;

    final savedHistory = storage.historyJson;
    if (savedHistory != null) {
      _historyService.fromJson(savedHistory);
    }

    _syncService = SyncService(
      repo: cloudRepo,
      encryption: _encryption,
      deviceId: deviceId,
      deviceName: deviceName,
      devicePlatform: Platform.operatingSystem,
      key: encryptionKey,
    );

    _monitor = ClipboardMonitor(onChanged: _onClipboardChanged, storage: storage);
    _monitor!.setSyncService(_syncService);
    _monitor!.loadState();
    // Forward monitor state changes to UI
    _monitor!.addListener(_onMonitorChanged);
    await _monitor!.start();

    // Register lifecycle observer
    WidgetsBinding.instance.addObserver(this);

    // Only start sync loop if background sync is enabled (or no settings yet)
    if (_settingsProvider?.backgroundSync ?? true) {
      _startSyncLoop();
    } else {
      _setStatus(SyncStatus.paused);
    }

    // Start foreground service if notification sync is enabled
    debugPrint('[CLIP-PROVIDER] _settingsProvider: ${_settingsProvider != null ? "set" : "NULL"}');
    debugPrint('[CLIP-PROVIDER] notificationSync: ${_settingsProvider?.notificationSync}');
    if (_settingsProvider?.notificationSync ?? true) {
      debugPrint('[CLIP-PROVIDER] Starting sync service...');
      startSyncService();
    }

    notifyListeners();
  }

  // -- WidgetsBindingObserver --

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && Platform.isAndroid) {
      if (_settingsProvider?.autoSyncOnResume ?? true) {
        _monitor?.syncClipboard();
      }
    }
  }

  // -- External sync trigger --

  /// External entry point for triggering sync (e.g., from notification action)
  Future<void> triggerSync() async {
    await _monitor?.syncClipboard();
  }

  /// Start the background sync service (notification-driven sync)
  Future<void> startSyncService() async {
    _monitor?.notificationSync = true;
    if (Platform.isAndroid) {
      const channel = MethodChannel('clipflow/clipboard');
      try {
        await channel.invokeMethod('startSyncService');
        print('[CLIP-PROVIDER] Native startSyncService invoked');
      } catch (e) {
        print('[CLIP-PROVIDER] startSyncService ERROR: $e');
      }
    }
    _startSyncLoop();
  }

  /// Stop the background sync service
  Future<void> stopSyncService() async {
    _monitor?.notificationSync = false;
    if (Platform.isAndroid) {
      const channel = MethodChannel('clipflow/clipboard');
      try {
        await channel.invokeMethod('stopSyncService');
        print('[CLIP-PROVIDER] Native stopSyncService invoked');
      } catch (e) {
        print('[CLIP-PROVIDER] stopSyncService ERROR: $e');
      }
    }
    _syncTimer?.cancel();
    _syncTimer = null;
  }

  /// Stop all sync activity (used when user disables background sync)
  void stopSync() {
    _monitor?.pause();
    _syncTimer?.cancel();
    _syncTimer = null;
    _setStatus(SyncStatus.paused);
  }

  /// Resume sync after it was stopped (e.g., user re-enables background sync)
  void resumeSync() {
    _monitor?.resume();
    _startSyncLoop();
    _setStatus(SyncStatus.connected);
  }

  /// Proxy to ClipboardMonitor for notification permission check
  Future<bool> checkNotificationPermission() async {
    return await _monitor?.checkNotificationPermission() ?? false;
  }

  /// Proxy to ClipboardMonitor for battery optimization check
  Future<bool> checkBatteryOptimization() async {
    return await _monitor?.checkBatteryOptimization() ?? false;
  }

  // -- Existing logic (with modifications) --

  /// Forward monitor state changes (syncStatus, isSyncing, etc.) to UI
  void _onMonitorChanged() {
    notifyListeners();
  }

  void _onClipboardChanged(String content) {
    _uploadDebounce?.cancel();
    _uploadDebounce = Timer(AppConstants.uploadDebounce, () {
      _uploadContent(content);
    });
  }

  Future<void> _uploadContent(String content) async {
    if (_syncService == null) return;
    _setStatus(SyncStatus.syncing);

    try {
      final uploaded = await _syncService!.uploadContent(content);

      // 只有真正上传成功才创建本地历史记录（跳过从其他设备同步来的内容）
      if (uploaded) {
        _historyService.addEntry(ClipboardEntry(
          id: const Uuid().v4(),
          content: content,
          sourceDeviceId: 'local',
          sourceDeviceName: '本设备',
          sourcePlatform: Platform.operatingSystem,
          timestamp: DateTime.now(),
          type: ContentType.text,
        ));
        await _saveHistory();
        notifyListeners();
      }

      _serverConnected = true;
      _setStatus(SyncStatus.connected);
    } catch (e) {
      _errorMessage = e.toString();
      _serverConnected = false;
      _setStatus(SyncStatus.error);
    }
  }

  void _startSyncLoop() {
    _syncTimer?.cancel(); // 防止 Timer 泄漏
    _syncTimer = Timer.periodic(AppConstants.pollInterval, (_) async {
      if (_syncService == null || _cloudRepo == null) return;
      if (_syncStatus == SyncStatus.paused) return;

      try {
        final content = await _syncService!.downloadLatestContent();
        if (content != null && content.isNotEmpty) {
          // 标记为已下载，防止监听器重复上传
          _syncService!.markAsDownloaded(content);

          // Add to ignoreHashes so syncClipboard() won't re-upload this content
          final contentHash = _syncService!.lastUploadedHash;
          _monitor?.addIgnoreHash(contentHash);

          _monitor?.pause();
          await Clipboard.setData(ClipboardData(text: content));
          await Future.delayed(const Duration(milliseconds: 100));
          _monitor?.resume();

          final current = await _cloudRepo!.getCurrentClipboard();
          if (current != null) {
            _historyService.addEntry(ClipboardEntry(
              id: const Uuid().v4(),
              content: content,
              sourceDeviceId: current['source_device'] as String? ?? 'unknown',
              sourceDeviceName: current['source_device_name'] as String? ?? 'Unknown',
              sourcePlatform: current['source_platform'] as String? ?? 'unknown',
              timestamp: DateTime.fromMillisecondsSinceEpoch(current['timestamp'] as int),
              type: ContentType.text,
            ));
            await _saveHistory();
            notifyListeners(); // 通知 UI 刷新
          }
        }
        _serverConnected = true;
        _setStatus(SyncStatus.connected);
      } catch (e) {
        _errorMessage = e.toString();
        _serverConnected = false;
        _setStatus(SyncStatus.error);
      }
    });
  }

  Future<void> refresh() async {
    _setStatus(SyncStatus.syncing);
    if (_syncService != null) {
      try {
        final content = await _syncService!.downloadLatestContent();
        if (content != null && content.isNotEmpty) {
          // Add to ignoreHashes
          final contentHash = _syncService!.lastUploadedHash;
          _monitor?.addIgnoreHash(contentHash);

          _monitor?.pause();
          await Clipboard.setData(ClipboardData(text: content));
          await Future.delayed(const Duration(milliseconds: 100));
          _monitor?.resume();
        }
        _serverConnected = true;
        _setStatus(SyncStatus.connected);
      } catch (e) {
        _errorMessage = e.toString();
        _serverConnected = false;
        _setStatus(SyncStatus.error);
      }
    }
    notifyListeners();
  }

  Future<void> copyEntry(String id) async {
    final entry = _historyService.entries.firstWhere((e) => e.id == id);
    _monitor?.pause();
    await Clipboard.setData(ClipboardData(text: entry.content));
    await Future.delayed(const Duration(milliseconds: 100));
    _monitor?.resume();
  }

  void togglePin(String id) {
    _historyService.togglePin(id);
    notifyListeners();
  }

  void removeEntry(String id) {
    _historyService.removeEntry(id);
    _selectedIds.remove(id);
    notifyListeners();
  }

  void enterMergeMode() {
    _isMergeMode = true;
    notifyListeners();
  }

  void exitMergeMode() {
    _isMergeMode = false;
    _selectedIds.clear();
    notifyListeners();
  }

  void toggleSelection(String id) {
    if (_selectedIds.contains(id)) {
      _selectedIds.remove(id);
    } else {
      _selectedIds.add(id);
    }
    notifyListeners();
  }

  void selectAll() {
    _selectedIds.addAll(_historyService.entries.map((e) => e.id));
    notifyListeners();
  }

  void setSeparator(String separator) {
    _mergeSeparator = separator;
    notifyListeners();
  }

  Future<void> copyMerged() async {
    final merged = mergePreview;
    _monitor?.pause();
    await Clipboard.setData(ClipboardData(text: merged));
    await Future.delayed(const Duration(milliseconds: 100));
    _monitor?.resume();
    exitMergeMode();
  }

  void _setStatus(SyncStatus status) {
    if (_syncStatus != status) {
      _syncStatus = status;
      notifyListeners();
    }
  }

  Future<void> _saveHistory() async {
    await _storage?.setHistoryJson(_historyService.toJson());
  }

  @override
  void dispose() {
    _uploadDebounce?.cancel();
    _syncTimer?.cancel();
    _monitor?.removeListener(_onMonitorChanged);
    _monitor?.stop();
    _monitor?.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}
