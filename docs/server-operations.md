# ClipFlow 服务器运维

本文件是服务器连接、部署、健康检查和排障的专题事实源。当前架构与安全约束见 `docs/architecture.md` 和 `docs/decisions/001-connectivity-direct-ip-selfsigned.md`。

## 0. 当前连接方式

- 生产 API：`https://121.196.222.122/api`（直连 IP + 自签证书 DER SHA-256 指纹固定）。
- 服务器进程只监听 `127.0.0.1:3000`，由本机 TLS 层对外持自签证书。
- 域名与 Cloudflare Tunnel 已废弃；不要按旧文档恢复域名方案。
- SSH：`ssh -i ~/Downloads/key241294.pem root@121.196.222.122`。

---

## 1. 连接服务器

```bash
ssh -i ~/Downloads/key241294.pem root@121.196.222.122
```

---

## 2. 服务管理

```bash
# 查看服务状态
sudo systemctl status clipflow

# 启动/停止/重启
sudo systemctl start clipflow
sudo systemctl stop clipflow
sudo systemctl restart clipflow

# 查看实时日志
sudo journalctl -u clipflow -f

# 查看最近 100 行日志
sudo journalctl -u clipflow -n 100 --no-pager
```

---

## 3. 部署更新

```bash
# 本地：上传代码到服务器
scp -i ~/Downloads/key241294.pem server/index.js server/file_store.js root@121.196.222.122:/opt/clipflow/

# 服务器：安装依赖并重启
cd /opt/clipflow
npm install --production
sudo systemctl restart clipflow
```

或使用部署脚本（会重装 Node.js + 完整重建服务）：

```bash
cd /opt/clipflow
bash deploy.sh
```

---

## 4. 数据库操作

```bash
cd /opt/clipflow

# 查看所有表
sqlite3 clipflow.db ".tables"

# 查看表结构
sqlite3 clipflow.db ".schema history"

# 查看某用户的 history 条数
sqlite3 clipflow.db "SELECT count(*) FROM history WHERE user_id='你的userId';"

# 查看所有设备
sqlite3 clipflow.db "SELECT id, name, platform, last_seen, removed_at FROM devices;"

# 查看 token 数量
sqlite3 clipflow.db "SELECT count(*) FROM tokens;"

# 查看被软删的历史条目
sqlite3 clipflow.db "SELECT id, deleted_at FROM history WHERE deleted_at IS NOT NULL;"

# 查看文件存储占用
du -sh /opt/clipflow/data/files/

# 查看数据库文件大小
ls -lh /opt/clipflow/clipflow.db
```

---

## 5. API 健康检查（服务器本机）

```bash
# 基础健康检查
curl http://127.0.0.1:3000/api/ping

# 认证测试（手动获取 token）
curl -s -X POST http://127.0.0.1:3000/api/auth \
  -H 'Content-Type: application/json' \
  -d '{"userId":"test_user"}' | jq .

# 用 token 查看剪切板
TOKEN="你的token"
curl -s http://127.0.0.1:3000/api/clipboard \
  -H "Authorization: Bearer $TOKEN" | jq .

# 查看历史记录
curl -s "http://127.0.0.1:3000/api/history?limit=10" \
  -H "Authorization: Bearer $TOKEN" | jq .

# 查看设备列表
curl -s http://127.0.0.1:3000/api/devices \
  -H "Authorization: Bearer $TOKEN" | jq .
```

---

## 6. 本地冒烟测试

```bash
# 在项目根目录执行；脚本自动起停本地服务器，无需连接远程
bash server/smoke-test.sh

# 自定义端口（默认 3210）
SMOKE_PORT=4000 bash server/smoke-test.sh
```

---

## 7. 本地 Flutter 验证

```bash
# 用项目当前工具链运行；测试数量以实际输出为准
flutter test

# 运行单个测试文件
flutter test test/services/encryption_service_test.dart

# 运行含关键字的测试
flutter test --name "encryption"

# 静态分析
flutter analyze
```

Flutter 位于 `~/development/flutter/bin/flutter`；旧的 `/opt/homebrew/bin/flutter` 已不存在。

---

## 8. 磁盘与系统监控

```bash
# 服务器磁盘使用
df -h

# clipflow 目录占用
du -sh /opt/clipflow/*

# 内存使用
free -h

# Node.js 进程状态
ps aux | grep node

# 端口监听确认
ss -tlnp | grep 3000
```

---

## 9. 网络调试

```bash
# 外部测试（从本地终端）
curl -k https://121.196.222.122/api/ping

# 测试 TLS 证书指纹
openssl s_client -connect 121.196.222.122:443 </dev/null 2>/dev/null \
  | openssl x509 -noout -fingerprint -sha256

# 查看 443/3000 端口监听情况
ss -tlnp | grep -E '443|3000'

# 查看反向代理配置
cat /etc/nginx/sites-enabled/* 2>/dev/null || cat /etc/caddy/Caddyfile 2>/dev/null
```

---

## 10. 紧急回滚

```bash
# 如果新版本出问题，SSH 上去手动回滚：
ssh -i ~/Downloads/key241294.pem root@121.196.222.122

cd /opt/clipflow

# 用备份的旧版本恢复（需提前备份）
cp index.js index.js.bak
# ... 上传旧版本 index.js ...
sudo systemctl restart clipflow

# 确认服务恢复
curl http://127.0.0.1:3000/api/ping
```
