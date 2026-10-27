# syntax=docker/dockerfile:1

FROM alpine:3.20

# mihomo 内核版本：https://github.com/MetaCubeX/mihomo/releases
ARG MIHOMO_VERSION=v1.19.33
# buildx 会自动注入 TARGETARCH（amd64 / arm64 / arm ...）
ARG TARGETARCH
ARG TARGETVARIANT

ENV TZ=Asia/Shanghai \
    SUBS_FILE=/data/subs.yaml \
    SUB_USER_AGENT=clash.meta

# 运行所需组件：
#   bash         - 启动脚本
#   curl         - 下载订阅
#   yq           - 解析 / 改写 YAML 配置
#   supervisor   - 同时管理多个 mihomo 进程 + crond，并输出每个 sub 独立日志
#   tini         - 作为 PID 1 回收僵尸进程
#   tzdata       - cron 的定时依赖正确时区
RUN apk add --no-cache \
        bash \
        ca-certificates \
        curl \
        yq \
        supervisor \
        tini \
        tzdata

# 只下载一个对应架构的 mihomo 二进制即可，多实例共用同一个二进制
RUN set -eux; \
    case "${TARGETARCH}" in \
        amd64)  MIHOMO_ARCH="amd64-compatible" ;; \
        arm64)  MIHOMO_ARCH="arm64" ;; \
        arm)    case "${TARGETVARIANT}" in \
                    v7) MIHOMO_ARCH="armv7" ;; \
                    *)  MIHOMO_ARCH="armv7" ;; \
                esac ;; \
        386)    MIHOMO_ARCH="386" ;; \
        *) echo "unsupported architecture: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    url="https://github.com/MetaCubeX/mihomo/releases/download/${MIHOMO_VERSION}/mihomo-linux-${MIHOMO_ARCH}-${MIHOMO_VERSION}.gz"; \
    echo "downloading ${url}"; \
    curl -fsSL -o /tmp/mihomo.gz "${url}"; \
    gunzip -c /tmp/mihomo.gz > /usr/local/bin/mihomo; \
    chmod +x /usr/local/bin/mihomo; \
    rm -f /tmp/mihomo.gz; \
    /usr/local/bin/mihomo -v

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY update-sub.sh /usr/local/bin/update-sub.sh
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/update-sub.sh

WORKDIR /data

ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/entrypoint.sh"]
