#!/usr/bin/env bash
set -Eeuo pipefail

echo "========================================"
echo "  3proxy SOCKS5 一键安装/配置（Ubuntu）"
echo "========================================"

if [ "${EUID}" -ne 0 ]; then
  echo "请使用 root 运行：sudo bash $0"
  exit 1
fi

AUTO_IP="$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
read -rp "公网 IPv4 [${AUTO_IP:-请输入}]: " PROXY_IP
PROXY_IP="${PROXY_IP:-$AUTO_IP}"

if [[ -z "$PROXY_IP" ]]; then
  echo "未获取到公网 IP，请重新运行并手动输入。"
  exit 1
fi

read -rp "SOCKS5 端口 [25000]: " PROXY_PORT
PROXY_PORT="${PROXY_PORT:-25000}"

read -rp "用户名 [admin]: " PROXY_USER
PROXY_USER="${PROXY_USER:-admin}"

read -rsp "密码（建议 12 位以上，避免冒号和空格）: " PROXY_PASS
echo
if [[ -z "$PROXY_PASS" ]]; then
  echo "密码不能为空。"
  exit 1
fi

if [[ "$PROXY_PASS" =~ [:[:space:]] ]]; then
  echo "密码请不要包含冒号(:)或空格/换行。"
  exit 1
fi

if [[ ! "$PROXY_PORT" =~ ^[0-9]+$ ]] || (( PROXY_PORT < 1 || PROXY_PORT > 65535 )); then
  echo "端口不合法。"
  exit 1
fi

if ss -lntp 2>/dev/null | grep -qE ":${PROXY_PORT}[[:space:]]"; then
  echo
  echo "端口 ${PROXY_PORT} 已被占用："
  ss -lntp 2>/dev/null | grep -E ":${PROXY_PORT}[[:space:]]" || true
  echo
  echo "请先关闭 Xray/其他程序中占用该端口的入站，再重新运行。"
  exit 1
fi

echo "[1/6] 安装 3proxy 官方 LTS 软件源..."
install -d -m 0755 /usr/share/keyrings /etc/apt/sources.list.d /etc/3proxy

curl -fsSL https://3proxy.org/repo/3proxy-release-key.asc \
  -o /usr/share/keyrings/3proxy.asc

cat >/etc/apt/sources.list.d/3proxy.sources <<'SRC'
Types: deb
URIs: https://3proxy.org/repo/deb
Suites: lts
Components: main
Signed-By: /usr/share/keyrings/3proxy.asc
SRC

echo "[2/6] 安装 3proxy..."
apt-get update
DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get install -y 3proxy curl

echo "[3/6] 写入 SOCKS5 配置..."
if [ -f /etc/3proxy/3proxy.cfg ]; then
  cp -a /etc/3proxy/3proxy.cfg "/etc/3proxy/3proxy.cfg.bak.$(date +%Y%m%d-%H%M%S)"
fi

cat >/etc/3proxy/3proxy.cfg <<CFG
nserver 1.1.1.1
nserver 8.8.8.8
nscache 65536

timeouts 1 5 30 60 180 1800 15 60
maxconn 1000

users ${PROXY_USER}:CL:${PROXY_PASS}

auth strong
allow ${PROXY_USER}

socks -p${PROXY_PORT} -i${PROXY_IP} -e${PROXY_IP} -u2
CFG

chmod 600 /etc/3proxy/3proxy.cfg

echo "[4/6] 启动并设置开机自启..."
systemctl enable 3proxy >/dev/null
systemctl restart 3proxy
sleep 1

echo "[5/6] 检查服务..."
if ! systemctl is-active --quiet 3proxy; then
  echo "3proxy 启动失败，最近日志如下："
  journalctl -u 3proxy -n 50 --no-pager
  exit 1
fi

if ! ss -lntp 2>/dev/null | grep -qE "${PROXY_IP}:${PROXY_PORT}[[:space:]]"; then
  echo "3proxy 已启动，但未发现 ${PROXY_IP}:${PROXY_PORT} TCP 监听。"
  ss -lntp 2>/dev/null | grep 3proxy || true
  exit 1
fi

echo "[6/6] 本机代理测试..."
TEST_IP="$(curl -4 -fsS --max-time 15 \
  --socks5-hostname "${PROXY_IP}:${PROXY_PORT}" \
  --proxy-user "${PROXY_USER}:${PROXY_PASS}" \
  https://api.ipify.org 2>/dev/null || true)"

echo
echo "========================================"
echo "安装完成"
echo "========================================"
echo "服务器：${PROXY_IP}"
echo "端口：  ${PROXY_PORT}"
echo "账号：  ${PROXY_USER}"
echo "密码：  ${PROXY_PASS}"
echo
echo "比特云机格式："
echo "${PROXY_IP}:${PROXY_PORT}:${PROXY_USER}:${PROXY_PASS}"
echo
echo "监听状态："
ss -lntp | grep -E ":${PROXY_PORT}[[:space:]]" || true
echo
if [[ "$TEST_IP" == "$PROXY_IP" ]]; then
  echo "TCP SOCKS5 测试：成功，出口 IP = ${TEST_IP}"
else
  echo "TCP SOCKS5 测试：未确认成功（返回：${TEST_IP:-无}）"
fi

echo
echo "注意："
echo "1) 比特云机需要勾选 SOCKS5 UDP。"
echo "2) SOCKS5 UDP ASSOCIATE 可能使用动态 UDP 端口；若云厂商安全组/UFW限制 UDP，需要额外放行。"
echo "3) 不要让 Xray/其他代理继续占用同一个 ${PROXY_PORT} 端口。"
echo "4) 查看状态：systemctl status 3proxy --no-pager"
echo "5) 查看监听：ss -lntp | grep ${PROXY_PORT}"
