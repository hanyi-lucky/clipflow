import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:clipflow/core/hex_utils.dart';
import 'package:clipflow/core/user_id.dart';
import 'package:clipflow/l10n/app_strings.dart';
import 'package:clipflow/providers/auth_provider.dart';
import 'package:clipflow/providers/clipboard_provider.dart';
import 'package:clipflow/providers/settings_provider.dart';
import 'package:clipflow/repositories/cloud_repository.dart';
import 'package:clipflow/repositories/local_storage.dart';
import 'package:clipflow/screens/backup/cloud_pull_screen.dart';
import 'package:clipflow/services/app_info.dart';
import 'package:clipflow/services/cloudbase_service.dart';
import 'package:clipflow/services/encryption_service.dart';

/// 测试 AuthProvider：直接注入 userId（真实登录需网络）。
class FakeAuthProvider extends AuthProvider {
  FakeAuthProvider(this.userIdValue);
  final String userIdValue;

  @override
  String get userId => userIdValue;
}

/// 目标（当前）账户仓库：history 提供现有条数，写入被记录。
class FakeTargetRepo extends CloudRepository {
  FakeTargetRepo() : super(CloudBaseService());

  List<Map<String, dynamic>> history = [];
  int getHistoryCalls = 0;
  final List<Map<String, dynamic>> uploadedHistory = [];

  @override
  Future<List<Map<String, dynamic>>> getHistoryEntries({int limit = 100}) async {
    getHistoryCalls++;
    return List.from(history);
  }

  @override
  Future<void> setCurrentClipboard(Map<String, dynamic> data) async {}

  @override
  Future<void> addHistoryEntry(Map<String, dynamic> data) async {
    uploadedHistory.add(data);
  }
}

/// 旧账户（源）仓库：只读；salt + 全量密文支持真实解密。
class FakeSourceRepo extends CloudRepository {
  FakeSourceRepo() : super(CloudBaseService());

  String? salt;
  List<Map<String, dynamic>> history = [];
  Map<String, String> contents = {};

  @override
  Future<String?> getSalt() async => salt;

  @override
  Future<List<Map<String, dynamic>>> getHistoryEntries({int limit = 100}) async {
    return List.from(history);
  }

  @override
  Future<Map<String, dynamic>?> getHistoryEntryContent(String entryId) async {
    final c = contents[entryId];
    if (c == null) return null;
    return {'content': c};
  }

  @override
  Future<http.StreamedResponse> downloadFile(String entryId) async {
    return http.StreamedResponse(const Stream.empty(), 404);
  }
}

Map<String, dynamic> serverRow({
  required String id,
  required String type,
  int? timestamp,
}) {
  return {
    'id': id,
    'type': type,
    'content': '',
    'source_device': 'd1',
    'source_device_name': 'Mac',
    'source_platform': 'macos',
    'timestamp': timestamp ?? 1700000000000,
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const oldPassword = 'old-password';
  const newPassword = 'new-password';
  final oldSaltHex =
      'aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899';
  final newSaltHex =
      'ccddeeff00112233445566778899aabbccddeeff00112233445566778899aabb';

  late EncryptionService encryption;
  late Uint8List key;
  late LocalStorage storage;
  late SettingsProvider settings;
  late ClipboardProvider provider;
  late FakeTargetRepo targetRepo;

  Future<void> initProviders() async {
    SharedPreferences.setMockInitialValues({});
    encryption = EncryptionService();
    key = await encryption.deriveKey(newPassword, hexToBytes(newSaltHex));
    storage = LocalStorage(await SharedPreferences.getInstance());
    settings = SettingsProvider();
    await settings.setBackgroundSync(false);
    await settings.setNotificationSync(false);
    provider = ClipboardProvider();
    provider.setSettingsProvider(settings);
    targetRepo = FakeTargetRepo();
    await provider.initialize(
      storage: storage,
      cloudRepo: targetRepo,
      deviceId: 'dev-1',
      deviceName: 'Test Mac',
      encryptionKey: key,
    );
  }

  Widget buildApp(FakeSourceRepo source, {required String userId}) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<AuthProvider>(
          create: (_) => FakeAuthProvider(userId),
        ),
        ChangeNotifierProvider<ClipboardProvider>(create: (_) => provider),
        ChangeNotifierProvider<SettingsProvider>(create: (_) => settings),
        Provider<AppInfo>.value(
          value: const AppInfo(version: 'test', buildNumber: '1'),
        ),
      ],
      child: MaterialApp(
        home: CloudPullScreen(
          sourceRepoFactory: (userId, deviceId) => source,
        ),
      ),
    );
  }

  Widget buildDisabledApp() {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<AuthProvider>(create: (_) => AuthProvider()),
        ChangeNotifierProvider(create: (_) => ClipboardProvider()),
        ChangeNotifierProvider(create: (_) => SettingsProvider()),
        Provider<AppInfo>.value(
          value: const AppInfo(version: 'test', buildNumber: '1'),
        ),
      ],
      child: const MaterialApp(home: CloudPullScreen()),
    );
  }

  Future<void> useTallViewport(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  testWidgets('云拉取页渲染引导 + 旧密码输入；无会话密钥时开始按钮禁用', (tester) async {
    await useTallViewport(tester);

    await tester.pumpWidget(buildDisabledApp());
    await tester.pumpAndSettle();

    expect(find.text(AppStrings.cloudPullTitle), findsOneWidget);
    expect(find.text(AppStrings.cloudPullGuideTitle), findsOneWidget);
    expect(find.text(AppStrings.cloudPullGuideBody), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);

    // 未解锁（encryptionKey == null / userId 空）→ 开始按钮禁用
    FilledButton buttonOf() => tester.widget<FilledButton>(
          find.ancestor(
            of: find.text(AppStrings.cloudPullStartAction),
            matching: find.byType(FilledButton),
          ),
        );
    expect(buttonOf().onPressed, isNull);

    // 输入旧密码后仍禁用（缺少会话密钥守卫）
    await tester.enterText(find.byType(TextField), 'old-password');
    await tester.pump();
    expect(buttonOf().onPressed, isNull);
  });

  testWidgets('目标账户已有条目且合并超 100：弹出上限警告，取消不执行导入', (tester) async {
    await useTallViewport(tester);
    await initProviders();

    // 目标账户已有 60 条；源账户 50 条 → 60 + 50 = 110 > 100
    targetRepo.history = List.generate(
      60,
      (i) => serverRow(id: 'target-$i', type: 'text'),
    );
    final source = FakeSourceRepo()
      ..salt = oldSaltHex
      ..history = List.generate(
        50,
        (i) => serverRow(id: 'src-$i', type: 'text'),
      );

    await tester.pumpWidget(buildApp(source, userId: deriveUserId(newPassword)));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), oldPassword);
    await tester.pump();

    await tester.tap(find.text(AppStrings.cloudPullStartAction));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // 警告对话框出现，文案含目标条数与合并后总量
    expect(find.text(AppStrings.cloudPullLimitDialogTitle), findsOneWidget);
    expect(find.textContaining('已有 60 条'), findsOneWidget);
    expect(find.textContaining('共 110 条'), findsOneWidget);

    // 取消 → 不执行导入（无写入，回到可再次开始状态）
    await tester.tap(find.text(AppStrings.commonCancel));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(targetRepo.uploadedHistory, isEmpty);
    expect(find.text(AppStrings.cloudPullStartAction), findsOneWidget);

    // 卸载释放轮询定时器
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('目标账户已有条目且合并超 100：确认后继续导入，写入目标账户', (tester) async {
    await useTallViewport(tester);
    await initProviders();

    // 目标账户已有 100 条；源账户 1 条可解密文本 → 101 > 100
    targetRepo.history = List.generate(
      100,
      (i) => serverRow(id: 'target-$i', type: 'text'),
    );
    final oldKey =
        await encryption.deriveKey(oldPassword, hexToBytes(oldSaltHex));
    final textCipher =
        (await encryption.encrypt('migrated text', oldKey)).toBase64();
    final source = FakeSourceRepo()
      ..salt = oldSaltHex
      ..history = [serverRow(id: 'src-1', type: 'text', timestamp: 1)]
      ..contents['src-1'] = textCipher;

    await tester.pumpWidget(buildApp(source, userId: deriveUserId(newPassword)));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), oldPassword);
    await tester.pump();

    await tester.tap(find.text(AppStrings.cloudPullStartAction));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text(AppStrings.cloudPullLimitDialogTitle), findsOneWidget);

    await tester.tap(find.text(AppStrings.cloudPullLimitConfirmAction));
    await tester.pump();
    // 进度条持续动画，不能用 pumpAndSettle；轮询推进直到迁移完成
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(targetRepo.uploadedHistory, isNotEmpty);
    expect(find.textContaining('导入 1 条'), findsOneWidget);

    // 卸载释放轮询定时器
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('旧密码与当前账户相同：在任何网络调用前拒绝，不弹上限警告', (tester) async {
    await useTallViewport(tester);
    await initProviders();

    targetRepo.history = List.generate(
      60,
      (i) => serverRow(id: 'target-$i', type: 'text'),
    );
    final source = FakeSourceRepo()..salt = oldSaltHex;

    // 当前账户 userId 与 oldPassword 派生相同
    await tester.pumpWidget(buildApp(source, userId: deriveUserId(oldPassword)));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), oldPassword);
    await tester.pump();

    final callsBefore = targetRepo.getHistoryCalls;
    await tester.tap(find.text(AppStrings.cloudPullStartAction));
    await tester.pump();

    expect(find.text(AppStrings.cloudPullSameAccount), findsOneWidget);
    expect(find.text(AppStrings.cloudPullLimitDialogTitle), findsNothing);
    expect(targetRepo.getHistoryCalls, callsBefore); // 目标账户未被查询
    expect(targetRepo.uploadedHistory, isEmpty);

    // 卸载释放轮询定时器
    await tester.pumpWidget(const SizedBox());
  });
}
