import 'dart:convert';
import 'dart:io' show Platform;
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/backup_manifest.dart';
import '../../providers/clipboard_provider.dart';
import '../../services/backup_service.dart';
import '../../services/encryption_service.dart';

/// 迁移码导入：选 .clipflow-backup.json → 输旧密码 → 旧密钥解密 →
/// 当前会话密钥重加密 → 上传（保留原始 ID/timestamp）→ 重新加载历史。
class ImportBackupScreen extends StatefulWidget {
  const ImportBackupScreen({super.key});

  @override
  State<ImportBackupScreen> createState() => _ImportBackupScreenState();
}

class _ImportBackupScreenState extends State<ImportBackupScreen> {
  final _passwordController = TextEditingController();
  bool _importing = false;
  double _progress = 0;
  String _status = '';
  String? _error;
  BackupManifest? _manifest;
  String? _fileName;
  ImportResult? _result;

  Future<void> _pickFile() async {
    if (_importing) return;
    final file = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(label: 'ClipFlow 备份', extensions: ['json']),
      ],
    );
    if (file == null) return;
    try {
      final raw = await file.readAsString();
      final manifest = BackupManifest.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
      if (!mounted) return;
      setState(() {
        _manifest = manifest;
        _fileName = file.name;
        _error = null;
        _result = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _manifest = null;
        _fileName = null;
        _error = '无法解析备份文件: $e';
      });
    }
  }

  Future<void> _startImport() async {
    final manifest = _manifest;
    if (manifest == null || _importing) return;

    final oldPassword = _passwordController.text.trim();
    if (oldPassword.isEmpty) {
      setState(() => _error = '请输入旧密码');
      return;
    }

    final provider = context.read<ClipboardProvider>();
    final newKey = provider.encryptionKey;
    final cloudRepo = provider.cloudRepo;
    final storage = provider.storage;
    if (newKey == null || cloudRepo == null || storage == null) {
      setState(() => _error = '未找到当前会话密钥，请返回解锁页重新解锁后再试');
      return;
    }

    setState(() {
      _importing = true;
      _progress = 0;
      _status = '正在导入...';
      _error = null;
      _result = null;
    });

    try {
      final service = BackupService(
        cloudRepo: cloudRepo,
        storage: storage,
        imageStore: provider.imageStore,
        fileStore: provider.fileStore,
        historyService: provider.historyService,
        encryption: EncryptionService(),
      );
      final result = await service.importBackup(
        manifest: manifest,
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

      // 导入完成后重新拉取历史，让新条目立即出现在历史列表
      await provider.reloadHistoryFromServer();

      if (!mounted) return;
      setState(() {
        _importing = false;
        _progress = 1;
        _status = '导入完成';
        _result = result;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _importing = false;
        _error = '导入失败: $e';
      });
    }
  }

  @override
  void dispose() {
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final manifest = _manifest;
    final result = _result;

    return Scaffold(
      appBar: AppBar(title: const Text('导入备份')),
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
                      '迁移说明',
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: theme.colorScheme.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '导入需输入「导出时的旧密码」：备份在本地用旧密码解密后，'
                      '再用当前密码（新账户）重新加密上传，服务端只存密文。',
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
            OutlinedButton.icon(
              onPressed: _importing ? null : _pickFile,
              icon: const Icon(Icons.folder_open),
              label: Text(_fileName == null ? '选择备份文件' : '已选择：$_fileName'),
            ),
            if (manifest != null) ...[
              const SizedBox(height: 12),
              Text(
                '备份共 ${manifest.entries.length} 条，来源：${manifest.sourceDevice.isEmpty ? '未知' : manifest.sourceDevice}',
                style: theme.textTheme.bodySmall,
              ),
            ],
            if (manifest != null) ...[
              const SizedBox(height: 16),
              TextField(
                controller: _passwordController,
                obscureText: true,
                enabled: !_importing,
                decoration: InputDecoration(
                  labelText: '旧密码（导出时使用的密码）',
                  prefixIcon: const Icon(Icons.lock_outline_rounded),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                onSubmitted: (_) => _startImport(),
              ),
            ],
            const SizedBox(height: 20),
            if (_importing) ...[
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
                '导入 ${result.imported} 条'
                '${result.failed > 0 ? '，失败 ${result.failed} 条' : ''}',
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
                onPressed: (manifest == null || _importing) ? null : _startImport,
                icon: _importing
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.upload),
                label: Text(_importing ? '导入中...' : '开始导入'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
