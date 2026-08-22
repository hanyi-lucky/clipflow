#!/usr/bin/env node
// ClipFlow smoke-test 专用本地 stub OSS：内存字节存储，模拟阿里云 OSS 的对象操作。
// 支持路径式访问（自定义 endpoint=IP，ali-oss 不拼 bucket 子域）：
//   PUT/HEAD/GET/DELETE /<objectKey>
//   GET /?prefix=...&marker=...&max-keys=...  → ListBucketResult XML（ali-oss list 用）
// 断言/控制端点（非 OSS 语义，仅供 smoke-test 检查与造数）：
//   GET  /__objects            → JSON { keys: [{ key, size, lastModified }] }
//   POST /__age?key=...&ms=... → 将指定对象 lastModified 拨旧 ms 毫秒（模拟孤儿过期）
const http = require('http');
const url = require('url');

const PORT = Number(process.env.STUB_PORT || 3299);
const objects = new Map(); // key -> { bytes, lastModified }

function objectKeyFromPath(pathname) {
  // 形如 /clipflow/<userId>/<uuid>（stub 只存 clipflow/ 前缀对象）
  return decodeURIComponent(pathname).replace(/^\//, '');
}

function xmlEscape(s) {
  return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

function sendJson(res, status, obj) {
  const body = JSON.stringify(obj);
  res.writeHead(status, { 'Content-Type': 'application/json' });
  res.end(body);
}

const server = http.createServer((req, res) => {
  const parsed = url.parse(req.url, true);
  const pathname = parsed.pathname || '/';
  const query = parsed.query || {};

  // ---- 控制端点 ----
  if (pathname === '/__objects' && req.method === 'GET') {
    const keys = [];
    for (const [key, obj] of objects.entries()) {
      keys.push({ key, size: obj.bytes.length, lastModified: new Date(obj.lastModified).toISOString() });
    }
    keys.sort((a, b) => (a.key < b.key ? -1 : 1));
    return sendJson(res, 200, { keys });
  }
  if (pathname === '/__age' && req.method === 'POST') {
    const key = query.key;
    const ms = Number(query.ms || 0);
    const obj = objects.get(key);
    if (!obj) return sendJson(res, 404, { error: 'not found' });
    obj.lastModified = Date.now() - ms;
    return sendJson(res, 200, { key, lastModified: new Date(obj.lastModified).toISOString() });
  }

  // ---- ListObjects（GET /?prefix=...）----
  if (pathname === '/' && req.method === 'GET') {
    const prefix = query.prefix || '';
    const marker = query.marker || '';
    const maxKeys = Number(query['max-keys'] || 1000);
    let entries = [...objects.entries()]
      .filter(([key]) => key.startsWith(prefix))
      .sort((a, b) => (a[0] < b[0] ? -1 : 1));
    if (marker) entries = entries.filter(([key]) => key > marker);
    const truncated = entries.length > maxKeys;
    const page = truncated ? entries.slice(0, maxKeys) : entries;
    const nextMarker = truncated ? page[page.length - 1][0] : null;

    let xml = '<?xml version="1.0" encoding="UTF-8"?>\n<ListBucketResult>';
    xml += `<Name>clipflow-files</Name><Prefix>${xmlEscape(prefix)}</Prefix>`;
    if (marker) xml += `<Marker>${xmlEscape(marker)}</Marker>`;
    xml += `<MaxKeys>${maxKeys}</MaxKeys><IsTruncated>${truncated}</IsTruncated>`;
    for (const [key, obj] of page) {
      xml += '<Contents>'
        + `<Key>${xmlEscape(key)}</Key>`
        + `<LastModified>${new Date(obj.lastModified).toISOString()}</LastModified>`
        + `<ETag>"${require('crypto').createHash('md5').update(obj.bytes).digest('hex')}"</ETag>`
        + '<Type>Normal</Type>'
        + `<Size>${obj.bytes.length}</Size>`
        + '<StorageClass>Standard</StorageClass>'
        + '<Owner><ID>stub</ID><DisplayName>stub</DisplayName></Owner>'
        + '</Contents>';
    }
    if (nextMarker) xml += `<NextMarker>${xmlEscape(nextMarker)}</NextMarker>`;
    xml += '</ListBucketResult>';
    res.writeHead(200, { 'Content-Type': 'application/xml' });
    return res.end(xml);
  }

  // ---- 对象操作 ----
  const key = objectKeyFromPath(pathname);
  if (!key) return sendJson(res, 400, { error: 'bad path' });

  if (req.method === 'PUT') {
    const chunks = [];
    req.on('data', (c) => chunks.push(c));
    req.on('end', () => {
      objects.set(key, { bytes: Buffer.concat(chunks), lastModified: Date.now() });
      res.writeHead(200, { 'Content-Type': 'application/xml' });
      res.end(`<?xml version="1.0" encoding="UTF-8"?><PutObjectResult><ETag>"stub"</ETag></PutObjectResult>`);
    });
    return;
  }

  const obj = objects.get(key);
  if (!obj) {
    if (req.method === 'DELETE') {
      res.writeHead(204);
      return res.end();
    }
    // 404：ali-oss 需要 NoSuchKey 语义（xml body）
    res.writeHead(404, { 'Content-Type': 'application/xml' });
    return res.end('<?xml version="1.0" encoding="UTF-8"?><Error><Code>NoSuchKey</Code><Message>The specified key does not exist.</Message></Error>');
  }

  if (req.method === 'HEAD') {
    res.writeHead(200, {
      'Content-Type': 'application/octet-stream',
      'Content-Length': String(obj.bytes.length),
      'Last-Modified': new Date(obj.lastModified).toUTCString(),
    });
    return res.end();
  }
  if (req.method === 'GET') {
    res.writeHead(200, {
      'Content-Type': 'application/octet-stream',
      'Content-Length': String(obj.bytes.length),
    });
    return res.end(obj.bytes);
  }
  if (req.method === 'DELETE') {
    objects.delete(key);
    res.writeHead(204);
    return res.end();
  }
  return sendJson(res, 405, { error: 'method not allowed' });
});

server.listen(PORT, '127.0.0.1', () => {
  console.log(`OSS stub listening on http://127.0.0.1:${PORT}`);
});
