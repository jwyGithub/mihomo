# mihomo 多端口订阅服务镜像

基于 [mihomo](https://github.com/MetaCubeX/mihomo) 内核，在**同一个容器内**用**一个** mihomo 二进制拉起**多个**实例，每个实例对应一条订阅、监听各自端口、按 cron 定时更新订阅并自动应用。

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

- `entrypoint.sh`：解析 `subs.yaml` → 为每个 sub 建独立运行目录 → 首次拉取订阅 → 动态生成 supervisor 程序块与 crontab → 启动 `supervisord`。
- `update-sub.sh`：下载订阅 → 用 `yq` 改写 `port` / `socks-port` / `external-controller` → 原子替换 `config.yaml`；`reload` 模式下通过 `supervisorctl restart` 使新配置生效。
- 进程托管用 `supervisord`：负责多实例保活、崩溃自动重启，并把**每个 sub 的日志单独**写到 `/data/logs/<name>.log`。
- 定时更新用 busybox `crond`，按每个 sub 的 `cron` 触发。

## 日志

| 文件 | 内容 |
| --- | --- |
| `/data/logs/<name>.log` | 对应实例的 mihomo 运行日志 |
| `/data/logs/<name>.update.log` | 对应实例的订阅更新日志 |
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

> 安全提示：`external-controller` 默认监听 `0.0.0.0` 且无 secret。若将 `port+2` 端口对外映射，建议在订阅配置里设置 `secret` 或仅在内网访问。
