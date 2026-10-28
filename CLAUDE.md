# CLAUDE.md

@AGENTS.md

上一行是 Claude Code 的记忆导入：会话启动时会把 `AGENTS.md`（本项目**唯一的 AI 指引事实源**）机械展开进上下文。

本文件**只保留一样东西**：即使导入失败也必须遵守的硬红线。
`AGENTS.md` 是路由入口：管线细则、架构/数据流、服务器运维等专题正文分别在 `docs/pipeline-workflow.md`、`docs/architecture.md`、`docs/server-operations.md`，设计理由在 `docs/decisions/`。本文件不重复专题正文，避免两处各自漂移。

## 硬红线（不可协商）

**适用域**：本节管的是**安全与不可逆的数据不变量**；`AGENTS.md` §2.2「强制底限」管的是**流程**。两者互不覆盖、都不可绕过。本节与 `AGENTS.md` 其他章节冲突时，以本节为准（并回过头修正 `AGENTS.md`）。

即使 `@AGENTS.md` 导入失效，以下也必须遵守：

- **加密算法**：AES-256-GCM（128-bit tag）+ PBKDF2-HMAC-SHA256（`pbkdf2Iterations = 100000`，密钥 32 字节，IV 12 字节）。算法与参数不可改
- **加密载荷格式**：`EncryptedData` 序列化为 `[2字节 IV 长度][IV][密文+tag]` 的整体 base64（`toBytes()` / `fromBytes()`，见 `lib/services/encryption_service.dart`）。**注意那 2 字节长度前缀**，漏了会读出不兼容的数据
- **账户**：`userId = "user_" + SHA256("clipflow:$password").substring(0, 16)`（`lib/core/user_id.dart`）。派生算法不可改（改了已有数据就访问不到）；**不得引入邮箱/用户名注册体系**
- **端到端加密**：所有内容在**客户端加密后**才上传，服务器只存密文
- **Token**：持久化在 SQLite `tokens` 表，**不可改回内存存储**，不可删表
- **数据库**：所有表**无 FOREIGN KEY 约束**（`server/index.js` 建表语句 9 处均无），新建表也不要加
- **LAN 密钥隔离**：`K_lan = HMAC-SHA256(账户密钥, "clipflow:lan-auth-v1")`（`lib/services/lan_handshake_service.dart`），与内容加密密钥不可混用
- **同步防回环**：`ignoreHashes`、文件在途签名守卫、时间戳+来源设备跳过检查 —— 三件套不可删，删了会引发同步风暴
- **历史裁剪语义**：置顶条目不占名额永不裁剪，垃圾箱软删条目不参与裁剪（服务端与 `HistoryService._trim()` 必须对齐）
- **401 处理**：客户端收到 401 自动重新 `POST /api/auth` 取新 token 并重试，不要手动中断
- **三端样式**：Android / macOS / Windows 用**同一份 Widget 树**，**UI 样式/布局层**禁止 `Platform.isXXX` / `kIsWeb` 分支。⚠️ **功能层的平台适配不受此限制**（Android MethodChannel 剪切板监听、Android-only 设置项显隐等）—— 实测 `lib/` 下有 18 处 `Platform.is`，属正常功能适配，**不要"修"掉**
- **技术栈**：Flutter + Provider（前端）；Node.js + Express + SQLite（后端）
- **Flutter 路径**：`~/development/flutter/bin/flutter`。`/opt/homebrew/bin/flutter` **已不存在**（2026-10-15 实测），照旧路径执行会 `exit 127`
- **连接方式**：服务器进程只监听 `127.0.0.1`（`process.env.HOST || '127.0.0.1'`，部署用 `Environment=HOST=127.0.0.1` 强制回环）；生产 API 是**直连 IP** `https://121.196.222.122/api` + 自签证书 DER SHA-256 指纹固定（`lib/services/pinned_client.dart`）。**域名与 Cloudflare Tunnel 已废弃**（决策 001：SNI 拦截），不要改回域名方案，也不要写"经 Cloudflare Tunnel 对外"
- **子代理不得写业务代码**：`explorer` / `architect` / `tester` / `reviewer` / `debugger` 禁止使用 Write、Edit 修改业务代码（指令级软约束，主代理须交叉校验）

---

本节以外的全部内容**一律以 `AGENTS.md` 为准**；发现不一致时改本文件，不要改事实源。
