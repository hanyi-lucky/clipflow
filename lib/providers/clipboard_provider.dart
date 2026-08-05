import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform, SocketException;
import 'dart:ui' show AppExitResponse, ViewFocusEvent;
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';
import '../models/clipboard_entry.dart';
import '../models/clipboard_image.dart';
import '../services/sync_service.dart';
import '../services/encryption_service.dart';
import '../services/history_service.dart';
import '../services/clipboard_monitor.dart';
import '../services/image_clipboard_service.dart';
import '../services/image_compression_service.dart';
import '../repositories/local_storage.dart';
import '../repositories/cloud_repository.dart';
import '../repositories/local_image_store.dart';
import '../core/constants.dart';
import '../core/exceptions.dart';
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
  ClipboardProvider({LocalImageStore? imageStore})
      : _localImageStore = imageStore ?? LocalImageStore();

  /// Convenience method to access ClipboardProvider from the widget tree
  static ClipboardProvider of(BuildContext context, {bool listen = true}) {
    return Provider.of<ClipboardProvider>(context, listen: listen);
  }
  final HistoryService _historyService = HistoryService(maxEntries: AppConstants.maxHistoryEntries);
  final EncryptionService _encryption = EncryptionService();
  final ImageClipboardService _imageClipboardService = ImageClipboardService();
  final ImageCompressionService _imageCompressionService = ImageCompressionService();
  final LocalImageStore _localImageStore;

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
  // Search/filter state
  String _searchQuery = '';
  ContentType? _activeTypeFilter;
  String? _activeDeviceFilter;
  Timer? _uploadDebounce;
  Timer? _syncTimer;
  Timer? _nextSyncTimer;
  final Set<String> _recentlyDeletedHashes = {};
  int _consecutiveFailures = 0;
  bool _serverConnected = false;
  bool _disposed = false;
  // 并发保护
  bool _isLoadingHistory = false;
  bool _isRefreshing = false;
  // 历史落盘节流
  Timer? _saveDebounceTimer;
  bool _savePending = false;

  List<ClipboardEntry> get history => _historyService.entries;
  SyncStatus get syncStatus => _syncStatus;
  String? get errorMessage => _errorMessage;
  bool get isMergeMode => _isMergeMode;
  Set<String> get selectedIds => Set.unmodifiable(_selectedIds);
  String get mergeSeparator => _mergeSeparator;
  bool get serverConnected => _serverConnected;

  bool get hasActiveFilters =>
      _searchQuery.isNotEmpty || _activeTypeFilter != null || _activeDeviceFilter != null;

  ContentType? get activeTypeFilter => _activeTypeFilter;
  String? get activeDeviceFilter => _activeDeviceFilter;
  String get searchQuery => _searchQuery;

  List<ClipboardEntry> get filteredHistory {
    var results = _historyService.entries;

    // Type filter
    if (_activeTypeFilter != null) {
      results = results.where((e) => e.type == _activeTypeFilter).toList();
    }

    // Device filter
    if (_activeDeviceFilter != null) {
      results = results.where((e) => e.sourceDeviceName == _activeDeviceFilter).toList();
    }

    // Keyword search (fuzzy, case-insensitive)
    if (_searchQuery.isNotEmpty) {
      final query = _searchQuery.toLowerCase();
      results = results.where((e) {
        switch (e.type) {
          case ContentType.text:
            return e.content.toLowerCase().contains(query);
          case ContentType.image:
            return false;
          case ContentType.file:
            return false; // v1.4: match by fileName
        }
      }).toList();
    }

    return results;
  }

  List<String> get availableDevices {
    return _historyService.entries
        .map((e) => e.sourceDeviceName)
        .toSet()
        .toList();
  }

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
    // 多选拼接仅文本：图片条目不参与
    final entries = _historyService.entries
        .where((e) => _selectedIds.contains(e.id) && e.type == ContentType.text)
        .toList();
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
    clearFilters();
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

    _monitor = ClipboardMonitor(onChanged: _onClipboardChanged, storage: storage);
    _monitor!.setSyncService(_syncService!);
    _monitor!.onContentSynced = _addSyncedToHistory;
    _monitor!.onImageChanged = _onImageClipboardChanged;
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

    // 后台异步加载历史，不阻塞解锁流程
    _loadHistoryFromServer().then((_) {
      notifyListeners();
    }).catchError((e) {
      debugPrint('[CLIP-PROVIDER] Background history load failed: $e');
    });
  }

  /// 从服务器加载历史记录，确保设备来源信息正确
  ///
  /// 全量加载策略：请求更大 limit（200），失败时保留当前内存历史，
  /// 加载后合并本地独有的条目（服务器没有的）。
  Future<void> _loadHistoryFromServer() async {
    if (_cloudRepo == null) return;
    if (_isLoadingHistory) return; // 防重入
    _isLoadingHistory = true;
    try {
      final serverEntries = await _cloudRepo!.getHistoryEntries(limit: 200);

      // 读取持久化的已删 ID 集合；若服务器仍返回这些行，再次尝试删除
      final originalDeletedIds = Set<String>.from(
          _storage?.deletedEntryIds ?? <String>{});
      if (originalDeletedIds.isNotEmpty) {
        final stillOnServer = serverEntries
            .where((e) => originalDeletedIds.contains(e['id'] as String))
            .toList();
        final failedIds = Set<String>.from(originalDeletedIds);
        for (final entry in stillOnServer) {
          final eid = entry['id'] as String;
          try {
            await _cloudRepo!.deleteHistoryEntry(eid);
            failedIds.remove(eid);
          } catch (_) {
            // 删除失败保留 ID，下次 refresh 重试
          }
        }
        await _storage?.setDeletedEntryIds(failedIds);
      }

      // 过滤：排除所有在原始已删集合中的条目（无论重删是否成功）
      final filteredEntries = serverEntries
          .where((e) => !originalDeletedIds.contains(e['id'] as String))
          .toList();

      // 保存当前本地独有的条目（服务器没有的）
      final serverIds = filteredEntries.map((e) => e['id'] as String).toSet();
      final localOnlyEntries = _historyService.entries
          .where((e) => !serverIds.contains(e.id))
          .toList();

      _historyService.clear();

      // 反转顺序：从最旧到最新处理
      // 这样当 addEntry 的去重逻辑遇到重复内容时，
      // 最新条目的设备名会覆盖最旧条目的设备名
      final reversed = filteredEntries.reversed.toList();
      final needsFallback = <Map<String, dynamic>>[];

      for (final entry in reversed) {
        final type = entry['type'] as String? ?? 'text';

        // 图片行：只解密缩略图，全图惰性加载
        if (type == ContentType.image.name) {
          final thumbBase64 = entry['thumb'] as String? ?? '';
          if (thumbBase64.isEmpty) continue;
          Uint8List thumbBytes;
          try {
            thumbBytes = await _syncService!.decryptImage(thumbBase64);
          } catch (e) {
            continue;
          }
          _historyService.addEntry(ClipboardEntry(
            id: entry['id'] as String? ?? const Uuid().v4(),
            content: '',
            sourceDeviceId: entry['source_device'] as String? ?? 'unknown',
            sourceDeviceName: entry['source_device_name'] as String? ?? 'Unknown',
            sourcePlatform: entry['source_platform'] as String? ?? 'unknown',
            timestamp: DateTime.fromMillisecondsSinceEpoch(entry['timestamp'] as int? ?? 0),
            type: ContentType.image,
            imageThumbBytes: thumbBytes,
            imageThumbEncryptedBase64: thumbBase64,
            imageWidth: entry['width'] as int?,
            imageHeight: entry['height'] as int?,
            imageFormat: entry['format'] as String?,
            stableHash: entry['hash'] as String?,
          ));
          continue;
        }

        final content = entry['content'] as String? ?? '';
        if (content.isEmpty) continue;

        // 先尝试直接解密（大部分短密文能成功，无需网络回补）
        String? decryptedContent;
        try {
          decryptedContent = await _syncService!.decryptContent(content);
        } catch (_) {
          // 直接解密失败，收集待回补
        }

        if (decryptedContent != null) {
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
        } else {
          // 收集待回补条目，后续并行拉取
          needsFallback.add(entry);
        }
      }

      // 第二阶段：并行回补解密失败的文本条目（/content 拉全量密文）
      if (needsFallback.isNotEmpty) {
        const concurrency = 4;
        for (var i = 0; i < needsFallback.length; i += concurrency) {
          final batch = needsFallback.skip(i).take(concurrency);
          final results = await Future.wait(
            batch.map((entry) async {
              final entryId = entry['id'] as String?;
              final content = entry['content'] as String;
              final result = await _fetchAndDecryptContent(entryId, content);
              return (entry: entry, decrypted: result);
            }),
          );
          for (final r in results) {
            if (r.decrypted == null) continue;
            final entry = r.entry;
            _historyService.addEntry(ClipboardEntry(
              id: entry['id'] as String? ?? const Uuid().v4(),
              content: r.decrypted!,
              sourceDeviceId: entry['source_device'] as String? ?? 'unknown',
              sourceDeviceName: entry['source_device_name'] as String? ?? 'Unknown',
              sourcePlatform: entry['source_platform'] as String? ?? 'unknown',
              timestamp: DateTime.fromMillisecondsSinceEpoch(entry['timestamp'] as int? ?? 0),
              type: ContentType.text,
              isPinned: (entry['pinned'] as int?) == 1,
            ));
          }
        }
      }

      // 合并本地独有的条目（服务器没有的）
      for (final entry in localOnlyEntries) {
        _historyService.addEntry(entry);
      }

      // 加载完成是关键操作，立即落盘（绕过节流）
      _saveDebounceTimer?.cancel();
      _savePending = false;
      await _storage?.setHistoryJson(_historyService.toJson());
      // 清理本地全图缓存中已不在历史里的孤儿文件
      await _localImageStore.cleanupOrphans(
        _historyService.entries.map((e) => e.id).toSet(),
      );
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
    } finally {
      _isLoadingHistory = false;
    }
  }

  /// 解密文本密文。列表响应中的 content 可能被服务端截断（≤10000 字符），
  /// 直接解密失败时按 id 经 GET /api/history/:id/content 拉全量密文重试一次；
  /// 仍失败返回 null（由调用方决定跳过条目或降级显示）。
  Future<String?> _decryptTextContentWithFallback(
    String? entryId,
    String content,
  ) async {
    try {
      return await _syncService!.decryptContent(content);
    } catch (_) {
      // 落入回补路径：可能是列表截断导致的 GCM 认证失败
    }
    if (entryId == null || _cloudRepo == null) return null;
    try {
      final fullEntry = await _cloudRepo!.getHistoryEntryContent(entryId);
      final fullContent = fullEntry?['content'] as String? ?? '';
      if (fullContent.isEmpty) return null;
      return await _syncService!.decryptContent(fullContent);
    } catch (_) {
      return null;
    }
  }

  /// 从服务器拉取全量密文并解密（用于并行回补，假设直接解密已失败）。
  Future<String?> _fetchAndDecryptContent(
    String? entryId,
    String content,
  ) async {
    if (entryId == null || _cloudRepo == null) return null;
    try {
      final fullEntry = await _cloudRepo!.getHistoryEntryContent(entryId);
      final fullContent = fullEntry?['content'] as String? ?? '';
      if (fullContent.isEmpty) return null;
      return await _syncService!.decryptContent(fullContent);
    } catch (_) {
      return null;
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

  void _onImageClipboardChanged(ClipboardImage image) {
    _uploadDebounce?.cancel();
    _uploadDebounce = Timer(AppConstants.uploadDebounce, () {
      _uploadImage(image);
    });
  }

  Future<void> _uploadImage(ClipboardImage image) async {
    if (_syncService == null) return;
    _setStatus(SyncStatus.syncing);

    try {
      final compressed = await _imageCompressionService.compress(image.bytes);

      if (compressed.bytes.length > AppConstants.maxImageBytes) {
        _errorMessage =
            '图片超过 ${AppConstants.maxImageBytes ~/ (1024 * 1024)}MB，已拒绝上传';
        _serverConnected = false;
        _setStatus(SyncStatus.error);
        return;
      }

      // 去重键用跨重编码稳定的像素内容哈希（P1 根治回声）
      final imageHash = compressed.stableHash;
      final result = await _syncService!.uploadImage(
        bytes: compressed.bytes,
        thumbBytes: compressed.thumbBytes,
        width: compressed.width,
        height: compressed.height,
        format: compressed.format,
        stableHash: imageHash,
      );

      // 只有真正上传成功才创建本地历史记录
      if (result != null) {
        _historyService.addEntry(ClipboardEntry(
          id: result.historyId,
          content: '',
          sourceDeviceId: _syncService!.deviceId,
          sourceDeviceName: _syncService!.deviceName,
          sourcePlatform: Platform.operatingSystem,
          timestamp: DateTime.now(),
          type: ContentType.image,
          imageThumbBytes: compressed.thumbBytes,
          imageThumbEncryptedBase64: result.encryptedThumbBase64,
          imageWidth: compressed.width,
          imageHeight: compressed.height,
          imageFormat: compressed.format,
          stableHash: imageHash,
        ));
        // 全图密文只落本地文件，不写 SharedPreferences
        await _localImageStore.save(result.historyId, result.encryptedBase64);
        _saveHistory();
        notifyListeners();
      }

      _serverConnected = true;
      _setStatus(SyncStatus.connected);
    } on ImageCompressionException catch (e) {
      // 无法解码的图片跳过，不影响文本路径
      debugPrint('[CLIP-PROVIDER] Image compression failed: $e');
      _serverConnected = true;
      _setStatus(SyncStatus.connected);
    } catch (e) {
      _errorMessage = e.toString();
      _serverConnected = false;
      _setStatus(SyncStatus.error);
    }
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
        _saveHistory();
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
    if (_disposed) return;
    final delay = _consecutiveFailures == 0
        ? AppConstants.pollInterval
        : Duration(
            milliseconds: (AppConstants.pollInterval.inMilliseconds * (1 << _consecutiveFailures.clamp(0, 6)))
                .clamp(500, 30000),
          );
    _nextSyncTimer = Timer(delay, _syncTick);
  }

  Future<void> _syncTick() async {
    if (_disposed) return;
    if (_syncService == null || _cloudRepo == null) return;
    if (_syncStatus == SyncStatus.paused) {
      _scheduleNextSync();
      return;
    }
    // 刷新进行中时跳过本轮，避免与 refresh 并发写历史
    if (_isRefreshing || _isLoadingHistory) {
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
        _saveHistory();
        notifyListeners();
      }

      // 处理恢复同步：将其他设备恢复的条目添加回本地历史
      if (result != null && result.restoredEntries.isNotEmpty) {
        await _handleRestoredEntries(result.restoredEntries);
      }

      if (result != null &&
          result.type == ContentType.image &&
          result.imageBytes != null) {
        final imageHash = result.imageHash ?? '';
        _syncService!.markAsDownloadedHash(imageHash);
        if (!_recentlyDeletedHashes.contains(imageHash)) {
          await _processImageDownload(result);
          // 图片完整写入剪切板并成功入历史后才推进时间戳
          _syncService!.markAsReceived(result.timestamp);
        }
      } else if (result != null && result.content.isNotEmpty) {
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
          _saveHistory();
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
      // 连续失败 ≥ 2 次才降级为 disconnected/error，首次失败保持原状态
      if (_consecutiveFailures >= 2) {
        _serverConnected = false;
        if (e is SocketException || e is TimeoutException) {
          _setStatus(SyncStatus.disconnected);
        } else {
          _setStatus(SyncStatus.error);
        }
      }
    }
    _scheduleNextSync();
  }

  /// 处理恢复同步条目：按 type 分流。
  ///
  /// image 行用缩略图密文重建条目（thumb 解密），全图密文按服务器 ID
  /// 落盘，恢复后全屏查看无需再拉服务器；text 行为保持原逻辑。
  Future<void> _handleRestoredEntries(
    List<Map<String, dynamic>> restoredEntries,
  ) async {
    var changed = false;
    for (final entry in restoredEntries) {
      final type = entry['type'] as String? ?? 'text';

      if (type == ContentType.image.name) {
        final entryId = entry['id'] as String? ?? const Uuid().v4();
        final hash = entry['hash'] as String? ?? '';
        if (hash.isNotEmpty && _recentlyDeletedHashes.contains(hash)) {
          continue;
        }
        final thumbBase64 = entry['thumb'] as String? ?? '';
        if (thumbBase64.isEmpty) continue;
        Uint8List thumbBytes;
        try {
          thumbBytes = await _syncService!.decryptImage(thumbBase64);
        } catch (e) {
          continue;
        }
        final fullEncrypted = entry['content'] as String?;

        // 条目已存在（如 refresh 先全量加载），只补全图缓存
        if (_historyService.entries.any((e) => e.id == entryId)) {
          if (fullEncrypted != null && fullEncrypted.isNotEmpty) {
            await _localImageStore.save(entryId, fullEncrypted);
          }
          continue;
        }

        _historyService.addEntry(ClipboardEntry(
          id: entryId,
          content: '',
          sourceDeviceId: entry['source_device'] as String? ?? 'unknown',
          sourceDeviceName: entry['source_device_name'] as String? ?? 'Unknown',
          sourcePlatform: entry['source_platform'] as String? ?? 'unknown',
          timestamp:
              DateTime.fromMillisecondsSinceEpoch(entry['timestamp'] as int? ?? 0),
          type: ContentType.image,
          imageThumbBytes: thumbBytes,
          imageThumbEncryptedBase64: thumbBase64,
          imageWidth: entry['width'] as int?,
          imageHeight: entry['height'] as int?,
          imageFormat: entry['format'] as String?,
          stableHash: hash.isEmpty ? null : hash,
        ));
        if (fullEncrypted != null && fullEncrypted.isNotEmpty) {
          await _localImageStore.save(entryId, fullEncrypted);
        }
        changed = true;
        continue;
      }

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
      changed = true;
    }
    if (changed) {
      // 恢复是关键操作，立即落盘（绕过节流）
      _saveDebounceTimer?.cancel();
      _savePending = false;
      await _storage?.setHistoryJson(_historyService.toJson());
      notifyListeners();
    }
  }

  /// 处理下载的图片：写剪切板、入历史、全图密文落盘
  Future<void> _processImageDownload(DownloadResult result) async {
    final imageBytes = result.imageBytes;
    if (imageBytes == null) return;

    _monitor?.pause();
    await _imageClipboardService.setImage(
      imageBytes,
      format: result.imageFormat ?? 'png',
    );
    // 回读实际写入剪切板的字节并登记循环防护：
    // macOS/Android 写入时会重编码，回读哈希才是监听器下一次比对的键域
    final readBack = await _imageClipboardService.getImage();
    if (readBack != null && readBack.bytes.isNotEmpty) {
      _monitor?.markImageAsWritten(readBack.bytes);
    }
    await Future.delayed(const Duration(milliseconds: 50));
    _monitor?.resume();

    // 下载条目与服务器历史行 ID 对齐（旧数据无 history_id 时回退 UUID）
    final entryId = (result.id != null && result.id!.isNotEmpty)
        ? result.id!
        : const Uuid().v4();

    final encrypted = result.imageEncryptedBase64;
    if (encrypted != null && encrypted.isNotEmpty) {
      await _localImageStore.save(entryId, encrypted);
    }

    // 已有同 ID 条目（如 refresh 先全量加载），只补缓存，不重复入史
    if (_historyService.entries.any((e) => e.id == entryId)) {
      return;
    }

    _historyService.addEntry(ClipboardEntry(
      id: entryId,
      content: '',
      sourceDeviceId: result.sourceDeviceId,
      sourceDeviceName: result.sourceDeviceName,
      sourcePlatform: result.sourcePlatform,
      timestamp: result.timestamp,
      type: ContentType.image,
      imageThumbBytes: result.imageThumbBytes,
      imageWidth: result.imageWidth,
      imageHeight: result.imageHeight,
      imageFormat: result.imageFormat,
      stableHash: result.imageHash,
    ));
    _saveHistory();
    notifyListeners();
  }

  Future<void> refresh() async {
    if (_isRefreshing) return; // 防重入
    _isRefreshing = true;
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
          if (result.type == ContentType.image) {
            _syncService!.markAsDownloadedHash(result.imageHash ?? '');
            await _processImageDownload(result);
          } else {
            _monitor?.pause();
            await Clipboard.setData(ClipboardData(text: result.content));
            await Future.delayed(const Duration(milliseconds: 50));
            _monitor?.resume();
            _syncService!.markAsDownloaded(result.content);
          }
        }
        // 处理删除同步
        if (result != null && result.hasDeletions) {
          for (final id in result.deletedIds) {
            _historyService.removeEntry(id);
          }
        }
        // 处理恢复同步
        if (result != null && result.hasRestorations) {
          await _handleRestoredEntries(result.restoredEntries);
        }
      }
      // 刷新完成是关键操作，立即落盘（绕过节流）
      _saveDebounceTimer?.cancel();
      _savePending = false;
      await _storage?.setHistoryJson(_historyService.toJson());
      _serverConnected = true;
      _setStatus(SyncStatus.connected);
    } catch (e) {
      // 不无条件置 error/disconnected，保留原状态（避免单次失败砸状态灯）
      _errorMessage = e.toString();
    }
    // 恢复 sync loop
    _consecutiveFailures = 0;
    _isRefreshing = false;
    _scheduleNextSync();
    notifyListeners();
  }

  Future<void> copyEntry(String id) async {
    final entry = _historyService.entries.firstWhere((e) => e.id == id);
    _monitor?.pause();
    if (entry.type == ContentType.image) {
      final bytes = await loadFullImageBytes(id);
      if (bytes != null) {
        await _imageClipboardService.setImage(
          bytes,
          format: entry.imageFormat ?? 'png',
        );
        // 同样回读登记防护，避免历史复制图片触发回声
        final readBack = await _imageClipboardService.getImage();
        if (readBack != null && readBack.bytes.isNotEmpty) {
          _monitor?.markImageAsWritten(readBack.bytes);
        }
      }
    } else {
      await Clipboard.setData(ClipboardData(text: entry.content));
    }
    await Future.delayed(const Duration(milliseconds: 50));
    _monitor?.resume();
  }

  /// 加载全图字节：本地缓存优先，未命中则从服务器拉取并缓存
  Future<Uint8List?> loadFullImageBytes(String entryId) async {
    if (_syncService == null || _cloudRepo == null) return null;
    try {
      final cached = await _localImageStore.load(entryId);
      if (cached != null && cached.isNotEmpty) {
        return await _syncService!.decryptImageIsolate(cached);
      }

      final serverEntry = await _cloudRepo!.getHistoryEntryContent(entryId);
      final encrypted = serverEntry?['content'] as String?;
      if (encrypted == null || encrypted.isEmpty) return null;

      await _localImageStore.save(entryId, encrypted);
      return await _syncService!.decryptImageIsolate(encrypted);
    } catch (e) {
      return null;
    }
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
    // 删除是关键操作，立即落盘（绕过节流）
    _saveDebounceTimer?.cancel();
    _savePending = false;
    await _storage?.setHistoryJson(_historyService.toJson());
    // 持久化已删 ID，防止重启后 _loadHistoryFromServer 把它复活
    if (_storage != null) {
      final deletedIds = _storage!.deletedEntryIds;
      deletedIds.add(id);
      await _storage!.setDeletedEntryIds(deletedIds);
    }
    notifyListeners();
    try {
      await _cloudRepo?.deleteHistoryEntry(id);
      // 服务器确认删除后从持久化集合移除
      if (_storage != null) {
        final ids = _storage!.deletedEntryIds;
        ids.remove(id);
        await _storage!.setDeletedEntryIds(ids);
      }
      // 同步删除本地全图缓存
      await _localImageStore.delete(id);
    } catch (e) {
      // 乐观更新，失败不回滚（集合保留，下次 refresh 会重试删除）
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
      for (final entry in entries) {
        final type = entry['type'] as String? ?? 'text';
        // 图片行：content 已被服务器剥离，用缩略图密文补预览
        if (type == ContentType.image.name) {
          final thumbBase64 = entry['thumb'] as String? ?? '';
          if (thumbBase64.isNotEmpty && _syncService != null) {
            try {
              entry['imageThumbBytes'] =
                  await _syncService!.decryptImage(thumbBase64);
              entry['imageFormat'] = entry['format'];
              entry['imageWidth'] = entry['width'];
              entry['imageHeight'] = entry['height'];
            } catch (e) {
              // 垃圾箱缩略图解密失败仅降级为空白预览
            }
          }
          continue;
        }
        // 解密文本内容：列表密文可能被服务端截断，失败时按 id 回补全量密文
        final encrypted = entry['content'] as String? ?? '';
        if (encrypted.isNotEmpty && _syncService != null) {
          final decrypted = await _decryptTextContentWithFallback(
            entry['id'] as String?,
            encrypted,
          );
          entry['content'] = decrypted ?? '[解密失败]';
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

  void setSearchQuery(String query) {
    _searchQuery = query;
    notifyListeners();
  }

  void setTypeFilter(ContentType? type) {
    _activeTypeFilter = type;
    notifyListeners();
  }

  void setDeviceFilter(String? device) {
    _activeDeviceFilter = device;
    notifyListeners();
  }

  void clearFilters() {
    _searchQuery = '';
    _activeTypeFilter = null;
    _activeDeviceFilter = null;
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
    if (_disposed) return;
    if (_syncStatus != status) {
      _syncStatus = status;
      notifyListeners();
    }
  }

  /// 节流落盘：800ms 内多次变更只写一次 SharedPreferences
  void _saveHistory() {
    _savePending = true;
    _saveDebounceTimer?.cancel();
    _saveDebounceTimer = Timer(const Duration(milliseconds: 800), () {
      _flushHistoryNow();
    });
  }

  /// 立即落盘（dispose / refresh 结束 / 删除恢复等关键路径调用）
  Future<void> _flushHistoryNow() async {
    _saveDebounceTimer?.cancel();
    if (!_savePending) return;
    _savePending = false;
    await _storage?.setHistoryJson(_historyService.toJson());
  }

  @override
  void dispose() {
    _disposed = true;
    _uploadDebounce?.cancel();
    _syncTimer?.cancel();
    _nextSyncTimer?.cancel();
    _saveDebounceTimer?.cancel();
    // 立即落盘未保存的历史
    if (_savePending) {
      _storage?.setHistoryJson(_historyService.toJson());
      _savePending = false;
    }
    _monitor?.removeListener(_onMonitorChanged);
    _monitor?.stop();
    _monitor?.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}
