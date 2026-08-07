import 'package:package_info_plus/package_info_plus.dart';

/// App 版本单一来源：`main()` 启动加载一次，经 `Provider<AppInfo>` 供设置页、
/// 经 `CrashReporter` 供崩溃上报，杜绝手工硬编码版本漂移。
class AppInfo {
  final String version;
  final String buildNumber;

  const AppInfo({required this.version, required this.buildNumber});

  /// 展示用完整版本号：如 `1.5.0+1`；buildNumber 缺失/unknown 时回退到 version。
  String get fullVersion {
    if (buildNumber.isEmpty || buildNumber == 'unknown') return version;
    return '$version+$buildNumber';
  }

  /// 从平台加载版本信息；失败兜底 unknown，绝不抛出。
  /// [loader] 仅供测试注入。
  static Future<AppInfo> load({Future<AppInfo> Function()? loader}) async {
    try {
      return await (loader ?? _fromPackageInfo)();
    } catch (_) {
      return const AppInfo(version: 'unknown', buildNumber: '');
    }
  }

  static Future<AppInfo> _fromPackageInfo() async {
    final info = await PackageInfo.fromPlatform();
    return AppInfo(version: info.version, buildNumber: info.buildNumber);
  }
}
