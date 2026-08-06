import 'dart:async';
import 'dart:convert';
import 'dart:io' show File, Platform, SocketException;
import 'dart:ui' show AppExitResponse, ViewFocusEvent;
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';
import '../models/clipboard_entry.dart';
import '../models/clipboard_file.dart';
import '../models/clipboard_image.dart';
import '../models/file_download_progress.dart';
import '../services/sync_service.dart';
import '../services/encryption_service.dart';
import '../services/history_service.dart';
import '../services/clipboard_monitor.dart';
import '../services/file_clipboard_service.dart';
import '../services/file_processing_service.dart';
import '../services/image_clipboard_service.dart';
import '../services/image_compression_service.dart';
import '../repositories/local_storage.dart';
import '../repositories/cloud_repository.dart';
import '../repositories/local_image_store.dart';
import '../repositories/local_file_store.dart';
import '../core/constants.dart';
import '../core/exceptions.dart';
import 'settings_provider.dart';

/// Mixin providing default no-op implementations for WidgetsBindingObserver.
/// Only override didChangeAppLifecycleState in ClipboardProvider.
mixin _DefaultWidgetsBindingObserver implements WidgetsBindingObserver {
  @override
  void didChangeAccessibilityFeatures() {}
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {}
  @override
  void didChangeLocales(List<Locale>? locales) {}
  @override
  void didChangeMetrics() {}
  @override
  void didChangePlatformBrightness() {}
  @override
  void didChangeTextScaleFactor() {}
  @override
  void didChangeViewFocus(ViewFocusEvent event) {}
  @override
  void didHaveMemoryPressure() {}
  @override
  Future<bool> didPopRoute() async => false;
  @override
  Future<bool> didPushRoute(String route) async => false;
  @override
  Future<bool> didPushRouteInformation(
    RouteInformation routeInformation,
  ) async => false;
  @override
  Future<AppExitResponse> didRequestAppExit() async => AppExitResponse.exit;
  @override
  bool handleStartBackGesture(PredictiveBackEvent backEvent) => false;
  @override
  void handleUpdateBackGestureProgress(PredictiveBackEvent backEvent) {}
  @override
  void handleCommitBackGesture() {}
  @override
  void handleCancelBackGesture() {}
  @override
  void handleStatusBarTap() {}
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

class ClipboardProvider extends ChangeNotifier
    with _DefaultWidgetsBindingObserver {
  ClipboardProvider({
    LocalImageStore? imageStore,
    LocalFileStore? fileStore,
    FileProcessingService? fileProcessingService,
    @visibleForTesting
    Duration retryBaseDelay = const Duration(milliseconds: 500),
  }) : _localImageStore = imageStore ?? LocalImageStore(),
       _localFileStore = fileStore ?? LocalFileStore(),
       _fileProcessingService =
           fileProcessingService ?? FileProcessingService(),
       _retryBaseDelay = retryBaseDelay;

  /// Convenience method to access ClipboardProvider from the widget tree
  static ClipboardProvider of(BuildContext context, {bool listen = true}) {
    return Provider.of<ClipboardProvider>(context, listen: listen);
  }

  final HistoryService _historyService = HistoryService(
    maxEntries: AppConstants.maxHistoryEntries,
  );
  final EncryptionService _encryption = EncryptionService();
  final ImageClipboardService _imageClipboardService = ImageClipboardService();
  final FileClipboardService _fileClipboardService = FileClipboardService();
  final ImageCompressionService _imageCompressionService =
      ImageCompressionService();
  final LocalImageStore _localImageStore;
  final LocalFileStore _localFileStore;
  final FileProcessingService _fileProcessingService;
  final Duration _retryBaseDelay;

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
  // 文件下载任务状态
  final Map<String, FileDownloadProgress> _fileDownloads = {};
  final Map<String, DownloadResult> _fileDownloadResults = {};
  String? _activeFileDownloadId;
  final Set<String> _pendingFileRetries = {};
  // 文件上传在途保护：同路径只允许一个上传任务。
  final Set<String> _pendingFileUploadPaths = {};

  List<ClipboardEntry> get history => _historyService.entries;
  SyncStatus get syncStatus => _syncStatus;
  String? get errorMessage => _errorMessage;
  bool get isMergeMode => _isMergeMode;
  Set<String> get selectedIds => Set.unmodifiable(_selectedIds);
  String get mergeSeparator => _mergeSeparator;
  bool get serverConnected => _serverConnected;

  bool get hasActiveFilters =>
      _searchQuery.isNotEmpty ||
      _activeTypeFilter != null ||
      _activeDeviceFilter != null;

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
      results = results
          .where((e) => e.sourceDeviceName == _activeDeviceFilter)
          .toList();
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
            return (e.fileName ?? '').toLowerCase().contains(query);
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
    entries.sort(
      (a, b) => (orderMap[a.id] ?? 0).compareTo(orderMap[b.id] ?? 0),
    );
    return entries;
  }

  String get mergePreview =>
      selectedEntries.map((e) => e.content).join(_mergeSeparator);

  /// Set the SettingsProvider reference for lifecycle-aware sync decisions
  void setSettingsProvider(SettingsProvider settings) {
    _settingsProvider = settings;
  }

  /// 更新设备名（供重命名当前设备后使用）
  void updateDeviceName(String name) {
    _syncService?.updateDeviceName(name);
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

    _monitor = ClipboardMonitor(
      onChanged: _onClipboardChanged,
      storage: storage,
    );
    _monitor!.setSyncService(_syncService!);
    _monitor!.onContentSynced = _addSyncedToHistory;
    _monitor!.onImageChanged = _onImageClipboardChanged;
    _monitor!.onFilesChanged = _onFileClipboardChanged;
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
    _loadHistoryFromServer()
        .then((_) {
          notifyListeners();
        })
        .catchError((e) {
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
        _storage?.deletedEntryIds ?? <String>{},
      );
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

        // 文件行：只展示元数据，内容经独立下载任务懒取
        if (type == ContentType.file.name) {
          _historyService.addEntry(
            ClipboardEntry(
              id: entry['id'] as String? ?? const Uuid().v4(),
              content: '',
              sourceDeviceId: entry['source_device'] as String? ?? 'unknown',
              sourceDeviceName:
                  entry['source_device_name'] as String? ?? 'Unknown',
              sourcePlatform: entry['source_platform'] as String? ?? 'unknown',
              timestamp: DateTime.fromMillisecondsSinceEpoch(
                entry['timestamp'] as int? ?? 0,
              ),
              type: ContentType.file,
              isPinned: (entry['pinned'] as int?) == 1,
              fileName: entry['file_name'] as String?,
              fileSize: (entry['file_size'] as num?)?.toInt(),
              mimeType: entry['mime_type'] as String?,
              fileHash: entry['hash'] as String?,
            ),
          );
          continue;
        }

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
          _historyService.addEntry(
            ClipboardEntry(
              id: entry['id'] as String? ?? const Uuid().v4(),
              content: '',
              sourceDeviceId: entry['source_device'] as String? ?? 'unknown',
              sourceDeviceName:
                  entry['source_device_name'] as String? ?? 'Unknown',
              sourcePlatform: entry['source_platform'] as String? ?? 'unknown',
              timestamp: DateTime.fromMillisecondsSinceEpoch(
                entry['timestamp'] as int? ?? 0,
              ),
              type: ContentType.image,
              imageThumbBytes: thumbBytes,
              imageThumbEncryptedBase64: thumbBase64,
              imageWidth: entry['width'] as int?,
              imageHeight: entry['height'] as int?,
              imageFormat: entry['format'] as String?,
              stableHash: entry['hash'] as String?,
            ),
          );
          continue;
        }

        final content = entry['content'] as String? ?? '';
        if (content.isEmpty) continue;

        // 先尝试直接解密（大部分短密文能成功，无需网络回补）
        String? decryptedContent;
        try {
          decryptedContent = _capContent(
            await _syncService!.decryptContentIsolate(content),
          );
        } catch (_) {
          // 直接解密失败，收集待回补
        }

        if (decryptedContent != null) {
          _historyService.addEntry(
            ClipboardEntry(
              id: entry['id'] as String? ?? const Uuid().v4(),
              content: decryptedContent,
              sourceDeviceId: entry['source_device'] as String? ?? 'unknown',
              sourceDeviceName:
                  entry['source_device_name'] as String? ?? 'Unknown',
              sourcePlatform: entry['source_platform'] as String? ?? 'unknown',
              timestamp: DateTime.fromMillisecondsSinceEpoch(
                entry['timestamp'] as int? ?? 0,
              ),
              type: ContentType.text,
              isPinned: (entry['pinned'] as int?) == 1,
            ),
          );
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
            _historyService.addEntry(
              ClipboardEntry(
                id: entry['id'] as String? ?? const Uuid().v4(),
                content: _capContent(r.decrypted!),
                sourceDeviceId: entry['source_device'] as String? ?? 'unknown',
                sourceDeviceName:
                    entry['source_device_name'] as String? ?? 'Unknown',
                sourcePlatform:
                    entry['source_platform'] as String? ?? 'unknown',
                timestamp: DateTime.fromMillisecondsSinceEpoch(
                  entry['timestamp'] as int? ?? 0,
                ),
                type: ContentType.text,
                isPinned: (entry['pinned'] as int?) == 1,
              ),
            );
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
      // 清理本地全图缓存中已不在历史里的孤儿文件；
      // 进行中的文件下载任务（密文已落盘、历史尚未入史）必须保留，否则会被误删
      final historyIds = _historyService.entries.map((e) => e.id).toSet();
      await _localImageStore.cleanupOrphans(historyIds);
      await _localFileStore.cleanupOrphans({
        ...historyIds,
        ..._fileDownloads.keys,
      });
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

  /// 统一截断超长文本：超过 50000 字符只保留前 50000，
  /// 防止超长密文/明文整段存储与渲染阻塞 UI。
  String _capContent(String value) {
    if (value.length <= AppConstants.maxContentLength) return value;
    return value.substring(0, AppConstants.maxContentLength);
  }

  /// 解密文本密文。列表响应中的 content 可能被服务端截断（≤10000 字符），
  /// 直接解密失败时按 id 经 GET /api/history/:id/content 拉全量密文重试一次；
  /// 仍失败返回 null（由调用方决定跳过条目或降级显示）。
  Future<String?> _decryptTextContentWithFallback(
    String? entryId,
    String content,
  ) async {
    try {
      return _capContent(await _syncService!.decryptContentIsolate(content));
    } catch (_) {
      // 落入回补路径：可能是列表截断导致的 GCM 认证失败
    }
    if (entryId == null || _cloudRepo == null) return null;
    try {
      final fullEntry = await _cloudRepo!.getHistoryEntryContent(entryId);
      final fullContent = fullEntry?['content'] as String? ?? '';
      if (fullContent.isEmpty) return null;
      return _capContent(
        await _syncService!.decryptContentIsolate(fullContent),
      );
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
      return _capContent(
        await _syncService!.decryptContentIsolate(fullContent),
      );
    } catch (_) {
      return null;
    }
  }

  // -- WidgetsBindingObserver --

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && Platform.isAndroid) {
      if (_settingsProvider?.autoSyncOnResume ?? true) {
        triggerSync();
      }
    }
  }

  // -- External sync trigger --

  /// External entry point for triggering sync (e.g., from notification action)
  ///
  /// 「打开并同步」：先上传本地剪贴板；若轮询未在运行（如「后台自动同步」
  /// 关闭），再补一次下载，保证双向同步。防重入：上传沿用 monitor
  /// `_isSyncing`，下载沿用 `_isRefreshing`/`_isLoadingHistory`，且仅在轮询
  /// 未运行时补下载，避免与 500ms loop 并发双下载。
  Future<void> triggerSync() async {
    await _monitor?.syncClipboard();
    if (_syncTimer != null || _nextSyncTimer != null) return;
    if (_disposed || _syncService == null || _cloudRepo == null) return;
    if (_isRefreshing || _isLoadingHistory) return;
    await _performDownload();
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
    _historyService.addEntry(
      ClipboardEntry(
        id: serverId,
        content: content,
        sourceDeviceId: _syncService!.deviceId,
        sourceDeviceName: _syncService!.deviceName,
        sourcePlatform: Platform.operatingSystem,
        timestamp: DateTime.now(),
        type: ContentType.text,
      ),
    );
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

  void _onFileClipboardChanged(List<ClipboardFile> files) {
    _uploadDebounce?.cancel();
    _uploadDebounce = Timer(AppConstants.uploadDebounce, () {
      _uploadFile(files);
    });
  }

  /// 上传第一个文件（多文件剪贴板其余跳过并 debug 日志）。
  Future<void> _uploadFile(List<ClipboardFile> files) async {
    if (_syncService == null || files.isEmpty) return;
    final file = files.first;
    if (files.length > 1) {
      debugPrint(
        '[CLIP-PROVIDER] Multiple files detected, syncing first only: '
        '${files.length} total',
      );
    }
    final path = file.path;
    if (path == null || path.isEmpty) {
      _setStatus(SyncStatus.connected);
      return;
    }
    if (_pendingFileUploadPaths.contains(path)) return;
    _setStatus(SyncStatus.syncing);

    _pendingFileUploadPaths.add(path);
    try {
      if (file.errorCode != null) {
        _errorMessage = '文件读取失败（${file.errorCode}），已拒绝上传';
        _serverConnected = false;
        _setStatus(SyncStatus.error);
        return;
      }
      if (file.size != null && file.size! > AppConstants.maxFileBytes) {
        _errorMessage =
            '文件超过 ${AppConstants.maxFileBytes ~/ (1024 * 1024)}MB，已拒绝上传';
        _serverConnected = false;
        _setStatus(SyncStatus.error);
        return;
      }
      final source = File(path);
      if (!await source.exists()) {
        _errorMessage = '文件不存在或已被移动，已跳过同步';
        _serverConnected = false;
        _setStatus(SyncStatus.error);
        return;
      }

      final plaintextHash = await _fileProcessingService.hashFile(path);
      if (_monitor?.consumeIgnoredFileHash(plaintextHash) ?? false) {
        // 下载回写/历史复制回声：忽略后不上传
        _monitor?.recordFileSignature(file);
        _setStatus(SyncStatus.connected);
        return;
      }
      if (_syncService!.isFileHashUploaded(plaintextHash)) {
        _monitor?.recordFileSignature(file);
        _setStatus(SyncStatus.connected);
        return;
      }

      final size = file.size ?? await source.length();
      final encryptedPath = await _localFileStore.newTempPath('.enc');
      await _fileProcessingService.encryptFile(
        sourcePath: path,
        encryptedPath: encryptedPath,
        key: _syncService!.key,
      );

      final result = await _syncService!.uploadFile(
        encryptedPath: encryptedPath,
        fileName: file.name ?? path.split(Platform.pathSeparator).last,
        fileSize: size,
        mimeType: file.mimeType ?? 'application/octet-stream',
        plaintextHash: plaintextHash,
        timestamp: DateTime.now().millisecondsSinceEpoch,
      );
      if (result != null) {
        await _localFileStore.importEncryptedFile(
          result.historyId,
          encryptedPath,
        );
        _historyService.addEntry(
          ClipboardEntry(
            id: result.historyId,
            content: '',
            sourceDeviceId: _syncService!.deviceId,
            sourceDeviceName: _syncService!.deviceName,
            sourcePlatform: Platform.operatingSystem,
            timestamp: DateTime.now(),
            type: ContentType.file,
            fileName: file.name ?? path.split(Platform.pathSeparator).last,
            fileSize: size,
            mimeType: file.mimeType ?? 'application/octet-stream',
            fileHash: plaintextHash,
          ),
        );
        _saveHistory();
        notifyListeners();
        await _localFileStore.enforceCacheLimit(
          AppConstants.localFileCacheMaxBytes,
          protectedIds: {result.historyId},
        );
        // 上传成功后才记录签名：失败时签名不落地，同文件可重试。
        _monitor?.recordFileSignature(file);
      }

      // Android 预拷贝临时文件上传成功后清理
      if (file.temp) {
        try {
          if (await source.exists()) {
            await source.delete();
          }
        } catch (e) {
          debugPrint('[CLIP-PROVIDER] Temp file cleanup failed: $e');
        }
      }
      try {
        final tmp = File(encryptedPath);
        if (await tmp.exists()) {
          await tmp.delete();
        }
      } catch (e) {
        debugPrint('[CLIP-PROVIDER] Encrypted temp cleanup failed: $e');
      }

      _serverConnected = true;
      _setStatus(SyncStatus.connected);
    } catch (e) {
      _monitor?.clearFileSignature(file);
      _errorMessage = e.toString();
      _serverConnected = false;
      _setStatus(SyncStatus.error);
    } finally {
      _pendingFileUploadPaths.remove(path);
    }
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
        _historyService.addEntry(
          ClipboardEntry(
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
          ),
        );
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
        _historyService.addEntry(
          ClipboardEntry(
            id: serverId,
            content: truncatedContent,
            sourceDeviceId: _syncService!.deviceId,
            sourceDeviceName: _syncService!.deviceName,
            sourcePlatform: Platform.operatingSystem,
            timestamp: DateTime.now(),
            type: ContentType.text,
          ),
        );
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
            milliseconds:
                (AppConstants.pollInterval.inMilliseconds *
                        (1 << _consecutiveFailures.clamp(0, 6)))
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

    await _performDownload();
    _scheduleNextSync();
  }

  /// 下载核心：拉取最新内容并处理删除/恢复/图片/文件/文本。
  ///
  /// 不含 paused/刷新守卫与轮询调度（`_scheduleNextSync`），由 `_syncTick`
  /// （轮询）与 `triggerSync`（通知「打开并同步」的一次性下载）复用，
  /// 保证下载逻辑单一来源。
  Future<void> _performDownload() async {
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
      } else if (result != null && result.hasFile) {
        final fileHash = result.fileHash ?? '';
        if (fileHash.isNotEmpty) {
          _syncService!.markAsDownloadedFileHash(fileHash);
        }
        await _processFileDownload(result);
      } else if (result != null && result.content.isNotEmpty) {
        // 跳过已删除的内容
        final syncContentHash = sha256
            .convert(utf8.encode(result.content))
            .toString();
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

          _historyService.addEntry(
            ClipboardEntry(
              id: const Uuid().v4(),
              content: result.content,
              sourceDeviceId: result.sourceDeviceId,
              sourceDeviceName: result.sourceDeviceName,
              sourcePlatform: result.sourcePlatform,
              timestamp: result.timestamp,
              type: ContentType.text,
            ),
          );
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

        _historyService.addEntry(
          ClipboardEntry(
            id: entryId,
            content: '',
            sourceDeviceId: entry['source_device'] as String? ?? 'unknown',
            sourceDeviceName:
                entry['source_device_name'] as String? ?? 'Unknown',
            sourcePlatform: entry['source_platform'] as String? ?? 'unknown',
            timestamp: DateTime.fromMillisecondsSinceEpoch(
              entry['timestamp'] as int? ?? 0,
            ),
            type: ContentType.image,
            imageThumbBytes: thumbBytes,
            imageThumbEncryptedBase64: thumbBase64,
            imageWidth: entry['width'] as int?,
            imageHeight: entry['height'] as int?,
            imageFormat: entry['format'] as String?,
            stableHash: hash.isEmpty ? null : hash,
          ),
        );
        if (fullEncrypted != null && fullEncrypted.isNotEmpty) {
          await _localImageStore.save(entryId, fullEncrypted);
        }
        changed = true;
        continue;
      }

      if (type == ContentType.file.name) {
        final entryId = entry['id'] as String? ?? const Uuid().v4();
        final hash = entry['hash'] as String? ?? '';
        if (hash.isNotEmpty && _recentlyDeletedHashes.contains(hash)) continue;
        _historyService.addEntry(
          ClipboardEntry(
            id: entryId,
            content: '',
            sourceDeviceId: entry['source_device'] as String? ?? 'unknown',
            sourceDeviceName:
                entry['source_device_name'] as String? ?? 'Unknown',
            sourcePlatform: entry['source_platform'] as String? ?? 'unknown',
            timestamp: DateTime.fromMillisecondsSinceEpoch(
              entry['timestamp'] as int? ?? 0,
            ),
            type: ContentType.file,
            fileName: entry['file_name'] as String?,
            fileSize: (entry['file_size'] as num?)?.toInt(),
            mimeType: entry['mime_type'] as String?,
            fileHash: hash.isEmpty ? null : hash,
          ),
        );
        changed = true;
        continue;
      }

      final content = entry['content'] as String? ?? '';
      if (content.isEmpty) continue;
      // 解密内容
      String decryptedContent;
      try {
        decryptedContent = _capContent(
          await _syncService!.decryptContentIsolate(content),
        );
      } catch (e) {
        continue;
      }
      // 跳过已删除的内容
      final restoredHash = sha256
          .convert(utf8.encode(decryptedContent))
          .toString();
      if (_recentlyDeletedHashes.contains(restoredHash)) continue;
      _historyService.addEntry(
        ClipboardEntry(
          id: entry['id'] as String? ?? const Uuid().v4(),
          content: decryptedContent,
          sourceDeviceId: entry['source_device'] as String? ?? 'unknown',
          sourceDeviceName: entry['source_device_name'] as String? ?? 'Unknown',
          sourcePlatform: entry['source_platform'] as String? ?? 'unknown',
          timestamp: DateTime.fromMillisecondsSinceEpoch(
            entry['timestamp'] as int? ?? 0,
          ),
          type: ContentType.text,
        ),
      );
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

    // 已有同 ID 条目（如 refresh 先全量加载），只补缓存，不重复入史
    final alreadyInHistory = _historyService.entries.any(
      (e) => e.id == entryId,
    );
    if (!alreadyInHistory) {
      _historyService.addEntry(
        ClipboardEntry(
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
        ),
      );
    }

    // 先入史再落盘：孤儿清理按历史 ID 计算保留集合，
    // 若清理在落盘期间并发执行，也不会把本条缓存误删
    final encrypted = result.imageEncryptedBase64;
    if (encrypted != null && encrypted.isNotEmpty) {
      await _localImageStore.save(entryId, encrypted);
    }

    if (!alreadyInHistory) {
      _saveHistory();
      notifyListeners();
    }
  }

  /// 文件下载入口：建立进度任务后串行执行。
  Future<void> _processFileDownload(DownloadResult result) async {
    final entryId = (result.id != null && result.id!.isNotEmpty)
        ? result.id!
        : const Uuid().v4();
    if (_fileDownloads.containsKey(entryId)) {
      final existing = _fileDownloads[entryId]!;
      if (existing.status == FileTransferStatus.pending ||
          existing.status == FileTransferStatus.downloading ||
          existing.status == FileTransferStatus.processing) {
        return; // 同一 historyId 已有活跃任务
      }
      if (existing.status == FileTransferStatus.cancelled) {
        return; // 取消后仅手动重试，轮询不再自动重启
      }
      if (_pendingFileRetries.contains(entryId)) return;
    }
    if (_activeFileDownloadId != null) return; // 同一时间只允许一个活跃下载

    _fileDownloadResults[entryId] = result;
    _fileDownloads[entryId] = FileDownloadProgress(
      entryId: entryId,
      fileName: result.fileName ?? 'file',
      totalBytes: null,
      status: FileTransferStatus.pending,
    );
    notifyListeners();
    await _runFileDownload(entryId, result);
  }

  Future<void> _runFileDownload(
    String entryId,
    DownloadResult result, {
    bool isRetry = false,
  }) async {
    _activeFileDownloadId = entryId;
    final progress = _fileDownloads[entryId];
    if (progress == null) {
      _activeFileDownloadId = null;
      return;
    }
    if (isRetry) {
      progress.status = FileTransferStatus.pending;
      progress.error = null;
      progress.receivedBytes = 0;
      progress.totalBytes = null;
      progress.cancelToken = FileTransferCancelToken();
      notifyListeners();
    }
    if (progress.status == FileTransferStatus.failed ||
        progress.status == FileTransferStatus.cancelled) {
      _activeFileDownloadId = null;
      return;
    }

    progress.cancelToken ??= FileTransferCancelToken();
    final cancelToken = progress.cancelToken!;
    String? decryptedTempPath;
    try {
      if (_cloudRepo == null) throw Exception('Cloud repository unavailable');
      final fileName = result.fileName ?? 'file';
      progress.fileName = fileName;
      progress.status = FileTransferStatus.downloading;
      notifyListeners();

      final response = await _cloudRepo!.downloadFile(entryId);
      if (progress.status == FileTransferStatus.cancelled) return;

      progress.totalBytes = response.contentLength;
      notifyListeners();
      final encryptedPath = await _localFileStore.saveEncryptedFromStream(
        entryId: entryId,
        stream: response.stream,
        onProgress: (received) {
          progress.receivedBytes = received;
          notifyListeners();
        },
        cancelToken: cancelToken,
      );
      if (encryptedPath == null) return; // 取消时 store 已删除 .part
      if (progress.status == FileTransferStatus.cancelled) return;

      progress.status = FileTransferStatus.processing;
      notifyListeners();
      decryptedTempPath = await _localFileStore.newTempPath('_decrypted');
      final plaintextHash = await _fileProcessingService.decryptFile(
        encryptedPath: encryptedPath,
        plaintextPath: decryptedTempPath,
        key: _syncService!.key,
      );
      if (progress.status == FileTransferStatus.cancelled) return;

      progress.decryptedHash = plaintextHash;
      final plaintextPath = await _localFileStore.movePlaintextIntoCache(
        entryId,
        fileName,
        decryptedTempPath,
      );
      if (progress.status == FileTransferStatus.cancelled) return;

      final written = await _fileClipboardService.setFiles([plaintextPath]);
      if (progress.status == FileTransferStatus.cancelled) return;
      if (!written) {
        throw Exception('Native setFiles failed');
      }
      final readBack = await _fileClipboardService.getFiles();
      if (progress.status == FileTransferStatus.cancelled) return;
      if (readBack != null && readBack.isNotEmpty) {
        await _suppressWrittenFileEcho(plaintextHash, readBack);
      }
      await Future.delayed(const Duration(milliseconds: 50));
      if (progress.status == FileTransferStatus.cancelled) return;

      _historyService.addEntry(
        ClipboardEntry(
          id: entryId,
          content: '',
          sourceDeviceId: result.sourceDeviceId,
          sourceDeviceName: result.sourceDeviceName,
          sourcePlatform: result.sourcePlatform,
          timestamp: result.timestamp,
          type: ContentType.file,
          fileName: fileName,
          fileSize: result.fileSize,
          mimeType: result.mimeType,
          fileHash: result.fileHash,
        ),
      );
      _saveHistory();
      notifyListeners();

      // 完整处理成功后才推进时间戳（顺序不可颠倒）
      _syncService!.markAsReceived(result.timestamp);
      progress.status = FileTransferStatus.completed;
      progress.error = null;
      await _localFileStore.enforceCacheLimit(
        AppConstants.localFileCacheMaxBytes,
        protectedIds: {entryId},
      );
    } catch (e) {
      if (progress.status == FileTransferStatus.cancelled) return;
      progress.error = e.toString();
      progress.retryCount += 1;
      if (!_disposed && progress.retryCount < 3) {
        progress.status = FileTransferStatus.pending;
        notifyListeners();
        _activeFileDownloadId = null;
        _pendingFileRetries.add(entryId);
        final backoffMs =
            (_retryBaseDelay.inMilliseconds * (1 << (progress.retryCount - 1)))
                .clamp(10, 8000);
        Timer(Duration(milliseconds: backoffMs), () {
          _pendingFileRetries.remove(entryId);
          if (_disposed) return;
          if (progress.status == FileTransferStatus.cancelled) return;
          if (_activeFileDownloadId != null) return;
          _runFileDownload(entryId, result, isRetry: true);
        });
        return;
      }
      progress.status = FileTransferStatus.failed;
    } finally {
      if (decryptedTempPath != null) {
        await _deleteTempFile(decryptedTempPath);
      }
      _activeFileDownloadId = null;
      notifyListeners();
    }
  }

  Future<void> _deleteTempFile(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {
      // 临时文件清理失败不影响主流程
    }
  }

  /// 取消下载：置位取消令牌（流式写入在下一个数据块处停止并删除 `.part`），
  /// 状态置 cancelled，不推进时间戳，本会话内不再自动重试。
  Future<void> cancelFileDownload(String entryId) async {
    final progress = _fileDownloads[entryId];
    if (progress == null) return;
    if (progress.status == FileTransferStatus.completed ||
        progress.status == FileTransferStatus.cancelled) {
      return;
    }
    progress.cancelToken?.cancel();
    progress.status = FileTransferStatus.cancelled;
    progress.error = '已取消';
    _pendingFileRetries.remove(entryId);
    if (_activeFileDownloadId == entryId) {
      _activeFileDownloadId = null;
    }
    await _localFileStore.deleteEntry(entryId);
    notifyListeners();
  }

  /// 手动重试：仅 failed/cancelled 且无活跃下载时启动，使用原始元数据。
  Future<void> retryFileDownload(String entryId) async {
    final progress = _fileDownloads[entryId];
    if (progress == null) return;
    if (progress.status != FileTransferStatus.failed &&
        progress.status != FileTransferStatus.cancelled) {
      return;
    }
    if (_activeFileDownloadId != null) return;
    final result = _fileDownloadResults[entryId];
    if (result == null) return;

    _pendingFileRetries.remove(entryId);
    progress.status = FileTransferStatus.pending;
    progress.error = null;
    progress.retryCount = 0;
    progress.receivedBytes = 0;
    progress.totalBytes = null;
    progress.decryptedHash = null;
    progress.cancelToken = FileTransferCancelToken();
    notifyListeners();
    await _runFileDownload(entryId, result, isRetry: true);
  }

  bool _isImageFile(ClipboardFile file) {
    final name = file.name ?? file.path ?? '';
    final dot = name.lastIndexOf('.');
    if (dot <= 0 || dot == name.length - 1) return false;
    return kImageFileExtensions
        .contains(name.substring(dot + 1).toLowerCase());
  }

  /// 文件写回系统剪贴板后登记循环防护：普通文件登记文件签名/哈希，
  /// 图片文件还要登记图片字节哈希，避免 macOS/Windows 检测到
  /// file-url/CF_HDROP 后把同一张图片再上传一次（产生“他端来源”的重复图片）。
  Future<void> _suppressWrittenFileEcho(
    String plaintextHash,
    List<ClipboardFile> readBack,
  ) async {
    _monitor?.markFileAsWritten(plaintextHash, readBack);
    if (readBack.any(_isImageFile)) {
      final image = await _imageClipboardService.getImage();
      if (image != null && image.bytes.isNotEmpty) {
        _monitor?.markImageAsWritten(image.bytes);
      }
    }
  }

  FileDownloadProgress? fileDownloadProgress(String entryId) {
    return _fileDownloads[entryId];
  }

  /// 测试钩子：直接驱动桌面轮询的文件检测分支。
  @visibleForTesting
  Future<void> debugFileCheck() => _monitor?.syncClipboard() ?? Future.value();

  @visibleForTesting
  void monitorAddIgnoreFileHash(String hash) {
    _monitor?.addIgnoreFileHash(hash);
  }

  /// 文件条目就绪路径：本地明文存在直接用，否则懒下载+解密，不推进时间戳。
  Future<String?> ensureFileReady(String entryId) async {
    final entry = _historyService.entries
        .where((e) => e.id == entryId)
        .firstOrNull;
    if (entry == null || entry.type != ContentType.file) return null;
    try {
      final fileName = entry.fileName ?? 'file';
      final encryptedPath = await _localFileStore.loadEncryptedPath(entryId);
      if (encryptedPath != null) {
        final plaintextPath = await _localFileStore.newTempPath('_decrypted');
        await _fileProcessingService.decryptFile(
          encryptedPath: encryptedPath,
          plaintextPath: plaintextPath,
          key: _syncService!.key,
        );
        return _localFileStore.movePlaintextIntoCache(
          entryId,
          fileName,
          plaintextPath,
        );
      }
      if (_cloudRepo == null) return null;
      final response = await _cloudRepo!.downloadFile(entryId);
      await _localFileStore.saveEncryptedFromStream(
        entryId: entryId,
        stream: response.stream,
      );
      final plaintextPath = await _localFileStore.newTempPath('_decrypted');
      await _fileProcessingService.decryptFile(
        encryptedPath: (await _localFileStore.loadEncryptedPath(entryId))!,
        plaintextPath: plaintextPath,
        key: _syncService!.key,
      );
      return _localFileStore.movePlaintextIntoCache(
        entryId,
        fileName,
        plaintextPath,
      );
    } catch (e) {
      return null;
    }
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
        if (result != null && (result.hasContent || result.hasFile)) {
          if (result.type == ContentType.image) {
            _syncService!.markAsDownloadedHash(result.imageHash ?? '');
            await _processImageDownload(result);
          } else if (result.hasFile) {
            _syncService!.markAsDownloadedFileHash(result.fileHash ?? '');
            await _processFileDownload(result);
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
    } else if (entry.type == ContentType.file) {
      final path = await ensureFileReady(id);
      if (path != null) {
        final written = await _fileClipboardService.setFiles([path]);
        if (written && entry.fileHash != null) {
          final readBack = await _fileClipboardService.getFiles();
          if (readBack != null && readBack.isNotEmpty) {
            await _suppressWrittenFileEcho(entry.fileHash!, readBack);
          }
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
      await _cloudRepo?.updateHistoryEntry(id, {
        'pinned': entry.isPinned ? 1 : 0,
      });
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
      // 同步删除本地文件密文/明文缓存
      await _localFileStore.deleteEntry(id);
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

  /// 倾倒垃圾桶：永久删除服务器端当前用户的所有软删条目，返回删除数量。
  Future<int> emptyTrash() async {
    if (_cloudRepo == null) return 0;
    return await _cloudRepo!.emptyTrash();
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
              entry['imageThumbBytes'] = await _syncService!.decryptImage(
                thumbBase64,
              );
              entry['imageFormat'] = entry['format'];
              entry['imageWidth'] = entry['width'];
              entry['imageHeight'] = entry['height'];
            } catch (e) {
              // 垃圾箱缩略图解密失败仅降级为空白预览
            }
          }
          continue;
        }
        if (type == ContentType.file.name) {
          // 垃圾箱对 file 行不尝试解密 content，按元数据展示
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
