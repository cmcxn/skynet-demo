# PostgREST Docker 使用说明

Skynet 的 Linux Docker 镜像内置 postgrest-lua、Skynet 适配器和共享 CRUD 测试。自建 PostgreSQL 与 CloudBase PG REST 使用同一业务 API；`client.new()` 无需传源码路径。基础 `compose.yaml` 可以独立启动，不要求数据库。原有 TCP/sproto Demo 不会自动查询数据库；业务服务调用 `client.new()` 后使用数据库。

以下命令在仓库根目录执行，要求 Docker Compose 可用。首次检出先运行 `sh scripts/update-submodules.sh`。实际配置放在 `.local/`，已排除出 Git 和镜像构建上下文；不要提交密码或 API Key。

| 项目 | 自建 PostgREST | CloudBase |
| --- | --- | --- |
| 运行服务 | Skynet + PostgreSQL + PostgREST | Skynet，连接云端 PG REST |
| 地址 | Compose 网络内 `http://postgrest:3000` | 环境网关 HTTPS URL |
| 鉴权 | 示例为内部 anon，业务需自行配置 | 服务端 API Key / 用户令牌与 RLS |
| 数据管理 | 命名卷、升级及备份由部署者管理 | 云端持久化，应用表和权限仍需管理 |
| 业务代码 | `client.new()` | `client.new()` |

## 自建 PostgreSQL + PostgREST

复制三个配置模板（`cp -n` 保留已有文件，不覆盖已填配置）：

```sh
mkdir -p .local
cp -n components/skynet-postgrest/config/postgrest-selfhost.env.example .local/postgrest-selfhost.env
cp -n components/skynet-postgrest/config/postgrest-db.env.example .local/postgrest-db.env
cp -n components/skynet-postgrest/config/postgrest-server.env.example .local/postgrest-server.env
```

三个文件分别交给 Skynet、PostgreSQL 和 PostgREST。模板使用内部演示密码 `skynet-local-test-password`；如修改，须同时更新数据库文件的 `POSTGRES_PASSWORD` 与服务文件的 `PGRST_DB_URI`。Skynet 文件内容为：

```dotenv
DB_REST_URL=http://postgrest:3000
DB_REST_TOKEN=
DB_TIMEOUT_TICKS=3000
```

这里的 `postgrest` 是 Compose 服务名。数据库连接在 `.local/postgrest-server.env` 中配置，模板值为 `postgres://postgres:skynet-local-test-password@postgres:5432/postgres`。不要将这个带数据库密码的连接串放入 Skynet 配置。

启动并查看状态：

```sh
docker compose -f compose.yaml -f compose.postgrest.yaml up -d --build
docker compose -f compose.yaml -f compose.postgrest.yaml ps
```

此叠加配置启动 PostgreSQL、PostgREST 与 Skynet，不向宿主机发布数据库或 REST API 端口。PostgreSQL 使用持久命名卷 `postgrest_data`（实际卷名通常带 Compose 项目前缀）。首次空卷启动时，初始化 SQL 创建测试表与内部演示用 anon 角色；它不是业务数据库的完整初始化方案。

内部演示允许无令牌 CRUD 测试。生产部署应设计自己的业务 schema、最小权限角色与认证，按实际网络边界配置 TLS，并建立备份和恢复流程。自建模式的数据库升级、权限、数据持久化和备份均由部署者管理。

停止服务并保留数据：

```sh
docker compose -f compose.yaml -f compose.postgrest.yaml down
```

已有卷不会重新执行初始化 SQL，修改环境变量也不会直接修改卷中已有数据库密码。需要变更时应执行数据库迁移或密码更新。只有明确要删除本地演示数据时才使用 `down -v`；该命令会删除本项目的 Compose 卷。

## CloudBase PG REST

复用已有 CloudBase PostgreSQL 环境和 PG REST 入口。先按 [建表及授权 SQL](../components/skynet-postgrest/tests/cloudbase-setup.sql) 在目标环境准备共享测试表；当前方案启用 RLS，显式授予 `service_role` CRUD，未开放公开访问策略。

```sh
mkdir -p .local
cp -n components/skynet-postgrest/config/postgrest-cloudbase.env.example .local/postgrest-cloudbase.env
```

编辑 `.local/postgrest-cloudbase.env`：`DB_REST_URL` 填目标环境的 `https://<envId>.api.tcloudbasegateway.com/v1/rdb/rest`；`DB_REST_TOKEN` 填服务端 `service_role` API Key；`DB_TIMEOUT_TICKS=3000` 表示 30 秒。若文件已存在，直接复用，不要用模板覆盖已填写配置。

```sh
docker compose -f compose.yaml -f compose.cloudbase.yaml up -d --build
docker compose -f compose.yaml -f compose.cloudbase.yaml ps
```

该叠加配置只为 Skynet 加载云端配置，不启动本地数据库或 PostgREST。数据库运行和持久化由云端环境提供；应用表结构、权限、API Key 保管及轮换仍需自行管理。当前共享测试验证服务端密钥调用，未验证普通用户 JWT 与用户间行隔离。

同一 Compose 项目不要同时叠加两种模式。切换前用当前模式的 Compose 命令执行 `down`，再启动另一种；保留自建数据时不要添加 `-v`。

## 运行镜像内的同一份测试

先启动所选模式并确认服务正常。为每轮测试生成唯一 ID：

```sh
RUN_ID=$(python3 -c 'import uuid; print(uuid.uuid4())')
# 自建模式
docker compose -f compose.yaml -f compose.postgrest.yaml run --rm --no-deps \
  -e DB_TEST_RUN_ID="$RUN_ID" skynet sh -ec 'timeout 120 ./skynet tests/postgrest/config'
```

CloudBase 模式替换叠加文件即可：

```sh
RUN_ID=$(python3 -c 'import uuid; print(uuid.uuid4())')
docker compose -f compose.yaml -f compose.cloudbase.yaml run --rm --no-deps \
  -e DB_TEST_RUN_ID="$RUN_ID" skynet sh -ec 'timeout 120 ./skynet tests/postgrest/config'
```

两种命令均运行镜像中的 `/skynet/tests/postgrest/`，不依赖 `/workspace` 或宿主机源码挂载。通过时输出 `PASS: 8 shared PostgREST integration groups`。测试按本轮 UUID 操作 `skynet_postgrest_test_20261026` 中的记录并清理，保留表结构；失败时检查清理结果，避免遗留测试记录。

独立 Python runner 同样支持已打包模式，适合直接访问云端入口：

```sh
python3 scripts/test-postgrest-config.py .local/postgrest-cloudbase.env --packaged
```

runner 默认镜像为 `skynet-demo:master-64391f7`，可通过 `POSTGREST_SKYNET_IMAGE` 覆盖。不传 `--packaged` 时使用原有源码挂载测试方式。自建 Compose 中的 `postgrest` DNS 名只在其网络内有效；在独立 runner 中复用自建配置时，还需用 `--network` 加入对应 Compose 网络。

组件 API、兼容性边界与此前测试记录见 [组件说明](../components/skynet-postgrest/README.md)。

## 本次验证（2026-10-26）

镜像 `skynet-demo:postgrest` 完整构建成功；自建与 CloudBase 的 Compose 入口分别通过镜像内 8/8 组测试，无源码挂载。原有 Demo 三项握手/读写检查通过；自建命名卷停止再启动后保留验证记录，记录随后已清理。本次不包含 Windows 或多架构验证。
