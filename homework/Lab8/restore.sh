#!/usr/bin/env bash
# Lab8：移除 8083 站点配置，清理可能残留的 netns/veth。
# 不删除 /var/log/nginx 和 Loki 里的日志。
set -euo pipefail

LAB_NAME="Lab8"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lablib.sh"

need_root

cleanup_netns "lab8-atk" "lab8-veth"

if [ ! -f "$STATE_DIR/backup.list" ]; then
  log "没有 Lab8 配置备份；没有需要恢复的 8083 站点。"
  log "已检查并清理可能残留的 netns/veth。"
  exit 0
fi

restore_backups

if systemctl is-active --quiet nginx; then
  nginx -t
  systemctl reload nginx
fi

log "已移除 Lab8 的 8083 站点配置。"
log "nginx 访问日志和 Loki 中的历史数据保留，供报告和复盘使用。"
