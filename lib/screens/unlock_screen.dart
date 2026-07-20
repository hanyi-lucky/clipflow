import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../providers/clipboard_provider.dart';
import '../providers/settings_provider.dart';
import '../repositories/local_storage.dart';
import '../services/encryption_service.dart';
import '../core/hex_utils.dart';

class UnlockScreen extends StatefulWidget {
  const UnlockScreen({super.key});

  @override
  State<UnlockScreen> createState() => _UnlockScreenState();
}

class _UnlockScreenState extends State<UnlockScreen> {
  final _passwordController = TextEditingController();
  final _encryption = EncryptionService();
  bool _isFirstTime = true;
  bool _initialized = false;
  bool _authSuccess = false;
  String? _error;
  bool _loading = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_initialized) {
      _init();
    }
  }

  Future<void> _init() async {
    try {
      final auth = context.read<AuthProvider>();
      final storage = await LocalStorage.create();
      await auth.initialize(storage);

      // 连接检查（不登录，登录在解锁时根据密码派生 userId）
      final settings = context.read<SettingsProvider>();
      await settings.initialize(storage);

      if (!mounted) return;
      setState(() {
        _isFirstTime = storage.encryptionSalt == null;
        _initialized = true;
        _authSuccess = true;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _initialized = true;
        _authSuccess = false;
        _error = '连接失败: $e';
      });
    }
  }

  Future<void> _unlock() async {
    if (!_authSuccess) return;

    final password = _passwordController.text.trim();
    if (password.isEmpty) return;

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      // 从密码派生 userId：相同密码 → 相同 userId → 共享数据
      final passwordHash = sha256.convert(utf8.encode('clipflow:$password')).toString();
      final userId = 'user_${passwordHash.substring(0, 16)}';

      final storage = await LocalStorage.create();
      final auth = context.read<AuthProvider>();

      // 使用密码派生的 userId 登录
      await auth.signIn(userId: userId);

      final cloudRepo = auth.cloudRepo;
      List<int> salt;

      // 1. 先尝试从云端下载 salt
      final cloudSalt = await cloudRepo.getSalt();

      if (cloudSalt != null) {
        // 云端已有 salt → 所有设备共享同一 salt
        salt = hexToBytes(cloudSalt);
        await storage.setEncryptionSalt(cloudSalt);
      } else {
        // 云端无 salt → 生成新 salt 并上传（首台设备）
        final localSalt = storage.encryptionSalt;
        if (localSalt != null) {
          salt = hexToBytes(localSalt);
        } else {
          salt = _encryption.generateSalt().toList();
          final saltHex = bytesToHex(salt);
          await storage.setEncryptionSalt(saltHex);
        }
        // 上传到云端，让其他设备共享
        await cloudRepo.setSalt(bytesToHex(salt));
      }

      final key = await _encryption.deriveKey(password, salt);
      final clipboardProvider = context.read<ClipboardProvider>();

      await clipboardProvider.initialize(
        storage: storage,
        cloudRepo: auth.cloudRepo,
        deviceId: auth.currentDevice.id,
        deviceName: auth.currentDevice.name,
        encryptionKey: key,
      );

      if (mounted) {
        Navigator.pushReplacementNamed(context, '/home');
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '解锁失败: $e';
      });
    }

    if (mounted) {
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: isDark
                ? [const Color(0xFF1A1B2E), const Color(0xFF0D0E1A)]
                : [const Color(0xFFF0F1FF), const Color(0xFFE8EAFF)],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 400),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    // Logo
                    Container(
                      width: 80,
                      height: 80,
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          colors: [Color(0xFF5B6CF0), Color(0xFF8B5CF6)],
                        ),
                        borderRadius: BorderRadius.circular(20),
                        boxShadow: [
                          BoxShadow(
                            color: const Color(0xFF5B6CF0).withOpacity(0.3),
                            blurRadius: 20,
                            offset: const Offset(0, 8),
                          ),
                        ],
                      ),
                      child: const Icon(
                        Icons.content_paste_rounded,
                        size: 36,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 32),

                    if (!_initialized) ...[
                      const SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(strokeWidth: 2.5),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        '正在连接服务器...',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.outline,
                        ),
                      ),
                    ] else if (!_authSuccess) ...[
                      // Error state
                      Icon(
                        Icons.wifi_off_rounded,
                        size: 48,
                        color: theme.colorScheme.error,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        '无法连接服务器',
                        style: theme.textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '请检查网络连接后重试',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.outline,
                        ),
                      ),
                      if (_error != null) ...[
                        const SizedBox(height: 12),
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.errorContainer,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            _error!,
                            style: TextStyle(
                              color: theme.colorScheme.onErrorContainer,
                              fontSize: 12,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ],
                      const SizedBox(height: 24),
                      SizedBox(
                        width: double.infinity,
                        height: 48,
                        child: ElevatedButton.icon(
                          icon: const Icon(Icons.refresh_rounded),
                          label: const Text('重试'),
                          onPressed: () {
                            setState(() {
                              _initialized = false;
                              _error = null;
                            });
                            _init();
                          },
                        ),
                      ),
                    ] else ...[
                      // Password input
                      Text(
                        _isFirstTime ? '设置主密码' : '解锁',
                        style: theme.textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _isFirstTime
                            ? '创建密码加密剪切板数据\n请在所有设备上使用相同密码'
                            : '输入主密码解锁',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.outline,
                          height: 1.5,
                        ),
                      ),
                      const SizedBox(height: 28),
                      TextField(
                        controller: _passwordController,
                        obscureText: true,
                        decoration: InputDecoration(
                          labelText: '主密码',
                          prefixIcon: const Icon(Icons.lock_outline_rounded),
                          errorText: _error,
                        ),
                        onSubmitted: (_) => _unlock(),
                      ),
                      const SizedBox(height: 20),
                      SizedBox(
                        width: double.infinity,
                        height: 50,
                        child: ElevatedButton(
                          onPressed: _loading ? null : _unlock,
                          child: _loading
                              ? const SizedBox(
                                  width: 24,
                                  height: 24,
                                  child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white),
                                )
                              : Text(
                                  _isFirstTime ? '创建并开始' : '解锁',
                                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                                ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _passwordController.dispose();
    super.dispose();
  }
}
