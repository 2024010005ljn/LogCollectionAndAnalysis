#!/usr/bin/env bash
# Lab8：创建 8083 演示站，让真实 HTTP 扫描请求进入 nginx access.log。
# 不注入日志；日志由 nginx 自己写。
set -euo pipefail

LAB_NAME="Lab8"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lablib.sh"

need_root
require_active nginx
require_active alloy
require_active loki
require_active grafana-server
require_command curl
state_init

# 8083 端口预检：允许上一次 Lab8 留下的 nginx 监听，阻止其他进程占用。
if command -v ss >/dev/null 2>&1; then
  if ss -ltnp 2>/dev/null | grep -qE '[:.]8083[[:space:]]'; then
    if ! ss -ltnp 2>/dev/null | grep -E '[:.]8083[[:space:]]' | grep -q 'nginx'; then
      die "8083 端口已被其他进程占用，请先释放端口：$(ss -ltnp 2>/dev/null | grep -E '[:.]8083[[:space:]]' | head -n 1)"
    fi
  fi
fi

backup_path /etc/nginx/sites-available/course-web.conf
backup_path /etc/nginx/sites-enabled/course-web.conf

# 配置写入后如果后续步骤失败，自动恢复原配置，避免留下半成品。
restore_on_error() {
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    log "setup.sh 失败，正在恢复原 nginx 配置……"
    restore_backups || true
    if systemctl is-active --quiet nginx; then
      nginx -t >/dev/null 2>&1 && systemctl reload nginx >/dev/null 2>&1 || true
    fi
  fi
  exit "$rc"
}
trap restore_on_error EXIT

cat > /etc/nginx/sites-available/course-web.conf <<'EOF'
# Lab8 专用日志格式：在 combined 末尾加 server_port，便于只筛 8083 的日志。
log_format course_web '$remote_addr - $remote_user [$time_local] "$request" '
                      '$status $body_bytes_sent "$http_referer" "$http_user_agent" '
                      'server_port=$server_port';

# setup.sh 的自检请求统一带 Lab8-setup-check UA，不写入访问日志，
# 避免把 8 条状态码校验误当成正常流量或攻击流量。
map $http_user_agent $lab8_loggable {
    default 1;
    "~*^Lab8-setup-check$" 0;
}

server {
    listen 8083;
    server_name _;
    access_log /var/log/nginx/access.log course_web if=$lab8_loggable;
    error_log /var/log/nginx/error.log;

    location = / {
        return 200 "course web ok\n";
    }
    location = /api/orders {
        return 200 '{"ok":true}\n';
    }
    location = /login {
        return 400 '{"error":"bad request"}\n';
    }
    location = /admin {
        return 403 '{"error":"forbidden"}\n';
    }
    location = /server-status {
        return 403 '{"error":"forbidden"}\n';
    }
    location = /.env {
        return 404 '{"error":"not found"}\n';
    }
    location = /config.php.bak {
        return 404 '{"error":"not found"}\n';
    }
    location ~ \.php$ {
        return 404 '{"error":"not found"}\n';
    }
    # 浏览器可能自动请求 favicon，不记录，避免给正常流量增加无意义的 404。
    location = /favicon.ico {
        access_log off;
        return 204;
    }
    location / {
        return 404 '{"error":"not found"}\n';
    }
}
EOF

ln -sfn /etc/nginx/sites-available/course-web.conf /etc/nginx/sites-enabled/course-web.conf
nginx_reload

# 逐项验证状态码，避免“配置写了但没生效”。
# 自检统一使用 Lab8-setup-check UA，上面 access_log if= 会把这些请求排除在日志外。
check() {
  local path="$1" expected="$2" code
  code="$(curl -sS -A "Lab8-setup-check" -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:8083${path}")"
  if [ "$code" != "$expected" ]; then
    die "$path 预期 $expected，实际 $code；请检查 nginx 配置和监听端口。"
  fi
  log "$path -> $code"
}

check "/" 200
check "/api/orders?id=1" 200
check "/login?user=admin'OR'1'='1" 400
check "/admin" 403
check "/server-status" 403
check "/.env" 404
check "/config.php.bak" 404
check "/wp-login.php" 404

log "8083 演示站已准备好。"
log "以上自检使用 UA Lab8-setup-check，不会写入 access.log。"
log "访问日志：/var/log/nginx/access.log（每行末尾有 server_port=8083）。"
log "下一步：sudo bash web-attack.sh"
