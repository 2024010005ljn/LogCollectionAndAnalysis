#!/usr/bin/env bash
# Lab8：从临时 netns 向本机 8083 演示站发起真实 HTTP 扫描。
# 脚本只发请求，不写任何日志；nginx 自己把请求写进 access.log。
set -euo pipefail

LAB_NAME="Lab8"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lablib.sh"

NETNS="lab8-atk"
VETH="lab8-veth"
SRC="203.0.113.50"
HOST_IP="10.99.3.1"
BASE="http://${HOST_IP}:8083"

need_root
require_command ip
require_command curl
require_active nginx
require_active alloy

code="$(wait_http "http://127.0.0.1:8083/" 10 || true)"
[ -n "$code" ] || die "8083 站点不可达，请先执行 sudo bash setup.sh。"

cleanup() {
  cleanup_netns "$NETNS" "$VETH"
}
trap cleanup EXIT
cleanup

if ! ip netns add "$NETNS" 2>/dev/null; then
  die "无法创建网络命名空间 ${NETNS}；请确认在 Ubuntu 虚拟机中以 root 运行，且内核支持 network namespace。"
fi

ip link add "$VETH" type veth peer name "${VETH}-ns"
ip link set "${VETH}-ns" netns "$NETNS"
ip addr add "${HOST_IP}/24" dev "$VETH"
ip link set "$VETH" up
ip netns exec "$NETNS" ip link set lo up
ip netns exec "$NETNS" ip addr add "${SRC}/24" dev "${VETH}-ns"
ip netns exec "$NETNS" ip link set "${VETH}-ns" up
ip netns exec "$NETNS" ip route replace "${HOST_IP%.*}.0/24" dev "${VETH}-ns"
ip route replace "${SRC%.*}.0/24" dev "$VETH"

log "① 正常请求（本机 127.0.0.1，用于和攻击流量对比）"
curl -sS -o /dev/null -w '  %{http_code} %{url_effective}\n' \
  --max-time 5 \
  -A "Mozilla/5.0 (X11; Linux x86_64) Firefox/128.0" \
  "http://127.0.0.1:8083/"
curl -sS -o /dev/null -w '  %{http_code} %{url_effective}\n' \
  --max-time 5 \
  -A "Mozilla/5.0 (X11; Linux x86_64) Firefox/128.0" \
  "http://127.0.0.1:8083/api/orders?id=1"

log "② 攻击请求（来源 ${SRC}，由临时 netns 发出，共 9 条）"
log "   说明：UA 由 curl -A 设置，用于模拟扫描器特征；脚本没有真正运行 sqlmap/Nikto。"

req() {
  ip netns exec "$NETNS" curl -sS -o /dev/null -w '  %{http_code} %{url_effective}\n' \
    --max-time 5 "$@"
}

# SQL 注入探测：sqlmap 只针对带参数的登录接口。
req -A "sqlmap/1.8" "${BASE}/login?user=admin'OR'1'='1"
req -A "sqlmap/1.8" "${BASE}/login?user=admin'OR'1'='1"

# 通用 Web 扫描器：敏感文件、后台、状态页、WordPress 路径和路径穿越。
req -A "Nikto/2.5.0" "${BASE}/.env"
req -A "Nikto/2.5.0" "${BASE}/config.php.bak"
req -A "Nikto/2.5.0" "${BASE}/admin"
req -A "Nikto/2.5.0" "${BASE}/server-status"
req -A "Nikto/2.5.0" "${BASE}/wp-login.php"
req -A "Nikto/2.5.0" --path-as-is "${BASE}/../../etc/passwd"

# 一条伪装成普通浏览器的探测，用于说明 UA 不能单独作为判断依据。
req -A "Mozilla/5.0" "${BASE}/wp-login.php"

log "完成。等待约 10 秒，在 Grafana Explore 查询："
log '  {job="nginx_access"} |= "server_port=8083"'
log "提示：从宿主机浏览器访问 http://<虚拟机IP>:8083/ 可生成正常的 192.168.x.x 记录。"
log "攻击流量来自 ${SRC}；netns/veth 已自动清理，日志保留。"
