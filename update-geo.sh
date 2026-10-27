#!/bin/bash
# 定时更新 GeoIP / GeoSite 数据库：
#   下载最新库 -> 校验（非空 + 最小体积，排除错误页）-> 刷新镜像基线(/opt/geo)与各实例工作目录 -> 重启实例应用
# 由 entrypoint 根据环境变量 GEO_UPDATE_CRON 登记为 cron 任务；也可手动执行：update-geo.sh
set -euo pipefail

SUBS_FILE="${SUBS_FILE:-/data/subs.yaml}"
RUN_DIR=/data/run
GEO_DIR=/opt/geo
SUP_CONF=/etc/supervisor/supervisord.conf

# 下载源（可用环境变量覆盖，CN 环境可改用 jsDelivr 等镜像）
GEO_BASE="${GEO_BASE:-https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest}"
GEO_ASN_URL="${GEO_ASN_URL:-https://github.com/xishang0128/geoip/releases/download/latest/GeoLite2-ASN.mmdb}"

# 下载参数（均可用环境变量覆盖）
RETRY="${GEO_RETRY:-3}"                       # 单个文件最大尝试次数
RETRY_DELAY="${GEO_RETRY_DELAY:-5}"           # 每次失败后等待秒数
CONNECT_TIMEOUT="${GEO_CONNECT_TIMEOUT:-15}"  # 建立连接超时（秒）
MAX_TIME="${GEO_MAX_TIME:-120}"               # 单次请求最长耗时（秒）
MIN_SIZE="${GEO_MIN_SIZE:-100000}"            # 合法库最小体积（字节），用于排除错误页/截断文件

# download_geo <显示名> <url> <required|optional> <输出路径>
#   必需文件失败 -> 返回 1（放弃整次更新，保留旧库不动）；可选文件失败 -> 返回 0（跳过）
download_geo() {
    name="$1"; url="$2"; required="$3"; out="$4"
    attempt=1
    tmp="$(mktemp)"
    while [ "$attempt" -le "$RETRY" ]; do
        echo "[geo] $(date '+%F %T') 下载 ${name} (第 ${attempt}/${RETRY} 次): ${url}"
        if curl -fsSL --connect-timeout "$CONNECT_TIMEOUT" --max-time "$MAX_TIME" -o "$tmp" "$url"; then
            size=$(wc -c < "$tmp" 2>/dev/null || echo 0)
            if [ "$size" -ge "$MIN_SIZE" ]; then
                mv "$tmp" "$out"
                echo "[geo] ${name}: 更新成功 (${size} 字节)"
                return 0
            fi
            echo "[geo] ${name}: 文件过小(${size}B < ${MIN_SIZE}B)，疑似错误页/截断，判定失败" >&2
        else
            echo "[geo] ${name}: 第 ${attempt} 次下载请求失败（curl 退出码 $?）" >&2
        fi
        attempt=$((attempt + 1))
        if [ "$attempt" -le "$RETRY" ]; then
            echo "[geo] ${name}: ${RETRY_DELAY} 秒后重试..." >&2
            sleep "$RETRY_DELAY"
        fi
    done
    rm -f "$tmp"
    if [ "$required" = "required" ]; then
        echo "[geo] ${name}: 下载失败（必需），本次更新放弃，保留现有库不变" >&2
        return 1
    fi
    echo "[geo] ${name}: 下载失败（可选），跳过" >&2
    return 0
}

mkdir -p "$GEO_DIR"

echo "[geo] ===== $(date '+%F %T') 开始更新 GeoIP/GeoSite 数据库 ====="

# 必需：geoip.metadb（默认 MMDB 模式）+ geosite.dat（GEOSITE 规则）
download_geo "geoip.metadb" "${GEO_BASE}/geoip.metadb" required "${GEO_DIR}/geoip.metadb" || exit 1
download_geo "geosite.dat"  "${GEO_BASE}/geosite.dat"  required "${GEO_DIR}/geosite.dat"  || exit 1
# 可选：geoip.dat（geodata-mode: true）/ country.mmdb / ASN
download_geo "geoip.dat"         "${GEO_BASE}/geoip.dat"    optional "${GEO_DIR}/geoip.dat"
download_geo "country.mmdb"      "${GEO_BASE}/country.mmdb" optional "${GEO_DIR}/country.mmdb"
download_geo "GeoLite2-ASN.mmdb" "$GEO_ASN_URL"            optional "${GEO_DIR}/GeoLite2-ASN.mmdb"

# 分发到每个实例工作目录并重启使其加载新库
if [ -f "$SUBS_FILE" ]; then
    yq '.[].name' "$SUBS_FILE" | while read -r name; do
        [ -z "$name" ] && continue
        [ "$name" = "null" ] && continue
        dir="${RUN_DIR}/${name}"
        [ -d "$dir" ] || continue
        cp -f "$GEO_DIR"/* "$dir"/ 2>/dev/null || true
        if supervisorctl -c "$SUP_CONF" restart "mihomo-${name}" >/dev/null 2>&1; then
            echo "[geo] ${name}: 已刷新 geo 数据并重启实例"
        else
            echo "[geo] ${name}: geo 已刷新，但重启失败（实例可能未运行）" >&2
        fi
    done
fi

echo "[geo] ===== $(date '+%F %T') GeoIP/GeoSite 更新完成 ====="
