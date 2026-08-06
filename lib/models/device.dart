class Device {
  final String id;
  final String name;
  final String platform;
  final DateTime lastSeen;

  const Device({
    required this.id,
    required this.name,
    required this.platform,
    required this.lastSeen,
  });

  Device copyWith({
    String? id,
    String? name,
    String? platform,
    DateTime? lastSeen,
  }) {
    return Device(
      id: id ?? this.id,
      name: name ?? this.name,
      platform: platform ?? this.platform,
      lastSeen: lastSeen ?? this.lastSeen,
    );
  }

  Map<String, dynamic> toMap() => {
    'id': id,
    'name': name,
    'platform': platform,
    'lastSeen': lastSeen.toIso8601String(),
  };

  factory Device.fromMap(Map<String, dynamic> map) {
    // 服务端返回 snake_case（last_seen），本地 map 使用 camelCase（lastSeen），
    // 都兼容；缺失或异常时回退当前时间，避免设备列表整体加载失败。
    final rawLastSeen = map['last_seen'] ?? map['lastSeen'];
    DateTime lastSeen = DateTime.now();
    if (rawLastSeen is String) {
      lastSeen = DateTime.tryParse(
            rawLastSeen.replaceFirst(' ', 'T'),
          ) ??
          lastSeen;
    }
    return Device(
      id: map['id'] as String,
      name: map['name'] as String,
      platform: map['platform'] as String,
      lastSeen: lastSeen,
    );
  }
}
