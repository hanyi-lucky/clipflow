import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:ui' show AppExitResponse, ViewFocusEvent;
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show debugPrint;
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
  Timer? _nextSyncTimer;
  final Set<String> _recentlyDeletedHashes = {};
  int _consecutiveFailures = 0;
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
    final orderMap = <String, int>{};
    var i = 0;
    for (final id in _selectedIds) {
      orderMap[id] = i++;
    }
    final entries = _historyService.entries.where((e) => _selectedIds.contains(e.id)).toList();
    entries.sort((a, b) => (orderMap[a.id] ?? 0).compareTo(orderMap[b.id] ?? 0));
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

    // 不从本地存储加载旧历史（可能包含错误的设备名）
    // 改为从服务器加载正确的历史记录

    _syncService = SyncService(
      repo: cloudRepo,
      encryption: _encryption,
      deviceId: deviceId,
      deviceName: deviceName,
      devicePlatform: Platform.operatingSystem,
      key: encryptionKey,
    );

    // 从服务器加载历史记录（带有正确的设备来源信息）
    await _loadHistoryFromServer();

    _monitor = ClipboardMonitor(onChanged: _onClipboardChanged, storage: storage);
    _monitor!.setSyncService(_syncService!);
    _monitor!.onContentSynced = _addSyncedToHistory;
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
    if (_settingsProvider?.notificationSync ?? true) {
      startSyncService();
    }

    notifyListeners();
  }

  /// 从服务器加载历史记录，确保设备来源信息正确
  ///
  /// 全量加载策略：请求更大 limit（200），失败时保留当前内存历史，
  /// 加载后合并本地独有的条目（服务器没有的）。
  Future<void> _loadHistoryFromServer() async {
    if (_cloudRepo == null) return;
    try {
      final serverEntries = await _cloudRepo!.getHistoryEntries(limit: 200);

      // 保存当前本地独有的条目（服务器没有的）
      final serverIds = serverEntries.map((e) => e['id'] as String).toSet();
      final localOnlyEntries = _historyService.entries
          .where((e) => !serverIds.contains(e.id))
          .toList();

      _historyService.clear();

      // 反转顺序：从最旧到最新处理
      // 这样当 addEntry 的去重逻辑遇到重复内容时，
      // 最新条目的设备名会覆盖最旧条目的设备名
      final reversed = serverEntries.reversed.toList();

      for (final entry in reversed) {
        final content = entry['content'] as String? ?? '';
        if (content.isEmpty) continue;

        // 解密内容，失败则跳过该条目
        String decryptedContent;
        try {
          decryptedContent = await _syncService!.decryptContent(content);
        } catch (e) {
          continue;
        }

        _historyService.addEntry(ClipboardEntry(
          id: entry['id'] as String? ?? const Uuid().v4(),
          content: decryptedContent,
          sourceDeviceId: entry['source_device'] as String? ?? 'unknown',
          sourceDeviceName: entry['source_device_name'] as String? ?? 'Unknown',
          sourcePlatform: entry['source_platform'] as String? ?? 'unknown',
          timestamp: DateTime.fromMillisecondsSinceEpoch(entry['timestamp'] as int? ?? 0),
          type: ContentType.text,
          isPinned: (entry['pinned'] as int?) == 1,
        ));
      }

      // 合并本地独有的条目（服务器没有的）
      for (final entry in localOnlyEntries) {
        _historyService.addEntry(entry);
      }

      await _saveHistory();
    } catch (e) {
      _errorMessage = '从服务器加载历史失败: $e';
      notifyListeners();
      // 失败时保留当前内存历史，不清空
      if (_historyService.entries.isEmpty) {
        final savedHistory = _storage?.historyJson;
        if (savedHistory != null) {
          _historyService.fromJson(savedHistory);
        }
      }
    }
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
        debugPrint('[CLIP-PROVIDER] Native startSyncService invoked');
      } catch (e) {
        debugPrint('[CLIP-PROVIDER] startSyncService ERROR: $e');
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
        debugPrint('[CLIP-PROVIDER] Native stopSyncService invoked');
      } catch (e) {
        debugPrint('[CLIP-PROVIDER] stopSyncService ERROR: $e');
      }
    }
    _syncTimer?.cancel();
    _syncTimer = null;
    _nextSyncTimer?.cancel();
    _nextSyncTimer = null;
  }

  /// Stop all sync activity (used when user disables background sync)
  void stopSync() {
    _monitor?.pause();
    _syncTimer?.cancel();
    _syncTimer = null;
    _nextSyncTimer?.cancel();
    _nextSyncTimer = null;
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

  /// Add synced content to local history (called by monitor after upload)
  void _addSyncedToHistory(String content, String serverId) {
    _historyService.addEntry(ClipboardEntry(
      id: serverId,
      content: content,
      sourceDeviceId: _syncService!.deviceId,
      sourceDeviceName: _syncService!.deviceName,
      sourcePlatform: Platform.operatingSystem,
      timestamp: DateTime.now(),
      type: ContentType.text,
    ));
    _saveHistory();
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

    // 截断超长内容
    final truncatedContent = content.length > AppConstants.maxContentLength
        ? content.substring(0, AppConstants.maxContentLength)
        : content;

    _setStatus(SyncStatus.syncing);

    try {
      final serverId = await _syncService!.uploadContent(truncatedContent);

      // 只有真正上传成功才创建本地历史记录（跳过从其他设备同步来的内容）
      if (serverId != null) {
        _historyService.addEntry(ClipboardEntry(
          id: serverId,
          content: truncatedContent,
          sourceDeviceId: _syncService!.deviceId,
          sourceDeviceName: _syncService!.deviceName,
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
    _syncTimer?.cancel();
    _nextSyncTimer?.cancel();
    _consecutiveFailures = 0;
    // 启动时立即执行一次同步，确保数据最新
    _setStatus(SyncStatus.syncing);
    _syncTick();
  }

  void _scheduleNextSync() {
    final delay = _consecutiveFailures == 0
        ? AppConstants.pollInterval
        : Duration(
            milliseconds: (AppConstants.pollInterval.inMilliseconds * (1 << _consecutiveFailures.clamp(0, 6)))
                .clamp(500, 30000),
          );
    _nextSyncTimer = Timer(delay, _syncTick);
  }

  Future<void> _syncTick() async {
    if (_syncService == null || _cloudRepo == null) return;
    if (_syncStatus == SyncStatus.paused) {
      _scheduleNextSync();
      return;
    }

    try {
      final result = await _syncService!.downloadLatestContent();

      // 处理删除同步：从本地历史中移除被其他设备删除的条目
      if (result != null && result.deletedIds.isNotEmpty) {
        for (final id in result.deletedIds) {
          _historyService.removeEntry(id);
        }
        await _saveHistory();
        notifyListeners();
      }

      // 处理恢复同步：将其他设备恢复的条目添加回本地历史
      if (result != null && result.restoredEntries.isNotEmpty) {
        for (final entry in result.restoredEntries) {
          final content = entry['content'] as String? ?? '';
          if (content.isEmpty) continue;
          // 解密内容
          String decryptedContent;
          try {
            decryptedContent = await _syncService!.decryptContent(content);
          } catch (e) {
            continue;
          }
          // 跳过已删除的内容
          final restoredHash = sha256.convert(utf8.encode(decryptedContent)).toString();
          if (_recentlyDeletedHashes.contains(restoredHash)) continue;
          _historyService.addEntry(ClipboardEntry(
            id: entry['id'] as String? ?? const Uuid().v4(),
            content: decryptedContent,
            sourceDeviceId: entry['source_device'] as String? ?? 'unknown',
            sourceDeviceName: entry['source_device_name'] as String? ?? 'Unknown',
            sourcePlatform: entry['source_platform'] as String? ?? 'unknown',
            timestamp: DateTime.fromMillisecondsSinceEpoch(entry['timestamp'] as int? ?? 0),
            type: ContentType.text,
          ));
        }
        await _saveHistory();
        notifyListeners();
      }

      if (result != null && result.content.isNotEmpty) {
        // 跳过已删除的内容
        final syncContentHash = sha256.convert(utf8.encode(result.content)).toString();
        if (_recentlyDeletedHashes.contains(syncContentHash)) {
          _syncService!.markAsDownloaded(result.content);
        } else {
          _syncService!.markAsDownloaded(result.content);

          final contentHash = _syncService!.lastUploadedHash;
          _monitor?.addIgnoreHash(contentHash);

          _monitor?.pause();
          await Clipboard.setData(ClipboardData(text: result.content));
          await Future.delayed(const Duration(milliseconds: 50));
          _monitor?.resume();

          _historyService.addEntry(ClipboardEntry(
            id: const Uuid().v4(),
            content: result.content,
            sourceDeviceId: result.sourceDeviceId,
            sourceDeviceName: result.sourceDeviceName,
            sourcePlatform: result.sourcePlatform,
            timestamp: result.timestamp,
            type: ContentType.text,
          ));
          await _saveHistory();
          notifyListeners();
          // 内容处理成功后才标记时间戳，防止处理失败导致该内容被永久跳过
          _syncService!.markAsReceived(result.timestamp);
        }
      }
      _consecutiveFailures = 0;
      _serverConnected = true;
      _setStatus(SyncStatus.connected);
    } catch (e) {
      _consecutiveFailures++;
      _errorMessage = e.toString();
      _serverConnected = false;
      _setStatus(SyncStatus.error);
    }
    _scheduleNextSync();
  }

  Future<void> refresh() async {
    _setStatus(SyncStatus.syncing);
    // 暂停 sync loop 防止并发
    _nextSyncTimer?.cancel();
    try {
      // 全量加载历史
      await _loadHistoryFromServer();
      // 下载最新 clipboard
      if (_syncService != null) {
        final result = await _syncService!.downloadLatestContent();
        if (result != null && result.hasContent) {
          _monitor?.pause();
          await Clipboard.setData(ClipboardData(text: result.content));
          await Future.delayed(const Duration(milliseconds: 50));
          _monitor?.resume();
          _syncService!.markAsDownloaded(result.content);
        }
        // 处理删除同步
        if (result != null && result.hasDeletions) {
          for (final id in result.deletedIds) {
            _historyService.removeEntry(id);
          }
        }
        // 处理恢复同步
        if (result != null && result.hasRestorations) {
          for (final entry in result.restoredEntries) {
            final content = entry['content'] as String? ?? '';
            if (content.isEmpty) continue;
            try {
              final decrypted = await _syncService!.decryptContent(content);
              _historyService.addEntry(ClipboardEntry(
                id: entry['id'] as String? ?? const Uuid().v4(),
                content: decrypted,
                sourceDeviceId: entry['source_device'] as String? ?? 'unknown',
                sourceDeviceName: entry['source_device_name'] as String? ?? 'Unknown',
                sourcePlatform: entry['source_platform'] as String? ?? 'unknown',
                timestamp: DateTime.fromMillisecondsSinceEpoch(entry['timestamp'] as int? ?? 0),
                type: ContentType.text,
              ));
            } catch (e) {
              continue;
            }
          }
        }
      }
      await _saveHistory();
      _serverConnected = true;
      _setStatus(SyncStatus.connected);
    } catch (e) {
      _errorMessage = e.toString();
      _serverConnected = false;
      _setStatus(SyncStatus.error);
    }
    // 恢复 sync loop
    _consecutiveFailures = 0;
    _scheduleNextSync();
    notifyListeners();
  }

  Future<void> copyEntry(String id) async {
    final entry = _historyService.entries.firstWhere((e) => e.id == id);
    _monitor?.pause();
    await Clipboard.setData(ClipboardData(text: entry.content));
    await Future.delayed(const Duration(milliseconds: 50));
    _monitor?.resume();
  }

  Future<void> togglePin(String id) async {
    _historyService.togglePin(id);
    notifyListeners();
    try {
      final entry = _historyService.entries.firstWhere((e) => e.id == id);
      await _cloudRepo?.updateHistoryEntry(id, {'pinned': entry.isPinned ? 1 : 0});
    } catch (e) {
      // 乐观更新，失败不回滚
    }
  }

  Future<void> removeEntry(String id) async {
    // 记录已删除内容的 hash，防止 sync loop 重新下载
    final entry = _historyService.entries.where((e) => e.id == id).firstOrNull;
    if (entry != null) {
      _recentlyDeletedHashes.add(entry.contentHash);
      // 30秒后清除，避免长期占用内存
      Timer(const Duration(seconds: 30), () {
        _recentlyDeletedHashes.remove(entry.contentHash);
      });
    }
    _historyService.removeEntry(id);
    _selectedIds.remove(id);
    notifyListeners();
    try {
      await _cloudRepo?.deleteHistoryEntry(id);
    } catch (e) {
      // 乐观更新，失败不回滚
    }
  }

  /// 恢复已删除的条目
  ///
  /// 仅调用服务器 API，不触发全量加载。
  /// 恢复的条目将通过 sync loop 的 restoredEntries 处理自动同步回来。
  Future<void> restoreEntry(String id) async {
    try {
      await _cloudRepo?.restoreHistoryEntry(id);
      // 不调用 _loadHistoryFromServer，让 sync loop 处理
      notifyListeners();
    } catch (e) {
      _errorMessage = '恢复失败: $e';
      notifyListeners();
    }
  }

  /// 获取垃圾箱条目
  Future<List<Map<String, dynamic>>> getTrashEntries() async {
    if (_cloudRepo == null) return [];
    try {
      final entries = await _cloudRepo!.getTrashEntries();
      // 解密每条内容
      for (final entry in entries) {
        final encrypted = entry['content'] as String? ?? '';
        if (encrypted.isNotEmpty && _syncService != null) {
          try {
            entry['content'] = await _syncService!.decryptContent(encrypted);
          } catch (e) {
            entry['content'] = '[解密失败]';
          }
        }
      }
      return entries;
    } catch (e) {
      return [];
    }
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
    await Future.delayed(const Duration(milliseconds: 50));
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
    _nextSyncTimer?.cancel();
    _monitor?.removeListener(_onMonitorChanged);
    _monitor?.stop();
    _monitor?.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}
