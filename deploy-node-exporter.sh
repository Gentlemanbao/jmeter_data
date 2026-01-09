#!/bin/bash
# 直接不用docker来部署node-export 而是使用 systemd 直接运行 node-exporter，这个是自动部署脚本，运行命令：sudo ./deploy-node-exporter.sh，注意运行之前先chmod +x deploy-node-exporter.sh 给执行权限 ，如果用这种方式可能会涉及到防火墙是否放行9100，用firewall-cmd --list-all | grep 9100 命令检查，
# 如果没有查询到数据那就添加，用这个命令firewall-cmd --permanent --add-port=9100/tcp 然后用这个命令firewall-cmd --reload 接着重新访问链接应该就行了http://47.92.159.196:9100

#!/bin/bash

set -e

echo "🚀 开始部署 node-exporter..."

# 1. 下载（最多重试 3 次）
for i in {1..3}; do
  echo "📥 第 $i 次尝试下载..."
  curl -L -o /tmp/node_exporter-1.8.0.linux-amd64.tar.gz \
    https://github.com/prometheus/node_exporter/releases/download/v1.8.0/node_exporter-1.8.0.linux-amd64.tar.gz && break
  sleep 5
done

# 2. 验证文件
if [ ! -f /tmp/node_exporter-1.8.0.linux-amd64.tar.gz ] || [ $(stat -c%s "/tmp/node_exporter-1.8.0.linux-amd64.tar.gz") -lt 5000000 ]; then
  echo "❌ 下载失败或文件不完整！"
  exit 1
fi

# 3. 解压
mkdir -p /opt/node_exporter
tar -xzf /tmp/node_exporter-1.8.0.linux-amd64.tar.gz -C /opt/node_exporter --strip-components=1

# 4. 创建目录
mkdir -p /var/lib/node_exporter/textfile_collector

# 5. 创建服务
cat > /etc/systemd/system/node-exporter.service << 'EOF'
[Unit]
Description=Node Exporter
After=network.target

[Service]
User=root
ExecStart=/opt/node_exporter/node_exporter --collector.vmstat --collector.diskstats --collector.netdev --collector.textfile --collector.textfile.directory=/var/lib/node_exporter/textfile_collector --web.listen-address=0.0.0.0:9100
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# 6. 启动
systemctl daemon-reload
systemctl enable --now node-exporter

# 7. 验证
sleep 2
if systemctl is-active --quiet node-exporter; then
  echo "✅ node-exporter 已成功启动！"
else
  echo "❌ 启动失败，请检查日志：journalctl -u node-exporter -n 50"
  exit 1
fi