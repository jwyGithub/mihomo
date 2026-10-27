# mihomo 多端口订阅服务镜像

[![Build and Push Docker Image](https://img.shields.io/github/actions/workflow/status/jwygithub/mihomo/docker-publish.yml?style=flat-square&logo=githubactions&logoColor=white&label=build)](https://github.com/jwygithub/mihomo/actions/workflows/docker-publish.yml)
[![mihomo](https://img.shields.io/badge/mihomo-v1.19.33-1f6feb?style=flat-square)](https://github.com/MetaCubeX/mihomo/releases/tag/v1.19.33)
[![Docker image](https://img.shields.io/badge/ghcr.io-jwygithub%2Fmihomo-2496ED?style=flat-square&logo=docker&logoColor=white)](https://github.com/jwygithub/mihomo/pkgs/container/mihomo)
[![Platforms](https://img.shields.io/badge/platform-amd64%20%7C%20arm64-success?style=flat-square)](https://github.com/jwygithub/mihomo/pkgs/container/mihomo)
[![Base](https://img.shields.io/badge/base-Alpine%203.20-0D597F?style=flat-square&logo=alpinelinux&logoColor=white)](https://hub.docker.com/_/alpine)

基于 [mihomo](https://github.com/MetaCubeX/mihomo) 内核，在**同一个容器内**用**一个** mihomo 二进制拉起**多个**实例，每个实例对应一条订阅、监听各自端口、按 cron 定时更新订阅并自动应用。

- **单二进制多实例**：按目标架构只内置一个 mihomo 二进制，由 supervisor 托管多个实例并保活。
- **多端口隔离**：每个 sub 自动占用 `port` / `port+1`（socks）/ `port+2`（controller）连续端口段。
- **订阅定时更新**：每个 sub 可配置独立 cron，到点重新拉取订阅、改写端口并热重启生效。
- **GeoIP/GeoSite 默认离线**：构建时把 geo 库打进镜像，运行时不联网（避免下载超时导致崩溃）；可选开启定时更新保持库新鲜。
- **更新前先校验**：每次应用新订阅前用 `mihomo -t` 校验，不通过则保留旧配置、不重启，杜绝"更新即失联"。
- **自定义不被覆盖**：可为每个实例挂一份 override 片段（规则/策略组/节点/DNS），订阅更新后自动合并。
- **开箱即用的默认增强**：内置 fake-ip DNS 模板、`external-controller` 密钥、节点选择与 fake-ip 映射持久化。

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
  secret: my-secret          # 可选：该实例面板/API 密钥；缺省回退到 CONTROLLER_SECRET
```

> `name` 必须唯一：重复会导致运行目录/日志互相覆盖、按名取值串线。

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
- `update-sub.sh`：下载订阅 →（合并 DNS 默认模板）→（合并自定义 override）→ 用 `yq` 归一化强制 `port` / `socks-port` / `external-controller` / `secret` / `profile` 等关键字段 → `mihomo -t` 校验 → 原子替换 `config.yaml`；`reload` 模式下通过 `supervisorctl restart` 使新配置生效。校验不通过则保留旧配置、不替换、不重启。
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

## 高级能力

### 1. 应用前配置校验（防"更新即失联"）

每次更新订阅、在替换并重启实例**之前**，先用 `mihomo -t -d <dir> -f <new>` 做一次静态校验：

- 校验**通过** → 原子替换 `config.yaml` 并重启实例。
- 校验**失败**（机场返回损坏/残缺配置等）→ 丢弃新配置、**保留旧配置、不重启**，并把错误打到更新日志。

极端情况下若 `mihomo -t` 误报，可临时设 `SKIP_CONFIG_TEST=1` 跳过。

### 2. external-controller 密钥（secret）

为面板/API 访问加一道密钥。优先级：`subs.yaml` 中该 sub 的 `secret` 字段 > 环境变量 `CONTROLLER_SECRET`（对所有实例生效）> 不设置（保持开放）。

### 3. 状态持久化

归一化阶段强制开启 `profile.store-selected: true` 与 `store-fake-ip: true`，容器重启 / 订阅更新后仍保留**手动选择的节点**与 **fake-ip 映射**。配合挂载 `./data/run:/data/run` 即可跨容器生命周期持久化。

### 4. 自定义 override 合并（不被订阅覆盖）

直接在 `subs.yaml` 里给某个 sub 增加 `override:` 块即可，无需额外挂载目录。每次更新订阅后自动合并，自定义内容不会被订阅覆盖。示例见 [`examples/subs.minimal.yaml.example`](examples/subs.minimal.yaml.example)（最简实例）与 [`examples/subs.override.yaml.example`](examples/subs.override.yaml.example)（带内联 override 的实例）。

```yaml
- name: sub-advanced
  sub: http://your-airport/subscribe?token=yyyy
  port: 7390
  override:
    prepend-rules:
      - 'DOMAIN-SUFFIX,internal.example.com,DIRECT'
    hosts:
      '*.dlife.cn': 140.246.46.164
    dns:
      fake-ip-filter:
        - '*.dlife.cn'
```

| override 键 | 作用 |
| --- | --- |
| `prepend-rules` / `append-rules` | 规则置顶（优先匹配）/ 置底（兜底）。优先级：置顶 > 订阅 > 置底 |
| `prepend-proxies` / `append-proxies` | 追加自定义节点 |
| `prepend-proxy-groups` / `append-proxy-groups` | 追加自定义策略组 |
| 其余顶层键（`hosts` / `dns` / `mode` / ...） | 深合并覆盖订阅同名设置（override 优先） |

> - 不要同时用 `prepend-rules`/`append-rules` 和顶层 `rules:`（后者会整表替换，覆盖前者）。
> - 深合并中**数组是整体替换而非追加**（如 `dns.fake-ip-filter` 会替换默认模板那份，需保留的条目请一并写全）。

### 5. DNS / fake-ip 默认模板

默认关闭（`DNS_TEMPLATE=off`），完全沿用订阅自带 DNS。设 `DNS_TEMPLATE=on` 时注入一份离线友好的 fake-ip DNS 模板（含 `fake-ip-filter`、按 `geosite:cn,private` 分流解析）。

- 启用模板：设 `DNS_TEMPLATE=on`（默认 `off`，完全沿用订阅自带 DNS）。
- 模板随镜像内置：源文件为项目内 `templates/dns.yaml`，构建时 `COPY` 到镜像的 `/opt/templates/dns.yaml`。
- 自定义模板：修改项目内 `templates/dns.yaml` 后重新 build，或运行时挂载替换 `/opt/templates/dns.yaml`，或用 `DNS_TEMPLATE_FILE` 指向其它路径。

#### DNS 合并优先级

当「DNS 模板（`DNS_TEMPLATE=on`）」「订阅自带 `dns`」「override 里的 `dns`」同时存在时，优先级（高 → 低）为：

```
归一化强制项  >  override.dns  >  订阅自带 dns  >  DNS 模板
```

即 **override 最高、订阅次之、模板垫底**；模板只负责补齐订阅没写的键。`update-sub.sh` 按固定顺序依次深合并（`*` 运算符，右操作数覆盖左操作数），后执行的一步覆盖前一步：

| 步骤 | 动作 | 语义 |
| --- | --- | --- |
| ① 基底 | 下载的订阅配置 | `.dns` = 订阅自带 dns |
| ② 模板合并（仅当 `DNS_TEMPLATE=on`） | `.dns = 模板 * 订阅.dns` | 模板作基底，订阅盖在上面 → **订阅赢**，模板只补订阅缺的键 |
| ③ override 合并 | `. * override` | 当前结果作基底，override 盖在上面 → **override 赢** |
| ④ 归一化 | 强制 `dns.listen = ""` | 最终定稿，谁都覆盖不了（见下） |

所以同名 DNS 键最终取值：有 override 用 override，否则用订阅，再否则用模板；非冲突的键三方累加（深合并取并集）。

> ⚠️ 两个关键点：
> - **数组是整体替换，不是追加**：深合并里映射逐键递归，但数组字段由最高优先级的那一方整体替换。例如 override 写了 `dns.fake-ip-filter: [*.dlife.cn]`，就会把模板的 `[*.lan, *.local]` **整份顶掉**；要保留模板条目必须一并写全（`nameserver` 等数组同理）。
> - **`dns.listen` 永远被清空**：为避免多实例争抢 `0.0.0.0:53`，归一化阶段无条件执行 `.dns.listen = ""`，无论模板/订阅/override 怎么写都无效（fake-ip 仍在实例内部正常工作）。

示例（`DNS_TEMPLATE=on`，订阅与 override 均含 `dns`）：

| 字段 | 模板 | 订阅 | override | 最终值 | 原因 |
| --- | --- | --- | --- | --- | --- |
| `enhanced-mode` | `fake-ip` | — | — | `fake-ip` | 仅模板有，补齐 |
| `nameserver` | `[223.5.5.5]` | `[8.8.8.8]` | — | `[8.8.8.8]` | 订阅赢（数组替换） |
| `fake-ip-filter` | `[*.lan, *.local]` | — | `[*.dlife.cn]` | `[*.dlife.cn]` | override 赢（数组替换，模板那份丢失） |
| `listen` | 任意 | 任意 | 任意 | `""` | 归一化强制清空 |

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
| `CONTROLLER_SECRET` | *(未设置)* | 所有实例 external-controller/面板的默认密钥（可被 `subs.yaml` 的 `secret` 覆盖） |
| `DNS_TEMPLATE` | `off` | `off` 完全沿用订阅自带 DNS；`on` 注入离线 fake-ip DNS 默认模板 |
| `DNS_TEMPLATE_FILE` | `/opt/templates/dns.yaml` | DNS 默认模板路径（镜像内置自 `templates/dns.yaml`，可挂载替换或指向自定义文件） |
| `SKIP_CONFIG_TEST` | `0` | 置 `1` 跳过应用前的 `mihomo -t` 校验（仅用于排查误报，不建议常开） |

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

> 安全提示：`external-controller` 默认监听 `0.0.0.0`。若将 `port+2` 端口对外映射，务必设置密钥——在 `subs.yaml` 为该 sub 配 `secret`，或用环境变量 `CONTROLLER_SECRET` 统一设置；否则请仅在内网访问。
