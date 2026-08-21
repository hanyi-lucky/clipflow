/// 应用文案资源层（zh 单一源）。
///
/// 命名规则：<域><语义>，如 settingsTitle / trashDeletedMinutesAgo / commonCancel。
/// 规则：无插值 → static const；有插值 → static String fn(args)；仅收用户可见文案。
/// 后续做 en 双语言时，把静态成员重构为 locale-aware 查询即可，调用点语义不变。
abstract final class AppStrings {
  // ===== 通用 =====
  static const String commonCancel = '取消';
  static const String commonSave = '保存';
  static const String commonGotIt = '知道了';
  static const String commonRetry = '重试';
  static const String commonDelete = '删除';
  static const String commonCopy = '复制';
  static const String commonRestore = '恢复';
  static const String commonRefresh = '刷新';

  // ===== 同步状态（SyncStatus 枚举标签，保持 const）=====
  static const String syncStatusConnected = '已连接';
  static const String syncStatusSyncing = '同步中...';
  static const String syncStatusError = '同步失败';
  static const String syncStatusDisconnected = '未连接';
  static const String syncStatusPaused = '已暂停同步';
  static const String syncStatusLocalOnly = '仅本地';
  static const String lanOnlyLocalOnlyBanner = '内容仅在本地、未同步到其他设备';
  static const String lanOnlyLocalOnlyBannerHint = '对端离线或未握手成功时，内容保留在本机，恢复连接后自动继续同步';

  // ===== 设置页 =====
  static const String settingsTitle = '设置';
  static const String settingsAppearanceSection = '外观';
  static const String themeFollowSystem = '跟随系统';
  static const String themeLight = '浅色模式';
  static const String themeDark = '深色模式';
  static const String settingsGeneralSection = '通用';
  static const String autoSyncTitle = '自动同步';
  static const String autoSyncSubtitle = '检测到新内容时自动同步到云端';
  static const String lanAccelerationTitle = '局域网加速';
  static const String lanAccelerationSubtitle = '同一 Wi-Fi 下优先经局域网快速同步文本与图片，失败自动回退云端';
  static const String lanOnlyTitle = '仅局域网同步（实验）';
  static const String lanOnlySubtitle = '内容只经局域网同步，不写云端（同 Wi-Fi 下零服务器流量）';
  static const String lanOnlyExperimentalHint = '实验功能：对端离线时不保证送达，内容会保留在本机';
  static const String lanOnlyEnabledSnackBar = '已开启仅局域网同步：内容仅在本机与同一 Wi-Fi 设备间同步';
  static const String lanPermissionDenied = '未获得局域网权限，已回退云端同步';
  static const String historyLimitTitle = '历史记录保留';
  static String historyLimitCount(int limit) => '$limit条';
  static const String settingsDevicesSection = '设备管理';
  static const String settingsAccountSection = '账户与数据';
  static const String changePasswordHint = '改密码 = 换新账户：先导出备份，改密码后导入恢复';
  static const String exportBackupTitle = '导出备份';
  static const String exportBackupSubtitle = '生成 .clipflow-backup.json 密文备份（含 salt，零明文）';
  static const String importBackupTitle = '导入备份';
  static const String importBackupSubtitle = '迁移码导入：输入旧密码，恢复到当前账户';
  static const String cloudPullTitle = '从云端拉取';
  static const String cloudPullSubtitle = '输入旧密码，直接把旧账户云端数据迁移到当前账户';
  static const String changePasswordInfoTitle = '改密码说明';
  static const String changePasswordInfoSubtitle = '改密码会进入新账户，旧数据如何找回？';
  static const String settingsSyncSection = '同步设置';
  static const String backgroundSyncTitle = '后台自动同步';
  static const String backgroundSyncSubtitle = 'Android 10+ 后台读取剪贴板受限，Android 16+ 仅打开 App 时可同步';
  static const String autoSyncOnResumeTitle = 'App打开自动同步';
  static const String autoSyncOnResumeSubtitle = '进入前台时自动检查并同步';
  static const String notificationSyncTitle = '通知栏同步';
  static const String notificationSyncSubtitle = '显示常驻通知，点击通知打开 App 并立即同步';
  static const String settingsPermissionSection = '权限状态';
  static const String notificationPermissionTitle = '通知权限';
  static const String batteryOptimizationTitle = '电池优化';
  static const String batteryOptimizationSubtitle = '关闭电池优化可提高后台同步稳定性';
  static const String appSettingsTitle = '应用详情设置';
  static const String appSettingsSubtitle = '管理通知、电池优化等系统权限';
  static const String settingsCompatibilitySection = '兼容性';
  static const String settingsDiagnosticsSection = '诊断（局域网）';
  static const String diagnosticsLanDisabled = '局域网未启用';
  static const String diagnosticsReset = '清零';
  static const String diagnosticsDiscovered = '发现设备';
  static const String diagnosticsHandshakeSuccess = '握手成功';
  static const String diagnosticsHandshakeRejected = '握手拒绝';
  static const String diagnosticsLanFetchHit = 'LAN 拉取命中';
  static const String diagnosticsLanFetchMiss = 'LAN 拉取未命中';
  static const String diagnosticsPushSent = '推送发送';
  static const String diagnosticsPushReceived = '推送接收';
  static const String diagnosticsAckSent = 'ACK 发送';
  static const String diagnosticsAckReceived = 'ACK 接收';
  static const String diagnosticsSessionDropped = '会话断开';
  static const String diagnosticsFallbackTitle = '回退原因';
  static const String diagnosticsFallbackLanDisabled = 'LAN 未启用';
  static const String diagnosticsFallbackNoPeer = '无可用设备';
  static const String diagnosticsFallbackHandshakeRejected = '握手被拒';
  static const String diagnosticsFallbackFetchTimeout = '拉取超时';
  static const String diagnosticsFallbackFetchError = '拉取错误';
  static const String diagnosticsFallbackDuplicate = '重复行';
  static const String diagnosticsFallbackDecodeFailed = '解密失败';
  static const String diagnosticsFallbackLocalMissingEnc = '本地密文缺失';
  static const String diagnosticsFallbackArtifactMismatch = '文件校验不符';
  static const String diagnosticsFallbackOverLimit = '超 LAN 上限';
  static const String settingsAboutSection = '关于';
  static const String aboutVersion = '版本';
  static const String aboutLicense = '开源协议';
  static const String compatibilityTitle = '图片与文件格式兼容性';
  static const String permissionGranted = '已授予';
  static const String permissionDenied = '未授予';
  static const String batteryOptimizationOff = '已关闭';
  static const String batteryOptimizationOn = '未关闭';

  // ===== 设置页：改密码对话框 =====
  static const String changePasswordDialogTitle = '改密码 = 换新账户';
  static const String changePasswordDialogBody = 'ClipFlow 用密码派生账户身份：密码不同 = 账户不同，旧数据不会自动带到新密码下。';
  static const String changePasswordStepsTitle = '改密码的正确步骤';
  static const String changePasswordStepsBody = '① 改密码前，先在「导出备份」生成 .clipflow-backup.json；\n② 在解锁页点击「切换到其他账户」（确认后清除本机旧账户标记），再输入新密码（= 进入新账户）；\n③ 在新账户下「导入备份」，选择备份文件并输入旧密码；\n④ 数据恢复完成。\n或在新账户设置页「从云端拉取」输入旧密码直接迁移。';
  static const String changePasswordNoteTitle = '注意';
  static const String changePasswordNoteBody = '旧账户数据仍保留在旧密码下，不会被删除。';

  // ===== 设置页：切换账号 =====
  static const String settingsSwitchAccountTitle = '切换账号';
  static const String settingsSwitchAccountSubtitle = '退出当前账户并回到登录页，可切换到其他密码对应的账户';
  static const String switchAccountDialogTitle = '切换账号';
  static const String switchAccountDialogBody = '切换后将退出当前账户并回到登录页。请确认已导出备份，否则当前设备上的历史记录将无法直接访问（之后可用旧密码从云端拉取恢复）。';
  static const String switchAccountDialogConfirmAction = '确认切换';

  // ===== 设置页：兼容性对话框 =====
  static const String compatibilityImageTitle = '图片';
  static const String compatibilityImageBody = '支持剪贴板图片 PNG/JPEG/GIF/TIFF/BMP/WebP/HEIC；统一转 PNG/JPEG，长边超 2048 压缩、JPEG q80、含透明转 PNG；单张上限 5MB。';
  static const String compatibilityFileTitle = '文件';
  static const String compatibilityFileBody = 'macOS 经 Finder 复制任意文件（file-url）；Android 经文件管理器复制（content://，无需存储权限）；Windows 剪贴板文件（CF_HDROP，已真机验证）；单文件 ≤50MB；一次复制多文件只同步第一个；文件夹同步不支持。';
  static const String compatibilityFormatsTitle = '常见文件格式';
  static const String compatibilityFormatsBody = '文本（txt/md/csv/json）、文档（pdf/doc/docx）、表格（xls/xlsx）、演示（ppt/pptx）、压缩（zip/7z/rar/tar/gz）、音视频（mp3/wav/mp4/mov/mkv）、代码（dart/swift/kt/cpp/h/py/js/ts/html/css）等；未识别扩展名按通用文件处理。';
  static const String compatibilityPlatformTitle = '平台差异';
  static const String compatibilityPlatformBody = 'macOS/Windows 500ms 轮询检测；Android 由前台服务 + 原生剪贴板监听，但 Android 10+ 后台读取剪贴板受限、Android 16+ 仅前台触发；删除记录在垃圾箱保留 24 小时，跨设备删除/恢复同步窗口 30 秒，“倾倒垃圾桶”可彻底删除本地/服务器/磁盘数据。';

  // ===== 解锁页 =====
  static const String switchAccountAction = '切换到其他账户';
  static const String switchAccountConfirmBody = '切换账户将清除本机已保存的账户标记与本地缓存（含加密盐），\n当前账户数据需先用「导出备份」保存，之后在新账户下用「导入备份」恢复。\n\n确定要继续切换吗？';
  static const String switchAccountConfirmAction = '继续切换';
  static const String unlockConnecting = '正在连接服务器...';
  static const String unlockServerUnreachable = '无法连接服务器';
  static const String unlockCheckNetwork = '请检查网络连接后重试';
  static const String unlockSetPasswordTitle = '设置主密码';
  static const String unlockTitle = '解锁';
  static const String unlockFirstTimeSubtitle = '创建密码加密剪切板数据\n请在所有设备上使用相同密码';
  static const String unlockEnterPassword = '输入主密码解锁';
  static const String masterPasswordLabel = '主密码';
  static const String weakPasswordFirstTime = '此密码过于简单，容易被猜中，建议设置更复杂的密码';
  static const String weakPasswordExisting = '此密码过于简单，请注意账户安全';
  static const String createAndStartAction = '创建并开始';
  static String unlockConnectFailed(String e) => '连接失败: $e';
  static String unlockTooManyAttempts(int seconds) => '尝试过于频繁，请 $seconds 秒后再试';
  static const String unlockWrongPassword = '密码错误，请重新输入';
  static String unlockFailed(String e) => '解锁失败: $e';

  // ===== 垃圾箱 =====
  static const String trashTitle = '垃圾箱';
  static const String emptyTrashTitle = '倾倒垃圾桶';
  static const String trashEmpty = '垃圾箱为空';
  static const String trashEmptyHint = '删除的记录将保留 24 小时';
  static const String emptyTrashConfirmBody = '确定要永久删除垃圾箱中的所有记录吗？此操作不可恢复。';
  static const String dumpAction = '倾倒';
  static const String restoreEntryTitle = '恢复记录';
  static const String restoreEntryConfirmBody = '确定要恢复这条记录吗？';
  static const String restoreSuccess = '已恢复';
  static const String trashDeletedJustNow = '刚刚删除';
  static String trashDeletedMinutesAgo(int n) => '$n分钟前删除';
  static String trashDeletedHoursAgo(int n) => '$n小时前删除';
  static String trashDeletedDaysAgo(int n) => '$n天前删除';
  static const String trashExpiringSoon = '即将清除';
  static String trashRemainingHoursMinutes(int hours, int minutes) => '剩余 $hours 小时 $minutes 分钟';
  static String trashRemainingMinutes(int minutes) => '剩余 $minutes 分钟';
  static String trashDumpedCount(int n) => '已倾倒 $n 条记录';
  static String trashDumpFailed(String e) => '倾倒失败: $e';

  // ===== 设备管理 =====
  static const String devicesLoadFailed = '加载失败';
  static const String devicesEmpty = '暂无设备';
  static const String currentDeviceBadge = '当前设备';
  static const String renameAction = '重命名';
  static const String removeAction = '移除';
  static const String renameDeviceTitle = '重命名设备';
  static const String deviceNameLabel = '设备名称';
  static const String deviceNameHint = '例如：Android · Xiaomi 15';
  static const String deviceRenamed = '设备已重命名';
  static const String removeDeviceTitle = '移除设备';
  static const String removeCurrentDeviceBody = '移除当前设备后，该设备的 token 将立即失效，无法继续同步。确定要移除吗？';
  static const String deviceRemovedSigningOut = '当前设备已移除，正在退出登录...';
  static const String deviceRemoved = '设备已移除';
  static const String deviceOnlineJustNow = '刚刚在线';
  static String deviceSubtitle(String platform, String lastSeen) => '$platform · $lastSeen';
  static String deviceRenameFailed(String e) => '重命名失败：$e';
  static String removeDeviceBody(String name) => '确定要移除设备「$name」吗？该设备的 token 将立即失效。';
  static String deviceRemoveFailed(String e) => '移除失败：$e';
  static String deviceOnlineMinutesAgo(int n) => '$n分钟前';
  static String deviceOnlineHoursAgo(int n) => '$n小时前';
  static String deviceOnlineDaysAgo(int n) => '$n天前';

  // ===== 首页 / 搜索 / 筛选 =====
  static const String mergeModeDoneTooltip = '完成选择';
  static const String mergeModeTooltip = '多选拼接';
  static const String searchNoResults = '没有找到匹配的记录';
  static const String homeEmptyTitle = '暂无剪切板记录';
  static const String homeEmptyHint = '复制内容后自动同步';
  static const String deleteEntryConfirmBody = '确定要删除这条记录吗？';
  static String searchResultCount(int n) => '$n 条结果';
  static const String typeText = '文本';
  static const String typeImage = '图片';
  static const String typeFile = '文件';
  static const String typeAll = '全部';
  static const String searchHistoryHint = '搜索历史记录';
  static const String deviceFilterLabel = '设备';
  static const String contentTypeTitle = '内容类型';
  static const String filterDevicesTitle = '筛选设备';
  static const String filterAllDevices = '全部设备';

  // ===== 图片预览 / 图片网格 =====
  static const String copiedToClipboard = '已复制到剪切板';
  static const String imagePreviewTitle = '图片预览';
  static const String imageDecryptFailed = '图片解密失败';
  static const String imageLoadFailed = '图片加载失败';
  static const String imageGridEmptyTitle = '暂无图片记录';
  static const String imageGridEmptyHint = '复制图片后自动同步到这里';
  static String imageGridYesterday(String timeStr) => '昨天 $timeStr';
  static String imageGridMonthDay(int month, int day, String timeStr) => '$month月$day日 $timeStr';

  // ===== 多选拼接 =====
  static const String mergeSeparatorLabel = '分隔符';
  static const String separatorNewline = '换行';
  static const String separatorComma = '逗号';
  static const String separatorSemicolon = '分号';
  static const String separatorSpace = '空格';
  static const String mergePreviewEmpty = '选择条目查看拼接预览';
  static String mergeCopyCount(int n) => '复制拼接内容 ($n条)';

  // ===== 条目卡片 =====
  static const String pinAction = '置顶';
  static const String unpinAction = '取消置顶';
  static const String fileSizeUnknown = '未知大小';
  static const String fileGenericLabel = '文件';
  static const String fileNameUntitled = '未命名文件';
  static const String fileProcessing = '处理中';
  static const String fileDownloadFailed = '下载失败';
  static const String fileCancelled = '已取消';
  static const String cancelDownloadTooltip = '取消下载';
  static const String retryDownloadTooltip = '重试下载';
  static const String imageLabel = '图片';
  static const String expandContent = '展开 ▼';
  static const String collapseContent = '折叠 ▲';
  static String clipboardTimeSecondsAgo(int n) => '$n秒前';
  static String clipboardTimeMinutesAgo(int n) => '$n分钟前';
  static String clipboardTimeHoursAgo(int n) => '$n小时前';
  static String clipboardTimeDaysAgo(int n) => '$n天前';
  static String deviceTimeSubtitle(String device, String time) => '$device · $time';
  static String fileMetaExtension(String ext) => '$ext 文件';
  static String fileDownloading(String received, String total) => '下载中 $received / $total';

  // ===== 备份导出/导入 =====
  static const String backupFileTypeLabel = 'ClipFlow 备份';
  static const String sessionKeyMissing = '未找到当前会话密钥，请返回解锁页重新解锁后再试';
  static const String exportFetching = '正在拉取并导出...';
  static const String backupExportDone = '导出完成';
  static const String largeBackupWarningTitle = '备份体积较大';
  static const String largeBackupContinueAction = '继续';
  static const String exportContentTitle = '备份内容';
  static const String exportContentBody = '导出本账户全部历史条目（文本 / 图片 / 文件）的密文与元数据，含解密所需 salt。文件为端到端加密密文，不含任何明文。';
  static const String exportChangePasswordHint = '改密码前请先导出备份：改密码 = 新账户，旧数据需用「导入备份」恢复。';
  static const String exportSaved = '备份已保存';
  static const String exportChooseLocation = '选择一个保存位置，将生成 .clipflow-backup.json 备份文件。';
  static const String exportInProgress = '导出中...';
  static const String exportAgain = '重新导出';
  static const String exportChooseAndExport = '选择位置并导出';
  static const String importGuideTitle = '迁移说明';
  static const String importGuideBody = '导入需输入「导出时的旧密码」：备份在本地用旧密码解密后，再用当前密码（新账户）重新加密上传，服务端只存密文。';
  static const String importChooseFile = '选择备份文件';
  static const String importInProgress = '正在导入...';
  static const String importInProgressButton = '导入中...';
  static const String importStartAction = '开始导入';
  static const String sourceUnknown = '未知';
  static const String oldPasswordLabel = '旧密码（导出时使用的密码）';
  static const String importEnterOldPassword = '请输入旧密码';
  static const String backupExportingLabel = '正在导出';
  static const String backupImportingLabel = '正在导入';
  static const String backupImportDone = '导入完成';
  static const String backupWrongOldPassword = '旧密码错误';
  static String exportFailed(String e) => '导出失败: $e';
  static String largeBackupWarningBody(String mb) => '当前备份预估约 $mb MB，导出与导入可能需要较长时间。是否继续？';
  static String importParseFailed(String e) => '无法解析备份文件: $e';
  static String importFileSelected(String name) => '已选择：$name';
  static String importFailed(String e) => '导入失败: $e';
  static String importSummary(int count, String source) => '备份共 $count 条，来源：$source';
  static String importResultCount(int n) => '导入 $n 条';
  static String importResultFailed(int n) => '，失败 $n 条';
  static String backupExporting(int i, int total) => '正在导出 $i/$total';
  static String backupImporting(int i, int total) => '正在导入 $i/$total';
  static String backupPinRestoreFailed(String id, String e) => '$id (置顶恢复): $e';

  // ===== 从云端拉取（旧账户迁移到当前账户） =====
  static const String cloudPullGuideTitle = '迁移说明';
  static const String cloudPullGuideBody = '输入旧账户的密码，旧账户云端密文将用旧密码解密、再用当前密码重新加密后写入当前账户，无需备份文件。';
  static const String cloudPullStartAction = '开始拉取';
  static const String cloudPullInProgress = '正在拉取...';
  static const String cloudPullInProgressButton = '拉取中...';
  static const String cloudPullFetchingLabel = '正在读取旧账户';
  static String cloudPullFetching(int i, int total) => '正在读取旧账户 $i/$total';
  static const String cloudPullDone = '拉取完成';
  static const String cloudPullSameAccount = '旧密码与当前账户相同，无需拉取';
  static const String cloudPullEmptyAccount = '未找到旧账户数据：旧密码错误或旧账户为空';
  static const String cloudPullLimitDialogTitle = '历史记录上限提示';
  static String cloudPullLimitDialogBody(int targetCount, int totalCount) =>
      '目标账户已有 $targetCount 条记录，加上本次迁移共 $totalCount 条。'
      '服务端仅保留每个账户最近 100 条历史，较早的迁移条目可能被自动清理。'
      '是否继续拉取？';
  static const String cloudPullLimitConfirmAction = '仍然继续';

  // ===== Provider / 服务层用户可见错误 =====
  static const String decryptFailedPlaceholder = '[解密失败]';
  static const String rateLimitedMessage = '尝试过于频繁，请稍后再试';
  static const String invalidBackupFormat = '不是有效的 ClipFlow 备份文件（format 不匹配）';
  static const String imageDecodeFailed = '无法解码图片数据';
  static const String imageCompressDecodeFailed = '无法解码压缩产物';
  static String loadHistoryFailed(String e) => '从服务器加载历史失败: $e';
  static String fileReadFailed(String errorCode) => '文件读取失败（$errorCode），已拒绝上传';
  static String fileTooLarge(int mb) => '文件超过 ${mb}MB，已拒绝上传';
  static const String fileMissing = '文件不存在或已被移动，已跳过同步';
  static String imageTooLarge(int mb) => '图片超过 ${mb}MB，已拒绝上传';
  static String restoreFailed(String e) => '恢复失败: $e';
  static String unsupportedBackupVersion(String version) => '不支持的备份版本: $version';

  // ===== 设备名（平台 · 机型）=====
  static String deviceNameAndroid(String model) => 'Android · $model';
  static String deviceNameWindows(String model) => 'Windows · $model';
  static String deviceNameMac(String model) => 'Mac · $model';
  static String deviceNameIos(String model) => 'iOS · $model';

  // ===== 剪贴板占位文本检测（微信/QQ/Finder 复制文件时的文本占位）=====
  static const List<String> clipboardPlaceholderTexts = [
    '[文件]',
    '[图片]',
    '[照片]',
    '[表情]',
    '[语音]',
    '[视频]',
    '[链接]',
  ];
}
