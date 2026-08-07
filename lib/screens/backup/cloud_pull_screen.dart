import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/exceptions.dart';
import '../../core/user_id.dart';
import '../../providers/auth_provider.dart';
import '../../providers/clipboard_provider.dart';
import '../../repositories/cloud_repository.dart';
import '../../services/backup_service.dart';
import '../../services/cloudbase_service.dart';
import '../../services/encryption_service.dart';
import '../../l10n/app_strings.dart';

/// 从云端拉取：输入旧账户密码，直接把旧账户云端数据迁移到当前账户。
///
/// 旧账户读取用「第二 CloudBaseService 实例」（旧 token 独立持有，不污染当前
/// 账户 token）；预检 / 数据源构建 / 导入编排全部收进 [BackupService]，
/// 写入复用 importBackup 管线（旧密钥解密 → 新密钥重加密 → 新账户上传）。
class CloudPullScreen extends StatefulWidget {
  const CloudPullScreen({super.key, @visibleForTesting this.sourceRepoFactory});

  /// 测试钩子：构造旧账户只读仓库。生产默认走真实第二实例
  /// （[CloudBaseService] 登录旧账户后包 [CloudRepository]）。
  @visibleForTesting
  final CloudRepository Function(String userId, String deviceId)?
      sourceRepoFactory;

  @override
  State<CloudPullScreen> createState() => _CloudPullScreenState();
}

class _CloudPullScreenState extends State<CloudPullScreen> {
  final _passwordController = TextEditingController();
  bool _pulling = false;
  double _progress = 0;
  String _status = '';
  String? _error;
  ImportResult? _result;

  /// 必须已解锁（有会话密钥）且已登录（userId 非空）才能开始拉取。
  bool get _canStart {
    final provider = context.read<ClipboardProvider>();
    final auth = context.read<AuthProvider>();
    return !_pulling &&
        provider.encryptionKey != null &&
        provider.cloudRepo != null &&
        provider.storage != null &&
        auth.userId.isNotEmpty;
  }

  Future<void> _startPull() async {
    if (_pulling) return;

    final oldPassword = _passwordController.text.trim();
    if (oldPassword.isEmpty) {
      setState(() => _error = AppStrings.importEnterOldPassword);
      return;
    }

    final provider = context.read<ClipboardProvider>();
    final auth = context.read<AuthProvider>();
    // 同账户守卫：旧密码派生 userId 与当前账户相同 → 在任何网络调用前拒绝
    if (deriveUserId(oldPassword) == auth.userId) {
      setState(() => _error = AppStrings.cloudPullSameAccount);
      return;
    }
    final newKey = provider.encryptionKey;
    final cloudRepo = provider.cloudRepo;
    final storage = provider.storage;
    if (newKey == null || cloudRepo == null || storage == null) {
      setState(() => _error = AppStrings.sessionKeyMissing);
      return;
    }

    setState(() {
      _pulling = true;
      _progress = 0;
      _status = AppStrings.cloudPullInProgress;
      _error = null;
      _result = null;
    });

    try {
      final oldUserId = deriveUserId(oldPassword);
      // 旧账户读取器：第二 CloudBaseService 实例 + 旧 userId 登录（绑定当前
      // deviceId，服务端 /auth 仅建 users 行 + 发旧账户 token，不注册设备）。
      final sourceRepo = widget.sourceRepoFactory != null
          ? widget.sourceRepoFactory!(oldUserId, provider.deviceId)
          : await _createSourceRepo(oldUserId, provider.deviceId);

      final service = BackupService(
        cloudRepo: cloudRepo,
        storage: storage,
        imageStore: provider.imageStore,
        fileStore: provider.fileStore,
        historyService: provider.historyService,
        encryption: EncryptionService(),
      );

      // 云端拉取前置上限检查：目标账户已有条目且合并后总量可能超过服务端
      // 「保留最近 100 条」上限 → 弹确认框，用户确认后才继续。
      final warning = await service.checkCloudPullHistoryLimit(
        sourceRepo: sourceRepo,
      );
      if (warning != null) {
        final confirmed = await _confirmHistoryLimit(warning);
        if (confirmed != true) {
          if (!mounted) return;
          setState(() {
            _pulling = false;
            _progress = 0;
            _status = '';
          });
          return;
        }
      }

      final result = await service.pullFromCloud(
        sourceRepo: sourceRepo,
        currentUserId: auth.userId,
        oldPassword: oldPassword,
        newKey: newKey,
        deviceId: provider.deviceId,
        deviceName: provider.deviceName,
        devicePlatform: Platform.operatingSystem,
        onProgress: (p, label) {
          if (!mounted) return;
          setState(() {
            _progress = p;
            _status = label;
          });
        },
      );

      // 拉取完成后重新拉取历史，让新条目立即出现在历史列表
      await provider.reloadHistoryFromServer();

      if (!mounted) return;
      setState(() {
        _pulling = false;
        _progress = 1;
        _status = AppStrings.cloudPullDone;
        _result = result;
      });
    } on CloudPullException catch (e) {
      if (!mounted) return;
      setState(() {
        _pulling = false;
        _error = e.type == CloudPullErrorType.sameAccount
            ? AppStrings.cloudPullSameAccount
            : AppStrings.cloudPullEmptyAccount;
      });
    } on DecryptionException {
      if (!mounted) return;
      setState(() {
        _pulling = false;
        _error = AppStrings.backupWrongOldPassword;
      });
    } on RateLimitedException {
      if (!mounted) return;
      setState(() {
        _pulling = false;
        _error = AppStrings.rateLimitedMessage;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _pulling = false;
        _error = AppStrings.importFailed('$e');
      });
    }
  }

  /// 构造旧账户只读仓库：第二 [CloudBaseService] 实例 + 旧 userId 登录。
  Future<CloudRepository> _createSourceRepo(
    String userId,
    String deviceId,
  ) async {
    final sourceCloud = CloudBaseService();
    await sourceCloud.signInAnonymously(userId: userId, deviceId: deviceId);
    return CloudRepository(sourceCloud);
  }

  /// 历史保留上限确认框：告知用户服务端仅保留最近 100 条，较早的迁移条目
  /// 可能被自动清理；返回 true 表示用户确认继续。
  Future<bool?> _confirmHistoryLimit(CloudPullLimitWarning warning) {
    return showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text(AppStrings.cloudPullLimitDialogTitle),
          surfaceTintColor: Colors.transparent,
          content: Text(
            AppStrings.cloudPullLimitDialogBody(
              warning.targetCount,
              warning.totalCount,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text(AppStrings.commonCancel),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text(AppStrings.cloudPullLimitConfirmAction),
            ),
          ],
        );
      },
    );
  }

  @override
  void dispose() {
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final result = _result;

    return Scaffold(
      appBar: AppBar(title: const Text(AppStrings.cloudPullTitle)),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      AppStrings.cloudPullGuideTitle,
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: theme.colorScheme.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      AppStrings.cloudPullGuideBody,
                      style: TextStyle(
                        color: theme.colorScheme.onSurfaceVariant,
                        height: 1.5,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _passwordController,
              obscureText: true,
              enabled: !_pulling,
              decoration: InputDecoration(
                labelText: AppStrings.oldPasswordLabel,
                prefixIcon: const Icon(Icons.lock_outline_rounded),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              onSubmitted: (_) => _startPull(),
            ),
            const SizedBox(height: 20),
            if (_pulling) ...[
              LinearProgressIndicator(value: _progress),
              const SizedBox(height: 12),
              Text(
                _status,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium,
              ),
            ] else if (result != null) ...[
              Icon(
                result.failed == 0 ? Icons.check_circle : Icons.warning_amber,
                size: 48,
                color: result.failed == 0
                    ? Colors.green.shade600
                    : Colors.orange.shade700,
              ),
              const SizedBox(height: 12),
              Text(
                AppStrings.importResultCount(result.imported) +
                    (result.failed > 0
                        ? AppStrings.importResultFailed(result.failed)
                        : ''),
                textAlign: TextAlign.center,
                style: theme.textTheme.titleMedium,
              ),
              if (result.errors.isNotEmpty) ...[
                const SizedBox(height: 8),
                Flexible(
                  child: SingleChildScrollView(
                    child: Text(
                      result.errors.take(10).join('\n'),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.error,
                      ),
                    ),
                  ),
                ),
              ],
            ] else if (_error != null) ...[
              Icon(Icons.error_outline, size: 48, color: theme.colorScheme.error),
              const SizedBox(height: 12),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium,
              ),
            ],
            const Spacer(),
            SizedBox(
              height: 50,
              child: FilledButton.icon(
                onPressed: _canStart ? _startPull : null,
                icon: _pulling
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.cloud_download_outlined),
                label: Text(
                  _pulling
                      ? AppStrings.cloudPullInProgressButton
                      : AppStrings.cloudPullStartAction,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
