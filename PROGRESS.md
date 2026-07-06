# ClipFlow 开发进度

> 更新时间：2026-07-05 19:15

---

## 已完成

### 1. 应用清理与重新安装
- Mac 端：删除 `/Applications/ClipFlow.app`、Preferences、Application Scripts、CrashReporter 残留
- Android 端：卸载旧版 APK（`com.clipflow.clipflow`）
- 两端均已重新构建并安装最新代码

### 2. 同步架构修复 — userId 生成策略
**问题：** 原来每次 `signInAnonymously()` 使用 `DateTime.now()` 生成随机 userId，导致每个设备在服务器上是不同用户，数据完全隔离。

**决策：** userId 从密码派生，相同密码 = 相同账户 = 共享数据；不同密码 = 数据隔离。

**改动文件：**
| 文件 | 改动 |
|------|------|
| `lib/services/cloudbase_service.dart` | `signInAnonymously()` 接受可选 `userId` 参数；保存 `_userId` 用于自动重新登录 |
| `lib/services/auth_service.dart` | 透传 `userId` 参数 |
| `lib/providers/auth_provider.dart` | `signIn()` 接受可选 `userId` 参数 |
| `lib/screens/unlock_screen.dart` | 从密码派生 userId：`SHA256("clipflow:$password")` 前16位，加 `user_` 前缀 |

### 3. 服务器端修复（`server/index.js`）
**问题：** 服务器重启后内存中的 token 丢失，后续请求 fallback 到不存在的 `'default'` userId，触发 FOREIGN KEY 错误。

**改动：**
- 移除所有表的 `FOREIGN KEY` 约束（`CREATE TABLE IF NOT EXISTS` 不会修改已有表，需删除旧数据库重建）
- token 改为 SQLite 数据库持久化（`tokens` 表），重启不丢失
- 认证中间件：无效 token 返回 `401`，不再 fallback 到 `'default'`
- 自动清理超过24小时的旧 token
- 已删除旧数据库 `clipflow.db` 并重建

### 4. 客户端自动重新登录
`cloudbase_service.dart` 的 `_callApi()` 方法：当服务器返回 `401` 时，自动用保存的 `_userId` 重新调用 `signInAnonymously()` 获取新 token，然后重试请求。

---

## 未完成

### 1. Android 端复制 → Mac 未同步 ❌
- Mac → Android 同步：✅ 正常
- Android → Mac 同步：❌ 失败
- 需要进一步排查 Android 端上传流程（剪切板监听、HTTP 请求、token 状态等）

---

## 关键技术决策记录

1. **密码即账户：** userId = `user_` + `SHA256("clipflow:$password").substring(0, 16)`，所有设备输入相同密码即共享数据
2. **加密方案不变：** AES-256-GCM + PBKDF2（10万次迭代），salt 存服务器共享
3. **token 持久化：** 从内存 Map 改为 SQLite `tokens` 表，解决服务器重启后 token 丢失问题
4. **数据库无外键：** 移除 FOREIGN KEY 约束，避免 token 失效时的级联错误

---

## 服务器信息

- **地址：** `http://121.196.222.122:3000/api`
- **SSH：** `ssh -i /Users/hanyi/Downloads/key241294.pem root@121.196.222.122`
- **服务管理：** `systemctl restart clipflow`
- **代码路径：** `/opt/clipflow/index.js`
- **数据库：** `/opt/clipflow/clipflow.db`（SQLite）

---

## 待验证

- [ ] Android → Mac 同步修复后，双向同步完整性测试
- [ ] 服务器重启后，客户端自动重新登录是否正常工作
- [ ] 不同密码的数据隔离是否正确
