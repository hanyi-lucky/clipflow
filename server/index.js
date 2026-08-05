const express = require('express');
const cors = require('cors');
const Database = require('better-sqlite3');
const { v4: uuidv4 } = require('uuid');
const path = require('path');
const fs = require('fs');
const fileStore = require('./file_store');

const app = express();
const PORT = process.env.PORT || 3000;

// 列表响应中文本行 content 的截断长度（避免超大文本行撑爆列表响应）
const HISTORY_LIST_CONTENT_LIMIT = 10000;

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
    last_seen TEXT DEFAULT CURRENT_TIMESTAMP
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
    created_at TEXT DEFAULT CURRENT_TIMESTAMP
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

// 认证中间件（token 从数据库读取，重启不丢失）
function authenticate(req, res, next) {
  const token = req.headers.authorization?.replace('Bearer ', '');
  if (!token) {
    return res.status(401).json({ code: 'UNAUTHORIZED', message: 'Token required' });
  }
  const row = db.prepare('SELECT user_id FROM tokens WHERE token = ?').get(token);
  if (!row) {
    return res.status(401).json({ code: 'UNAUTHORIZED', message: 'Token invalid or expired' });
  }
  req.userId = row.user_id;
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
  const { userId, password, salt } = req.body;

  if (!userId) {
    return res.json({ code: 'ERROR', message: 'userId is required' });
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
  db.prepare('INSERT INTO tokens (token, user_id) VALUES (?, ?)').run(token, userId);

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

// ==================== 设备 API ====================

// 注册/更新设备
app.post('/api/device', authenticate, (req, res) => {
  const { id, name, platform } = req.body;

  if (!id || !name || !platform) {
    return res.json({ code: 'ERROR', message: 'id, name, platform are required' });
  }

  db.prepare(`INSERT OR REPLACE INTO devices (id, user_id, name, platform, last_seen)
    VALUES (?, ?, ?, ?, CURRENT_TIMESTAMP)`).run(id, req.userId, name, platform);

  res.json({ code: 'SUCCESS' });
});

// 获取设备列表
app.get('/api/devices', authenticate, (req, res) => {
  const rows = db.prepare('SELECT * FROM devices WHERE user_id = ?')
    .all(req.userId);

  res.json({
    code: 'SUCCESS',
    data: rows
  });
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
app.listen(PORT, '0.0.0.0', () => {
  console.log(`ClipFlow server running on port ${PORT}`);
  console.log(`Health check: http://localhost:${PORT}/api/ping`);

  // 每小时清理过期 token 和超过 24h 的已删除条目
  setInterval(() => {
    db.prepare("DELETE FROM tokens WHERE created_at < datetime('now', '-1 day')").run();

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
