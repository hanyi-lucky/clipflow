import 'dart:convert';
import 'dart:io';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/backup_manifest.dart';
import '../../providers/clipboard_provider.dart';
import '../../services/backup_service.dart';
import '../../services/encryption_service.dart';

/// 密文备份导出：选保存路径 → 顺序导出（进度 + 大体积警告）→ 写
/// `.clipflow-backup.json`（版本化、含 salt、条目密文 EncryptedData 兼容、零明文）。
class ExportBackupScreen extends StatefulWidget {
  const ExportBackupScreen({super.key});

  @override
  State<ExportBackupScreen> createState() => _ExportBackupScreenState();
}

class _ExportBackupScreenState extends State<ExportBackupScreen> {
  static const int _largeExportWarningBytes = 300 * 1024 * 1024;

  bool _exporting = false;
  double _progress = 0;
  String _status = '';
  String? _resultPath;
  String? _error;

  Future<void> _startExport() async {
    if (_exporting) return;

    final provider = context.read<ClipboardProvider>();
    final key = provider.encryptionKey;
    if (key == null) {
      setState(() => _error = '未找到当前会话密钥，请返回解锁页重新解锁后再试');
      return;
    }

    final location = await getSaveLocation(
      suggestedName:
          'clipflow-backup-${DateTime.now().millisecondsSinceEpoch}.clipflow-backup.json',
      acceptedTypeGroups: const [
        XTypeGroup(label: 'ClipFlow 备份', extensions: ['json']),
      ],
    );
    if (location == null || location.path == null || location.path!.isEmpty) {
      return; // 用户取消
    }
    final targetPath = location.path!;

    setState(() {
      _exporting = true;
      _progress = 0;
      _status = '正在拉取并导出...';
      _error = null;
      _resultPath = null;
    });

    try {
      final service = BackupService(
        cloudRepo: provider.cloudRepo!,
        storage: provider.storage!,
        imageStore: provider.imageStore,
        fileStore: provider.fileStore,
        historyService: provider.historyService,
        encryption: EncryptionService(),
      );

      final manifest = await service.buildExport(
        deviceName: provider.deviceName,
        encryptionKey: key,
        onProgress: (p, label) {
          if (!mounted) return;
          setState(() {
            _progress = p;
            _status = label;
          });
        },
      );

      final size = manifest.estimateBytes();
      if (size > _largeExportWarningBytes) {
        final proceed = await _confirmLargeExport(size);
        if (!proceed) {
          if (!mounted) return;
          setState(() {
            _exporting = false;
            _status = '';
          });
          return;
        }
      }

      await File(targetPath).writeAsString(jsonEncode(manifest.toJson()));

      if (!mounted) return;
      setState(() {
        _exporting = false;
        _progress = 1;
        _status = '导出完成';
        _resultPath = targetPath;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _exporting = false;
        _error = '导出失败: $e';
      });
    }
  }

  Future<bool> _confirmLargeExport(int bytes) {
    final mb = (bytes / (1024 * 1024)).toStringAsFixed(1);
    return showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('备份体积较大'),
          content: Text(
            '当前备份预估约 $mb MB，导出与导入可能需要较长时间。是否继续？',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('继续'),
            ),
          ],
        );
      },
    ).then((v) => v ?? false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('导出备份')),
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
                      '备份内容',
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: theme.colorScheme.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '导出本账户全部历史条目（文本 / 图片 / 文件）的密文与元数据，'
                      '含解密所需 salt。文件为端到端加密密文，不含任何明文。',
                      style: TextStyle(
                        color: theme.colorScheme.onSurfaceVariant,
                        height: 1.5,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '改密码前请先导出备份：改密码 = 新账户，旧数据需用「导入备份」恢复。',
                      style: TextStyle(
                        color: theme.colorScheme.error,
                        height: 1.5,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 24),
            if (_exporting) ...[
              LinearProgressIndicator(value: _progress),
              const SizedBox(height: 12),
              Text(
                _status,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium,
              ),
            ] else if (_resultPath != null) ...[
              Icon(Icons.check_circle, size: 48, color: Colors.green.shade600),
              const SizedBox(height: 12),
              Text(
                '备份已保存',
                textAlign: TextAlign.center,
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              SelectableText(
                _resultPath!,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ] else if (_error != null) ...[
              Icon(Icons.error_outline, size: 48, color: theme.colorScheme.error),
              const SizedBox(height: 12),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium,
              ),
            ] else ...[
              const Icon(Icons.save_alt_rounded, size: 48),
              const SizedBox(height: 12),
              Text(
                '选择一个保存位置，将生成 .clipflow-backup.json 备份文件。',
                textAlign: TextAlign.center,
                style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
              ),
            ],
            const Spacer(),
            SizedBox(
              height: 50,
              child: FilledButton.icon(
                onPressed: _exporting ? null : _startExport,
                icon: _exporting
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.download),
                label: Text(_exporting
                    ? '导出中...'
                    : (_resultPath != null ? '重新导出' : '选择位置并导出')),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
