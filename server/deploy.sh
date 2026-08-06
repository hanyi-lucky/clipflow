#!/bin/bash
# ClipFlow 服务器部署脚本
# 在阿里云服务器上执行
# 部署时需同时上传 server/index.js 与 server/file_store.js 到 /opt/clipflow/

set -e

echo "=== ClipFlow Server Deployment ==="

# 1. 安装 Node.js
echo "Installing Node.js..."
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
sudo apt-get install -y nodejs

# 2. 安装依赖
echo "Installing dependencies..."
cd /opt/clipflow
npm install --production

# 2.5 创建文件存储目录
echo "Creating file storage directory..."
sudo mkdir -p /opt/clipflow/data/files
sudo chown -R clipflow:clipflow /opt/clipflow/data

# 3. 创建 systemd 服务
echo "Creating systemd service..."
sudo tee /etc/systemd/system/clipflow.service > /dev/null << 'EOF'
[Unit]
Description=ClipFlow Server
After=network.target

[Service]
Type=simple
User=clipflow
WorkingDirectory=/opt/clipflow
ExecStart=/usr/bin/node index.js
Restart=always
RestartSec=10
Environment=PORT=3000
# 只监听回环，禁止公网直连 3000（配合 Cloudflare Tunnel；index.js 默认 0.0.0.0，勿删此行）
Environment=HOST=127.0.0.1
Environment=FILE_DIR=/opt/clipflow/data/files

[Install]
WantedBy=multi-user.target
EOF

# 4. 启动服务
echo "Starting service..."
sudo systemctl daemon-reload
sudo systemctl enable clipflow
sudo systemctl start clipflow

# 5. 检查状态
echo "Checking status..."
sudo systemctl status clipflow --no-pager

echo ""
echo "=== Deployment Complete ==="
echo "Server: https://api.yihanlife.ccwu.cc/api（服务仅监听 127.0.0.1:3000，不对外暴露 3000）"
