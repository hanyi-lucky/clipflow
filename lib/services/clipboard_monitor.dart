import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'package:flutter/services.dart';
import 'package:crypto/crypto.dart';
import '../core/constants.dart';

typedef ClipboardChangeCallback = void Function(String content);

class ClipboardMonitor {
  Timer? _pollTimer;
  String _lastHash = '';
  bool _isPaused = false;
  final ClipboardChangeCallback onChanged;
  MethodChannel? _androidChannel;

  ClipboardMonitor({required this.onChanged}) {
    if (Platform.isAndroid) {
      _androidChannel = const MethodChannel('clipflow/clipboard');
      _androidChannel!.setMethodCallHandler(_handleAndroidMethodCall);
    }
  }

  Future<void> start() async {
    if (Platform.isAndroid) {
      await _androidChannel?.invokeMethod('startListening');
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
    if (call.method == 'onClipboardChanged') {
      final text = call.arguments as String?;
      if (text != null && text.isNotEmpty) {
        final hash = sha256.convert(utf8.encode(text)).toString();
        if (hash != _lastHash) {
          _lastHash = hash;
          onChanged(text);
        }
      }
    }
  }
}
