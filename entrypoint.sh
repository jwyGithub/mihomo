#!/bin/bash
# 容器入口：解析 subs.yaml -> 为每个 sub 生成独立配置与进程 -> 由 supervisor 托管
set -euo pipefail

SUBS_FILE="${SUBS_FILE:-/data/subs.yaml}"
RUN_DIR=/data/run
LOG_DIR=/data/logs
SUP_CONF=/etc/supervisor/supervisord.conf
CRONTAB_DIR=/etc/crontabs
CRONTAB_FILE="${CRONTAB_DIR}/root"
DNS_TEMPLATE_FILE="${DNS_TEMPLATE_FILE:-/opt/templates/dns.yaml}"

mkdir -p "$RUN_DIR" "$LOG_DIR" /etc/supervisor "$CRONTAB_DIR" /run

# ---- 默认 DNS / Fake-IP 模板（feature 7）----
# 模板已随镜像内置（templates/dns.yaml -> /opt/templates/dns.yaml），不再运行时生成。
# update-sub.sh 会把它作为「基底」合并进订阅（订阅自带 dns 优先，模板仅补齐缺失项）；
# 自定义：修改项目内 templates/dns.yaml 重新 build，或挂载替换 / 用 DNS_TEMPLATE_FILE 指向其它路径；
# 默认关闭（沿用订阅自带 DNS），设置 DNS_TEMPLATE=on 启用模板合并。
if [ "${DNS_TEMPLATE:-off}" != "off" ] && [ ! -f "$DNS_TEMPLATE_FILE" ]; then
    echo "[entrypoint] 警告：未找到 DNS 模板 ${DNS_TEMPLATE_FILE}，将跳过模板合并" >&2
fi

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

    # 预置镜像内置的 GeoIP/GeoSite 数据库到实例工作目录，
    # 避免 mihomo 运行时联网下载（下载超时会导致 fatal 崩溃）。
    if [ -d /opt/geo ]; then
        cp -f /opt/geo/* "$dir"/ 2>/dev/null || true
    fi

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

# ---- GeoIP/GeoSite 数据库定时更新（可选）----
# 设置环境变量 GEO_UPDATE_CRON 即启用，例如：
#   每周一次：  GEO_UPDATE_CRON="0 5 * * 0"   (每周日 5:00)
#   每月一次：  GEO_UPDATE_CRON="0 5 1 * *"   (每月 1 号 5:00)
# 不设置则保持纯离线（仅用镜像内置库）。
if [ -n "${GEO_UPDATE_CRON:-}" ]; then
    echo "${GEO_UPDATE_CRON} /usr/local/bin/update-geo.sh >> ${LOG_DIR}/geo.update.log 2>&1" >> "$CRONTAB_FILE"
    echo "[entrypoint] 已登记 GeoIP/GeoSite 定时更新: ${GEO_UPDATE_CRON}"
fi

echo "[entrypoint] 启动 supervisord（管理所有 mihomo 实例 + crond）"
exec supervisord -c "$SUP_CONF"
