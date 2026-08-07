import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../providers/clipboard_provider.dart';
import '../providers/settings_provider.dart';
import '../repositories/local_storage.dart';
import '../services/encryption_service.dart';
import '../services/auth_guard.dart';
import '../core/hex_utils.dart';
import '../core/exceptions.dart';
import '../l10n/app_strings.dart';

class UnlockScreen extends StatefulWidget {
  const UnlockScreen({super.key});

  @override
  State<UnlockScreen> createState() => _UnlockScreenState();
}

class _UnlockScreenState extends State<UnlockScreen> {
  final _passwordController = TextEditingController();
  final _encryption = EncryptionService();
  // 本地密码错误限流（内存态，App 重启清零；服务端另有 API 层尝试速率限流）
  final _authGuard = AuthGuard();
  LocalStorage? _storage;
  bool _isFirstTime = true;
  bool _hasStoredUserId = false;
  bool _initialized = false;
  bool _authSuccess = false;
  bool _isWeakPassword = false;
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
      _storage ??= await LocalStorage.create();
      final storage = _storage!;
      await auth.initialize(storage);

      // 连接检查（不登录，登录在解锁时根据密码派生 userId）
      final settings = context.read<SettingsProvider>();
      await settings.initialize(storage);

      if (!mounted) return;
      setState(() {
        _isFirstTime = storage.encryptionSalt == null;
        _hasStoredUserId = storage.userId != null;
        _initialized = true;
        _authSuccess = true;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _initialized = true;
        _authSuccess = false;
        _error = AppStrings.unlockConnectFailed('$e');
      });
    }
  }

  Future<void> _unlock() async {
    if (!_authSuccess) return;

    final password = _passwordController.text.trim();
    if (password.isEmpty) return;

    // 本地锁定：连续输错密码超阈值，倒计时结束后才允许再次尝试
    if (_authGuard.isLocked) {
      final seconds = _authGuard.lockRemaining.inSeconds + 1;
      setState(() {
        _error = AppStrings.unlockTooManyAttempts(seconds);
      });
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      // 从密码派生 userId：相同密码 → 相同 userId → 共享数据
      final passwordHash = sha256.convert(utf8.encode('clipflow:$password')).toString();
      final userId = 'user_${passwordHash.substring(0, 16)}';

      final storage = _storage ?? await LocalStorage.create();

      // 本地密码错误判定：已有 storedUserId（非新设备首登）且派生 userId 不一致
      // → 密码错误：不发 /auth、不进 salt 分支（避免污染本地 salt 到错误账户）
      if (_authGuard.isPasswordMismatch(
        attemptedUserId: userId,
        storedUserId: storage.userId,
      )) {
        _authGuard.recordFailure();
        setState(() {
          _loading = false;
          _error = AppStrings.unlockWrongPassword;
        });
        return;
      }

      final auth = context.read<AuthProvider>();

      // 使用密码派生的 userId 登录
      await auth.signIn(userId: userId);

      final cloudRepo = auth.cloudRepo;
      List<int> salt;

      // 并行执行：下载 salt + 注册设备（不互相依赖）
      final results = await Future.wait([
        cloudRepo.getSalt(),
        auth.registerCurrentDevice(),
      ]);
      final cloudSalt = results[0] as String?;

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

      final key = await _encryption.deriveKeyIsolate(password, salt);
      final clipboardProvider = context.read<ClipboardProvider>();

      await clipboardProvider.initialize(
        storage: storage,
        cloudRepo: auth.cloudRepo,
        deviceId: auth.currentDevice.id,
        deviceName: auth.currentDevice.name,
        encryptionKey: key,
      );

      // 解锁成功后才写 userId 标记（供后续本地密码错误判定）并清除失败计数
      await storage.setUserId(userId);
      _authGuard.reset();

      if (mounted) {
        Navigator.pushReplacementNamed(context, '/home');
      }
    } on RateLimitedException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = AppStrings.unlockTooManyAttempts(
          (e.retryAfterMs / 1000).ceil(),
        );
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = AppStrings.unlockFailed('$e');
      });
    }

    if (mounted) {
      setState(() => _loading = false);
    }
  }

  /// 切换到其他账户：确认后清除本机账户标记与本地缓存（含加密盐），
  /// 使解锁页可输入新密码进入新账户（改密码迁移主流程的出口）。
  Future<void> _confirmSwitchAccount() async {
    final storage = _storage ?? await LocalStorage.create();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text(AppStrings.switchAccountAction),
          content: const Text(AppStrings.switchAccountConfirmBody),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text(AppStrings.commonCancel),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text(AppStrings.switchAccountConfirmAction),
            ),
          ],
        );
      },
    );
    if (confirmed != true) return;
    if (!mounted) return;

    await storage.clearAccountIdentity();
    _authGuard.reset();
    _passwordController.clear();
    setState(() {
      _hasStoredUserId = false;
      _isFirstTime = true;
      _isWeakPassword = false;
      _error = null;
    });
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
                        AppStrings.unlockConnecting,
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
                        AppStrings.unlockServerUnreachable,
                        style: theme.textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        AppStrings.unlockCheckNetwork,
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
                          label: const Text(AppStrings.commonRetry),
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
                        _isFirstTime
                            ? AppStrings.unlockSetPasswordTitle
                            : AppStrings.unlockTitle,
                        style: theme.textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _isFirstTime
                            ? AppStrings.unlockFirstTimeSubtitle
                            : AppStrings.unlockEnterPassword,
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
                          labelText: AppStrings.masterPasswordLabel,
                          prefixIcon: const Icon(Icons.lock_outline_rounded),
                          errorText: _error,
                          filled: true,
                          fillColor: Theme.of(context).colorScheme.surfaceContainerHighest.withOpacity(0.3),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide(color: Theme.of(context).colorScheme.outline.withOpacity(0.3)),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide(color: Theme.of(context).colorScheme.outline.withOpacity(0.3)),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide(color: Theme.of(context).colorScheme.primary, width: 2),
                          ),
                        ),
                        onChanged: (value) {
                          setState(() {
                            _isWeakPassword = _authGuard.isWeakPassword(value);
                          });
                        },
                        onSubmitted: (_) => _unlock(),
                      ),
                      if (_isWeakPassword) ...[
                        const SizedBox(height: 10),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 10,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.orange.withOpacity(0.12),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: Colors.orange.withOpacity(0.4),
                            ),
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Icon(
                                Icons.warning_amber_rounded,
                                size: 18,
                                color: Colors.orange,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  _isFirstTime
                                      ? AppStrings.weakPasswordFirstTime
                                      : AppStrings.weakPasswordExisting,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Colors.orange.shade800,
                                    height: 1.4,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
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
                                  _isFirstTime
                                      ? AppStrings.createAndStartAction
                                      : AppStrings.unlockTitle,
                                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                                ),
                        ),
                      ),
                      if (_hasStoredUserId) ...[
                        const SizedBox(height: 8),
                        TextButton.icon(
                          onPressed: _loading ? null : _confirmSwitchAccount,
                          icon: const Icon(Icons.switch_account_outlined, size: 18),
                          label: const Text(AppStrings.switchAccountAction),
                        ),
                      ],
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
