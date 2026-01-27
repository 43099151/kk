# Quark Auto Save (FRP + Python保活 + 自动备份)
# 目标镜像
FROM cp0204/quark-auto-save:latest

USER root

# 1. 安装基础工具 (Rclone, FRP, Python3)
# 自动判断是 Alpine 还是 Debian 系统，防止安装报错
RUN if [ -f /etc/alpine-release ]; then \
      apk update && \
      apk add --no-cache curl unzip bash ca-certificates procps sed python3 rclone openssh-server socat && \
      sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config && \
      echo "PermitRootLogin yes" >> /etc/ssh/sshd_config && \
      ssh-keygen -A; \
    else \
      apt-get update && \
      apt-get install -y curl unzip bash ca-certificates procps sed python3 rclone openssh-server socat && \
      mkdir -p /run/sshd && \
      sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config && \
      rm -rf /var/lib/apt/lists/*; \
    fi

# 2. 安装 tailscale (使用静态二进制文件，更稳定)
ARG TS_VERSION=""
ARG TS_ARCH=amd64
RUN set -eux; \
    if [ -z "$TS_VERSION" ] || [ "$TS_VERSION" = "latest" ]; then \
      TS_VERSION=$(curl -fsSL https://tailscale.com/changelog/index.xml | sed -n 's/.*<title>Tailscale v\([0-9][0-9.]*\).*/\1/p' | head -n1); \
      if [ -z "$TS_VERSION" ]; then \
        echo "Failed to detect TS_VERSION from changelog; aborting"; exit 1; \
      fi; \
    fi; \
    echo "Installing tailscale version: $TS_VERSION (arch: $TS_ARCH)"; \
    curl -fsSL "https://pkgs.tailscale.com/stable/tailscale_${TS_VERSION}_${TS_ARCH}.tgz" -o /tmp/tailscale.tgz; \
    cd /tmp; \
    tar xzf tailscale.tgz; \
    mv "tailscale_${TS_VERSION}_${TS_ARCH}/tailscaled" /usr/sbin/tailscaled; \
    mv "tailscale_${TS_VERSION}_${TS_ARCH}/tailscale" /usr/bin/tailscale; \
    chmod +x /usr/sbin/tailscaled /usr/bin/tailscale; \
    rm -rf /tmp/tailscale.tgz /tmp/"tailscale_${TS_VERSION}_${TS_ARCH}"

# 3. 注入启动脚本
COPY entrypoint.sh /entrypoint.sh
RUN sed -i 's/\r$//' /entrypoint.sh && chmod +x /entrypoint.sh

# 4. 设置入口

ENTRYPOINT ["/entrypoint.sh"]

