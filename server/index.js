const express = require('express');
const cors = require('cors');
const Database = require('better-sqlite3');
const { v4: uuidv4 } = require('uuid');
const path = require('path');

const app = express();
const PORT = process.env.PORT || 3000;

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
    FOREIGN KEY (user_id) REFERENCES users(id)
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
    FOREIGN KEY (user_id) REFERENCES users(id)
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
    FOREIGN KEY (user_id) REFERENCES users(id)
  );

  CREATE TABLE IF NOT EXISTS salt (
    user_id TEXT PRIMARY KEY,
    value TEXT NOT NULL,
    FOREIGN KEY (user_id) REFERENCES users(id)
  );
`);

// 简单的 token 存储（生产环境应用 Redis 或数据库）
const tokens = new Map();

// 认证中间件
function authenticate(req, res, next) {
  const token = req.headers.authorization?.replace('Bearer ', '');
  if (!token || !tokens.has(token)) {
    // 允许无 token 访问（简化版，使用 userId 参数）
    req.userId = req.query.userId || req.body?.userId || 'default';
    return next();
  }
  req.userId = tokens.get(token);
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
      userId, password || 'default', salt || 'default'
    );
  }

  const token = uuidv4();
  tokens.set(token, userId);

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

  res.json({
    code: 'SUCCESS',
    data: row
  });
});

// 上传剪切板内容
app.post('/api/clipboard', authenticate, (req, res) => {
  const { content, hash, sourceDevice, sourceDeviceName, sourcePlatform, timestamp, type } = req.body;

  if (!content || !hash) {
    return res.json({ code: 'ERROR', message: 'content and hash are required' });
  }

  const id = uuidv4();

  // 覆盖当前剪切板
  db.prepare(`INSERT OR REPLACE INTO clipboard (id, user_id, content, hash, source_device, source_device_name, source_platform, timestamp, type)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`).run(
    id, req.userId, content, hash, sourceDevice || 'unknown', sourceDeviceName || 'Unknown', sourcePlatform || 'unknown', timestamp || Date.now(), type || 'text'
  );

  // 同时写入历史记录
  db.prepare(`INSERT INTO history (id, user_id, content, source_device, source_device_name, source_platform, timestamp, type)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?)`).run(
    uuidv4(), req.userId, content, sourceDevice || 'unknown', sourceDeviceName || 'Unknown', sourcePlatform || 'unknown', timestamp || Date.now(), type || 'text'
  );

  // 清理旧历史记录（保留最近100条）
  db.prepare(`DELETE FROM history WHERE user_id = ? AND id NOT IN (
    SELECT id FROM history WHERE user_id = ? ORDER BY timestamp DESC LIMIT 100
  )`).run(req.userId, req.userId);

  res.json({ code: 'SUCCESS', id });
});

// ==================== 历史记录 API ====================

// 获取历史记录
app.get('/api/history', authenticate, (req, res) => {
  const limit = parseInt(req.query.limit) || 100;
  const rows = db.prepare('SELECT * FROM history WHERE user_id = ? ORDER BY timestamp DESC LIMIT ?')
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

// 删除历史记录
app.delete('/api/history/:id', authenticate, (req, res) => {
  db.prepare('DELETE FROM history WHERE id = ? AND user_id = ?')
    .run(req.params.id, req.userId);
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

// 启动服务器
app.listen(PORT, '0.0.0.0', () => {
  console.log(`ClipFlow server running on port ${PORT}`);
  console.log(`Health check: http://localhost:${PORT}/api/ping`);
});
