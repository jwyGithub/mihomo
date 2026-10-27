#!/bin/bash
# 下载指定 sub 的订阅 -> 改写 port / socks-port(+1) / external-controller(+2) -> 应用
#   用法: update-sub.sh <name> [init|reload]
#     init   : 仅生成配置，不重启（容器首启时由 entrypoint 调用）
#     reload : 生成配置后通过 supervisorctl 重启该实例（cron 定时调用）
set -euo pipefail

NAME="${1:?用法: update-sub.sh <name> [init|reload]}"
MODE="${2:-reload}"

SUBS_FILE="${SUBS_FILE:-/data/subs.yaml}"
RUN_DIR=/data/run
SUP_CONF=/etc/supervisor/supervisord.conf
UA="${SUB_USER_AGENT:-clash.meta}"

# 下载重试参数（均可通过环境变量覆盖）
RETRY="${SUB_RETRY:-5}"                       # 最大尝试次数
RETRY_DELAY="${SUB_RETRY_DELAY:-5}"           # 每次失败后的等待秒数
CONNECT_TIMEOUT="${SUB_CONNECT_TIMEOUT:-15}"  # 建立连接超时（秒）
MAX_TIME="${SUB_MAX_TIME:-60}"                # 单次请求最长耗时（秒）

sub=$(yq ".[] | select(.name == \"${NAME}\") | .sub" "$SUBS_FILE")
port=$(yq ".[] | select(.name == \"${NAME}\") | .port" "$SUBS_FILE")

if [ -z "$sub" ] || [ "$sub" = "null" ]; then
    echo "[update] ${NAME}: 未找到 sub 订阅地址" >&2
    exit 1
fi
if [ -z "$port" ] || [ "$port" = "null" ]; then
    echo "[update] ${NAME}: 未配置 port" >&2
    exit 1
fi

socks=$((port + 1))
ctrl=$((port + 2))
dir="${RUN_DIR}/${NAME}"
mkdir -p "$dir"
tmp="$(mktemp)"

# 带重试的下载：每次尝试后都校验内容，任一环节失败则等待后重试
download_ok=0
attempt=1
while [ "$attempt" -le "$RETRY" ]; do
    echo "[update] $(date '+%F %T') 拉取 ${NAME} 订阅 (第 ${attempt}/${RETRY} 次): ${sub}"

    if curl -fsSL \
            --connect-timeout "$CONNECT_TIMEOUT" \
            --max-time "$MAX_TIME" \
            -A "$UA" \
            -o "$tmp" "$sub"; then
        # 校验：非空 + 合法 YAML + 根节点为映射（排除 HTML 错误页 / 纯文本提示）
        if [ -s "$tmp" ] && yq '.' "$tmp" >/dev/null 2>&1 && [ "$(yq 'tag' "$tmp" 2>/dev/null)" = "!!map" ]; then
            download_ok=1
            break
        fi
        echo "[update] ${NAME}: 下载内容为空 / 非法 YAML / 非 clash 配置，判定失败" >&2
    else
        echo "[update] ${NAME}: 第 ${attempt} 次下载请求失败（curl 退出码 $?）" >&2
    fi

    attempt=$((attempt + 1))
    if [ "$attempt" -le "$RETRY" ]; then
        echo "[update] ${NAME}: ${RETRY_DELAY} 秒后重试..." >&2
        sleep "$RETRY_DELAY"
    fi
done

if [ "$download_ok" -ne 1 ]; then
    echo "[update] ${NAME}: 重试 ${RETRY} 次后仍失败，保留现有配置不变" >&2
    rm -f "$tmp"
    exit 1
fi

# 改写三个关键端口字段（字段不存在时 yq 会自动创建）
yq -i "
    .port = ${port} |
    .\"socks-port\" = ${socks} |
    .\"external-controller\" = \"0.0.0.0:${ctrl}\"
" "$tmp"

mv "$tmp" "${dir}/config.yaml"
echo "[update] ${NAME}: 配置已更新 (port=${port} socks-port=${socks} external-controller=0.0.0.0:${ctrl})"

if [ "$MODE" = "reload" ]; then
    if supervisorctl -c "$SUP_CONF" restart "mihomo-${NAME}" >/dev/null 2>&1; then
        echo "[update] ${NAME}: 已重启实例 mihomo-${NAME}，新配置生效"
    else
        echo "[update] ${NAME}: 通过 supervisorctl 重启失败（实例可能尚未启动）" >&2
    fi
fi
