# postgrest-lua × Skynet

本地 PostgREST 与 CloudBase PG REST 共用初始化模块、业务查询代码和集成测试，
只通过配置切换 URL、令牌和超时。当前仍为兼容性试验，尚未纳入发行镜像或 Windows 包。

上游 `vendor/postgrest-lua` 为 Git 子模块，固定提交
`8777cac6b2ece5248dbf3157fdc7c45e49efa8c9`，保留原始源码和许可证。
`skynet_postgrest.lua` 在私有加载环境中以 Skynet `http.httpc` 代替少量 lua-http 接口，
不占用全局 `package.loaded['http.request']`。JSON 使用运行镜像中的 cjson。

## 配置写在哪里

实际配置文件（已从 Git 和 Docker 构建中排除）：

- `.local/postgrest-local.env`：本地临时 PostgREST。
- `.local/postgrest-cloudbase.env`：CloudBase PG REST，含服务端密钥。

仓库中的无密钥模板位于 `config/*.env.example`；新检出时先复制到 `.local/` 对应文件，
再填写云端 URL 和令牌。本次已生成两份实际配置。启动脚本读取所选文件，将下列变量
注入 Skynet 进程；Lua 不自行读取 dotenv 文件。

| 变量 | 用途 | 本地示例 |
| --- | --- | --- |
| `DB_REST_URL` | REST 基础 URL，不带表名 | `http://127.0.0.1:3000` |
| `DB_REST_TOKEN` | Bearer 令牌；本地允许空值 | 空 |
| `DB_TIMEOUT_TICKS` | 请求总超时，正整数；1 tick = 10ms | `3000`（30 秒） |

CloudBase 的 URL 填 `https://<envId>.api.tcloudbasegateway.com/v1/rdb/rest`，
令牌填 API Key。旧 `.local/cloudbase.env` 保留，但新的测试入口不再读取它。
配置采用简单 `KEY=value`，允许整行注释和成对引号，不执行 shell，也不展开变量引用。

## 业务代码

每个 Skynet 服务启动时初始化一次，随后始终使用同一查询接口：

```lua
local client = require 'skynet_postgrest_client'
local db = client.new('/workspace/vendor/postgrest-lua')
local rows = db:from('skynet_postgrest_test_20261026')
    :select():filter{id=id}:execute()
db:from('skynet_postgrest_test_20261026')
    :update{done=true}:filter{id=id}:execute()
```

初始化模块统一设置 `Prefer: return=representation`，非空令牌自动添加 Authorization，
使用系统 CA 证书校验 HTTPS，并强制直连。模块不判断本地或 CloudBase。
`httpc` 超时是服务内共享配置，应在初始化时设置，避免运行中反复切换。
部署时将组件 lualib 加入 Lua 搜索路径，并提供上游代码目录；当前测试挂载在 `/workspace`。

## 分别测试

先启动 Docker 并初始化子模块：

```sh
sh scripts/update-submodules.sh
# 已有运行镜像可跳过构建
docker build -t skynet-demo:master-64391f7 .
```

本地：

```sh
sh scripts/test-postgrest.sh
```

脚本使用 `.local/postgrest-local.env`，启动独立网络、临时 PostgreSQL 和 PostgREST，
退出清理容器与网络，不发布宿主机端口。Skynet 与 PostgREST 共享网络命名空间，
因此本地配置的 `127.0.0.1:3000` 在运行容器中可达。
镜像可通过 `POSTGREST_SKYNET_IMAGE`、`POSTGREST_DB_IMAGE`、`POSTGREST_IMAGE` 覆盖。

CloudBase（已有测试表）：

```sh
python3 scripts/test-postgrest-config.py .local/postgrest-cloudbase.env
# 兼容入口，调用同一 runner 和配置文件
python3 scripts/test-cloudbase-postgrest.py
```

两种方式最终都运行 `tests/config` 和 `tests/integration.lua`。
两端表名、字段与类型均为 `skynet_postgrest_test_20261026(id text, task text, done boolean)`；
本地初始化 SQL 为 `tests/init.sql`，云端建表记录为 `tests/cloudbase-setup.sql`。
云端表启用 RLS，显式授予 service_role CRUD，没有新增公开访问策略。
云端使用 service_role API Key，尚未验证普通用户 JWT 和行隔离。

每轮生成 UUID，仅按该 ID 读写、删除测试记录；失败时尝试清理并报告清理失败，
保留测试表。不要将此测试改为无条件更新或删除。

## 验证记录（2026-10-26）

macOS Docker Desktop，复用 `skynet-demo:master-64391f7`（Lua 5.5.1）。
两端完整测试命令退出码均为 0，各 8/8 通过；本地临时容器与网络已清理。
本地 postgres:16-alpine + postgrest/postgrest:v12.2.12，以及 CloudBase 环境
`chenmin-d9gyunevr6418cb9a`，分别运行完全相同的 8 组测试：

1. 中文 JSON 插入并返回记录。
2. 指定字段查询与过滤。
3. 中文及空格过滤值编码。
4. 更新并返回记录。
5. 操作符过滤。
6. HTTP 400 错误传播。
7. 删除并返回记录。
8. 删除后空结果。

## 已知边界

- 兼容层仅实现固定上游版本实际使用的 lua-http 接口。
- 保留上游 encodeURI 语义，过滤值中的 `&`、`#` 等保留字符仍可能改变 URL 含义，
  不应用于不受控输入；生产适配需要按查询参数编码并验证引号/转义规则。
- 上游 execute 会修改 query_parameters；每次使用新查询对象，避免重复附加过滤串。
- 上游错误包含原始响应正文；测试入口对已知令牌脱敏，生产使用仍需要统一错误脱敏策略。
- 并发调度、分页、Upsert、RPC、Windows 尚未验证。
