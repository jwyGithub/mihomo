#!/bin/bash
# 容器入口：解析 subs.yaml -> 为每个 sub 生成独立配置与进程 -> 由 supervisor 托管
set -euo pipefail

SUBS_FILE="${SUBS_FILE:-/data/subs.yaml}"
RUN_DIR=/data/run
LOG_DIR=/data/logs
SUP_CONF=/etc/supervisor/supervisord.conf
CRONTAB_DIR=/etc/crontabs
CRONTAB_FILE="${CRONTAB_DIR}/root"

mkdir -p "$RUN_DIR" "$LOG_DIR" /etc/supervisor "$CRONTAB_DIR" /run

# ---- 时区（cron 定时依赖）----
if [ -n "${TZ:-}" ] && [ -f "/usr/share/zoneinfo/${TZ}" ]; then
    cp "/usr/share/zoneinfo/${TZ}" /etc/localtime
    echo "${TZ}" > /etc/timezone
fi

if [ ! -f "$SUBS_FILE" ]; then
    echo "[entrypoint] 找不到订阅配置文件: $SUBS_FILE" >&2
    exit 1
fi

# ---- supervisor 主配置 + crond 托管 ----
cat > "$SUP_CONF" <<'EOF'
[supervisord]
nodaemon=true
user=root
logfile=/data/logs/supervisord.log
logfile_maxbytes=10MB
logfile_backups=3
pidfile=/run/supervisord.pid

[unix_http_server]
file=/run/supervisor.sock

[supervisorctl]
serverurl=unix:///run/supervisor.sock

[rpcinterface:supervisor]
supervisor.rpcinterface_factory = supervisor.rpcinterface:make_main_rpcinterface

[program:crond]
command=crond -f -d 8 -c /etc/crontabs
autorestart=true
stdout_logfile=/data/logs/cron.log
stdout_logfile_maxbytes=10MB
stdout_logfile_backups=3
redirect_stderr=true
EOF

# ---- 重置 crontab ----
: > "$CRONTAB_FILE"

# ---- 遍历每个 sub ----
yq '.[].name' "$SUBS_FILE" | while read -r name; do
    [ -z "$name" ] && continue
    [ "$name" = "null" ] && continue

    port=$(yq ".[] | select(.name == \"${name}\") | .port" "$SUBS_FILE")
    cron=$(yq ".[] | select(.name == \"${name}\") | .cron" "$SUBS_FILE")
    dir="${RUN_DIR}/${name}"
    mkdir -p "$dir"

    echo "[entrypoint] 准备实例 ${name}  (port=${port} socks=$((port + 1)) controller=$((port + 2)))"

    # 首次下载并生成配置（init 模式：此时 supervisord 尚未启动，不触发重启）
    /usr/local/bin/update-sub.sh "$name" init || \
        echo "[entrypoint] 警告：${name} 首次订阅拉取失败，将使用已有配置（若存在）" >&2

    # 为该 sub 追加一个 mihomo 进程，日志独立输出到 ${name}.log
    cat >> "$SUP_CONF" <<EOF

[program:mihomo-${name}]
command=/usr/local/bin/mihomo -d ${dir} -f ${dir}/config.yaml
autorestart=true
startsecs=5
startretries=3
stdout_logfile=${LOG_DIR}/${name}.log
stdout_logfile_maxbytes=10MB
stdout_logfile_backups=3
redirect_stderr=true
EOF

    # 定时更新：到点重新拉取订阅并重启该实例（reload 模式）
    if [ -n "$cron" ] && [ "$cron" != "null" ]; then
        echo "${cron} /usr/local/bin/update-sub.sh ${name} reload >> ${LOG_DIR}/${name}.update.log 2>&1" >> "$CRONTAB_FILE"
        echo "[entrypoint] 已登记定时任务 ${name}: ${cron}"
    fi
done

echo "[entrypoint] 启动 supervisord（管理所有 mihomo 实例 + crond）"
exec supervisord -c "$SUP_CONF"
