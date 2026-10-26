# Skynet → PostgREST → pgvector 双端验证

配置、建表及完整编程步骤见 [pgvector 使用说明书](pgvector-manual.md)。

本机 PostgreSQL 与 CloudBase PG REST 使用同一份 Skynet Lua 测试、同样的表结构和 RPC。
连接仍只用 `DB_REST_URL`、`DB_REST_TOKEN`、`DB_TIMEOUT_TICKS` 配置，业务查询不区分环境。

## 本次实测（2026-10-26）

| 目标 | 数据库扩展 | 客户端与链路 | 结果 |
| --- | --- | --- | --- |
| 本机 `pgvector/pgvector:pg16` | vector 0.8.7 | Skynet Linux Docker → PostgREST v12.2.12 → PG16 | 11/11 |
| CloudBase `chenmin-d9gyunevr6418cb9a` | vector 0.8.2 | 同一 Skynet Linux Docker → HTTPS PG REST | 11/11 |

CloudBase 原先未启用 vector；本次确认可用版本后，通过管理 SQL API 在 public schema 启用。
创建独立测试表 `public.skynet_pgvector_test_20261026` 和
`public.skynet_pgvector_match_20261026(vector,text,text,integer)`，不修改业务表。
云端表启用 RLS，CRUD 与函数执行显式授权 service_role；函数为 SECURITY INVOKER，
撤销了 PUBLIC 的默认执行权限。此次不验证普通用户 JWT 和行权限。

每端均通过：

1. 三条向量批量插入及返回记录。
2. vector 文本序列化、读取及反序列化。
3. L2 最近邻排序及实际距离值。
4. 余弦距离排序及实际距离值。
5. 内积排序及负内积距离值。
6. RPC 返回数量限制。
7. 按测试 run_id 隔离，其他 run_id 返回空集。
8. 错误维度写入被拒绝且没有新增记录。
9. 非法检索度量被拒绝。
10. 更新向量后最近邻结果改变。
11. 按本轮 run_id 删除并确认查询及 RPC 均为空。

本地临时容器、网络已清理；云端测试记录清零，扩展、表与 RPC 留作复跑。
测试不调用模型服务，不依赖付费 embeddings；使用固定三维样本。
本次是小样本精确检索，不是 HNSW/IVFFlat 索引或性能测试，也不新增 Windows/Wine 向量测试结论。

## 复跑

Docker 需已运行，并具有 Skynet 运行镜像及本机数据库镜像。
默认 Skynet 镜像为 `skynet-demo:postgrest`，可通过 `POSTGREST_SKYNET_IMAGE` 覆盖。
本机数据库镜像默认 `pgvector/pgvector:pg16`，可通过 `PGVECTOR_TEST_IMAGE` 覆盖。
云端使用已有 `.local/postgrest-cloudbase.env`，不需要把密钥写进代码。

```sh
# 两端都测，复用已经准备好的云端表/RPC
python3 scripts/test-pgvector-postgrest.py

# 只测本机：创建隔离的临时数据库与 PostgREST，退出清理
python3 scripts/test-pgvector-postgrest.py --target local

# 只测 CloudBase
python3 scripts/test-pgvector-postgrest.py --target cloudbase

# 首次准备云端扩展与专用测试资源，再测试
python3 scripts/test-pgvector-postgrest.py --target cloudbase --prepare-cloud
```

`--prepare-cloud` 需要 Node/npx 及有管理 SQL 权限的 CloudBase API Key，使用 CLI `tcb db execute`。
脚本先检查已安装扩展和测试表列结构，再创建缺失的专用资源；不会替换已有同名函数。
若已有结构不符或函数实现不符，应检查后处理，不要直接删除现有数据。
SQL 源文件为 `components/skynet-postgrest/tests/pgvector-setup.sql`；每条语句单独提交。
脚本默认从源码挂载运行测试，使用系统 CA 验证云端 HTTPS，强制直连。
脱敏结果位于 `.local/pgvector-postgrest-results/local.log` 与 `cloudbase.log`。

## Lua 写法

pgvector.lua 的文本序列化可复用于 REST 的 vector 输入：

```lua
local db = require('skynet_postgrest_client').new()
local vector = require 'pgvector'

local rows = db:from('skynet_pgvector_test_20261026'):insert{
    run_id = run_id,
    label = 'east',
    embedding = vector.serialize{1, 0, 0}, -- JSON 字符串 "[1,0,0]"
}:execute()

-- 固定上游没有 rpc() 方法，复用 POST builder 调用 PostgREST 的 RPC 路径。
local nearest = db:from('rpc/skynet_pgvector_match_20261026'):insert{
    query_embedding = vector.serialize{0.9, 0.1, 0},
    test_run = run_id,
    metric = 'cosine', -- l2 / cosine / inner_product
    match_count = 3,
}:execute()
```

检索函数在数据库执行距离运算；表过滤接口不能直接表达这些运算。
示例 RPC 用 CASE 选择度量，仅用于验证正确性。生产近似索引检索应设计独立 SQL 查询与索引，
通过 EXPLAIN 确认执行计划，不能将此测试的结果当作大规模搜索性能结论。
