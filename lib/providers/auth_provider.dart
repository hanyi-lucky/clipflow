import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import '../services/auth_service.dart';
import '../services/cloudbase_service.dart';
import '../repositories/local_storage.dart';
import '../repositories/cloud_repository.dart';
import '../models/device.dart';

class AuthProvider extends ChangeNotifier {
  final CloudBaseService _cloudService = CloudBaseService();
  late final AuthService _authService;
  late final CloudRepository _cloudRepo;

  LocalStorage? _storage;

  bool _isLoading = false;
  String? _error;

  bool get isLoading => _isLoading;
  String? get error => _error;
  bool get isAuthenticated => _cloudService.isLoggedIn;
  String get userId => _cloudService.openId ?? '';

  Device? _currentDevice;
  Device get currentDevice {
    if (_currentDevice == null) {
      throw StateError('Device not registered yet. Call signIn() first.');
    }
    return _currentDevice!;
  }

  AuthProvider() {
    _authService = AuthService(_cloudService);
    _cloudRepo = CloudRepository(_cloudService);
  }

  AuthService get authService => _authService;
  CloudRepository get cloudRepo => _cloudRepo;

  Future<void> initialize(LocalStorage storage) async {
    _storage = storage;
  }

  Future<void> signIn({String? userId}) async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      await _authService.signInAnonymously(userId: userId);
      await _registerCurrentDevice();
    } on Exception catch (e) {
      _error = e.toString();
      _isLoading = false;
      notifyListeners();
      rethrow;
    }

    _isLoading = false;
    notifyListeners();
  }

  Future<void> _registerCurrentDevice() async {
    if (_storage == null) return;

    String deviceId = _storage!.deviceId ?? const Uuid().v4();
    await _storage!.setDeviceId(deviceId);

    String deviceName = _storage!.deviceName ?? _getDefaultDeviceName();
    await _storage!.setDeviceName(deviceName);

    _currentDevice = Device(
      id: deviceId,
      name: deviceName,
      platform: Platform.operatingSystem,
      lastSeen: DateTime.now(),
    );

    await _cloudRepo.registerDevice(currentDevice);
  }

  String _getDefaultDeviceName() {
    if (Platform.isMacOS) return 'Mac';
    if (Platform.isWindows) return 'Windows PC';
    if (Platform.isAndroid) return 'Android Phone';
    if (Platform.isIOS) return 'iOS Device';
    return 'Unknown Device';
  }

  Future<void> signOut() async {
    _cloudService.clearToken();
    _currentDevice = null;
    notifyListeners();
  }
}
