# postgrest-lua × Skynet

自建 PostgreSQL + PostgREST 与 CloudBase PG REST 共用初始化模块、业务查询代码和一份 CRUD 集成测试，只通过配置切换 URL、令牌和超时。Linux Docker 镜像已包含组件和测试；Windows 包尚未验证。

上游 `vendor/postgrest-lua` 为 Git 子模块，固定提交 `8777cac6b2ece5248dbf3157fdc7c45e49efa8c9`，保留原始源码和许可证。`skynet_postgrest.lua` 在私有加载环境中以 Skynet `http.httpc` 代替上游使用的少量 lua-http 接口，不占用全局 `package.loaded['http.request']`。JSON 使用运行镜像中的 cjson。

## Docker 部署

完整的配置、启动、测试和数据管理步骤见 [PostgREST Docker 使用说明](../../docs/postgrest-docker.md)。基础 `compose.yaml` 不要求数据库；按需叠加一个配置：

```sh
# 自建 PostgreSQL + PostgREST + Skynet（先按文档准备三个配置文件）
docker compose -f compose.yaml -f compose.postgrest.yaml up -d --build

# CloudBase PG REST（先准备云端表、权限与配置文件）
docker compose -f compose.yaml -f compose.cloudbase.yaml up -d --build
```

同一 Compose 项目选择一种模式运行。两种模式使用相同业务 API，区别在数据库、认证和运维的管理位置。

## 配置

实际配置放在已从 Git 和 Docker 构建中排除的 `.local/`，无密钥模板位于本目录 `config/*.env.example`。

| 文件 | 用途 |
| --- | --- |
| `.local/postgrest-selfhost.env` | 自建 Compose 的 Skynet REST 配置 |
| `.local/postgrest-db.env` | 自建 PostgreSQL 密码 |
| `.local/postgrest-server.env` | 自建 PostgREST 数据库连接及角色配置 |
| `.local/postgrest-cloudbase.env` | CloudBase URL 和服务端 API Key |
| `.local/postgrest-local.env` | 旧的临时本地测试脚本配置 |

Skynet 仅接收以下三个变量；Lua 不自行读取 dotenv 文件：

| 变量 | 用途 | 自建 Compose 示例 |
| --- | --- | --- |
| `DB_REST_URL` | REST 基础 URL，不带表名 | `http://postgrest:3000` |
| `DB_REST_TOKEN` | Bearer 令牌；内部演示允许空值 | 空 |
| `DB_TIMEOUT_TICKS` | 请求总超时，正整数；1 tick = 10ms | `3000`（30 秒） |

CloudBase URL 为 `https://<envId>.api.tcloudbasegateway.com/v1/rdb/rest`，令牌为具备所需权限的服务端 API Key。当前共享测试使用 `service_role`，尚未验证普通用户 JWT 和行隔离。不要把该密钥放入前端或提交到仓库。

Python 测试入口的配置格式为简单 `KEY=value`，支持整行注释和成对引号，不执行 shell，也不展开变量引用。旧 `.local/cloudbase.env` 不再由新入口读取。

## 业务代码

每个 Skynet 服务启动时初始化一次，随后使用相同接口：

```lua
local client = require 'skynet_postgrest_client'
local db = client.new()
local rows = db:from('skynet_postgrest_test_20261026')
    :select():filter{id=id}:execute()
db:from('skynet_postgrest_test_20261026')
    :update{done=true}:filter{id=id}:execute()
```

镜像将上游 Lua 文件安装到 `/skynet/lualib/postgrest/`，适配器和客户端安装到 `/skynet/lualib/`，测试安装到 `/skynet/tests/postgrest/`。`client.new()` 直接使用已打包模块，无需源码挂载；显式传入上游源码目录的旧用法仍可使用。

初始化统一设置 `Prefer: return=representation`，非空令牌自动添加 Authorization，使用系统 CA 验证 HTTPS，并强制直连。模块不判断部署模式。`httpc` 超时是服务内共享配置，应在初始化时设置，避免运行中反复切换。

## 共用集成测试

Docker 镜像测试命令见部署文档。也可通过 Python runner 验证不挂载宿主机源码的云端调用：

```sh
python3 scripts/test-postgrest-config.py .local/postgrest-cloudbase.env --packaged
```

不传 `--packaged` 时保留源码挂载方式。`sh scripts/test-postgrest.sh` 仍启动临时本地数据库与 PostgREST，使用 `.local/postgrest-local.env`，退出时清理容器和网络；`python3 scripts/test-cloudbase-postgrest.py` 为云端兼容入口。

所有入口共用 `tests/integration.lua`。两端表结构均为 `skynet_postgrest_test_20261026(id text, task text, done boolean)`；本地初始化 SQL 为 `tests/init.sql`，云端建表与授权参考 `tests/cloudbase-setup.sql`。云端启用 RLS，显式授予 `service_role` CRUD，没有新增公开访问策略。

每轮生成 UUID，仅按该 ID 读写、删除测试记录；失败时尝试清理并报告清理失败，保留测试表。不要将此测试改为无条件更新或删除。

## 已有验证记录（2026-10-26）

Docker 打包集成前，在 macOS Docker Desktop 上复用 `skynet-demo:master-64391f7`（Lua 5.5.1），本地临时 PostgreSQL 16 + PostgREST v12.2.12 和 CloudBase PG REST 两端各 8/8 通过，测试命令退出码均为 0；本地临时容器和网络已清理。这是此前源码挂载方式的记录。

本次已成功构建 `skynet-demo:postgrest`；自建模式通过 Compose 运行镜像内测试、CloudBase 模式通过 Compose 及 Python runner 的 `--packaged` 入口运行镜像内测试，两端均 8/8 通过、退出码为 0，全程无需宿主机源码挂载。该记录仅覆盖本机 Docker 构建与运行，不包含 Windows 或多架构验证。

共享的 8 组测试覆盖中文 JSON 插入、指定字段与过滤、中文及空格过滤值编码、更新返回记录、操作符过滤、HTTP 400 错误传播、删除返回记录及删除后空结果。

## 已知边界

- 兼容层仅实现固定上游版本实际使用的 lua-http 接口。
- 保留上游 encodeURI 语义，过滤值中的 `&`、`#` 等保留字符仍可能改变 URL 含义，不应用于不受控输入；生产适配需要按查询参数编码并验证引号与转义规则。
- 上游 execute 会修改 query_parameters；每次使用新查询对象，避免重复附加过滤串。
- 上游错误包含原始响应正文；测试入口对已知令牌脱敏，生产使用仍需统一错误脱敏策略。
- 并发调度、分页、Upsert、RPC、Windows 尚未验证。
