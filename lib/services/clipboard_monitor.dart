import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../l10n/app_strings.dart';
import 'package:crypto/crypto.dart';
import '../core/constants.dart';
import '../models/clipboard_file.dart';
import '../models/clipboard_image.dart';
import '../repositories/local_storage.dart';
import '../services/file_clipboard_service.dart';
import '../services/image_clipboard_service.dart';
import '../services/sync_service.dart';

typedef ClipboardChangeCallback = void Function(String content);
typedef ImageClipboardChangeCallback = void Function(ClipboardImage image);
typedef FileClipboardChangeCallback = void Function(List<ClipboardFile> files);

class ClipboardMonitor extends ChangeNotifier {
  Timer? _pollTimer;
  String _lastHash = '';
  String _lastImageHash = '';
  bool _isPaused = false;
  final ClipboardChangeCallback onChanged;
  final ImageClipboardService _imageClipboardService = ImageClipboardService();
  final FileClipboardService _fileClipboardService = FileClipboardService();
  MethodChannel? _androidChannel;
  LocalStorage? _storage;

  // New sync state
  static const int _maxIgnoreHashes = 10;
  final Set<String> _ignoreHashes = {};
  static const int _maxIgnoreFileHashes = 16;
  final Set<String> _ignoreFileHashes = {};
  final Map<String, String> _lastFileSignatures = {};
  DateTime? _lastSyncTime;
  bool _autoSyncOnResume = true;
  bool _notificationSync = true;
  bool _isSyncing = false;
  String _syncStatus = 'idle';

  /// 微信/QQ/Finder 复制图片文件时剪贴板常只含 file-url + 文本占位，
  /// 这些占位不是真实文本内容，命中则跳过上传。
  static final Set<String> _placeholderTexts =
      AppStrings.clipboardPlaceholderTexts.toSet();

  // SyncService reference (set externally)
  SyncService? _syncService;

  /// Callback when content is successfully uploaded (for adding to local history)
  void Function(String content, String serverId)? onContentSynced;

  /// Callback when a clipboard image is detected (provider compresses/uploads)
  void Function(ClipboardImage image)? onImageChanged;

  /// Callback when clipboard file metadata is detected (provider uploads).
  void Function(List<ClipboardFile> files)? onFilesChanged;

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
  Set<String> get ignoreFileHashes => Set.unmodifiable(_ignoreFileHashes);
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
  void setSyncService(SyncService syncService) {
    _syncService = syncService;
  }

  /// Load persisted state from SharedPreferences
  void loadState() {
    _loadSyncState();
    _loadIgnoreHashes();
    _loadFileState();
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

  /// 测试钩子：直接驱动桌面轮询检测逻辑（等价于下一次 timer tick）。
  @visibleForTesting
  Future<void> debugCheckClipboard() => _checkClipboard();

  /// 测试钩子：直接驱动 Android 原生 MethodChannel 回调（等价于原生层调用）。
  @visibleForTesting
  Future<dynamic> debugHandleAndroidMethodCall(MethodCall call) =>
      _handleAndroidMethodCall(call);

  // -- New sync API --

  /// Unified sync method: reads clipboard (or uses pre-read content), checks for duplicates/ignored, uploads
  Future<void> syncClipboard({
    String? preReadContent,
    ClipboardImage? preReadImage,
    List<ClipboardFile>? preReadFiles,
  }) async {
    if (_isSyncing) return;
    _isSyncing = true;
    _syncStatus = 'syncing';
    notifyListeners();
    debugPrint(
      '[SYNC] syncClipboard started, _syncService=${_syncService != null ? "set" : "NULL"}',
    );

    try {
      // 原生传入图片：交给 provider 压缩上传
      if (preReadImage != null) {
        debugPrint(
          '[SYNC] Using pre-read image: ${preReadImage.bytes.length} bytes',
        );
        final hash = sha256.convert(preReadImage.bytes).toString();
        if (!_consumeIgnoredImageHash(hash)) {
          _lastImageHash = hash;
          onImageChanged?.call(preReadImage);
        }
        _syncStatus = 'idle';
        return;
      }

      if (preReadFiles != null && preReadFiles.isNotEmpty) {
        _handleFiles(preReadFiles);
        _syncStatus = 'idle';
        return;
      }

      String? text;
      if (preReadContent != null) {
        text = preReadContent;
        debugPrint('[SYNC] Using pre-read content: ${text.length} chars');
      } else {
        // 先图后文
        if (await _imageClipboardService.hasImage()) {
          final image = await _imageClipboardService.getImage();
          if (image != null && image.bytes.isNotEmpty) {
            debugPrint(
              '[SYNC] Clipboard image detected: ${image.bytes.length} bytes',
            );
            final hash = sha256.convert(image.bytes).toString();
            if (!_consumeIgnoredImageHash(hash)) {
              _lastImageHash = hash;
              onImageChanged?.call(image);
            }
            _syncStatus = 'idle';
            return;
          }
          // hasImage 为 true 但 getImage 返回 null/空（图片文件 URL 读取失败等）：
          // 先走文件分支兜底（图片文件不会静默丢弃），但绝不落入文本分支，
          // 避免把 "[文件]" 占位文本当内容上传
          if (await _fileClipboardService.hasFiles()) {
            final files = await _fileClipboardService.getFiles();
            if (files != null && files.isNotEmpty) {
              _handleFiles(files);
            }
          }
          _syncStatus = 'idle';
          return;
        }
        // 文件分支：图片之后、文本之前（文件复制常带文本占位）
        if (await _fileClipboardService.hasFiles()) {
          final files = await _fileClipboardService.getFiles();
          if (files != null && files.isNotEmpty) {
            _handleFiles(files);
          }
          _syncStatus = 'idle';
          return;
        }
        final content = await Clipboard.getData(Clipboard.kTextPlain);
        debugPrint(
          '[SYNC] Clipboard content: ${content?.text?.length ?? 0} chars',
        );
        text = content?.text;
      }

      if (text == null || text.isEmpty) {
        _syncStatus = 'idle';
        return;
      }

      // 占位/垃圾文本（图片文件复制残留或二进制解码乱码）不触发上传
      if (_isSkippableText(text)) {
        debugPrint('[SYNC] Placeholder/garbage text skipped');
        _syncStatus = 'idle';
        return;
      }

      final hash = sha256.convert(utf8.encode(text)).toString();
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
        final serverId = await _syncService!.uploadContent(text);
        debugPrint('[SYNC] Upload result: $serverId');
        if (serverId != null) {
          _lastHash = hash;
          _lastSyncTime = DateTime.now();
          _saveSyncState();
          _syncStatus = 'success';
          // Notify provider to add to local history
          onContentSynced?.call(text, serverId);
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

  /// 标记图片已写入剪切板（回读字节），供检测路径抑制回声。
  ///
  /// macOS/Android 写入时会重编码字节，因此必须用「回读字节」的哈希
  /// 同时更新 `_lastImageHash` 并登记忽略表——回读哈希才是监听器
  /// 下一次比对/查询的键域。
  void markImageAsWritten(Uint8List bytes) {
    final hash = sha256.convert(bytes).toString();
    _lastImageHash = hash;
    addIgnoreHash(hash);
  }

  /// 标记文件已写入剪切板（下载写回/历史复制）：登记内容哈希与
  /// 同剪贴板签名，供检测路径抑制回声。
  void markFileAsWritten(String hash, List<ClipboardFile> files) {
    _ignoreFileHashes.add(hash);
    while (_ignoreFileHashes.length > _maxIgnoreFileHashes) {
      _ignoreFileHashes.remove(_ignoreFileHashes.first);
    }
    _saveFileState();
    for (final file in files) {
      recordFileSignature(file);
    }
  }

  /// 文件签名（path+size+lastModified）是否已在内存中记录并命中。
  bool isFileSignatureHandled(ClipboardFile file) {
    if (file.path == null || file.path!.isEmpty) return false;
    final signature = _fileSignature(file);
    return signature.isNotEmpty && _lastFileSignatures[file.path] == signature;
  }

  /// 仅在上传/写入成功后记录文件签名，防止同一次复制被重复上传。
  void recordFileSignature(ClipboardFile file) {
    if (file.path == null || file.path!.isEmpty) return;
    _lastFileSignatures[file.path!] = _fileSignature(file);
    _trimFileSignatures();
  }

  /// 上传失败时清除签名，允许同路径同大小同 mtime 的文件再次上传。
  void clearFileSignature(ClipboardFile file) {
    if (file.path == null || file.path!.isEmpty) return;
    _lastFileSignatures.remove(file.path);
  }

  void addIgnoreFileHash(String hash) {
    _ignoreFileHashes.add(hash);
    while (_ignoreFileHashes.length > _maxIgnoreFileHashes) {
      _ignoreFileHashes.remove(_ignoreFileHashes.first);
    }
    _saveFileState();
  }

  bool consumeIgnoredFileHash(String hash) {
    if (_ignoreFileHashes.remove(hash)) {
      _saveFileState();
      return true;
    }
    return false;
  }

  /// 检测图片字节哈希是否命中忽略表；命中则消费并更新本地基线。
  bool _consumeIgnoredImageHash(String hash) {
    if (_ignoreHashes.contains(hash)) {
      _ignoreHashes.remove(hash);
      _saveIgnoreHashes();
      _lastImageHash = hash;
      return true;
    }
    return false;
  }

  /// Check notification permission (Android only)
  Future<bool> checkNotificationPermission() async {
    if (!Platform.isAndroid) return true;
    try {
      final result = await _androidChannel?.invokeMethod<bool>(
        'checkNotificationPermission',
      );
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
      final result = await _androidChannel?.invokeMethod<bool>(
        'checkBatteryOptimization',
      );
      return result ?? false;
    } catch (e) {
      debugPrint('[CLIP-MON] checkBatteryOptimization ERROR: $e');
      return false;
    }
  }

  // -- Internal methods --

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(
      AppConstants.pollInterval,
      (_) => _checkClipboard(),
    );
  }

  void _stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  Future<void> _checkClipboard() async {
    if (_isPaused) return;

    try {
      // 先图后文：剪切板同时含文本+图片时优先图片
      if (await _imageClipboardService.hasImage()) {
        final image = await _imageClipboardService.getImage();
        if (image != null && image.bytes.isNotEmpty) {
          final hash = sha256.convert(image.bytes).toString();
          if (_consumeIgnoredImageHash(hash)) {
            // 刚写入的图片：命中忽略表，不触发上传
            return;
          }
          if (hash != _lastImageHash) {
            _lastImageHash = hash;
            onImageChanged?.call(image);
          }
        }
        // hasImage 为 true 但 getImage 返回 null/空：先走文件分支兜底，
        // 但不落入文本分支（文件复制常带 "[文件]" 占位文本）
        if (await _fileClipboardService.hasFiles()) {
          final files = await _fileClipboardService.getFiles();
          if (files != null && files.isNotEmpty) {
            _handleFiles(files);
          }
        }
        return;
      }

      // 文件分支：图片之后、文本之前（Finder/资源管理器复制文件时常带文本占位）
      if (await _fileClipboardService.hasFiles()) {
        final files = await _fileClipboardService.getFiles();
        if (files != null && files.isNotEmpty) {
          _handleFiles(files);
        }
        return;
      }

      final data = await Clipboard.getData(Clipboard.kTextPlain);
      if (data?.text != null && data!.text!.isNotEmpty) {
        final text = data.text!;
        // 占位/垃圾文本（图片文件复制残留或二进制解码乱码）不触发上传
        if (_isSkippableText(text)) return;
        final hash = sha256.convert(utf8.encode(text)).toString();
        if (hash != _lastHash) {
          _lastHash = hash;
          onChanged(text);
        }
      }
    } catch (_) {
      // Clipboard access may fail; silently ignore
    }
  }

  /// 占位符/二进制垃圾文本检测：
  /// - trim 后命中占位集合（如 "[文件]"）；
  /// - 含 NUL 字符（\u0000）；
  /// - 含大量 U+FFFD（二进制被当 UTF-8 解码的乱码）——同时满足
  ///   「至少 3 个」且「占比 ≥10%」。
  bool _isSkippableText(String text) {
    final trimmed = text.trim();
    if (_placeholderTexts.contains(trimmed)) return true;
    if (trimmed.contains('\u0000')) return true;
    final length = trimmed.length;
    if (length == 0) return false;
    var replacementCount = 0;
    for (final unit in trimmed.codeUnits) {
      if (unit == 0xFFFD) replacementCount++;
    }
    return replacementCount >= 3 && replacementCount * 10 >= length;
  }

  Future<dynamic> _handleAndroidMethodCall(MethodCall call) async {
    switch (call.method) {
      case 'onClipboardFilesChanged':
        final args = call.arguments;
        if (args is List && _isPaused == false) {
          final files = <ClipboardFile>[];
          for (final raw in args) {
            if (raw is Map) {
              files.add(
                ClipboardFile.fromMap(raw.map((k, v) => MapEntry('$k', v))),
              );
            }
          }
          if (files.isNotEmpty) {
            _handleFiles(files);
          }
        }
        break;
      case 'onClipboardImageChanged':
        final args = call.arguments;
        if (args is Map) {
          final rawBytes = args['bytes'];
          Uint8List? bytes;
          if (rawBytes is Uint8List) {
            bytes = rawBytes;
          } else if (rawBytes is List) {
            try {
              bytes = Uint8List.fromList(rawBytes.cast<int>());
            } catch (_) {
              bytes = null;
            }
          }
          if (bytes != null && bytes.isNotEmpty) {
            // 原生 setImage 会自触发 onPrimaryClipChanged，暂停期间的回调直接丢弃
            if (_isPaused) break;
            final hash = sha256.convert(bytes).toString();
            if (_consumeIgnoredImageHash(hash)) {
              break;
            }
            if (hash != _lastImageHash) {
              _lastImageHash = hash;
              onImageChanged?.call(
                ClipboardImage(
                  bytes: bytes,
                  format: args['format'] as String? ?? 'png',
                  width: args['width'] as int? ?? 0,
                  height: args['height'] as int? ?? 0,
                ),
              );
            }
          }
        }
        break;
      case 'onClipboardChanged':
        final text = call.arguments as String?;
        // 与 _checkClipboard/syncClipboard 一致：占位/垃圾文本不触发上传
        if (text != null && text.isNotEmpty && !_isSkippableText(text)) {
          final hash = sha256.convert(utf8.encode(text)).toString();
          if (hash != _lastHash) {
            _lastHash = hash;
            onChanged(text);
          }
        }
        break;
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

  void _handleFiles(List<ClipboardFile> files) {
    if (files.isEmpty || files.first.path == null) return;
    final first = files.first;
    if (isFileSignatureHandled(first)) return;
    if (first.errorCode != null) {
      debugPrint('[CLIP-MON] File metadata error: ${first.errorCode}');
      return;
    }
    if (first.size != null && first.size! > AppConstants.maxFileBytes) {
      debugPrint('[CLIP-MON] File too large: ${first.size} bytes');
      return;
    }
    onFilesChanged?.call(files);
  }

  String _fileSignature(ClipboardFile file) =>
      '${file.path}|${file.size}|${file.lastModified}';

  void _trimFileSignatures() {
    while (_lastFileSignatures.length > _maxIgnoreFileHashes) {
      final first = _lastFileSignatures.keys.first;
      _lastFileSignatures.remove(first);
    }
  }

  void _loadFileState() {
    if (_storage == null) return;
    final hashes = _storage!.monitorIgnoreFileHashes;
    _ignoreFileHashes.clear();
    _ignoreFileHashes.addAll(hashes.take(_maxIgnoreFileHashes));
    // 文件签名只存内存：不恢复旧持久化签名，避免历史失败签名继续抑制上传。
    _lastFileSignatures.clear();
    _trimFileSignatures();
  }

  void _saveFileState() {
    _storage?.setMonitorIgnoreFileHashes(_ignoreFileHashes.toList());
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }
}
