import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import '../services/auth_service.dart';
import '../services/cloudbase_service.dart';
import '../services/device_identity_service.dart';
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

  /// 当前登录 token（可空：未登录/已登出）。崩溃上报匿名兜底用。
  String? get authToken => _cloudService.authToken;

  /// 当前设备 ID（注册完成后才有；可空）。崩溃上报元信息用。
  String? get currentDeviceIdOrNull => _currentDevice?.id;

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
      // 确保有 deviceId（首次登录生成 UUID）
      String? deviceId = _storage?.deviceId;
      if (deviceId == null || deviceId.isEmpty) {
        deviceId = const Uuid().v4();
        await _storage?.setDeviceId(deviceId);
      }
      await _authService.signInAnonymously(userId: userId, deviceId: deviceId);
    } on Exception catch (e) {
      _error = e.toString();
      _isLoading = false;
      notifyListeners();
      rethrow;
    }

    _isLoading = false;
    notifyListeners();
  }

  Future<void> registerCurrentDevice() async {
    if (_storage == null) return;

    String deviceId = _storage!.deviceId ?? const Uuid().v4();
    await _storage!.setDeviceId(deviceId);

    // 使用 DeviceIdentityService 获取准确的设备名
    String? deviceName = _storage!.deviceName;
    if (deviceName == null ||
        deviceName.isEmpty ||
        isLegacyDefaultDeviceName(deviceName)) {
      final identity = await loadDeviceIdentity();
      var suggested = identity.suggestedName;
      try {
        final existing = await _cloudRepo.getDevices();
        suggested = uniqueDeviceName(
          suggested,
          existing.map((d) => d.name),
        );
      } catch (_) {
        // 拉取失败时直接使用建议名，不阻塞注册
      }
      deviceName = suggested;
      await _storage!.setDeviceName(deviceName);
    }

    _currentDevice = Device(
      id: deviceId,
      name: deviceName,
      platform: Platform.operatingSystem,
      lastSeen: DateTime.now(),
    );

    await _cloudRepo.registerDevice(currentDevice);
  }

  /// 获取所有设备列表
  Future<List<Device>> fetchDevices() async {
    return await _cloudRepo.getDevices();
  }

  /// 重命名设备
  Future<void> renameDevice(String deviceId, String name) async {
    await _cloudRepo.updateDeviceName(deviceId, name);

    // 如果是当前设备，更新本地存储
    if (_currentDevice?.id == deviceId) {
      await _storage?.setDeviceName(name);
      _currentDevice = _currentDevice!.copyWith(name: name);
      notifyListeners();
    }
  }

  /// 移除设备
  Future<void> removeDevice(String deviceId) async {
    await _cloudRepo.removeDevice(deviceId);

    // 如果是当前设备，清空 token 和 storage，退出登录
    if (_currentDevice?.id == deviceId) {
      await signOut();
    }
  }

  Future<void> signOut() async {
    _cloudService.clearToken();
    _currentDevice = null;
    notifyListeners();
  }
}
