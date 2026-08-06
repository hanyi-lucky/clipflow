import 'dart:io' show Platform;
import 'package:device_info_plus/device_info_plus.dart';

class DeviceIdentity {
  final String platform;
  final String? model;
  const DeviceIdentity({required this.platform, this.model});

  String get suggestedName => buildDefaultDeviceName(platform: platform, model: model);
}

/// v1.4 及更早版本的默认设备名：命中说明用户没有自定义过名称，
/// 升级后应自动替换为「平台 · 机型」。
const Set<String> kLegacyDefaultDeviceNames = {
  'Mac',
  'Windows PC',
  'Android Phone',
  'iOS Device',
  'Unknown Device',
};

bool isLegacyDefaultDeviceName(String name) {
  return kLegacyDefaultDeviceNames.contains(name.trim());
}

/// 生成默认设备名
/// 规则：model 先 trim，空则回退默认名
String buildDefaultDeviceName({required String platform, String? model}) {
  final trimmed = model?.trim();
  if (trimmed == null || trimmed.isEmpty) {
    switch (platform) {
      case 'android':
        return 'Android Phone';
      case 'windows':
        return 'Windows PC';
      case 'macos':
        return 'Mac';
      case 'ios':
        return 'iOS Device';
      default:
        return 'Unknown Device';
    }
  }

  switch (platform) {
    case 'android':
      return 'Android · $trimmed';
    case 'windows':
      return 'Windows · $trimmed';
    case 'macos':
      return 'Mac · $trimmed';
    case 'ios':
      return 'iOS · $trimmed';
    default:
      return 'Unknown Device';
  }
}

/// 同密码多设备场景：默认名冲突时追加序号，避免两台同型号设备混淆。
String uniqueDeviceName(String baseName, Iterable<String> existingNames) {
  final used = existingNames.toSet();
  if (!used.contains(baseName)) return baseName;
  var index = 2;
  while (true) {
    final candidate = '$baseName ($index)';
    if (!used.contains(candidate)) return candidate;
    index++;
  }
}

/// 加载设备信息
Future<DeviceIdentity> loadDeviceIdentity() async {
  final deviceInfo = DeviceInfoPlugin();

  if (Platform.isAndroid) {
    final androidInfo = await deviceInfo.androidInfo;
    final model = '${androidInfo.manufacturer} ${androidInfo.model}'.trim();
    return DeviceIdentity(platform: 'android', model: model);
  } else if (Platform.isIOS) {
    final iosInfo = await deviceInfo.iosInfo;
    return DeviceIdentity(platform: 'ios', model: iosInfo.model);
  } else if (Platform.isMacOS) {
    final macOsInfo = await deviceInfo.macOsInfo;
    return DeviceIdentity(platform: 'macos', model: macOsInfo.model);
  } else if (Platform.isWindows) {
    final windowsInfo = await deviceInfo.windowsInfo;
    return DeviceIdentity(platform: 'windows', model: windowsInfo.computerName);
  } else {
    return DeviceIdentity(platform: 'unknown');
  }
}
