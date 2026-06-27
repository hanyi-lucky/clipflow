#!/bin/bash
# ClipFlow 服务器部署脚本
# 在阿里云服务器上执行

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

# 3. 创建 systemd 服务
echo "Creating systemd service..."
sudo tee /etc/systemd/system/clipflow.service > /dev/null << 'EOF'
[Unit]
Description=ClipFlow Server
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/clipflow
ExecStart=/usr/bin/node index.js
Restart=always
RestartSec=10
Environment=PORT=3000

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
echo "Server: http://$(curl -s ifconfig.me):3000/api/ping"
