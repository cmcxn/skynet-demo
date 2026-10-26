# Skynet 使用 pgvector 说明书

本说明适用于本项目的 `skynet_postgrest_client`：Skynet 通过 HTTP 访问 PostgREST，
由 PostgreSQL 的 pgvector 扩展存储向量并执行距离计算。本机 PostgreSQL 和 CloudBase
共用 Lua 代码，差别放在连接配置、数据库初始化及权限中。

## 1. 已经完成了什么

本次没有修改客户端核心实现或已有业务流程，新增的是独立测试、SQL 和说明文档。

- CloudBase 环境 `chenmin-d9gyunevr6418cb9a` 已在 public schema 启用 vector 0.8.2。
- 云端已创建测试表 `skynet_pgvector_test_20261026` 和检索 RPC `skynet_pgvector_match_20261026`。
- 本机使用 `pgvector/pgvector:pg16`，实测 vector 0.8.7。
- 两端通过同一份 Skynet Linux Docker 测试，各 11/11；测试数据已清理。
- 测试资源已准备好，但不会自动给你的业务表增加向量字段，也不会自动生成 Embedding。

扩展、表和函数不是独立进程；数据库重启后仍然存在，不用每次重新安装。
详细测试记录和命令见 [双端验证记录](pgvector-postgrest.md)。

## 2. 三项连接配置

实际密钥文件放在已被 Git 忽略的 `.local/`；不要写进 Lua 或 Dockerfile。

| 变量 | 本机示例 | CloudBase 示例 |
| --- | --- | --- |
| `DB_REST_URL` | `http://postgrest:3000` | `https://<envId>.api.tcloudbasegateway.com/v1/rdb/rest` |
| `DB_REST_TOKEN` | 内部演示允许空值 | 服务端 API Key |
| `DB_TIMEOUT_TICKS` | `3000` | `3000` |

3000 tick 是 30 秒。URL 是 REST 基础地址，不包含表名或 PostgreSQL 连接串。
`postgrest` 仅在相应 Docker 网络中作为服务名使用；同一进程网络命名空间的测试也可使用
`127.0.0.1:3000`，Windows 主机则需要能从该主机实际访问的地址。

云端现有配置位于 `.local/postgrest-cloudbase.env`：

```dotenv
DB_REST_URL=https://你的完整环境ID.api.tcloudbasegateway.com/v1/rdb/rest
DB_REST_TOKEN=你的服务端API密钥
DB_TIMEOUT_TICKS=3000
```

Lua 只读取进程环境，不自行解析 dotenv。Docker 用 `--env-file` / Compose `env_file`
注入，项目 Python 测试入口会读取所选配置文件。Windows 使用相同变量名的 BAT 配置，见
[Windows 指南](postgrest-windows.md)。本轮没有增加 Windows/Wine 的向量检索验证。

## 3. 准备数据库

### CloudBase

现有测试环境已完成本节，无需重复建表。
在其他环境先用控制台 SQL 编辑器或管理 SQL API 查询：

```sql
SELECT name, default_version, installed_version
FROM pg_available_extensions WHERE name = 'vector';
```

可用且尚未安装时执行：

```sql
CREATE EXTENSION vector WITH SCHEMA public;
```

安装状态查询：

```sql
SELECT e.extversion, n.nspname AS extension_schema
FROM pg_extension e
JOIN pg_namespace n ON n.oid = e.extnamespace
WHERE e.extname = 'vector';
```

这只启用当前数据库的扩展，版本由平台提供，并不是启动新的服务。
如果扩展已装在其他 schema，不要重复安装或擅自移动它，应按实际 schema 引用类型和操作符。

本项目的首次初始化入口会检查扩展和已有测试表，再创建缺失的专用测试资源：

```sh
python3 scripts/test-pgvector-postgrest.py --target cloudbase --prepare-cloud
```

该命令需要 Node/npx、Docker 和 `.local/postgrest-cloudbase.env` 中有管理 SQL 权限的密钥。
它也会运行测试。SQL 来源是 [pgvector-setup.sql](../components/skynet-postgrest/tests/pgvector-setup.sql)，
管理 API 每次执行一条语句。已有同名但结构不同的表、或实现不同的函数，需要先检查再处理。

### 自建 PostgreSQL

本机已有 `pgvector/pgvector:pg16`，最直接的完整验证命令是：

```sh
python3 scripts/test-pgvector-postgrest.py --target local
```

脚本自动创建临时数据库、启用扩展、建表、创建 RPC、启动 PostgREST，测试后删除临时容器与网络。
它不会连接或修改你其他 PostgreSQL 容器中的数据库。

长期自建服务按 [Docker 使用说明](postgrest-docker.md)部署，但需要选择包含 pgvector 的数据库镜像。
现有普通 `postgres:16-alpine` 示例不会因为 Lua 包含 `pgvector.lua` 而自动获得服务器扩展。
对于新建数据库可使用 `pgvector/pgvector:pg16` 并执行上述 `CREATE EXTENSION`。
已有数据库应按备份、迁移和镜像兼容流程处理，不要直接覆盖旧数据卷来试验。

CloudBase 中已经有 `service_role`。本机临时测试会创建同名 BYPASSRLS 角色，
作为不发布宿主机端口的演示 PostgREST 角色；这一设置仅用于验证，生产服务应使用自己的认证和权限方案。

## 4. 表结构与权限

当前测试表的结构为：

```sql
CREATE TABLE public.skynet_pgvector_test_20261026 (
    run_id text NOT NULL,
    label text NOT NULL,
    embedding public.vector(3) NOT NULL,
    PRIMARY KEY (run_id, label)
);
```

`run_id` 用来隔离每轮测试，`label` 是同一轮中唯一的样本名，`embedding` 是三维向量。
已有表不要再次执行 CREATE TABLE。生产业务通常改成文档 ID、正文、owner 和向量字段，
使用自己的表名、检索函数和迁移流程。

云端测试表开启 RLS，显式给 `service_role` 授予 CRUD。检索函数使用 SECURITY INVOKER，
撤销 PUBLIC 的默认执行权限，再授权 `service_role`。API Key 只用于服务端；
当前测试没有覆盖普通用户 JWT 和用户间行权限。`run_id` 过滤是测试范围约束，不是用户身份认证。

## 5. 在 Skynet 中写入、读取、更新和删除

以下片段要在 Skynet 服务的 `skynet.start` 回调或正常业务请求中运行，不能直接交给独立 Lua 解释器。
环境变量先由启动进程注入，初始化在每个服务启动时做一次：

```lua
local db = require('skynet_postgrest_client').new()
local vector = require 'pgvector'
```

本机与 CloudBase 的这些调用完全相同。以下示例使用已存在的测试资源，
`run_id` 应由业务或调用方生成，保证本轮唯一，避免重复执行时主键冲突：

```lua
local run_id = '替换为本轮唯一ID'

-- REST 的 vector 输入使用文本字面量，最终是 JSON 字符串 "[1,0,0]"。
local inserted = db:from('skynet_pgvector_test_20261026'):insert {
    run_id = run_id,
    label = 'document-a',
    embedding = vector.serialize {1, 0, 0},
}:execute()

local rows = db:from('skynet_pgvector_test_20261026'):select()
    :filter {run_id = run_id, label = 'document-a'}
    :execute()
local embedding = vector.deserialize(rows[1].embedding)

local updated = db:from('skynet_pgvector_test_20261026'):update {
    embedding = vector.serialize {0, 1, 0},
}:filter {run_id = run_id, label = 'document-a'}:execute()

-- 删除时保留范围条件；不要无条件清空整张表。
local deleted = db:from('skynet_pgvector_test_20261026'):delete()
    :filter {run_id = run_id, label = 'document-a'}
    :execute()
```

初始化器统一发送 `Prefer: return=representation`，写入、更新、删除可以读取返回记录。
HTTP 或数据库错误会抛出 Lua 异常；业务层应用 `pcall` / `xpcall` 处理并脱敏记录错误。
每次创建新的查询对象，不反复 execute 同一个构造器。

## 6. 相似度检索：调用 RPC

本项目固定的上游客户端没有 `db:rpc()` 方法。可以复用 POST builder，
向 PostgREST 的 `rpc/<函数名>` 路径发请求；两端已经实测通过：

```lua
local nearest = db:from('rpc/skynet_pgvector_match_20261026'):insert {
    query_embedding = vector.serialize {0.9, 0.1, 0},
    test_run = run_id,
    metric = 'cosine',
    match_count = 5,
}:execute()

for _, row in ipairs(nearest) do
    print(row.label, row.distance)
end
```

检索前需先在同一 `run_id` 下插入候选记录；上节最后的 delete 只是清理示例，
实际流程是在检索完成后删除测试数据。返回结果已经按距离升序排序。

| metric | 数据库运算符 | distance 含义 | 排序 |
| --- | --- | --- | --- |
| `l2` | `<->` | 欧氏距离 | 越小越近 |
| `cosine` | `<=>` | 余弦距离 | 越小越近，相似度可表示为 `1 - distance` |
| `inner_product` | `<#>` | 负内积 | 越小代表内积越大 |

检索函数只看 `test_run` 对应的记录，返回条数限制在 1～20；找不到候选时返回空数组。
函数 SQL 见 [pgvector-setup.sql](../components/skynet-postgrest/tests/pgvector-setup.sql)。
生产使用时应创建针对自己表结构、权限和索引的检索函数，而不是让业务依赖这个日期命名的测试表。

## 7. 接入真正的 Embedding

三维样本仅用于确认链路与数学结果。语义搜索的实际流程为：

1. 用选定的 Embedding 模型将文档转成数值数组并写入向量列。
2. 用同一模型将用户查询转成向量。
3. 调用数据库检索 RPC，返回匹配的文档。

数据库 `vector(n)` 的 n 必须等于模型输出维度，写入与查询要使用相同模型和相同处理规则。
余弦检索应避免零向量。切换模型或维度时，需要相应数据迁移或重建 Embedding，
不是只改 REST URL。本次脚本不调用模型服务。

当前示例使用 CASE 选择度量，验证的是小样本精确搜索。大规模近似搜索需要单独设计
HNSW/IVFFlat 索引及查询，并用 EXPLAIN 和真实数据验证索引命中和召回效果。

## 8. 复跑与排查

```sh
# 两端：自动创建本机临时服务，云端复用已准备资源
python3 scripts/test-pgvector-postgrest.py

# 只测某一端
python3 scripts/test-pgvector-postgrest.py --target local
python3 scripts/test-pgvector-postgrest.py --target cloudbase
```

成功时各端输出 `PASS ...: 11/11`。云端结束后还会检查测试表剩余记录为 0。
结果日志位于 `.local/pgvector-postgrest-results/`，不提交到仓库。
默认 Skynet 镜像为 `skynet-demo:postgrest`，可用 `POSTGREST_SKYNET_IMAGE` 覆盖；
自建数据库镜像默认 `pgvector/pgvector:pg16`，可用 `PGVECTOR_TEST_IMAGE` 覆盖。
测试从源码挂载运行，不代表已把这一新增向量测试自动加入此前发布的 Docker/Windows 产物。

| 现象 | 检查项 |
| --- | --- |
| vector 类型不存在 | 当前数据库是否启用扩展、实际安装 schema 是否正确 |
| 维度错误 / HTTP 400 | 表维度与写入、查询向量长度是否一致 |
| 表或 RPC 不存在 | 是否在对应环境完成建表及函数创建；检查 PostgREST schema cache |
| 401 / 403 | URL 是否对应正确环境、密钥是否有效、角色是否有表和函数权限 |
| 有表但读取为空 | 查询范围是否正确、RLS 是否允许当前用户读取 |
| 唯一约束冲突 | 同一 run_id 下是否重复写入相同 label |
| 本机连不上 | Docker 是否运行、REST 地址是否在 Skynet 所在网络内可达 |

需要检查原始错误时应避免打印完整密钥和请求头；保留 HTTPS 证书及主机名校验。
