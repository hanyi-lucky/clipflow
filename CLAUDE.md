# CLAUDE.md

本文件为 Claude Code (claude.ai/code) 在此仓库中工作提供指引。

## 可用 Skills

本项目已安装以下插件提供的 Skills，可通过 `/<skill名称>` 调用：

| Skill | 用途 | 使用场景 |
|-------|------|----------|
| `code-review` | 代码审查 | 提交前检查代码质量、潜在 bug |
| `github` | GitHub 操作 | PR、Issue、Release 管理 |
| `playwright` | 浏览器自动化 | Web 端 UI 测试 |
| `frontend-design` | 前端设计 | UI/UX 设计建议 |
| `feature-dev` | 功能开发 | 新功能开发流程 |
| `skill-creator` | 创建 Skill | 自定义项目专属 Skill |
| `claude-md-management` | 文档管理 | CLAUDE.md 维护优化 |

---

# Agent 专用管线工作流

## 1. 核心原则
- 禁止主代理在当前会话内分角色模拟开发/测试/验收，必须串行委派真实子代理实例执行。
- 仅串行委派，一次只启动一个子代理，等其返回后再启动下一个。
- 子代理拥有完全独立的上下文，其内部工具调用、中间推理过程严禁输出到用户主聊天框，仅将最终结果返回给主代理，由主代理统一汇总交付。
- 主代理只做路由和编排，不加载 Skill 定义，不执行分析流程。

### 6 个专用 Agent
| Agent | 职责 | 方法论 | 可写代码 |
|-------|------|--------|---------|
| explorer | 代码探索、执行路径追踪 | code-explorer | ❌ |
| architect | 方案设计、架构决策 | code-architect | ❌ |
| coder | TDD 代码实现 | test-driven-development | ✅ |
| tester | 测试验证、完成声明验证 | verification-before-completion | ❌ |
| reviewer | 终审、置信度评分 | confidence-scoring | ❌ |
| debugger | 根因分析 | systematic-debugging | ❌ |

### 工具约束与校验
- explorer、architect、tester、reviewer、debugger 禁止使用 Write、Edit 工具修改业务代码，为指令级软约束；
- 主代理在收到子代理结果后，需交叉校验是否存在违规修改业务代码的操作；
- 所有子代理工具调用可通过 Argus 插件回溯审计。

## 2. 任务路由
用户下发需求 → 主代理判断任务类型 → 按路由表串行委派：

| 类型 | 判断条件 | Agent 管线 |
|------|---------|-----------|
| 轻量改动 | 单文件、无逻辑变更（注释、配置、文档、文案） | 主代理直接处理 |
| Bug 修复 | 用户描述了具体错误行为或测试失败 | explorer → debugger → coder → tester |
| 新功能 | 需要新增组件、服务、API 或 UI 交互 | explorer → architect → coder → tester → reviewer |
| 重大改动 | 涉及加密、同步机制、架构重构，或跨 3+ 文件 | explorer → architect → coder → tester → reviewer → /code-review |

### 整改循环（最多 3 轮）
若 tester 或 reviewer 判定不通过：
1. 主代理派 debugger 做根因分析
2. 将 debugger 根因分析 + tester 失败报告 + reviewer 整改清单合并，传给 coder
3. coder 基于根因修复（不自由探索）
4. 重新进入 tester → reviewer 流程
5. **最多执行 3 轮整改**；若 3 轮仍未通过，则自动终止流程，向用户上报完整问题详情与历史迭代记录，由人工介入处理

### 交付规范
全部验收通过后，主代理统一汇总并交付给用户，内容必须精简：
- 仅保留：核心改动清单、测试结论、验收最终结果、关键风险提示
- 完整原始报告仅保留在子代理上下文中，用户主动索要时再单独输出
- 禁止完整粘贴子代理的原始报告、调试日志到用户主聊天框

## 3. 分场景触发规则
| 场景 | 处理方式 |
|------|---------|
| 轻量改动（注释、文案、配置、文档） | 主代理直接处理，不启动任何 agent |
| 普通功能新增 / Bug 修复 | 执行标准管线流程 |
| 核心重大改动（架构重构、加密逻辑、同步机制） | 执行完整管线流程，reviewer 通过后再调 /code-review 做多角度审查 |

## 4. 子代理调用方式
使用 Agent 工具，关键参数：
- `subagent_type`：分别指定 `explorer`、`architect`、`coder`、`tester`、`reviewer`、`debugger`
- `run_in_background: false`：确保串行等待
- `prompt`：包含完整的任务描述 + 上下文（整改时需包含前序报告）

## 5. 子代理规则边界
- 子代理仅加载自身 `.md` 文件内的系统提示，不继承项目 CLAUDE.md 的全局规则
- 所有子代理专属的职责、约束、校验标准必须全部写入各自的 agent.md 文件
- 不得依赖 CLAUDE.md 向子代理传递专属规则

---

## 构建、测试、检查

```bash
# 运行所有测试（无需服务器连接即可跑核心服务测试）
flutter test

# 运行单个测试文件
flutter test test/services/encryption_service_test.dart

# 静态检查（info 级别也会导致 exit code 1，只有 error 需要关注）
flutter analyze

# 在 macOS 上运行
flutter run -d macos

# 构建发布版本
flutter build macos --release     # macOS .app
flutter build apk --release       # Android .apk
flutter build windows --release   # Windows .exe
```

**Flutter 安装路径：** `/opt/homebrew/bin/flutter`，如直接运行 `flutter` 命令找不到，请使用完整路径。

## 架构

**跨平台剪切板同步工具，端到端加密。** Flutter 前端，Node.js + SQLite 自建服务器后端。支持 macOS、Android、Windows，iPad/iOS 通过快捷指令 + Web App 补充。

### 整体架构

```
Flutter App
    ↓ HTTP POST (JSON)
Node.js Server (Express + SQLite)
    ↓
阿里云 ECS (2核2G, 40GB SSD)
```

### 服务器地址

- **API 基础地址：** `http://121.196.222.122:3000/api`
- **健康检查：** `http://121.196.222.122:3000/api/ping`
- **SSH：** `ssh -i /Users/hanyi/Downloads/key241294.pem root@121.196.222.122`
- **服务管理：** `systemctl restart clipflow`
- **服务器代码路径：** `/opt/clipflow/index.js`
- **数据库路径：** `/opt/clipflow/clipflow.db`（SQLite）

## 历史重大决策

记录项目演进过程中的关键选择，帮助理解"为什么是现在这样"。

### 后端三迁：Firebase → 腾讯云 → 阿里云自建

| 阶段 | 方案 | 迁移原因 |
|------|------|----------|
| v1.0 | Firebase | 初期快速验证，但国内需要梯子，用户无法使用 |
| v1.1 | 腾讯云开发 CloudBase | 国内直连，通过云函数 HTTP 端点访问数据库。但使用的是体验版，每月有资源点上限，而本项目的轮询机制会 24 小时与数据库互动，资源点很快耗尽 |
| v1.2+ | 阿里云 ECS 自建 | 买了一年服务器，无限次调用，完全自主可控，可直接 SSH 调试 |

**教训：** 有持续轮询需求的项目不适合按量计费或有资源上限的 BaaS 服务。自建服务器固定成本，无调用次数限制。

### 桌面端轮询 vs 系统原生 API

**决策：** macOS/Windows 使用 `Timer.periodic` 500ms 轮询 `Clipboard.getData()`，而非系统原生剪切板变更通知 API。

**原因：**
- Flutter 没有跨平台的剪切板变更通知 API
- 各平台原生 API 差异大（macOS 用 NSPasteboard observer，Windows 用 AddClipboardFormatListener）
- 500ms 轮询对剪切板场景完全够用，CPU 占用极低
- 实现简单，一个文件覆盖所有桌面平台

**例外：** Android 使用原生 `ClipboardManager.OnPrimaryClipChangedListener`（通过 MethodChannel），因为 Android 10+ 限制了后台剪切板访问，轮询方式不可靠。

### 端到端加密 vs 服务器端加密

**决策：** 所有数据在客户端加密后才上传，服务器只存储密文。

**原因：** 剪切板内容可能包含密码、token、私密信息等极度敏感数据。如果服务器被攻破，密文无法被解读。即使是我们自己运维的服务器，也不应该能看到用户数据。

### SQLite vs MongoDB/Redis

**决策：** 使用 SQLite 作为服务器数据库。

**原因：** 阿里云 ECS 是 2核2G 小机器，SQLite 零配置、零运维、单文件存储，对这个量级（个人工具，几台设备）绰绰有余。MongoDB/Redis 会额外占用几百 MB 内存，对小机器不友好。

---

## 核心设计决策（重要！）

以下是不可轻易更改的架构决策，修改前必须理解其原因。

### 1. 密码即账户（Password-as-Identity）

**机制：** userId = `user_` + `SHA256("clipflow:$password").substring(0, 16)`

- 相同密码 → 相同 userId → 共享数据
- 不同密码 → 不同 userId → 数据完全隔离
- 不存在传统的注册/登录/用户名系统

**为什么这样做：** 用户无需注册账号，输入密码即可跨设备同步。密码本身就是身份标识。

**⚠️ 不要做的事：**
- 不要实现邮箱/用户名注册系统
- 不要让用户创建独立的账户
- 不要修改 userId 的派生算法（会导致已有数据无法访问）

### 2. Token 持久化

**机制：** 服务器 token 存储在 SQLite `tokens` 表中（不是内存 Map），重启不丢失。

**为什么这样做：** 早期版本用内存 Map 存 token，服务器重启后所有客户端 token 失效，触发 FOREIGN KEY 错误。

**⚠️ 不要做的事：**
- 不要把 token 改回内存存储
- 不要删除 `tokens` 表
- 客户端收到 401 时会自动重新登录（`cloudbase_service.dart` 的 `_callApi`），不要手动处理

### 3. 数据库无外键约束

**机制：** 所有表（clipboard、history、devices、salt、tokens）都没有 FOREIGN KEY 约束。

**为什么这样做：** 早期有 FOREIGN KEY，当 token 失效导致 userId fallback 到不存在的 `'default'` 时，INSERT 操作报错且无法被客户端优雅处理。

**⚠️ 不要做的事：**
- 不要给现有表添加 FOREIGN KEY 约束
- 如果需要新建表，也不要加 FOREIGN KEY

### 4. 认证流程

```
用户输入密码
    ↓
SHA256("clipflow:$password") → userId
    ↓
POST /api/auth { userId } → 获取 token
    ↓
后续请求 Authorization: Bearer <token>
    ↓
token 失效(401) → 自动重新 POST /api/auth → 获取新 token → 重试
```

## 入口与路由

- `lib/main.dart` — 应用入口。用 `MultiProvider` 包裹组件树启动 App。
- `lib/app.dart` — `MaterialApp`，3 个命名路由：`/unlock` → `/home` → `/settings`。

## Provider 状态层

- `AuthProvider` — 生成设备 ID + 设备注册。通过 `LocalStorage` 在本地存储 `deviceId`/`deviceName`。
- `SettingsProvider` — 自动同步开关、历史记录条数限制。底层使用 `SharedPreferences`。
- `ClipboardProvider` — **核心调度器。** 持有 `SyncService`、`ClipboardMonitor`、`HistoryService`、`EncryptionService`。管理同步循环（500ms 轮询）、多选拼接状态、以及所有剪切板读写（含循环防护）。

## 数据流（复制 → 同步 → 粘贴）

```
[设备 A 复制内容]
    ↓ ClipboardMonitor 检测变化（桌面端 500ms 轮询，Android 原生监听）
    ↓ _onClipboardChanged() → 防抖 500ms → _uploadContent()
    ↓ SyncService.uploadContent()：SHA256 哈希 → AES-256-GCM 加密 → 调用服务器 API 写入数据库
    ↓
[其他设备通过 _startSyncLoop() 每 500ms 轮询服务器]
    ↓ SyncService.downloadLatestContent()：跳过自己的上传或过期数据 → 解密 → 返回
    ↓ ClipboardProvider 写入系统剪切板（先暂停监听器防止循环同步）
    ↓ 条目加入 HistoryService
```

## 服务器 API

服务器通过 HTTP 接收 JSON 请求：

| 方法 | 路径 | 说明 |
|-----|------|------|
| GET | `/api/ping` | 健康检查 |
| POST | `/api/auth` | 登录/注册（body: `{ userId }`） |
| GET | `/api/clipboard` | 获取最新剪切板 |
| POST | `/api/clipboard` | 上传剪切板内容 |
| GET | `/api/history` | 获取历史记录 |
| PATCH | `/api/history/:id` | 更新历史记录（置顶等） |
| DELETE | `/api/history/:id` | 删除历史记录 |
| POST | `/api/device` | 注册/更新设备 |
| GET | `/api/devices` | 获取设备列表 |
| GET | `/api/salt` | 获取加密盐值 |
| POST | `/api/salt` | 设置加密盐值 |

## 加密

- `EncryptionService` 在 `lib/services/encryption_service.dart` — AES-256-GCM（基于 pointycastle）。密钥通过 PBKDF2-HMAC-SHA256 派生（10 万次迭代）。`EncryptedData` 将 IV + 密文打包为单个 base64 字符串。
- 主密码在 `UnlockScreen` 输入。Salt 存储在服务器数据库。所有设备使用相同密码即可派生相同密钥。

## 剪切板监听

- `ClipboardMonitor` 在 `lib/services/clipboard_monitor.dart`
- **桌面端（macOS/Windows）：** `Timer.periodic` 每 500ms 轮询 `Clipboard.getData()`
- **Android：** 通过 `MethodChannel` (`clipflow/clipboard`) 与原生层通信。原生层使用 `ClipboardManager.OnPrimaryClipChangedListener` + Foreground Service 保活，检测到变化后调用 `syncClipboard` 传入剪切板内容（Android 10+ 限制后台读取剪切板，因此由原生层传递内容而非 Flutter 层主动读取）
- 提供 `pause()`/`resume()` 方法，在将接收到的数据写入剪切板时暂停监听以防止循环同步
- `ignoreHashes` 机制：从其他设备同步来的内容加入忽略列表，防止上传自己刚下载的内容

## 数据库模型

服务器使用 SQLite，表在启动时自动创建，**所有表无 FOREIGN KEY 约束**。

```sql
users (id TEXT PK, password_hash TEXT, salt TEXT, created_at TEXT)
devices (id TEXT PK, user_id TEXT, name TEXT, platform TEXT, last_seen TEXT)
clipboard (id TEXT PK, user_id TEXT, content TEXT, hash TEXT, source_device TEXT,
           source_device_name TEXT, source_platform TEXT, timestamp INTEGER, type TEXT)
history (id TEXT PK, user_id TEXT, content TEXT, source_device TEXT,
         source_device_name TEXT, source_platform TEXT, timestamp INTEGER,
         type TEXT, pinned INTEGER, deleted_at INTEGER, restored_at INTEGER)
salt (user_id TEXT PK, value TEXT)
tokens (token TEXT PK, user_id TEXT, created_at TEXT)
```

- `clipboard` 表仅保留每用户最新 1 条记录（上传时 DELETE + INSERT）
- `history` 表保留最近 100 条（服务端自动清理），支持软删除（`deleted_at`）和恢复（`restored_at`）
- `tokens` 每小时清理超过 24 小时的过期 token

## 同步去重

- 上传：明文 SHA256 与 `_lastUploadedHash` 比对 — 相同则跳过。
- 下载：时间戳比对 + 来源设备检查 — 跳过自己的上传和过期数据。

## 多选拼接

- `ClipboardProvider` 维护 `_isMergeMode`、`_selectedIds`（有序集合）、`_mergeSeparator`。
- `MergeBar` 组件显示实时拼接预览和分隔符下拉选择器（换行、逗号、分号、空格）。
- 复制拼接内容：用选定的分隔符将已选条目的内容拼接为一个字符串写入剪切板。

## 测试说明

核心服务测试（加密、历史记录、数据模型）不依赖服务器，可直接运行。UI 测试需要网络连接，当前以 smoke test 为主。`test/widget_test.dart` 包含核心模型和服务的基础验证。

## 服务器部署

```bash
# 在阿里云服务器上
ssh -i /Users/hanyi/Downloads/key241294.pem root@121.196.222.122
cd /opt/clipflow
bash deploy.sh
```
