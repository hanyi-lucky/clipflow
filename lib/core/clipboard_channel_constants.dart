/// 剪切板 MethodChannel 常量，Dart / Android Kotlin / macOS Swift 三端对照
class AppChannelNames {
  static const String clipboard = 'clipflow/clipboard';
}

class AppChannelMethods {
  static const String getImage = 'getImage';
  static const String setImage = 'setImage';
  static const String hasImage = 'hasImage';
  static const String onClipboardImageChanged = 'onClipboardImageChanged';
}
