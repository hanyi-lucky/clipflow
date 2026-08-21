const express = require('express');
const cors = require('cors');
const crypto = require('crypto');
const Database = require('better-sqlite3');
const { v4: uuidv4 } = require('uuid');
const path = require('path');
const fs = require('fs');
const fileStore = require('./file_store');

const app = express();
const PORT = process.env.PORT || 3000;

// 列表响应中文本行 content 的截断长度（避免超大文本行撑爆列表响应）
const HISTORY_LIST_CONTENT_LIMIT = 10000;

// 同步操作（durable cursor + tombstone）保留期与分页上限：
// op log 保留 7 天（覆盖离线 >30s 甚至数天的收敛）；tombstone 快照保留 24 小时
// （与垃圾箱/24h 物理清理 UX 对齐，同时钉死快照存储上界——全图密文快照至多滞留 24h）
const SYNC_RETENTION_MS = 7 * 24 * 60 * 60 * 1000;
const SYNC_TOMBSTONE_RETENTION_MS = 24 * 60 * 60 * 1000;
const SYNC_PAGE_LIMIT = 100;

// 文件同步配额（均可用环境变量覆盖，smoke-test 注入小值验证 413/507）
function envInt(name, fallback) {
  const raw = process.env[name];
  if (raw === undefined || raw === '') return fallback;
  const value = Number.parseInt(raw, 10);
  return Number.isFinite(value) && value > 0 ? value : fallback;
}

const MAX_FILE_BYTES = envInt('MAX_FILE_BYTES', 50 * 1024 * 1024);
const USER_FILE_QUOTA_BYTES = envInt('USER_FILE_QUOTA_BYTES', 1024 * 1024 * 1024);
const GLOBAL_FILE_QUOTA_BYTES = envInt('GLOBAL_FILE_QUOTA_BYTES', 4 * 1024 * 1024 * 1024);
// 单载荷 AES-256-GCM 密文 = 明文 + 2 字节 IV 长度 + 12 字节 IV + 16 字节 tag；
// 1024 字节余量同时作为防配额绕过的大小校验窗口
const FILE_CIPHERTEXT_OVERHEAD_BYTES = 1024;

// 登录限流（POST /api/auth）：内存双滑动窗口（IP 桶 + userId 桶），全部 env 可调。
// 重启清零=限制更宽松（无安全回退、无一致性要求，明确接受）；单实例（deploy.sh 强制 127.0.0.1）无共享需求。
const AUTH_MAX_IP_REQUESTS = envInt('AUTH_MAX_IP_REQUESTS', 60);
const AUTH_MAX_USER_REQUESTS = envInt('AUTH_MAX_USER_REQUESTS', 30);
const AUTH_WINDOW_MS = envInt('AUTH_WINDOW_MS', 60000);
const AUTH_CLEANUP_MS = envInt('AUTH_CLEANUP_MS', 60000);

// key -> 窗口内时间戳数组（'ip:'+ip / 'user:'+userId）
const authBuckets = new Map();

// 来源 IP 识别：cf-connecting-ip → x-forwarded-for 首项 → socket remoteAddress。
// 服务仅监听 127.0.0.1、外部流量必经 Cloudflare Tunnel（默认注入 CF 头），伪造面可忽略。
function clientIp(req) {
  const cf = req.headers['cf-connecting-ip'];
  if (cf) {
    const v = String(cf).trim();
    if (v) return v;
  }
  const xff = req.headers['x-forwarded-for'];
  if (xff) {
    const first = String(xff).split(',')[0].trim();
    if (first) return first;
  }
  return req.socket.remoteAddress || 'unknown';
}

// 清理过期时间戳，防止内存膨胀（与 token 清理定时器同构）
function pruneAuthBuckets(now) {
  for (const [key, stamps] of authBuckets) {
    const kept = stamps.filter((t) => now - t < AUTH_WINDOW_MS);
    if (kept.length === 0) authBuckets.delete(key);
    else authBuckets.set(key, kept);
  }
}

function isAuthLimited(key, now, limit) {
  const stamps = authBuckets.get(key) || [];
  const kept = stamps.filter((t) => now - t < AUTH_WINDOW_MS);
  authBuckets.set(key, kept);
  return kept.length >= limit;
}

function recordAuth(key, now) {
  const stamps = authBuckets.get(key) || [];
  stamps.push(now);
  authBuckets.set(key, stamps);
}

// 计算最早超龄时间差；窗口已被 prune 清空时兜底返回整个窗口
function computeRetryAfterMs(now, keys) {
  let earliest = Infinity;
  for (const key of keys) {
    for (const t of authBuckets.get(key) || []) {
      if (t < earliest) earliest = t;
    }
  }
  const wait = earliest === Infinity ? AUTH_WINDOW_MS : (earliest + AUTH_WINDOW_MS - now);
  return Math.max(wait, 1000);
}

// 崩溃上报限流（POST /api/crash）：独立于 authBuckets 的内存双滑动窗口（IP 桶 + userId 桶），
// 全部 env 可调。崩溃可能发生在未登录态，匿名上报由 IP 桶 + body 上限 + 30 天清理兜底。
const CRASH_MAX_IP_REQUESTS = envInt('CRASH_MAX_IP_REQUESTS', 20);
const CRASH_MAX_USER_REQUESTS = envInt('CRASH_MAX_USER_REQUESTS', 10);
const CRASH_WINDOW_MS = envInt('CRASH_WINDOW_MS', 60000);
const CRASH_CLEANUP_MS = envInt('CRASH_CLEANUP_MS', 60000);
// 单条崩溃报告 body 上限（全局 express.json 50mb 已先行解析，路由级 limit 不生效，handler 内校验）
const CRASH_MAX_BODY_BYTES = 256 * 1024;
// 崩溃报告保留期：30 天（小时级清理任务执行）
const CRASH_RETENTION_MS = 30 * 24 * 60 * 60 * 1000;

// key -> 窗口内时间戳数组（'crash-ip:'+ip / 'crash-user:'+userId）
const crashBuckets = new Map();

function isCrashLimited(key, now) {
  const stamps = crashBuckets.get(key) || [];
  const kept = stamps.filter((t) => now - t < CRASH_WINDOW_MS);
  crashBuckets.set(key, kept);
  return kept.length >= (key.startsWith('crash-user:') ? CRASH_MAX_USER_REQUESTS : CRASH_MAX_IP_REQUESTS);
}

function recordCrash(key, now) {
  const stamps = crashBuckets.get(key) || [];
  stamps.push(now);
  crashBuckets.set(key, stamps);
}

// 计算最早超龄时间差；窗口已被 prune 清空时兜底返回整个窗口
function computeCrashRetryAfterMs(now, keys) {
  let earliest = Infinity;
  for (const key of keys) {
    for (const t of crashBuckets.get(key) || []) {
      if (t < earliest) earliest = t;
    }
  }
  const wait = earliest === Infinity ? CRASH_WINDOW_MS : (earliest + CRASH_WINDOW_MS - now);
  return Math.max(wait, 1000);
}

// 清理过期时间戳，防止内存膨胀
function pruneCrashBuckets(now) {
  for (const [key, stamps] of crashBuckets) {
    const kept = stamps.filter((t) => now - t < CRASH_WINDOW_MS);
    if (kept.length === 0) crashBuckets.delete(key);
    else crashBuckets.set(key, kept);
  }
}

// ==================== LAN 票据（A3 双向挑战的服务端部分）====================
// 短时票据：HMAC-SHA256(LAN_TICKET_SECRET, "clipflow:lan-ticket-v1|payload")。
// LAN_TICKET_SECRET 支持环境变量；缺省启动随机生成并 warn（重启后旧票据失效，
// 客户端握手时自动重取，无感）。payload 只含 deviceId+exp，**不含 userId**——
// userId 由 verify 端点从 devices 表反查返回，客户端仅在内存中与自身比对，
// userId 永不落线。
const LAN_TICKET_TTL_MS = envInt('LAN_TICKET_TTL_MS', 5 * 60 * 1000);
const LAN_TICKET_SECRET = process.env.LAN_TICKET_SECRET
  || (() => {
    const secret = crypto.randomBytes(32).toString('hex');
    console.warn('LAN_TICKET_SECRET not set; using ephemeral random secret (LAN tickets invalid after restart)');
    return secret;
  })();

// LAN 票据校验限流（POST /api/lan/ticket/verify）：轻量独立 IP 桶（verify 无认证，
// 无 userId 概念），与 auth/crash 同构的滑动窗口辅助函数。
const LAN_VERIFY_MAX_IP_REQUESTS = envInt('LAN_VERIFY_MAX_IP_REQUESTS', 60);
const LAN_VERIFY_WINDOW_MS = envInt('LAN_VERIFY_WINDOW_MS', 60000);
const LAN_VERIFY_CLEANUP_MS = envInt('LAN_VERIFY_CLEANUP_MS', 60000);
// key -> 窗口内时间戳数组（'lan-verify-ip:'+ip）
const lanVerifyBuckets = new Map();

function isLanVerifyLimited(key, now) {
  const stamps = lanVerifyBuckets.get(key) || [];
  const kept = stamps.filter((t) => now - t < LAN_VERIFY_WINDOW_MS);
  lanVerifyBuckets.set(key, kept);
  return kept.length >= LAN_VERIFY_MAX_IP_REQUESTS;
}

function recordLanVerify(key, now) {
  const stamps = lanVerifyBuckets.get(key) || [];
  stamps.push(now);
  lanVerifyBuckets.set(key, stamps);
}

// 计算最早超龄时间差；窗口已被 prune 清空时兜底返回整个窗口
function computeLanVerifyRetryAfterMs(now, key) {
  let earliest = Infinity;
  for (const t of lanVerifyBuckets.get(key) || []) {
    if (t < earliest) earliest = t;
  }
  const wait = earliest === Infinity ? LAN_VERIFY_WINDOW_MS : (earliest + LAN_VERIFY_WINDOW_MS - now);
  return Math.max(wait, 1000);
}

function pruneLanVerifyBuckets(now) {
  for (const [key, stamps] of lanVerifyBuckets) {
    const kept = stamps.filter((t) => now - t < LAN_VERIFY_WINDOW_MS);
    if (kept.length === 0) lanVerifyBuckets.delete(key);
    else lanVerifyBuckets.set(key, kept);
  }
}

// 签发票据：payload = base64url({deviceId, exp})，mac = HMAC(secret, 域前缀|payload)。
function signLanTicket(deviceId, exp) {
  const payload = Buffer.from(JSON.stringify({ deviceId, exp })).toString('base64url');
  const mac = crypto.createHmac('sha256', LAN_TICKET_SECRET)
    .update(`clipflow:lan-ticket-v1|${payload}`)
    .digest('base64url');
  return `${payload}.${mac}`;
}

// 校验票据：结构/HMAC（常量时间）/过期。返回 {ok, deviceId?, expiresAtMs?}。
// 任何一步失败均返回 ok=false（verify 端点统一 403，不泄露具体失败原因）。
function verifyLanTicket(ticket) {
  if (typeof ticket !== 'string' || ticket.length === 0 || ticket.length > 4096) {
    return { ok: false };
  }
  const dot = ticket.indexOf('.');
  if (dot <= 0 || dot === ticket.length - 1) return { ok: false };
  const payload = ticket.slice(0, dot);
  const mac = ticket.slice(dot + 1);
  if (!/^[A-Za-z0-9_-]+$/.test(payload) || !/^[A-Za-z0-9_-]+$/.test(mac)) {
    return { ok: false };
  }
  const expected = crypto.createHmac('sha256', LAN_TICKET_SECRET)
    .update(`clipflow:lan-ticket-v1|${payload}`)
    .digest();
  let provided;
  try {
    provided = Buffer.from(mac, 'base64url');
  } catch (e) {
    return { ok: false };
  }
  if (provided.length !== expected.length || !crypto.timingSafeEqual(provided, expected)) {
    return { ok: false };
  }
  let parsed;
  try {
    parsed = JSON.parse(Buffer.from(payload, 'base64url').toString('utf8'));
  } catch (e) {
    return { ok: false };
  }
  if (typeof parsed.deviceId !== 'string' || parsed.deviceId.length === 0
      || typeof parsed.exp !== 'number' || !Number.isFinite(parsed.exp)) {
    return { ok: false };
  }
  if (parsed.exp <= Date.now()) return { ok: false };
  return { ok: true, deviceId: parsed.deviceId, expiresAtMs: parsed.exp };
}

// 中间件
app.use(cors());
app.use(express.json({ limit: '50mb' }));

// 初始化数据库
const db = new Database(path.join(__dirname, 'clipflow.db'));
db.pragma('journal_mode = WAL');

// 创建表
db.exec(`
  CREATE TABLE IF NOT EXISTS users (
    id TEXT PRIMARY KEY,
    password_hash TEXT NOT NULL,
    salt TEXT NOT NULL,
    created_at TEXT DEFAULT CURRENT_TIMESTAMP
  );

  CREATE TABLE IF NOT EXISTS devices (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    name TEXT NOT NULL,
    platform TEXT NOT NULL,
    last_seen TEXT DEFAULT CURRENT_TIMESTAMP,
    removed_at INTEGER DEFAULT NULL
  );

  CREATE TABLE IF NOT EXISTS clipboard (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    content TEXT NOT NULL,
    hash TEXT NOT NULL,
    source_device TEXT NOT NULL,
    source_device_name TEXT NOT NULL,
    source_platform TEXT NOT NULL,
    timestamp INTEGER NOT NULL,
    type TEXT DEFAULT 'text',
    thumb TEXT,
    width INTEGER,
    height INTEGER,
    format TEXT,
    history_id TEXT
  );

  CREATE TABLE IF NOT EXISTS history (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    content TEXT NOT NULL,
    source_device TEXT NOT NULL,
    source_device_name TEXT NOT NULL,
    source_platform TEXT NOT NULL,
    timestamp INTEGER NOT NULL,
    type TEXT DEFAULT 'text',
    pinned INTEGER DEFAULT 0,
    deleted_at INTEGER DEFAULT NULL,
    hash TEXT,
    thumb TEXT,
    width INTEGER,
    height INTEGER,
    format TEXT
  );

  CREATE TABLE IF NOT EXISTS salt (
    user_id TEXT PRIMARY KEY,
    value TEXT NOT NULL
  );

  CREATE TABLE IF NOT EXISTS tokens (
    token TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    device_id TEXT,
    created_at TEXT DEFAULT CURRENT_TIMESTAMP
  );
  CREATE TABLE IF NOT EXISTS crash_reports (
    id TEXT PRIMARY KEY,
    user_id TEXT,
    device_id TEXT,
    app_version TEXT,
    platform TEXT,
    device_model TEXT,
    exception_type TEXT,
    message TEXT,
    stack TEXT,
    reported_at INTEGER NOT NULL
  );

  CREATE TABLE IF NOT EXISTS sync_operations (
    seq INTEGER PRIMARY KEY AUTOINCREMENT,
    operation_id TEXT NOT NULL,
    user_id TEXT NOT NULL,
    kind TEXT NOT NULL,
    entry_id TEXT NOT NULL,
    payload TEXT,
    created_at INTEGER NOT NULL
  );
  CREATE UNIQUE INDEX IF NOT EXISTS idx_sync_operations_user_op ON sync_operations (user_id, operation_id);
  CREATE INDEX IF NOT EXISTS idx_sync_operations_user_seq ON sync_operations (user_id, seq);

  CREATE TABLE IF NOT EXISTS sync_tombstones (
    user_id TEXT NOT NULL,
    entry_id TEXT NOT NULL,
    entry_type TEXT NOT NULL,
    deleted_at INTEGER NOT NULL,
    restored_at INTEGER,
    seq INTEGER,
    snapshot TEXT,
    PRIMARY KEY (user_id, entry_id)
  );
`);


// 为已有数据库的 history 表添加 deleted_at 列（如果不存在）
try { db.exec('ALTER TABLE history ADD COLUMN deleted_at INTEGER DEFAULT NULL'); } catch(e) {}
try { db.exec('ALTER TABLE history ADD COLUMN restored_at INTEGER DEFAULT NULL'); } catch(e) {}

// 为已有数据库补充图片相关列（无外键，兼容升级）
try { db.exec('ALTER TABLE clipboard ADD COLUMN thumb TEXT'); } catch(e) {}
try { db.exec('ALTER TABLE clipboard ADD COLUMN width INTEGER'); } catch(e) {}
try { db.exec('ALTER TABLE clipboard ADD COLUMN height INTEGER'); } catch(e) {}
try { db.exec('ALTER TABLE clipboard ADD COLUMN format TEXT'); } catch(e) {}
try { db.exec('ALTER TABLE clipboard ADD COLUMN history_id TEXT'); } catch(e) {}
try { db.exec('ALTER TABLE history ADD COLUMN hash TEXT'); } catch(e) {}
try { db.exec('ALTER TABLE history ADD COLUMN thumb TEXT'); } catch(e) {}
try { db.exec('ALTER TABLE history ADD COLUMN width INTEGER'); } catch(e) {}
try { db.exec('ALTER TABLE history ADD COLUMN height INTEGER'); } catch(e) {}
try { db.exec('ALTER TABLE history ADD COLUMN format TEXT'); } catch(e) {}

// 为已有数据库补充文件同步列（无外键，兼容升级）
try { db.exec('ALTER TABLE clipboard ADD COLUMN file_name TEXT'); } catch(e) {}
try { db.exec('ALTER TABLE clipboard ADD COLUMN file_size INTEGER'); } catch(e) {}
try { db.exec('ALTER TABLE clipboard ADD COLUMN mime_type TEXT'); } catch(e) {}
try { db.exec('ALTER TABLE clipboard ADD COLUMN file_key TEXT'); } catch(e) {}
try { db.exec('ALTER TABLE history ADD COLUMN file_name TEXT'); } catch(e) {}
try { db.exec('ALTER TABLE history ADD COLUMN file_size INTEGER'); } catch(e) {}
try { db.exec('ALTER TABLE history ADD COLUMN mime_type TEXT'); } catch(e) {}
try { db.exec('ALTER TABLE history ADD COLUMN file_key TEXT'); } catch(e) {}

// 为 tokens 表绑定设备（无外键，兼容升级）
try { db.exec('ALTER TABLE tokens ADD COLUMN device_id TEXT'); } catch(e) {}
// 设备软删除标记（移除后禁止重新登录，防“删了又复活”）
try { db.exec('ALTER TABLE devices ADD COLUMN removed_at INTEGER'); } catch(e) {}

// 清理过期同步状态：op log 保留 7 天、tombstone 快照保留 24 小时。
// 启动时调用一次 + 并入小时任务；不依赖任何客户端心跳，重启即生效。
function pruneSyncState(now) {
  db.prepare('DELETE FROM sync_operations WHERE created_at < ?').run(now - SYNC_RETENTION_MS);
  db.prepare('DELETE FROM sync_tombstones WHERE deleted_at < ?').run(now - SYNC_TOMBSTONE_RETENTION_MS);
}

// 认证中间件（token 从数据库读取，重启不丢失）
function authenticate(req, res, next) {
  const token = req.headers.authorization?.replace('Bearer ', '');
  if (!token) {
    return res.status(401).json({ code: 'UNAUTHORIZED', message: 'Token required' });
  }
  const row = db.prepare('SELECT user_id, device_id FROM tokens WHERE token = ?').get(token);
  if (!row) {
    return res.status(401).json({ code: 'UNAUTHORIZED', message: 'Token invalid or expired' });
  }
  req.userId = row.user_id;
  req.token = token;
  // 在线心跳：绑定设备的 token 每次请求都刷新 last_seen，设备列表可显示在线状态
  if (row.device_id) {
    db.prepare('UPDATE devices SET last_seen = CURRENT_TIMESTAMP WHERE id = ? AND user_id = ?')
      .run(row.device_id, row.user_id);
  }
  next();
}

// 可选认证：有有效 token 则填充 req.userId/req.token（并刷新设备心跳），
// 无/无效 token 放行——崩溃上报在未登录/解锁页也可匿名上报（由限流兜底）。
function authenticateOptional(req, res, next) {
  const token = req.headers.authorization?.replace('Bearer ', '');
  if (!token) return next();
  const row = db.prepare('SELECT user_id, device_id FROM tokens WHERE token = ?').get(token);
  if (row) {
    req.userId = row.user_id;
    req.token = token;
    if (row.device_id) {
      db.prepare('UPDATE devices SET last_seen = CURRENT_TIMESTAMP WHERE id = ? AND user_id = ?')
        .run(row.device_id, row.user_id);
    }
  }
  next();
}

// base64url header 解码（文件元数据全部走 header）
function decodeBase64UrlHeader(value) {
  if (value == null) return null;
  const s = String(value);
  // 兼容带尾部 = 填充的 base64url（Node 生成的通常无填充）
  if (!/^[A-Za-z0-9_-]*={0,2}$/.test(s)) return null;
  try {
    return Buffer.from(s, 'base64url').toString('utf8');
  } catch (err) {
    return null;
  }
}

function collectValidFileKeys() {
  return db.prepare('SELECT file_key FROM history WHERE file_key IS NOT NULL')
    .all().map(r => r.file_key);
}

// 启动时清理未被任何 history 行引用的磁盘文件（含中断上传遗留的 .part）
try {
  fileStore.pruneUnreferencedFiles(collectValidFileKeys());
} catch (err) {
  console.error('Startup file prune failed:', err);
}

// 文件上传错误响应：若请求体尚未读完，响应发完后再断开连接
function sendFileError(req, res, status, message) {
  res.status(status).json({ code: 'ERROR', message });
  res.on('finish', () => {
    if (!req.complete) req.destroy();
  });
}

// ==================== API 路由 ====================

// 健康检查
app.get('/api/ping', (req, res) => {
  res.json({ code: 'SUCCESS', message: 'ok', timestamp: Date.now() });
});

// 登录/注册
app.post('/api/auth', (req, res) => {
  // 限流放 handler 最顶部（userId 校验前）：任何 /auth 请求都计尝试。
  // 两桶：IP 桶拦「变换 userId 的暴力枚举」；userId 桶拦「单账户高频重试/脚本重放」。
  const now = Date.now();
  const ip = clientIp(req);
  const body = req.body || {};
  const { userId, password, salt, deviceId } = body;
  const ipKey = 'ip:' + ip;
  const userKey = userId ? 'user:' + userId : null;
  const limitedKeys = [];
  if (isAuthLimited(ipKey, now, AUTH_MAX_IP_REQUESTS)) limitedKeys.push(ipKey);
  if (userKey && isAuthLimited(userKey, now, AUTH_MAX_USER_REQUESTS)) limitedKeys.push(userKey);
  if (limitedKeys.length > 0) {
    const retryAfterMs = computeRetryAfterMs(now, limitedKeys);
    res.set('Retry-After', String(Math.max(1, Math.ceil(retryAfterMs / 1000))));
    return res.status(429).json({
      code: 'RATE_LIMITED',
      message: '尝试过于频繁，请稍后再试',
      retryAfterMs,
    });
  }
  recordAuth(ipKey, now);
  if (userKey) recordAuth(userKey, now);

  if (!userId) {
    return res.json({ code: 'ERROR', message: 'userId is required' });
  }

  // 已移除的设备禁止重新登录（防止删除后自动重登复活）
  if (deviceId) {
    const removed = db.prepare('SELECT removed_at FROM devices WHERE id = ? AND user_id = ?')
      .get(deviceId, userId);
    if (removed && removed.removed_at != null) {
      return res.status(403).json({
        code: 'ERROR',
        message: '设备已被移除，请清除应用数据后重新添加',
      });
    }
  }

  // 检查用户是否存在
  const existing = db.prepare('SELECT * FROM users WHERE id = ?').get(userId);

  if (!existing) {
    // 新用户，注册
    db.prepare('INSERT INTO users (id, password_hash, salt) VALUES (?, ?, ?)').run(
      userId, userId, salt || 'default'
    );
  }

  const token = uuidv4();
  db.prepare('INSERT INTO tokens (token, user_id, device_id) VALUES (?, ?, ?)').run(token, userId, deviceId || null);

  // 清理超过24小时的旧 token
  db.prepare("DELETE FROM tokens WHERE created_at < datetime('now', '-1 day')").run();

  res.json({
    code: 'SUCCESS',
    data: { token, userId }
  });
});

// ==================== 剪切板 API ====================

// 获取最新剪切板内容
app.get('/api/clipboard', authenticate, (req, res) => {
  const row = db.prepare('SELECT * FROM clipboard WHERE user_id = ? ORDER BY timestamp DESC LIMIT 1')
    .get(req.userId);

  if (!row) {
    return res.json({ code: 'NOT_FOUND' });
  }

  // 获取最近 30 秒内删除的条目 ID
  const deletedRows = db.prepare('SELECT id FROM history WHERE user_id = ? AND deleted_at > ?')
    .all(req.userId, Date.now() - 30000);
  const deletedIds = deletedRows.map(r => r.id);

  // 获取最近 30 秒内恢复的条目（完整数据，客户端需要重新添加到本地历史）
  const restoredRows = db.prepare('SELECT * FROM history WHERE user_id = ? AND restored_at > ? AND deleted_at IS NULL')
    .all(req.userId, Date.now() - 30000);
  // file 行与列表一致只暴露空 content，避免旧客户端把文件标记当文本处理
  const restoredEntries = restoredRows.map(r => (
    r.type === 'file' ? { ...r, content: '' } : r
  ));

  res.json({
    code: 'SUCCESS',
    data: row,
    deletedIds,
    restoredEntries
  });
});

// 上传剪切板内容
app.post('/api/clipboard', authenticate, (req, res) => {
  const {
    content, hash, sourceDevice, sourceDeviceName, sourcePlatform,
    timestamp, type, thumb, width, height, format,
  } = req.body;

  if (!content || !hash) {
    return res.json({ code: 'ERROR', message: 'content and hash are required' });
  }

  // 密文原样存储，不做静默截断：列表体积由「列表响应截断 + 客户端 /content 回补」控制；
  // 超过 express.json 50mb 上限的请求由末尾全局错误中间件返回显式 413，绝不静默损坏合法数据
  const storedContent = content;

  const id = uuidv4();
  const historyId = req.body.historyId || uuidv4();

  // 删除该用户旧的 clipboard 记录，防止无限膨胀
  db.prepare('DELETE FROM clipboard WHERE user_id = ?').run(req.userId);

  // 插入新记录
  db.prepare(`INSERT INTO clipboard (id, user_id, content, hash, source_device, source_device_name, source_platform, timestamp, type, thumb, width, height, format, history_id)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`).run(
    id, req.userId, storedContent, hash, sourceDevice || 'unknown', sourceDeviceName || 'Unknown',
    sourcePlatform || 'unknown', timestamp || Date.now(), type || 'text',
    thumb || null, width || null, height || null, format || null, historyId
  );

  // 同时写入历史记录（使用客户端提供的 ID，确保客户端和服务器 ID 一致）
  db.prepare(`INSERT OR REPLACE INTO history (id, user_id, content, hash, source_device, source_device_name, source_platform, timestamp, type, thumb, width, height, format)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`).run(
    historyId, req.userId, storedContent, hash || null, sourceDevice || 'unknown',
    sourceDeviceName || 'Unknown', sourcePlatform || 'unknown', timestamp || Date.now(),
    type || 'text', thumb || null, width || null, height || null, format || null
  );

  // 清理旧历史记录（保留最近100条）
  db.prepare(`DELETE FROM history WHERE user_id = ? AND id NOT IN (
    SELECT id FROM history WHERE user_id = ? ORDER BY timestamp DESC LIMIT 100
  )`).run(req.userId, req.userId);

  res.json({ code: 'SUCCESS', id });
});

// ==================== 文件 API ====================

// 上传文件密文（raw octet-stream，元数据全部走 header）
app.post('/api/file', authenticate, async (req, res) => {
  if (!req.is('application/octet-stream')) {
    return sendFileError(req, res, 400, 'Content-Type must be application/octet-stream');
  }

  const historyId = req.headers['x-clipflow-history-id'];
  const hash = req.headers['x-clipflow-hash'];
  const fileSizeRaw = req.headers['x-clipflow-file-size'];
  const fileName = decodeBase64UrlHeader(req.headers['x-clipflow-file-name']);
  const marker = decodeBase64UrlHeader(req.headers['x-clipflow-marker']);

  if (!historyId || !hash || fileSizeRaw == null || !fileName || !marker) {
    return sendFileError(req, res, 400, 'Missing required file metadata headers');
  }

  const fileSize = Number.parseInt(fileSizeRaw, 10);
  if (!Number.isInteger(fileSize) || fileSize < 0) {
    return sendFileError(req, res, 400, 'Invalid x-clipflow-file-size');
  }
  if (fileSize > MAX_FILE_BYTES) {
    return sendFileError(req, res, 413, `File too large: ${fileSize} exceeds ${MAX_FILE_BYTES}`);
  }

  const mimeType = decodeBase64UrlHeader(req.headers['x-clipflow-mime-type']) || 'application/octet-stream';
  const sourceDevice = decodeBase64UrlHeader(req.headers['x-clipflow-source-device']) || 'unknown';
  const sourceDeviceName = decodeBase64UrlHeader(req.headers['x-clipflow-source-device-name']) || 'Unknown';
  const sourcePlatform = decodeBase64UrlHeader(req.headers['x-clipflow-source-platform']) || 'unknown';
  const timestamp = Number.parseInt(req.headers['x-clipflow-timestamp'], 10) || Date.now();

  try {
    const userFileBytes = db.prepare(
      'SELECT COALESCE(SUM(file_size), 0) AS total FROM history WHERE user_id = ?'
    ).get(req.userId).total;
    if (userFileBytes + fileSize > USER_FILE_QUOTA_BYTES) {
      return sendFileError(req, res, 507,
        `User file quota exceeded (${userFileBytes} + ${fileSize} > ${USER_FILE_QUOTA_BYTES})`);
    }

    const globalFileBytes = db.prepare(
      'SELECT COALESCE(SUM(file_size), 0) AS total FROM history'
    ).get().total;
    if (globalFileBytes + fileSize > GLOBAL_FILE_QUOTA_BYTES) {
      return sendFileError(req, res, 507,
        `Global file quota exceeded (${globalFileBytes} + ${fileSize} > ${GLOBAL_FILE_QUOTA_BYTES})`);
    }
  } catch (err) {
    console.error('File quota check failed:', err);
    return sendFileError(req, res, 500, 'Internal server error');
  }

  const fileKey = uuidv4();
  try {
    // body 上限 = 明文上限 + 密文开销余量
    const received = await fileStore.writeUploadStream(
      req, req.userId, fileKey, fileSize,
      MAX_FILE_BYTES + FILE_CIPHERTEXT_OVERHEAD_BYTES,
    );
    // 真实客户端 header 声明的是明文大小，请求体是密文（明文+约30字节）。
    // 拒绝小于明文或超出明文+余量的请求，防声明小、实际大绕过配额。
    if (received < fileSize ||
        received > fileSize + FILE_CIPHERTEXT_OVERHEAD_BYTES) {
      console.error('File size mismatch: declared', fileSize, 'received', received);
      try { fileStore.deleteFile(req.userId, fileKey); } catch (cleanupErr) {
        console.error('File cleanup failed:', cleanupErr);
      }
      return sendFileError(req, res, 400,
        `FILE_SIZE_MISMATCH: declared ${fileSize}, received ${received}`);
    }
  } catch (err) {
    console.error('File upload stream failed:', err);
    if (err.statusCode) {
      return sendFileError(req, res, err.statusCode, err.message || 'File upload failed');
    }
    try { fileStore.deleteFile(req.userId, fileKey); } catch (cleanupErr) {
      console.error('File cleanup failed:', cleanupErr);
    }
    return sendFileError(req, res, 500, 'Internal server error');
  }

  let oldFileKey = null;
  let trimmedFileKeys = [];
  try {
    db.transaction(() => {
      const existing = db.prepare('SELECT file_key FROM history WHERE id = ? AND user_id = ?')
        .get(historyId, req.userId);
      oldFileKey = existing && existing.file_key ? existing.file_key : null;

      db.prepare('DELETE FROM clipboard WHERE user_id = ?').run(req.userId);
      db.prepare(`INSERT INTO clipboard (id, user_id, content, hash, source_device, source_device_name, source_platform, timestamp, type, thumb, width, height, format, history_id, file_name, file_size, mime_type, file_key)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`).run(
        uuidv4(), req.userId, marker, hash, sourceDevice, sourceDeviceName, sourcePlatform,
        timestamp, 'file', null, null, null, null, historyId, fileName, fileSize, mimeType, fileKey
      );

      db.prepare(`INSERT OR REPLACE INTO history (id, user_id, content, hash, source_device, source_device_name, source_platform, timestamp, type, pinned, deleted_at, restored_at, thumb, width, height, format, file_name, file_size, mime_type, file_key)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`).run(
        historyId, req.userId, marker, hash, sourceDevice, sourceDeviceName, sourcePlatform,
        timestamp, 'file', 0, null, null, null, null, null, null, fileName, fileSize, mimeType, fileKey
      );

      trimmedFileKeys = db.prepare(`SELECT file_key FROM history
        WHERE user_id = ? AND file_key IS NOT NULL AND id NOT IN (
          SELECT id FROM history WHERE user_id = ? ORDER BY timestamp DESC LIMIT 100
        )`).all(req.userId, req.userId).map(r => r.file_key);

      db.prepare(`DELETE FROM history WHERE user_id = ? AND id NOT IN (
        SELECT id FROM history WHERE user_id = ? ORDER BY timestamp DESC LIMIT 100
      )`).run(req.userId, req.userId);
    })();

    // 磁盘删除放到事务之后：先收集 file_key，再删记录，最后删文件
    if (oldFileKey && oldFileKey !== fileKey) {
      fileStore.deleteFile(req.userId, oldFileKey);
    }
    for (const key of trimmedFileKeys) {
      fileStore.deleteFile(req.userId, key);
    }
  } catch (err) {
    console.error('File metadata insert failed:', err);
    try { fileStore.deleteFile(req.userId, fileKey); } catch (cleanupErr) {
      console.error('File cleanup failed:', cleanupErr);
    }
    return sendFileError(req, res, 500, 'Internal server error');
  }

  res.json({ code: 'SUCCESS', id: historyId });
});

// 下载文件密文（按 user_id 作用域校验）
app.get('/api/file/:id/content', authenticate, (req, res) => {
  const row = db.prepare('SELECT * FROM history WHERE id = ? AND user_id = ?')
    .get(req.params.id, req.userId);

  if (!row || row.type !== 'file' || !row.file_key) {
    return res.status(404).json({ code: 'NOT_FOUND' });
  }

  const stream = fileStore.readFileStream(req.userId, row.file_key);
  if (!stream) {
    return res.status(404).json({ code: 'NOT_FOUND' });
  }

  const filePath = fileStore.getFilePath(req.userId, row.file_key);
  res.setHeader('Content-Type', 'application/octet-stream');
  res.setHeader('Content-Length', fs.statSync(filePath).size);
  stream.on('error', () => res.destroy());
  stream.pipe(res);
});

// ==================== 历史记录 API ====================

// 获取历史记录（排除已删除）
app.get('/api/history', authenticate, (req, res) => {
  const limit = parseInt(req.query.limit) || 100;
  const rows = db.prepare(`SELECT id,
      CASE
        WHEN type = 'image' THEN ''
        WHEN type = 'file' THEN ''
        ELSE substr(content, 1, ${HISTORY_LIST_CONTENT_LIMIT})
      END AS content,
      source_device, source_device_name, source_platform, timestamp, type, pinned,
      deleted_at, restored_at, hash, thumb, width, height, format,
      file_name, file_size, mime_type, file_key
    FROM history WHERE user_id = ? AND deleted_at IS NULL ORDER BY timestamp DESC LIMIT ?`)
    .all(req.userId, limit);

  res.json({
    code: 'SUCCESS',
    data: { records: rows }
  });
});

// 更新历史记录（置顶等）
app.patch('/api/history/:id', authenticate, (req, res) => {
  const { pinned } = req.body;
  db.prepare('UPDATE history SET pinned = ? WHERE id = ? AND user_id = ?')
    .run(pinned ? 1 : 0, req.params.id, req.userId);
  res.json({ code: 'SUCCESS' });
});

// 倾倒垃圾桶：物理删除当前用户所有软删条目，并同步清理磁盘文件
app.delete('/api/history/trash', authenticate, (req, res) => {
  const fileRows = db.prepare(
    'SELECT file_key FROM history WHERE user_id = ? AND deleted_at IS NOT NULL AND file_key IS NOT NULL'
  ).all(req.userId);
  const info = db.prepare(
    'DELETE FROM history WHERE user_id = ? AND deleted_at IS NOT NULL'
  ).run(req.userId);
  for (const row of fileRows) {
    try {
      fileStore.deleteFile(req.userId, row.file_key);
    } catch (err) {
      console.error('Trash file cleanup failed:', err);
    }
  }
  res.json({ code: 'SUCCESS', deleted: info.changes });
});

// 删除历史记录（软删除）
app.delete('/api/history/:id', authenticate, (req, res) => {
  db.prepare('UPDATE history SET deleted_at = ? WHERE id = ? AND user_id = ?')
    .run(Date.now(), req.params.id, req.userId);
  res.json({ code: 'SUCCESS' });
});

// 获取垃圾箱（已删除条目）
app.get('/api/history/trash', authenticate, (req, res) => {
  const rows = db.prepare(`SELECT id,
      CASE
        WHEN type = 'image' THEN ''
        WHEN type = 'file' THEN ''
        ELSE substr(content, 1, ${HISTORY_LIST_CONTENT_LIMIT})
      END AS content,
      source_device, source_device_name, source_platform, timestamp, type, pinned,
      deleted_at, restored_at, hash, thumb, width, height, format,
      file_name, file_size, mime_type, file_key
    FROM history WHERE user_id = ? AND deleted_at IS NOT NULL ORDER BY deleted_at DESC`)
    .all(req.userId);
  res.json({
    code: 'SUCCESS',
    data: { records: rows }
  });
});

// 获取历史记录完整内容（图片全图密文，按 user_id 作用域防止越权）
app.get('/api/history/:id/content', authenticate, (req, res) => {
  const row = db.prepare('SELECT * FROM history WHERE id = ? AND user_id = ?')
    .get(req.params.id, req.userId);

  if (!row) {
    return res.json({ code: 'NOT_FOUND' });
  }

  res.json({ code: 'SUCCESS', data: row });
});

// 恢复已删除条目
app.post('/api/history/:id/restore', authenticate, (req, res) => {
  db.prepare('UPDATE history SET deleted_at = NULL, restored_at = ? WHERE id = ? AND user_id = ?')
    .run(Date.now(), req.params.id, req.userId);
  res.json({ code: 'SUCCESS' });
});

// ==================== 同步操作 API（durable cursor + tombstone）====================

// 行整形：与 /api/clipboard 的 restoredEntries 同规则（file 行只暴露空 content，
// 避免旧客户端把文件标记当文本处理；image/text 保留完整密文）
function shapeSyncRow(row) {
  if (!row) return null;
  return row.type === 'file' ? { ...row, content: '' } : row;
}

// 取 restore 的权威 row：现行未删除行 → tombstone 快照 → null
// （快照被 24h GC 后仍会在 op log 中留 restore op，客户端收到 row:null 跳过，
//   最终态由启动/手动全量刷新收敛）
function resolveRestoreRow(userId, entryId) {
  const current = db.prepare('SELECT * FROM history WHERE id = ? AND user_id = ?')
    .get(entryId, userId);
  if (current && current.deleted_at === null) {
    return shapeSyncRow(current);
  }
  const tomb = db.prepare('SELECT snapshot FROM sync_tombstones WHERE user_id = ? AND entry_id = ?')
    .get(userId, entryId);
  if (tomb && tomb.snapshot) {
    try {
      return shapeSyncRow(JSON.parse(tomb.snapshot));
    } catch (err) {
      console.error('Invalid tombstone snapshot for', entryId, err);
    }
  }
  return null;
}

// 从快照重建 history 行：deleted_at=NULL、restored_at=now、pinned 从快照恢复。
// file 行的 file_key 指向的磁盘字节可能已被 trash 倾倒删除——恢复仅元数据（下载 404），
// 属 durable tombstone 的已知边界（architect D3）。
function rebuildFromSnapshot(userId, entryId, snap) {
  db.prepare(`INSERT OR REPLACE INTO history (id, user_id, content, source_device, source_device_name, source_platform, timestamp, type, pinned, deleted_at, restored_at, hash, thumb, width, height, format, file_name, file_size, mime_type, file_key)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`)
    .run(
      snap.id || entryId, userId, snap.content || '', snap.source_device || 'unknown',
      snap.source_device_name || 'Unknown', snap.source_platform || 'unknown',
      snap.timestamp || Date.now(), snap.type || 'text',
      snap.pinned ? 1 : 0, null, Date.now(),
      snap.hash || null, snap.thumb || null, snap.width || null,
      snap.height || null, snap.format || null, snap.file_name || null,
      snap.file_size || null, snap.mime_type || null, snap.file_key || null
    );
}

// 解析 operationId：`del:<id>` / `rest:<id>`，容忍周期后缀 `#<n>`
// （删除→恢复→再删除等周期事件生成唯一 opId，绕开 UNIQUE(user_id, operation_id)）。
// entryId 为 UUID，`#` 不会出现在其中，取 `#` 前部分即为真实 entryId。
// 返回 { kind, entryId }；格式非法返回 null。
function parseSyncOperationId(operationId) {
  if (typeof operationId !== 'string') return null;
  let kind = null;
  let offset = 0;
  if (operationId.startsWith('del:')) { kind = 'delete'; offset = 4; }
  else if (operationId.startsWith('rest:')) { kind = 'restore'; offset = 5; }
  else return null;
  let rest = operationId.slice(offset);
  const hashIdx = rest.indexOf('#');
  if (hashIdx >= 0) rest = rest.slice(0, hashIdx);
  if (rest.length === 0) return null;
  return { kind, entryId: rest };
}

// 生成下一个周期 opId：`<base>#<maxN+1>`（base = `del:<id>` / `rest:<id>`）。
// 扫描已存在的 `base#<n>` 后缀取最大值 +1，客户端与服务端各自生成的周期 opId 共存不冲突。
function nextCycleOperationId(userId, baseOperationId) {
  const prefix = baseOperationId + '#';
  const rows = db.prepare('SELECT operation_id FROM sync_operations WHERE user_id = ? AND operation_id LIKE ?')
    .all(userId, prefix + '%');
  let maxN = 0;
  for (const r of rows) {
    const n = Number.parseInt(r.operation_id.slice(prefix.length), 10);
    if (Number.isFinite(n) && n > maxN) maxN = n;
  }
  return prefix + (maxN + 1);
}

// 删除事件：服务端自建全列快照 + 置 deleted_at + 写 op log。
// 返回新 seq；未知条目/无 tombstone 返回 null（调用方按 ignored 处理）。
function commitDeleteEvent(userId, operationId, entryId, payload, now) {
  const row = db.prepare('SELECT * FROM history WHERE id = ? AND user_id = ?')
    .get(entryId, userId);
  if (!row) return null;
  return db.transaction(() => {
    const info = db.prepare(`INSERT INTO sync_operations (operation_id, user_id, kind, entry_id, payload, created_at)
      VALUES (?, ?, ?, ?, ?, ?)`)
      .run(operationId, userId, 'delete', entryId,
        payload ? JSON.stringify(payload) : null, now);
    const opSeq = Number(info.lastInsertRowid);
    db.prepare(`INSERT OR REPLACE INTO sync_tombstones (user_id, entry_id, entry_type, deleted_at, restored_at, seq, snapshot)
      VALUES (?, ?, ?, ?, NULL, ?, ?)`)
      .run(userId, entryId, row.type || 'text', now, opSeq, JSON.stringify(row));
    db.prepare('UPDATE history SET deleted_at = ? WHERE id = ? AND user_id = ?')
      .run(now, entryId, userId);
    return opSeq;
  })();
}

// 恢复事件：现行行恢复 or 快照重建 + 标记 tombstone restored_at + 写 op log。
// 返回新 seq；未知条目/无快照返回 null（调用方按 ignored 处理）。
function commitRestoreEvent(userId, operationId, entryId, payload, now) {
  const current = db.prepare('SELECT * FROM history WHERE id = ? AND user_id = ?')
    .get(entryId, userId);
  const tomb = db.prepare('SELECT * FROM sync_tombstones WHERE user_id = ? AND entry_id = ?')
    .get(userId, entryId);
  if (!current && !(tomb && tomb.snapshot)) return null;
  return db.transaction(() => {
    if (current) {
      db.prepare('UPDATE history SET deleted_at = NULL, restored_at = ? WHERE id = ? AND user_id = ?')
        .run(now, entryId, userId);
    } else {
      let snap = null;
      try { snap = JSON.parse(tomb.snapshot); } catch (err) { snap = null; }
      if (snap) rebuildFromSnapshot(userId, entryId, snap);
    }
    const info = db.prepare(`INSERT INTO sync_operations (operation_id, user_id, kind, entry_id, payload, created_at)
      VALUES (?, ?, ?, ?, ?, ?)`)
      .run(operationId, userId, 'restore', entryId,
        payload ? JSON.stringify(payload) : null, now);
    const opSeq = Number(info.lastInsertRowid);
    // 标记 tombstone 已恢复（保留快照供 24h 内再次物理删除后恢复）
    if (tomb) {
      db.prepare('UPDATE sync_tombstones SET restored_at = ? WHERE user_id = ? AND entry_id = ?')
        .run(now, userId, entryId);
    }
    return opSeq;
  })();
}

// 提交删除/恢复操作：幂等（duplicate）、冲突拒绝（409）、未知条目忽略（ignored）。
// 周期检测：同 opId 再次提交时按「当前状态与 op 意图是否匹配」判定——
// delete 时条目当前活跃（已被恢复）→ 视为新删除事件（周期后缀 opId 绕开 UNIQUE）；
// restore 时条目当前已删（被再次删除）→ 视为新恢复事件。兼容无周期计数的旧客户端。
app.post('/api/sync/commit', authenticate, (req, res) => {
  const { operationId, kind, entryId, payload } = req.body || {};

  if (typeof operationId !== 'string' || operationId.length === 0 ||
      typeof kind !== 'string' || typeof entryId !== 'string' || entryId.length === 0) {
    return res.json({ code: 'ERROR', message: 'operationId, kind, entryId are required' });
  }

  const parsed = parseSyncOperationId(operationId);
  if (!parsed) {
    return res.json({ code: 'ERROR', message: 'operationId must be del:<id> or rest:<id>' });
  }
  if (kind !== parsed.kind) {
    return res.json({ code: 'ERROR', message: 'kind does not match operationId prefix' });
  }

  // 幂等：同 (user, operationId) 已存在 → duplicate（restore 额外带 row 供重放）；
  // kind/entryId 不一致 → 409（优先于 entryId 语法校验，保持旧语义）。
  const existing = db.prepare('SELECT * FROM sync_operations WHERE user_id = ? AND operation_id = ?')
    .get(req.userId, operationId);
  if (existing) {
    if (existing.kind !== kind || existing.entry_id !== entryId) {
      return res.status(409).json({ code: 'CONFLICT', message: 'operationId already used with different kind/entryId' });
    }
    const now = Date.now();
    if (kind === 'delete') {
      const cur = db.prepare('SELECT * FROM history WHERE id = ? AND user_id = ?')
        .get(entryId, req.userId);
      if (cur && cur.deleted_at === null) {
        // 当前活跃（已被 restore 过）→ 新删除事件
        const cycleOpId = nextCycleOperationId(req.userId, 'del:' + entryId);
        const seq = commitDeleteEvent(req.userId, cycleOpId, entryId, payload, now);
        if (seq === null) {
          return res.json({ code: 'SUCCESS', data: { ignored: true, seq: null } });
        }
        return res.json({ code: 'SUCCESS', data: { seq } });
      }
    } else if (kind === 'restore') {
      const cur = db.prepare('SELECT * FROM history WHERE id = ? AND user_id = ?')
        .get(entryId, req.userId);
      if (cur && cur.deleted_at !== null) {
        // 当前已删（被再次删除过）→ 新恢复事件
        const cycleOpId = nextCycleOperationId(req.userId, 'rest:' + entryId);
        const seq = commitRestoreEvent(req.userId, cycleOpId, entryId, payload, now);
        if (seq === null) {
          return res.json({ code: 'SUCCESS', data: { ignored: true, seq: null, row: null } });
        }
        const row = resolveRestoreRow(req.userId, entryId);
        return res.json({ code: 'SUCCESS', data: { seq, row } });
      }
    }
    const row = kind === 'restore' ? resolveRestoreRow(req.userId, entryId) : null;
    const data = { duplicate: true, seq: existing.seq };
    if (kind === 'restore') data.row = row;
    return res.json({ code: 'SUCCESS', data });
  }

  if (entryId !== parsed.entryId) {
    return res.json({ code: 'ERROR', message: 'entryId does not match operationId' });
  }

  const now = Date.now();

  if (kind === 'delete') {
    const seq = commitDeleteEvent(req.userId, operationId, entryId, payload, now);
    if (seq === null) {
      // 未知条目/无 tombstone：SUCCESS + ignored，不写 log、不产生噪音
      return res.json({ code: 'SUCCESS', data: { ignored: true, seq: null } });
    }
    return res.json({ code: 'SUCCESS', data: { seq } });
  }

  // restore 分支
  const seq = commitRestoreEvent(req.userId, operationId, entryId, payload, now);
  if (seq === null) {
    // 未知条目/无快照：SUCCESS + ignored + row:null
    return res.json({ code: 'SUCCESS', data: { ignored: true, seq: null, row: null } });
  }
  const row = resolveRestoreRow(req.userId, entryId);
  return res.json({ code: 'SUCCESS', data: { seq, row } });
});

// 获取增量变更：独立于 /api/clipboard（绕开空剪切板 NOT_FOUND 边界）。
// after 游标（容忍缺失/0/负数），limit 钳制 1..SYNC_PAGE_LIMIT；
// 返回升序 changes，restore 的 row 按 restoredEntries 同规则整形（file → content=''）。
app.get('/api/sync/changes', authenticate, (req, res) => {
  let after = Number.parseInt(req.query.after, 10);
  if (!Number.isFinite(after) || after < 0) after = 0;

  let limit = Number.parseInt(req.query.limit, 10);
  if (!Number.isFinite(limit)) limit = SYNC_PAGE_LIMIT;
  limit = Math.max(1, Math.min(SYNC_PAGE_LIMIT, limit));

  const rows = db.prepare('SELECT * FROM sync_operations WHERE user_id = ? AND seq > ? ORDER BY seq ASC LIMIT ?')
    .all(req.userId, after, limit + 1);

  const hasMore = rows.length > limit;
  const page = hasMore ? rows.slice(0, limit) : rows;

  const changes = page.map((op) => {
    const change = {
      seq: op.seq,
      operationId: op.operation_id,
      kind: op.kind,
      entryId: op.entry_id,
    };
    if (op.kind === 'restore') {
      change.row = resolveRestoreRow(req.userId, op.entry_id);
    }
    return change;
  });

  const cursor = page.length > 0 ? page[page.length - 1].seq : after;

  res.json({
    code: 'SUCCESS',
    data: { cursor, hasMore, changes },
  });
});

// ==================== 设备 API ====================

// 注册/更新设备
app.post('/api/device', authenticate, (req, res) => {
  const { id, name, platform } = req.body;

  if (!id || !name || !platform) {
    return res.json({ code: 'ERROR', message: 'id, name, platform are required' });
  }

  // 已移除的设备不允许重新注册（避免设备列表复活）
  const removed = db.prepare('SELECT removed_at FROM devices WHERE id = ? AND user_id = ?')
    .get(id, req.userId);
  if (removed && removed.removed_at != null) {
    return res.status(403).json({
      code: 'ERROR',
      message: '设备已被移除，请清除应用数据后重新添加',
    });
  }

  db.prepare(`INSERT OR REPLACE INTO devices (id, user_id, name, platform, last_seen)
    VALUES (?, ?, ?, ?, CURRENT_TIMESTAMP)`).run(id, req.userId, name, platform);

  res.json({ code: 'SUCCESS' });
});

// 获取设备列表
app.get('/api/devices', authenticate, (req, res) => {
  const rows = db.prepare('SELECT * FROM devices WHERE user_id = ? AND removed_at IS NULL')
    .all(req.userId);

  res.json({
    code: 'SUCCESS',
    data: rows
  });
});

// 更新设备名称
app.patch('/api/device/:id', authenticate, (req, res) => {
  const { name } = req.body;
  if (!name) {
    return res.json({ code: 'ERROR', message: 'name is required' });
  }

  const result = db.prepare('UPDATE devices SET name=?, last_seen=CURRENT_TIMESTAMP WHERE id=? AND user_id=?')
    .run(name, req.params.id, req.userId);

  if (result.changes === 0) {
    return res.status(404).json({ code: 'ERROR', message: 'Device not found' });
  }

  res.json({ code: 'SUCCESS' });
});

// 删除设备
app.delete('/api/device/:id', authenticate, (req, res) => {
  const device = db.prepare('SELECT id, removed_at FROM devices WHERE id=? AND user_id=?')
    .get(req.params.id, req.userId);

  if (!device) {
    return res.status(404).json({ code: 'ERROR', message: 'Device not found' });
  }

  // 软删除：设备行保留但标记 removed_at，禁止再次登录/注册
  db.prepare('UPDATE devices SET removed_at = ? WHERE id = ? AND user_id = ?')
    .run(Date.now(), req.params.id, req.userId);

  // 删除该设备绑定的 token
  db.prepare('DELETE FROM tokens WHERE device_id = ?').run(req.params.id);

  // 同时删除发起删除请求的当前 token（兼容未绑定 device_id 的旧会话）
  if (req.token) {
    db.prepare('DELETE FROM tokens WHERE token = ?').run(req.token);
  }

  res.json({ code: 'SUCCESS' });
});

// ==================== Salt API ====================

// 获取 salt
app.get('/api/salt', authenticate, (req, res) => {
  const row = db.prepare('SELECT * FROM salt WHERE user_id = ?').get(req.userId);

  if (!row) {
    return res.json({ code: 'NOT_FOUND' });
  }

  res.json({
    code: 'SUCCESS',
    data: { value: row.value }
  });
});

// 设置 salt
app.post('/api/salt', authenticate, (req, res) => {
  const { value } = req.body;

  if (!value) {
    return res.json({ code: 'ERROR', message: 'value is required' });
  }

  db.prepare('INSERT OR REPLACE INTO salt (user_id, value) VALUES (?, ?)')
    .run(req.userId, value);

  res.json({ code: 'SUCCESS' });
});

// ==================== LAN 票据 API ====================

// 取票：authenticate 鉴权 + token 绑定的 device_id 与 body 一致性 + removed_at 403。
// 签发 HMAC 短时票据（默认 5min TTL）。不建表、不加外键、不动 tokens 机制。
app.post('/api/lan/ticket', authenticate, (req, res) => {
  const { deviceId } = req.body || {};
  if (typeof deviceId !== 'string' || deviceId.length === 0 || deviceId.length > 128) {
    return res.status(400).json({ code: 'ERROR', message: 'deviceId is required' });
  }

  // token device_id 一致性：票据只能为当前 token 绑定的设备签发
  const tokenRow = db.prepare('SELECT user_id, device_id FROM tokens WHERE token = ?').get(req.token);
  if (!tokenRow || tokenRow.device_id !== deviceId) {
    return res.status(400).json({ code: 'ERROR', message: 'deviceId does not match token' });
  }

  // removed_at 复查（撤销实时生效；正常 API 移除会同时删除绑定 token，
  // 此处兜底带外移除 / 竞态）
  const device = db.prepare('SELECT removed_at FROM devices WHERE id = ? AND user_id = ?')
    .get(deviceId, req.userId);
  if (device && device.removed_at != null) {
    return res.status(403).json({
      code: 'ERROR',
      message: '设备已被移除，请清除应用数据后重新添加',
    });
  }

  const exp = Date.now() + LAN_TICKET_TTL_MS;
  const ticket = signLanTicket(deviceId, exp);
  res.json({ code: 'SUCCESS', data: { ticket, expiresAtMs: exp } });
});

// 校验票据：独立 IP 限流 + HMAC/过期复查 + removed_at 复查。
// 返回 userId/deviceId（userId 仅经此加密通道返回，客户端在内存中比对）。
app.post('/api/lan/ticket/verify', (req, res) => {
  const now = Date.now();
  const ipKey = 'lan-verify-ip:' + clientIp(req);
  if (isLanVerifyLimited(ipKey, now)) {
    const retryAfterMs = computeLanVerifyRetryAfterMs(now, ipKey);
    res.set('Retry-After', String(Math.max(1, Math.ceil(retryAfterMs / 1000))));
    return res.status(429).json({
      code: 'RATE_LIMITED',
      message: '尝试过于频繁，请稍后再试',
      retryAfterMs,
    });
  }

  const { ticket } = req.body || {};
  const result = verifyLanTicket(ticket);
  if (!result.ok) {
    return res.status(403).json({ code: 'ERROR', message: 'Invalid ticket' });
  }

  // 校验通过才记账（与 /auth 同语义），避免非法请求刷爆桶
  recordLanVerify(ipKey, now);

  // 实时复查 removed_at：设备被移除后已签发票据立即失效
  const device = db.prepare('SELECT user_id, removed_at FROM devices WHERE id = ?')
    .get(result.deviceId);
  if (!device || device.removed_at != null) {
    return res.status(403).json({
      code: 'ERROR',
      message: '设备已被移除，请清除应用数据后重新添加',
    });
  }

  res.json({
    code: 'SUCCESS',
    data: { userId: device.user_id, deviceId: result.deviceId, expiresAtMs: result.expiresAtMs },
  });
});

// 崩溃上报：可选认证 + 独立双滑动窗口限流 + stack 必填 + body 256KB + 字段裁剪入库。
// 白名单字段（异常类型/消息/栈/平台/机型/版本/设备/指纹/时间），绝不采集剪贴板明文/密码。
app.post('/api/crash', authenticateOptional, (req, res) => {
  const now = Date.now();
  const keys = ['crash-ip:' + clientIp(req)];
  if (req.userId) keys.push('crash-user:' + req.userId);
  if (keys.some((k) => isCrashLimited(k, now))) {
    const retryAfterMs = computeCrashRetryAfterMs(now, keys);
    res.set('Retry-After', String(Math.max(1, Math.ceil(retryAfterMs / 1000))));
    return res.status(429).json({
      code: 'RATE_LIMITED',
      message: 'Too many crash reports',
      retryAfterMs,
    });
  }

  const body = req.body || {};
  const stack = typeof body.stack === 'string' ? body.stack : '';
  if (stack.trim().length === 0) {
    return res.status(400).json({ code: 'ERROR', message: 'stack is required' });
  }
  if (Buffer.byteLength(JSON.stringify(body), 'utf8') > CRASH_MAX_BODY_BYTES) {
    return res.status(413).json({ code: 'ERROR', message: 'Crash report too large' });
  }

  // 校验通过才记账（与 /auth 同语义），避免非法请求刷爆桶
  keys.forEach((k) => recordCrash(k, now));

  const safe = (v, max) => (typeof v === 'string' ? v.slice(0, max) : null);
  db.prepare(`INSERT INTO crash_reports (id, user_id, device_id, app_version, platform, device_model, exception_type, message, stack, reported_at)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`)
    .run(uuidv4(), req.userId || null,
      safe(body.deviceId, 64), safe(body.appVersion, 64), safe(body.platform, 32),
      safe(body.deviceModel, 300), safe(body.exceptionType, 128),
      safe(body.message, 5000), stack.slice(0, 100000), now);

  res.json({ code: 'SUCCESS' });
});

// 全局错误处理中间件
app.use((err, req, res, next) => {
  console.error('Server error:', err);
  // body-parser 超过 50mb 上限时抛出 PayloadTooLargeError（status=413, type='entity.too.large'），
  // 显式透传 413；其余错误保持 500，不向客户端暴露内部细节
  if (err.type === 'entity.too.large' || err.status === 413) {
    return res.status(413).json({ code: 'ERROR', message: 'Payload too large' });
  }
  res.status(500).json({ code: 'ERROR', message: 'Internal server error' });
});

process.on('uncaughtException', (err) => {
  console.error('Uncaught exception:', err);
});
process.on('unhandledRejection', (err) => {
  console.error('Unhandled rejection:', err);
});

// 启动服务器
app.listen(PORT, process.env.HOST || '0.0.0.0', () => {
  console.log(`ClipFlow server running on port ${PORT}`);
  console.log(`Health check: http://localhost:${PORT}/api/ping`);

  // 启动时清理一次过期同步状态（op 7d / tombstone 24h），重启即生效
  pruneSyncState(Date.now());

  // 登录限流桶与崩溃限流桶定时清理（防内存膨胀；重启清零=更宽松，接受）
  setInterval(() => {
    pruneAuthBuckets(Date.now());
    pruneCrashBuckets(Date.now());
  }, Math.min(AUTH_CLEANUP_MS, CRASH_CLEANUP_MS));

  // LAN 票据校验限流桶定时清理（防内存膨胀；重启清零=更宽松，接受）
  setInterval(() => {
    pruneLanVerifyBuckets(Date.now());
  }, LAN_VERIFY_CLEANUP_MS);

  // 每小时清理过期 token、超过 24h 的已删除条目、超过 30 天的崩溃报告，以及过期同步状态
  setInterval(() => {
    pruneSyncState(Date.now());
    db.prepare("DELETE FROM tokens WHERE created_at < datetime('now', '-1 day')").run();
    db.prepare('DELETE FROM crash_reports WHERE reported_at < ?').run(Date.now() - CRASH_RETENTION_MS);

    // 软删超过 24h 的 file 行先收集 file_key，物理删除后同步清理磁盘文件
    const expiredFileRows = db.prepare(
      'SELECT user_id, file_key FROM history WHERE deleted_at IS NOT NULL AND deleted_at < ? AND file_key IS NOT NULL'
    ).all(Date.now() - 24 * 60 * 60 * 1000);
    db.prepare("DELETE FROM history WHERE deleted_at IS NOT NULL AND deleted_at < ?").run(Date.now() - 24 * 60 * 60 * 1000);
    for (const row of expiredFileRows) {
      try {
        fileStore.deleteFile(row.user_id, row.file_key);
      } catch (err) {
        console.error('Expired file cleanup failed:', err);
      }
    }
    try {
      fileStore.pruneUnreferencedFiles(collectValidFileKeys());
    } catch (err) {
      console.error('Hourly file prune failed:', err);
    }
  }, 60 * 60 * 1000);
});
