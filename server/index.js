const express = require('express');
const cors = require('cors');
const Database = require('better-sqlite3');
const { v4: uuidv4 } = require('uuid');
const path = require('path');

const app = express();
const PORT = process.env.PORT || 3000;

// 列表响应中文本行 content 的截断长度（避免超大文本行撑爆列表响应）
const HISTORY_LIST_CONTENT_LIMIT = 10000;

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

  res.json({
    code: 'SUCCESS',
    data: row,
    deletedIds,
    restoredEntries: restoredRows
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

// ==================== 历史记录 API ====================

// 获取历史记录（排除已删除）
app.get('/api/history', authenticate, (req, res) => {
  const limit = parseInt(req.query.limit) || 100;
  const rows = db.prepare(`SELECT id,
      CASE
        WHEN type = 'image' THEN ''
        ELSE substr(content, 1, ${HISTORY_LIST_CONTENT_LIMIT})
      END AS content,
      source_device, source_device_name, source_platform, timestamp, type, pinned,
      deleted_at, restored_at, hash, thumb, width, height, format
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
        ELSE substr(content, 1, ${HISTORY_LIST_CONTENT_LIMIT})
      END AS content,
      source_device, source_device_name, source_platform, timestamp, type, pinned,
      deleted_at, restored_at, hash, thumb, width, height, format
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
    db.prepare("DELETE FROM history WHERE deleted_at IS NOT NULL AND deleted_at < ?").run(Date.now() - 24 * 60 * 60 * 1000);
  }, 60 * 60 * 1000);
});
