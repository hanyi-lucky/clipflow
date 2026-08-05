// ClipFlow 文件存储：文件密文本体只落磁盘，SQLite 只保存 marker 元数据。
const fs = require('fs');
const path = require('path');

const FILE_DIR = process.env.FILE_DIR || path.join(__dirname, 'data', 'files');
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const SAFE_USER_ID_RE = /^[A-Za-z0-9_.-]+$/;

function getFilePath(userId, fileKey) {
  if (typeof userId !== 'string' || !SAFE_USER_ID_RE.test(userId)) return null;
  if (typeof fileKey !== 'string' || !UUID_RE.test(fileKey)) return null;
  return path.join(FILE_DIR, userId, fileKey);
}

function writeUploadStream(req, userId, fileKey, expectedSize, maxBodyBytes) {
  const finalPath = getFilePath(userId, fileKey);
  if (!finalPath) {
    return Promise.reject(Object.assign(new Error('Invalid user or file key'), { statusCode: 400 }));
  }
  fs.mkdirSync(path.dirname(finalPath), { recursive: true });

  const partPath = `${finalPath}.part`;
  return new Promise((resolve, reject) => {
    const out = fs.createWriteStream(partPath);
    let received = 0;
    let settled = false;

    const fail = (statusCode, message) => {
      if (settled) return;
      settled = true;
      out.destroy();
      req.unpipe(out);
      fs.unlink(partPath, () => {});
      reject(Object.assign(new Error(message), { statusCode }));
    };

    req.on('data', (chunk) => {
      received += chunk.length;
      if (received > maxBodyBytes) {
        fail(413, 'File payload exceeds body limit');
      }
    });
    req.on('aborted', () => fail(400, 'Upload aborted'));
    req.on('error', () => fail(500, 'Upload stream error'));
    out.on('error', () => fail(500, 'File write failed'));
    out.on('finish', () => {
      if (settled) return;
      settled = true;
      fs.rename(partPath, finalPath, (err) => {
        if (err) {
          fs.unlink(partPath, () => {});
          reject(Object.assign(new Error('File finalize failed'), { statusCode: 500 }));
          return;
        }
        resolve(received);
      });
    });

    req.pipe(out);
  });
}

function readFileStream(userId, fileKey) {
  const filePath = getFilePath(userId, fileKey);
  if (!filePath || !fs.existsSync(filePath)) return null;
  return fs.createReadStream(filePath);
}

function deleteFile(userId, fileKey) {
  const filePath = getFilePath(userId, fileKey);
  if (!filePath) return;
  try {
    fs.unlinkSync(filePath);
  } catch (err) {
    if (err.code !== 'ENOENT') throw err;
    return;
  }

  try {
    const userDir = path.dirname(filePath);
    if (fs.existsSync(userDir) && fs.readdirSync(userDir).length === 0) {
      fs.rmdirSync(userDir);
    }
    const filesDir = path.dirname(userDir);
    if (fs.existsSync(filesDir) && fs.readdirSync(filesDir).length === 0) {
      fs.rmdirSync(filesDir);
    }
  } catch (err) {
    // 空目录清理是尽力而为，删除失败不影响主流程
  }
}

function pruneUnreferencedFiles(validKeys) {
  const valid = new Set(validKeys || []);
  if (!fs.existsSync(FILE_DIR)) return 0;

  let removed = 0;
  for (const userDirName of fs.readdirSync(FILE_DIR)) {
    const userDir = path.join(FILE_DIR, userDirName);
    let stat;
    try {
      stat = fs.statSync(userDir);
    } catch (err) {
      continue;
    }
    if (!stat.isDirectory()) continue;

    for (const name of fs.readdirSync(userDir)) {
      if (valid.has(name)) continue;
      try {
        fs.unlinkSync(path.join(userDir, name));
        removed += 1;
      } catch (err) {
        console.error('Prune file failed:', path.join(userDir, name), err.message);
      }
    }

    try {
      if (fs.readdirSync(userDir).length === 0) fs.rmdirSync(userDir);
    } catch (err) {
      // 尽力而为
    }
  }

  try {
    if (fs.readdirSync(FILE_DIR).length === 0) fs.rmdirSync(FILE_DIR);
  } catch (err) {
    // 尽力而为
  }
  return removed;
}

module.exports = {
  FILE_DIR,
  getFilePath,
  writeUploadStream,
  readFileStream,
  deleteFile,
  pruneUnreferencedFiles,
};
