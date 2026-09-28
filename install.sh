#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# HY2 + Dante V5 (Non-blocking Universal Version) - Optimized
# Debian 12
# ============================================================

export DEBIAN_FRONTEND=noninteractive

HY2_VERSION="v2.12.2"
HY2_PORT="5443"
SOCKS_PORT="1080"

# 1. 自动获取当前 VPS 公网 IP
PUBLIC_IP="$(curl -s https://api.ipify.org || curl -s https://ipv4.icanhazip.com)"

# 2. 动态获取域名/IP（若未指定，默认使用当前公网 IP）
HY2_DOMAIN="${HY2_DOMAIN:-$PUBLIC_IP}"

HY2_DIR="/etc/hysteria"
HY2_CERT="${HY2_DIR}/server.crt"
HY2_KEY="${HY2_DIR}/server.key"
HY2_CONFIG="${HY2_DIR}/config.yaml"

DANTE_CONFIG="/etc/danted.conf"
SERVICE_NAME="hysteria-server"
SOCKS_USER="proxyuser"

log() {
    echo
    echo "============================================================"
    echo "$1"
    echo "============================================================"
}

die() {
    echo
    echo "[ERROR] $1"
    echo
    exit 1
}

trap 'echo; echo "[ERROR] 脚本在第 $LINENO 行执行失败"; exit 1' ERR

if [[ "${EUID}" -ne 0 ]]; then
    die "请使用 root 执行此脚本"
fi

log "0/10 检查系统"

if [[ ! -f /etc/debian_version ]]; then
    die "本脚本针对 Debian 系统"
fi

echo "系统："
cat /etc/os-release | grep -E '^(PRETTY_NAME|VERSION_ID)=' || true

echo
echo "CPU："
uname -m

echo
echo "公网 IP：${PUBLIC_IP}"
echo "设置 SNI/域名：${HY2_DOMAIN}"

log "1/10 更新 Debian 系统并安装依赖"

# 【优化部分】仅更新软件源索引，移除导致低配谷歌云卡死死机的所有全局升级指令
apt-get update
apt-get install -f -y

# 精准装配网络节点所需的基础依赖包
apt-get install -y \
    curl \
    wget \
    ca-certificates \
    openssl \
    iproute2 \
    procps \
    grep \
    sed \
    gawk \
    coreutils \
    bind9-dnsutils \
    net-tools \
    psmisc \
    lsof

log "2/10 检查域名解析"

if [[ "${HY2_DOMAIN}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "[INFO] 正在使用纯 IP 地址模式部署"
else
    RESOLVED_IP="$(getent ahostsv4 "${HY2_DOMAIN}" 2>/dev/null | awk 'NR==1 {print $1}' || true)"
    if [[ -z "${RESOLVED_IP}" ]]; then
        echo "[WARN] ${HY2_DOMAIN} 当前无法解析，继续完成部署..."
    else
        echo "DNS：${HY2_DOMAIN} -> ${RESOLVED_IP}"
        if [[ "${RESOLVED_IP}" != "${PUBLIC_IP}" ]]; then
            echo "[WARN] DNS 解析到 ${RESOLVED_IP}，与服务器公网 IP (${PUBLIC_IP}) 不匹配，继续完成部署..."
        else
            echo "[OK] DNS 与公网 IP 一致"
        fi
    fi
fi

log "3/10 安装官方 Hysteria 2 ${HY2_VERSION}"

HYSTERIA_USER=root \
bash <(curl -fsSL https://get.hy2.sh/) --version "${HY2_VERSION}"

if [[ ! -x /usr/local/bin/hysteria ]]; then
    die "没有找到 /usr/local/bin/hysteria，HY2 安装失败"
fi

/usr/local/bin/hysteria version || true

log "4/10 清理旧 HY2 配置并生成自签证书"

systemctl stop "${SERVICE_NAME}" 2>/dev/null || true
systemctl disable "${SERVICE_NAME}" 2>/dev/null || true
systemctl reset-failed "${SERVICE_NAME}" 2>/dev/null || true

mkdir -p "${HY2_DIR}"
mkdir -p /var/lib/hysteria

rm -rf "${HY2_DIR}/acme" /var/lib/hysteria/acme /root/acme
rm -f "${HY2_CERT}" "${HY2_KEY}"

if [[ "${HY2_DOMAIN}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    SAN_ARG="IP:${HY2_DOMAIN}"
else
    SAN_ARG="DNS:${HY2_DOMAIN}"
fi

openssl req -x509 -nodes -newkey rsa:2048 \
    -keyout "${HY2_KEY}" \
    -out "${HY2_CERT}" \
    -days 3650 \
    -subj "/CN=${HY2_DOMAIN}" \
    -addext "subjectAltName=${SAN_ARG}"

if [[ ! -s "${HY2_CERT}" || ! -s "${HY2_KEY}" ]]; then
    die "HY2 自签证书生成失败"
fi

chmod 644 "${HY2_CERT}"
chmod 600 "${HY2_KEY}"
chown root:root "${HY2_CERT}" "${HY2_KEY}"

log "5/10 生成 HY2 配置"

HY2_PASSWORD="$(openssl rand -hex 24)"

cat > "${HY2_CONFIG}" <<EOF
listen: :${HY2_PORT}

tls:
  cert: ${HY2_CERT}
  key: ${HY2_KEY}
  sniGuard: disable

auth:
  type: password
  password: ${HY2_PASSWORD}

masquerade:
  type: proxy
  proxy:
    url: https://www.bing.com
EOF

chmod 600 "${HY2_CONFIG}"
chown root:root "${HY2_CONFIG}"

log "6/10 创建 HY2 systemd 服务"

cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=Hysteria 2 Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Group=root
WorkingDirectory=/var/lib/hysteria
ExecStart=/usr/local/bin/hysteria server --config /etc/hysteria/config.yaml
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "${SERVICE_NAME}"

log "7/10 安装并配置 Dante SOCKS5"

apt-get install -y dante-server

SOCKS_PASSWORD="$(openssl rand -hex 18)"

if id "${SOCKS_USER}" >/dev/null 2>&1; then
    usermod -s /usr/sbin/nologin "${SOCKS_USER}" || true
else
    useradd --system --no-create-home --shell /usr/sbin/nologin "${SOCKS_USER}"
fi

echo "${SOCKS_USER}:${SOCKS_PASSWORD}" | chpasswd

DEFAULT_IFACE="$(ip route get 1.1.1.1 | awk '{for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}')"

if [[ -z "${DEFAULT_IFACE}" ]]; then
    die "无法确定默认 network 接口"
fi

cat > "${DANTE_CONFIG}" <<EOF
logoutput: /var/log/danted.log

internal: ${DEFAULT_IFACE} port = ${SOCKS_PORT}
external: ${DEFAULT_IFACE}

clientmethod: none
socksmethod: username

user.privileged: root
user.unprivileged: nobody

client pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
}

socks pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    command: connect
    socksmethod: username
    protocol: tcp
}

socks pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    command: udpassociate
    socksmethod: username
    protocol: udp
}
EOF

chmod 600 "${DANTE_CONFIG}"
chown root:root "${DANTE_CONFIG}"

log "8/10 验证配置"

if /usr/local/bin/hysteria server --config "${HY2_CONFIG}" --help >/dev/null 2>&1; then
    echo "[OK] HY2 可执行文件正常"
fi

if command -v danted >/dev/null 2>&1; then
    danted -V -f "${DANTE_CONFIG}" || true
    echo "[OK] Dante 已加载配置检查"
else
    die "danted 未安装"
fi

log "9/10 启动服务"

systemctl daemon-reload
systemctl enable "${SERVICE_NAME}"
systemctl restart "${SERVICE_NAME}"

systemctl enable danted
systemctl restart danted

sleep 3

log "10/10 最终检查"

if ! systemctl is-active --quiet "${SERVICE_NAME}"; then
    journalctl -u "${SERVICE_NAME}" -n 30 --no-pager -l
    die "HY2 启动失败"
fi

if ! systemctl is-active --quiet danted; then
    journalctl -u danted -n 30 --no-pager -l
    die "Dante 启动失败"
fi

FINGERPRINT="$(openssl x509 -in "${HY2_CERT}" -noout -fingerprint -sha256 | sed 's/.*=//' | tr -d ':')"
HY2_URI="hysteria2://${HY2_PASSWORD}@${HY2_DOMAIN}:${HY2_PORT}/?sni=${HY2_DOMAIN}&insecure=1&pinSHA256=${FINGERPRINT}#HY2-NODE"

cat > /root/HY2-SOCKS5-INFO.txt <<EOF
HY2 SERVER
==============================
IP: ${PUBLIC_IP}
Domain/SNI: ${HY2_DOMAIN}
Port: ${HY2_PORT}/UDP
Password: ${HY2_PASSWORD}
SHA256: ${FINGERPRINT}
HY2 URI: ${HY2_URI}

SOCKS5
==============================
Server: ${PUBLIC_IP}
Port: ${SOCKS_PORT}
Username: ${SOCKS_USER}
Password: ${SOCKS_PASSWORD}
Protocol: SOCKS5
EOF

chmod 600 /root/HY2-SOCKS5-INFO.txt

clear
echo "============================================================"
echo "HY2 + SOCKS5 V5 部署成功"
echo "连接配置已存入 /root/HY2-SOCKS5-INFO.txt"
echo "============================================================"
cat /root/HY2-SOCKS5-INFO.txt
