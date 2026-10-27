# mihomo 多端口订阅服务镜像

[![Build and Push Docker Image](https://img.shields.io/github/actions/workflow/status/jwygithub/mihomo/docker-publish.yml?style=flat-square&logo=githubactions&logoColor=white&label=build)](https://github.com/jwygithub/mihomo/actions/workflows/docker-publish.yml)
[![GitHub stars](https://img.shields.io/github/stars/jwygithub/mihomo?style=flat-square&logo=github)](https://github.com/jwygithub/mihomo/stargazers)
[![GitHub forks](https://img.shields.io/github/forks/jwygithub/mihomo?style=flat-square&logo=github)](https://github.com/jwygithub/mihomo/network/members)
[![mihomo](https://img.shields.io/badge/mihomo-v1.19.33-1f6feb?style=flat-square)](https://github.com/MetaCubeX/mihomo/releases/tag/v1.19.33)
[![Docker image](https://img.shields.io/badge/ghcr.io-jwygithub%2Fmihomo-2496ED?style=flat-square&logo=docker&logoColor=white)](https://github.com/jwygithub/mihomo/pkgs/container/mihomo)
[![Platforms](https://img.shields.io/badge/platform-amd64%20%7C%20arm64-success?style=flat-square)](https://github.com/jwygithub/mihomo/pkgs/container/mihomo)
[![Base](https://img.shields.io/badge/base-Alpine%203.20-0D597F?style=flat-square&logo=alpinelinux&logoColor=white)](https://hub.docker.com/_/alpine)

基于 [mihomo](https://github.com/MetaCubeX/mihomo) 内核，在**同一个容器内**用**一个** mihomo 二进制拉起**多个**实例，每个实例对应一条订阅、监听各自端口、按 cron 定时更新订阅并自动应用。

- **单二进制多实例**：按目标架构只内置一个 mihomo 二进制，由 supervisor 托管多个实例并保活。
- **多端口隔离**：每个 sub 自动占用 `port` / `port+1`（socks）/ `port+2`（controller）连续端口段。
- **订阅定时更新**：每个 sub 可配置独立 cron，到点重新拉取订阅、改写端口并热重启生效。
- **GeoIP/GeoSite 默认离线**：构建时把 geo 库打进镜像，运行时不联网（避免下载超时导致崩溃）；可选开启定时更新保持库新鲜。

## 端口规则

每个 sub 依据配置的 `port` 占用连续 3 个端口：

| 字段 | 值 |
| --- | --- |
| `port`（HTTP 代理） | `port` |
| `socks-port`（SOCKS 代理） | `port + 1` |
| `external-controller`（API/面板） | `0.0.0.0:(port + 2)` |

> 各 sub 的端口区间 `[port, port+2]` 不能重叠。

## 配置文件 `subs.yaml`

```yaml
- name: sub-jawyn            # 实例名（唯一，用作目录与日志名）
  sub: https://.../sub?...&clash   # 订阅地址
  port: 7290                 # http=7290, socks=7291, controller=7292
  cron: 0 8 * * *            # 每天 8:00 更新订阅并重启该实例
```

## 使用

```bash
# 构建（多架构，只会按目标架构下载对应的单个 mihomo 二进制）
docker buildx build --platform linux/amd64,linux/arm64 \
  -t ghcr.io/jwygithub/mihomo:latest --push .

# 本机构建并运行
docker build -t ghcr.io/jwygithub/mihomo:latest .
docker compose up -d
```

## 工作原理

- `entrypoint.sh`：解析 `subs.yaml` → 为每个 sub 建独立运行目录并预置内置 geo 库 → 首次拉取订阅 → 动态生成 supervisor 程序块与 crontab（含可选的 geo 更新任务）→ 启动 `supervisord`。
- `update-sub.sh`：下载订阅 → 用 `yq` 改写 `port` / `socks-port` / `external-controller` → 原子替换 `config.yaml`；`reload` 模式下通过 `supervisorctl restart` 使新配置生效。
- `update-geo.sh`（可选）：下载最新 GeoIP/GeoSite 库 → 校验（非空 + 最小体积，排除错误页/截断）→ 刷新镜像基线 `/opt/geo` 与各实例目录 → 逐个重启实例加载新库。仅当设置 `GEO_UPDATE_CRON` 时启用。
- 进程托管用 `supervisord`：负责多实例保活、崩溃自动重启，并把**每个 sub 的日志单独**写到 `/data/logs/<name>.log`。
- 定时更新用 busybox `crond`，按每个 sub 的 `cron`（以及可选的 `GEO_UPDATE_CRON`）触发。

## GeoIP / GeoSite 数据库

默认策略是**纯离线**：geo 库在构建镜像时打进 `/opt/geo`，容器启动时拷贝到每个实例目录，配置里 `geo-auto-update: false`，mihomo 运行期间**不会联网**下载 geo 库（避免下载超时导致 fatal 崩溃）。

如需让库保持新鲜，可设置 `GEO_UPDATE_CRON` 开启**可选的定时更新**（见环境变量）：平时仍完全离线，仅到点联网拉取一次最新库并热更到各实例。

- **失败不破坏现状**：必需库（`geoip.metadb` / `geosite.dat`）下载失败时整次更新放弃、保留旧库不动，绝不会用空文件/错误页覆盖导致下次启动崩溃；可选库（`geoip.dat` / `country.mmdb` / ASN）失败仅跳过。
- **更新即生效**：刷新文件后重启各实例，由 mihomo 重新加载新库。
- 想立即验证（不必等 cron）：`docker exec mihomo /usr/local/bin/update-geo.sh`。

> CN 环境若直连 GitHub 不稳定，可用 `GEO_BASE` 指向 jsDelivr 等镜像/CDN 加速下载。

## 日志

| 文件 | 内容 |
| --- | --- |
| `/data/logs/<name>.log` | 对应实例的 mihomo 运行日志 |
| `/data/logs/<name>.update.log` | 对应实例的订阅更新日志 |
| `/data/logs/geo.update.log` | GeoIP/GeoSite 定时更新日志（启用 `GEO_UPDATE_CRON` 时） |
| `/data/logs/cron.log` | crond 日志 |
| `/data/logs/supervisord.log` | supervisor 日志 |

## 环境变量

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `TZ` | `Asia/Shanghai` | 时区，影响 cron 触发时间 |
| `SUBS_FILE` | `/data/subs.yaml` | 订阅配置路径 |
| `SUB_USER_AGENT` | `clash.meta` | 拉取订阅时的 UA（部分机场按 UA 返回 clash 格式） |
| `SUB_RETRY` | `5` | 下载订阅的最大尝试次数 |
| `SUB_RETRY_DELAY` | `5` | 每次下载失败后的等待秒数 |
| `SUB_CONNECT_TIMEOUT` | `15` | 建立连接超时（秒） |
| `SUB_MAX_TIME` | `60` | 单次下载请求最长耗时（秒） |

> 下载订阅内置重试：每次尝试后都会校验内容非空、为合法 YAML 且根节点为映射（排除错误页/空响应），全部重试失败则保留现有配置不动，不会用坏数据覆盖正常配置。

### GeoIP/GeoSite 定时更新（可选）

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `GEO_UPDATE_CRON` | *(未设置)* | 设置后启用 geo 定时更新（5 字段 cron），如 `0 5 * * 0`（每周日 5:00）、`0 5 1 * *`（每月 1 号 5:00）；不设置则保持纯离线 |
| `GEO_BASE` | `https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest` | geo 库下载源，CN 环境可换镜像/CDN |
| `GEO_ASN_URL` | `.../xishang0128/geoip/.../GeoLite2-ASN.mmdb` | ASN 库下载地址（可选库） |
| `GEO_RETRY` | `3` | 单个库文件最大尝试次数 |
| `GEO_RETRY_DELAY` | `5` | 每次下载失败后的等待秒数 |
| `GEO_CONNECT_TIMEOUT` | `15` | 建立连接超时（秒） |
| `GEO_MAX_TIME` | `120` | 单次下载请求最长耗时（秒） |
| `GEO_MIN_SIZE` | `100000` | 合法库最小体积（字节），用于排除错误页/截断文件 |

> geo 定时更新依赖容器时区（由 `TZ` 控制）。必需库下载失败会放弃整次更新并保留旧库，不影响正在运行的实例。

> 安全提示：`external-controller` 默认监听 `0.0.0.0` 且无 secret。若将 `port+2` 端口对外映射，建议在订阅配置里设置 `secret` 或仅在内网访问。
