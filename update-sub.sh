#!/bin/bash
# 下载指定 sub 的订阅 -> 合并 DNS 模板/自定义 override -> 改写端口等关键字段 -> 校验 -> 应用
#   用法: update-sub.sh <name> [init|reload]
#     init   : 仅生成配置，不重启（容器首启时由 entrypoint 调用）
#     reload : 生成配置后通过 supervisorctl 重启该实例（cron 定时调用）
#
# 处理流水线（对下载到的临时配置依次施加）：
#   1) 下载订阅 + 重试 + 合法性校验（非空 / 合法 YAML / 根为映射）
#   2) DNS/fake-ip 默认模板合并（默认关闭，DNS_TEMPLATE=on 启用；订阅自带 dns 优先）
#   3) 自定义 override 合并（subs.yaml 中该 sub 的 .override 块，用户配置优先）
#   4) 归一化：强制 port/socks-port/external-controller/secret/profile 等关键字段（最后执行，
#      保证多实例端口隔离与离线策略不会被模板/override 破坏）
#   5) mihomo -t 校验：不通过则保留现有配置、不替换、不重启（SKIP_CONFIG_TEST=1 可跳过）
set -euo pipefail

NAME="${1:?用法: update-sub.sh <name> [init|reload]}"
MODE="${2:-reload}"

SUBS_FILE="${SUBS_FILE:-/data/subs.yaml}"
RUN_DIR=/data/run
SUP_CONF=/etc/supervisor/supervisord.conf
MIHOMO_BIN="${MIHOMO_BIN:-/usr/local/bin/mihomo}"
UA="${SUB_USER_AGENT:-clash.meta}"

# DNS 默认模板（feature 7）
DNS_TEMPLATE="${DNS_TEMPLATE:-off}"                              # on|off（默认 off，按需开启）
DNS_TEMPLATE_FILE="${DNS_TEMPLATE_FILE:-/opt/templates/dns.yaml}"

# 下载重试参数（均可通过环境变量覆盖）
RETRY="${SUB_RETRY:-5}"                       # 最大尝试次数
RETRY_DELAY="${SUB_RETRY_DELAY:-5}"           # 每次失败后的等待秒数
CONNECT_TIMEOUT="${SUB_CONNECT_TIMEOUT:-15}"  # 建立连接超时（秒）
MAX_TIME="${SUB_MAX_TIME:-60}"                # 单次请求最长耗时（秒）

sub=$(yq ".[] | select(.name == \"${NAME}\") | .sub" "$SUBS_FILE" | head -n1)
port=$(yq ".[] | select(.name == \"${NAME}\") | .port" "$SUBS_FILE" | head -n1)
# 每实例 secret：优先 subs.yaml 的 .secret，其次环境变量 CONTROLLER_SECRET，否则不设置
secret_val=$(yq ".[] | select(.name == \"${NAME}\") | .secret // \"\"" "$SUBS_FILE" | head -n1)
[ "$secret_val" = "null" ] && secret_val=""
[ -z "$secret_val" ] && secret_val="${CONTROLLER_SECRET:-}"

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

# ---- (2) DNS/fake-ip 默认模板合并（作为基底；订阅自带 dns 优先，模板只补齐缺失项）----
if [ "$DNS_TEMPLATE" != "off" ] && [ -f "$DNS_TEMPLATE_FILE" ]; then
    if yq '.' "$DNS_TEMPLATE_FILE" >/dev/null 2>&1; then
        export MH_DNSTPL="$DNS_TEMPLATE_FILE"
        # 模板可写成带顶层 dns: 的片段，也可直接写 dns 下的字段（两种都支持）。
        # (dnstpl * existing)：同名标量/映射/数组以订阅为准，模板仅补齐订阅没有的键。
        yq -i '
            (load(strenv(MH_DNSTPL))) as $tpl
            | (($tpl.dns) // $tpl) as $dnstpl
            | .dns = ($dnstpl * (.dns // {}))
        ' "$tmp"
        echo "[update] ${NAME}: 已合并 DNS/fake-ip 默认模板 (${DNS_TEMPLATE_FILE})"
    else
        echo "[update] ${NAME}: DNS 模板非法 YAML，已跳过: ${DNS_TEMPLATE_FILE}" >&2
    fi
fi

# ---- (3) 自定义 override 合并（subs.yaml 中该 sub 的 .override 块，用户优先）----
#   prepend-rules / append-rules           : 规则置顶 / 置底（优先级：置顶 > 订阅 > 置底）
#   prepend-proxies / append-proxies        : 追加自定义节点
#   prepend-proxy-groups / append-proxy-groups : 追加自定义策略组
#   其余顶层键（hosts/dns/mode/...）          : 深合并覆盖订阅（override 优先）
ov_tmp="$(mktemp)"
yq ".[] | select(.name == \"${NAME}\") | .override // {}" "$SUBS_FILE" > "$ov_tmp" 2>/dev/null || true
# 仅当 .override 是非空映射时才合并（缺省/为空/null 都跳过）
if [ -s "$ov_tmp" ] \
    && [ "$(yq 'tag' "$ov_tmp" 2>/dev/null)" = "!!map" ] \
    && [ "$(yq 'length' "$ov_tmp" 2>/dev/null)" != "0" ]; then
    export MH_OV="$ov_tmp"
    yq -i '
        (load(strenv(MH_OV))) as $ov
        | .rules = ( (($ov | .["prepend-rules"]) // []) + ((.rules) // []) + (($ov | .["append-rules"]) // []) )
        | .proxies = ( ((.proxies) // []) + (($ov | .["prepend-proxies"]) // []) + (($ov | .["append-proxies"]) // []) )
        | .["proxy-groups"] = ( ((.["proxy-groups"]) // []) + (($ov | .["prepend-proxy-groups"]) // []) + (($ov | .["append-proxy-groups"]) // []) )
        | . * ($ov | del(.["prepend-rules"], .["append-rules"], .["prepend-proxies"], .["append-proxies"], .["prepend-proxy-groups"], .["append-proxy-groups"]))
    ' "$tmp"
    echo "[update] ${NAME}: 已合并自定义 override (subs.yaml .override)"
fi
rm -f "$ov_tmp"

# ---- (4) 归一化：强制关键字段（最后执行，确保端口隔离/离线策略不被覆盖）----
#   - port / socks-port(+1) / external-controller(+2)：按约定改写
#   - mixed-port / redir-port / tproxy-port：置 0，避免多实例抢占同一监听端口
#   - dns.listen：置空，避免多实例都抢 0.0.0.0:53（保留 DNS 解析能力，仅不监听端口）
#   - tun.enable：关闭，多实例共存且无需 tun
#   - geo-auto-update：关闭，GeoIP/GeoSite 已内置，杜绝运行时联网下载导致的崩溃
#   - profile.store-selected / store-fake-ip：持久化节点选择与 fake-ip 映射（feature 4）
export MH_PORT="$port" MH_SOCKS="$socks" MH_CTRL="0.0.0.0:${ctrl}"
yq -i '
    .port = env(MH_PORT) |
    .["socks-port"] = env(MH_SOCKS) |
    .["mixed-port"] = 0 |
    .["redir-port"] = 0 |
    .["tproxy-port"] = 0 |
    .["external-controller"] = strenv(MH_CTRL) |
    .["geo-auto-update"] = false |
    .dns.listen = "" |
    .tun.enable = false |
    .profile.store-selected = true |
    .profile.store-fake-ip = true
' "$tmp"

# external-controller secret（feature 3）：有值才设置，保持向后兼容
if [ -n "$secret_val" ]; then
    export MH_SECRET="$secret_val"
    yq -i '.secret = strenv(MH_SECRET)' "$tmp"
    echo "[update] ${NAME}: 已为 external-controller 设置 secret"
fi

# ---- (5) 应用前校验：mihomo -t（feature 1）----
if [ "${SKIP_CONFIG_TEST:-0}" != "1" ]; then
    test_log="$(mktemp)"
    if "$MIHOMO_BIN" -t -d "$dir" -f "$tmp" >"$test_log" 2>&1; then
        echo "[update] ${NAME}: 配置校验通过 (mihomo -t)"
    else
        echo "[update] ${NAME}: 配置校验失败，保留现有配置（不替换 / 不重启）：" >&2
        sed 's/^/[update]   /' "$test_log" >&2 || true
        rm -f "$tmp" "$test_log"
        exit 1
    fi
    rm -f "$test_log"
fi

mv "$tmp" "${dir}/config.yaml"
echo "[update] ${NAME}: 配置已更新 (port=${port} socks-port=${socks} external-controller=0.0.0.0:${ctrl})"

if [ "$MODE" = "reload" ]; then
    if supervisorctl -c "$SUP_CONF" restart "mihomo-${NAME}" >/dev/null 2>&1; then
        echo "[update] ${NAME}: 已重启实例 mihomo-${NAME}，新配置生效"
    else
        echo "[update] ${NAME}: 通过 supervisorctl 重启失败（实例可能尚未启动）" >&2
    fi
fi
