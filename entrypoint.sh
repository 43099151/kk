#!/bin/bash
set -x

# ==========================================
# 🟢【硬编码配置区】(Quark 专用)
# ==========================================
export PROJECT_NAME="quark-auto-save"
export TS_NAME="kk"
# Quark 内部端口
export APP_INTERNAL_PORT=5005


# 备份路径 (配置文件在 /app/config)
# 备份路径 (配置文件在 /app/config，Tailscale 状态在 /var/lib/tailscale)
export BACKUP_PATH="/app/config /var/lib/tailscale"

# 【启动命令】
# 大多数这类 Python 镜像的启动命令是 python3 main.py
# 如果启动失败，我们会在日志里打印文件列表来排查
export APP_COMMAND="python3 ./app/run.py"

# 【应用专用变量】(可以在 HF 网页覆盖这些默认值)
export WEBUI_USERNAME="${WEBUI_USERNAME:-admin}"
export WEBUI_PASSWORD="${WEBUI_PASSWORD:-admin123}"
export R2_ACCESS_KEY="75e72cddecc51b32deab13873c967000"
export R2_ENDPOINT="https://6e84f688bfe062834470070a2d946be5.r2.cloudflarestorage.com"
export R2_BUCKET_NAME="hf--backups"
# ==========================================

# --- 1. 系统环境准备 ---
echo "==> [System] 优化 DNS..."
if echo "nameserver 8.8.8.8" > /etc/resolv.conf 2>/dev/null; then
    echo "nameserver 1.1.1.1" >> /etc/resolv.conf
    echo "options timeout:2 attempts:3 rotate" >> /etc/resolv.conf
fi

# 确保目录存在
mkdir -p /app/config /media /root/.config/rclone/

# --- 2. 配置文件生成 ---

# Rclone
cat > /root/.config/rclone/rclone.conf <<EOF
[r2]
type = s3
provider = Cloudflare
access_key_id = ${R2_ACCESS_KEY}
secret_access_key = ${R2_SECRET_KEY}
endpoint = ${R2_ENDPOINT}
acl = private
EOF

# --- 3. 恢复数据 ---
echo "==> [Restore] 尝试恢复数据..."
rclone copy "r2:${R2_BUCKET_NAME}/${PROJECT_NAME}_backup" / --verbose || echo "跳过"

# 修复权限 (防止恢复后只有 root 能读)
chmod -R 777 /app/config /media

# --- 4. 配置 SSH (Root 登录) ---
echo "==> [SSH] 配置 Root 密码..."
if [ -n "$WEBUI_PASSWORD" ]; then
    echo "root:$WEBUI_PASSWORD" | chpasswd
    echo "Root 密码已设置为 WEBUI_PASSWORD"
else
    echo "Root 密码未设置 (使用默认值: admin123)"
    echo "root:admin123" | chpasswd
fi

echo "==> [SSH] 启动 sshd..."
/usr/sbin/sshd -D &

# --- 5. [已修改] 启动端口转发 (7860 -> 8008) ---
# 删除原来的 Python 代码，改用 socat 转发
echo "==> [Network] 启动端口转发: HF(7860) -> App(5005)..."
# TCP-LISTEN:7860  : 监听 HF 的入口端口
# fork             : 允许并发连接
# TCP:127.0.0.1:8008 : 转发给内部的主程序端口
socat TCP-LISTEN:7860,fork,bind=0.0.0.0 TCP:127.0.0.1:5005 &

# --- 6. 启动 Tailscale (Userspace 模式) ---
echo "==> [Tailscale] 初始化..."

# 检查 path (调试用)
echo "==> [Tailscale] PATH: $PATH"
echo "==> [Tailscale] Version:"
tailscale version

# 创建状态目录 (防止部分环境报错)
mkdir -p /var/lib/tailscale

# 启动后台进程 (tun=userspace-networking 是关键，不需要 root 权限)
# 将日志输出到文件以便调试
/usr/sbin/tailscaled --tun=userspace-networking --socket=/tmp/tailscaled.sock --state=/var/lib/tailscale/tailscaled.state > /tmp/tailscaled.log 2>&1 &

# 等待 socket 文件生成 (最多等待 10 秒)
TRIES=0
while [ ! -S /tmp/tailscaled.sock ] && [ $TRIES -lt 20 ]; do
    sleep 0.5
    TRIES=$((TRIES + 1))
done

if [ ! -S /tmp/tailscaled.sock ]; then
    echo "❌ Tailscale socket 未生成，tailscaled 启动失败！"
    echo "=== Tailscale Logs ==="
    cat /tmp/tailscaled.log
    echo "======================"
else
    echo "✅ Tailscale socket 已就绪 (耗时 $((TRIES * 500))ms)"
fi

# 登录
if [ -n "$TS_AUTH_KEY" ]; then
    # 尝试 Up，如果失败则输出日志
    # 去掉绝对路径，直接使用 tailscale
    if tailscale --socket=/tmp/tailscaled.sock up --authkey="${TS_AUTH_KEY}" --hostname="${TS_NAME}" --ssh --accept-routes --advertise-exit-node; then
        # 获取 Tailscale IP 方便调试
        TS_IP=$(tailscale --socket=/tmp/tailscaled.sock ip -4)
        echo "✅ Tailscale 启动成功! IP: $TS_IP"
        # ======================================================
        (
            sleep 5
            echo "==> [Tailscale] Enabling Funnel for Port 8008..."
            # 将公网 HTTPS (443) 流量转发到本地 8008
            tailscale --socket=/tmp/tailscaled.sock funnel --bg --yes 5005
            echo "✅ Funnel enabled."
        ) &
        # ======================================================
    else
        echo "❌ Tailscale up 失败！"
        echo "=== Tailscale Logs (tailscaled) ==="
        cat /tmp/tailscaled.log
        echo "==================================="
    fi
else
    echo "⚠️ 未检测到 TS_AUTH_KEY，跳过 Tailscale 启动"
fi
# --- 7. 启动定时备份 (每12小时 + 启动后立即备份以保存DeviceID) ---
echo "==> [System] 启动定时备份 (每12小时)..."
(
  while true; do
    # 首次启动等待 60 秒后备份一次，确保 State 文件已生成
    sleep 60
    echo "==> [Backup] 执行同步..."
    for DIR in ${BACKUP_PATH}; do
        [ -d "$DIR" ] && rclone sync "$DIR" "r2:${R2_BUCKET_NAME}/${PROJECT_NAME}_backup$DIR" --verbose 2>/dev/null
    done
    # 之后每 12 小时循环
    sleep 43200
  done
) &

# --- 8. 启动主程序 ---
echo "==> [System] 启动 Quark Auto Save..."
# 切换到工作目录 (通常是 /app)
cd /app || true

# 启动程序
${APP_COMMAND} || {
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo "!!! 主程序崩溃，打印当前目录文件以供排查 !!!"
    ls -R /app
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    sleep infinity

}
