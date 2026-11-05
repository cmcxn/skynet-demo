# Skynet PostgreSQL 与 pgvector

将 mao 项目的 PostgreSQL 库直接纳入本仓库维护，保留 `require "pgmoon"`、
`require "pgvector"` 和 `require "sha2"` 接口。支持 Lua 5.5、Linux Docker、Linux
原生构建及 Windows x64 便携包，不依赖 LuaSocket、OpenResty 或系统安装的 Lua。
来源、原文件 SHA-256 及许可证见 [SOURCES.md](SOURCES.md)、
[SOURCE-SHA256.json](SOURCE-SHA256.json) 和 [LICENSE](LICENSE)。不是 Git 子模块；
原远端仓库删除不会影响本仓库已有代码的克隆与构建。

## 安装

从项目根目录执行 `docker compose build`，重建容器后即可使用；Windows 用
`./scripts/build-windows.sh` 重新生成并完整替换便携包；Linux 原生用
`sh scripts/build-native.sh`。这些构建都会安装 `lualib/pgmoon/`、`pgvector.lua`、
`sha2.lua` 与 `luaclib/skynet_postgres_native.so`，并携带来源和许可证。
Windows 的 `.so` 实际为 PE DLL，必须与同包的 Lua/DLL 配套使用。

独立接入其他 Skynet 项目时，复制本组件的 `lualib/` 到运行时的 `lualib/`，再执行：

```sh
make -C components/skynet-postgres LUA_INC=/path/to/skynet/3rd/lua OUT_DIR=/path/to/runtime/luaclib
```

需要 OpenSSL 3 开发包、C 编译器和对应 Lua 头文件；JSON 功能需要本项目已经包含的
`cjson`。原生模块独立于 `skynet-llm`，没有对 LLM 服务或其 TLS DLL 的运行时依赖。

## 连接与参数化查询

以下代码在 Skynet 服务内运行，数据库账号由进程环境传入，不能把密钥写入仓库。
连接建立及查询必须检查返回值；失败返回 `nil, error`，不会自动重放 SQL。

```lua
local skynet = require "skynet"
local pgmoon = require "pgmoon"

skynet.start(function()
    local pg = pgmoon.new {
        host = assert(os.getenv("PGHOST")),
        port = tonumber(os.getenv("PGPORT") or "5432"),
        database = assert(os.getenv("PGDATABASE")),
        user = assert(os.getenv("PGUSER")),
        password = assert(os.getenv("PGPASSWORD")),
        ssl = true,                -- 默认已启用，验证证书链及目标 DNS/IP SAN
        cafile = os.getenv("PGSSLROOTCERT"), -- 私有 CA；nil 使用默认信任库
        timeout = 5000,             -- 毫秒：完整 connect/auth 或单次 query 的总预算
    }
    local connected, err = pg:connect()
    if not connected then
        skynet.error("数据库连接失败:", err)
        skynet.exit()
        return
    end

    local rows, query_err = pg:query("SELECT $1::text AS name, $2::int AS score", "Alice", 42)
    if rows then
        skynet.error(rows[1].name, rows[1].score)
    else
        skynet.error("查询失败:", query_err)
    end
    local closed, close_err = pg:disconnect()
    if not closed then skynet.error("关闭连接失败:", close_err) end
    skynet.exit()
end)
```

`PGHOST` 等变量在上面的示例代码中读取，库不会自动加载这些环境变量。
Compose 也不会自动传递数据库账号，应在自己的部署配置中显式注入。
带参数的 `query(sql, ...)` 使用 PostgreSQL 扩展查询协议；值用 `$1`、`$2` 占位，
不要拼接外部输入。占位符只能替代值，不能替代表名/列名；动态标识符应先使用业务
允许列表，再用 `pg:escape_identifier(name)`。无参数时使用简单查询协议。

普通 SQL NULL 默认解码为缺失字段（Lua `nil`）；需要保留 NULL 时设置
`convert_null = true`，结果使用 `pgmoon.Postgres.NULL` 哨兵。参数使用该哨兵可显式
写入 NULL。支持 JSON/JSONB、数组、bytea 等原 pgmoon 编解码功能。

## TLS 与认证

- 默认 `ssl=true`，PostgreSQL SSLRequest 被拒绝时直接失败，不降级为明文。
- 强制校验证书链和 DNS 主机名/IP SAN；`ssl_verify=false` 被拒绝。最低 TLS 1.2。
- `cafile` / `capath` 指定自定义 CA，替换默认信任来源；目录需 OpenSSL 哈希索引。
- 连接 IP 与证书域名不同时，可显式设置 `ssl_server_name="db.example.com"`，验证该
  身份；不要把这项设置为与实际服务无关的名称。
- Linux 默认使用 OpenSSL 信任来源，支持 `SSL_CERT_FILE` / `SSL_CERT_DIR`。
  Windows 从便携包根目录启动，默认使用 `certs/ca-bundle.crt`；显式 CA 参数和上述
  环境变量优先。Windows 不读取系统证书库。
- 使用 OpenSSL 安全随机数与 SHA-256/HMAC/PBKDF2 完成 SCRAM-SHA-256，Windows
  不依赖 `/dev/urandom`。支持旧 MD5 认证，但建议数据库使用 SCRAM。
- 当前不支持 SCRAM-SHA-256-PLUS/channel binding；服务器同时提供普通 SCRAM 时
  选择普通 SCRAM，但仍保留 TLS 证书校验。只提供 PLUS 时返回错误。
- 暂不支持客户端证书/mTLS；不要传入原 LuaSec/cqueues 的 SSL 选项期望它们生效。
- 隔离的本地数据库可显式设置 `ssl=false`；这会让数据库协议和数据明文传输。
  `http_proxy`、`https_proxy` 对 PostgreSQL TCP 连接没有作用。

构建保留本项目 CA 安全门禁。运行时注入的私有 CA 或替换的公共 CA 需单独审计。

## DNS 与 Windows 网络

Linux 默认使用 Skynet 异步 DNS 与 `/etc/resolv.conf`。Windows 通过原生
`GetNetworkParams` 发现系统 IPv4 DNS，不依赖该 Unix 文件；发现失败时返回明确错误。
自定义 DNS 可在启动进程前设置 `SKYNET_POSTGRES_DNS_SERVER=192.168.1.1`（也可带
`:53` 端口）。此设置在当前服务首次解析域名时读取，并配置该服务共享的 Skynet
DNS 解析器；HTTP 等同服务内使用该解析器的客户端也会受影响。
Windows 可从 `ipconfig /all` 查找本机/VPN 使用的 DNS；填写可达的 DNS 地址，
避免用公共 DNS 查询企业内网域名。直接连接 IP 时无需 DNS 配置。

初始化顺序：应在该服务进行其他 DNS 查询前，先建立本组件的首个域名连接。
Skynet 的 `dns.server()` 不会立即重连已经打开的 DNS UDP socket；如果 HTTP 等
客户端先使用了解析器，随后设置的 DNS 地址可能要等旧 socket 退休后才生效。
建议数据库使用独立 worker 服务，启动时统一配置，不要在运行中切换 DNS。

## 超时、错误与并发

`timeout` 和 `pg:settimeout(ms)` 单位均为毫秒，必须为 1–2147483647 的整数，默认 30000。
预算分别覆盖整个连接流程（DNS、TCP、TLS、认证）或一次完整查询/通知等待，
不是每读一个数据包就重新计时。Skynet 定时精度约为 10 毫秒，不是硬实时保证。
DNS 使用 Skynet 异步解析；调用方超时后立即返回，共享解析器自身的在途查询可继续结束。

超时、TLS/网络异常、截断消息会关闭 fd 和 TLS 资源，返回 `nil, error`；再次查询会提示
未连接。可以显式 `pg:connect()` 重连，但不能据此认定上一次 SQL 没有执行。
例如 INSERT 超时后服务端可能已经提交，业务应使用幂等键或查证结果，不能盲目重试。
普通 SQL 错误会消费协议直到 ReadyForQuery，连接仍可用；事务出错后通常需 ROLLBACK。

同一个连接同时只允许一个协程操作，重叠查询/通知等待返回 `connection is busy`。
`simple_query`、`extended_query`、`wait_for_notification` 也遵循此规则。
每个 worker 使用独立连接，或用 `skynet.queue` 串行管理同一连接。
不提供 nginx keepalive 池；`keepalive()` 返回不支持，使用 `disconnect()` 显式关闭。
不要修改 `pg.sock` 或直接调用底层协议读写方法。
单帧默认最多 16 MiB，可通过正整数 `max_message_bytes` 调整；它不是整个结果集上限。

## 事务封装（推荐）

`require "pgmoon.db"` 提供应用持有的单连接封装。连接只保存在闭包内，不暴露
`pg`、`sock`、原始查询入口或可替换的队列。`connect`、普通 `query`、整个
`transaction` 和 `disconnect` 共用一个 `skynet.queue`；事务持锁直到提交/回滚及
连接清理结束。它不是连接池，不做自动重连、自动重试或 RPC 分发。

```lua
local database = require "pgmoon.db"
local db = database.new {
    host = assert(os.getenv("PGHOST")),
    database = assert(os.getenv("PGDATABASE")),
    user = assert(os.getenv("PGUSER")),
    password = assert(os.getenv("PGPASSWORD")),
    ssl = true,
    cafile = os.getenv("PGSSLROOTCERT"),
    timeout = 5000,
}
assert(db:connect())

local ok, value, commit = db:transaction(function(tx)
    local rows, err = tx:query(
        "UPDATE players SET score=score+$1 WHERE id=$2 RETURNING score", 10, 42)
    if not rows then error(err) end
    if #rows == 0 then tx:abort("player not found") end
    return rows[1].score
end, {
    timeout = 5000,
    statement_timeout = 3000,
    idle_timeout = 3000,
    cleanup_timeout = 1000,
})
if ok then
    print("已提交，分数:", value)
    -- commit.connection_usable=false 时，提交仍已确认，但连接已丢弃。
else
    local err = value
    print(err.kind, err.phase, err.outcome, err.message, err.sqlstate)
    if err.cleanup_error then print("清理失败:", err.cleanup_error.message) end
    -- outcome=unknown 时需要业务查证；不要重放事务。
end
assert(db:disconnect())
```

接口约定：

- `database.new(config)` 复制配置并创建未连接的封装；配置约束沿用 pgmoon。
- `db:connect()` / `db:disconnect()`：成功 `true`，失败 `nil, error_table`。
  丢弃连接后可显式重新 `connect()`；这不意味着前一次写入没执行。
- `db:query(sql, ...)` / `tx:query(sql, ...)`：成功 `rows, nil, metadata`，
  失败 `nil, error_table`。无行命令也可能按原驱动返回 `true`。
- `db:transaction(callback, options)`：成功 `true, callback_value, metadata`，
  失败 `false, error_table`。只取回调的**第一个**返回值；`nil` 或 `false` 都是合法的
  成功值，不表示回滚。需要取消时用 `tx:abort(reason)`，不是 `return false`。
- `tx:abort(reason)` 记录取消并抛出内部信号；即使回调捕获它，事务也必须回滚。
  回调异常保存在 `error.cause`；失败后仍保留首个主要错误和独立 `cleanup_error`。
- 任意 `tx:query` 失败都会将事务标记为只能回滚，后续查询直接拒绝；忽略返回值、
  `pcall` 捕获、甚至回调正常返回，都不能清除该状态。
- 不支持嵌套事务/savepoint。回调所属协程不能绕过 `tx` 调用 `db` 方法。
  `tx` 不能交给另一协程，回调结束后立即失效；误用会返回 context 错误。
  其他协程调用普通 `db` 方法会排队。回调不要等待另一协程/RPC 对同一 `db` 的操作，
  否则会形成应用层死锁；外部等待不受数据库查询定时器中断。

参数对象的 `pgmoon_serialize(value, context)` 仍受支持，但封装只传入含本地
`NULL` 的值上下文，绝不把私有连接传给序列化器。内置数组（含嵌套序列化器）和
pgvector 参数保持可用；依赖原始连接方法的自定义序列化器需要改为纯值编码。
序列化期间也不能重入 `db` 方法。这里不防护同进程恶意 Lua 对 debug/模块全局的篡改。

### 单语句与 SQL 安全边界

封装始终调用扩展查询协议，**没有参数时也一样**。PostgreSQL 的 Parse 阶段拒绝
多条语句，不能使用 `INSERT ...; COMMIT` 绕过封装；不是靠正则拆分分号。
带引号/美元引用字符串中的分号、合法注释和单个末尾分号仍由 PostgreSQL 正确解析。

本地扫描器只跳过开头的空白、行注释和嵌套块注释，再检查首关键字。允许：
`SELECT INSERT UPDATE DELETE MERGE WITH VALUES TABLE CREATE ALTER DROP TRUNCATE
COMMENT EXPLAIN ANALYZE REFRESH`。直接事务控制、`SET/RESET/DISCARD`、
`PREPARE/EXECUTE`、`CALL/DO`、`COPY` 和其他入口拒绝；扩展协议暂不支持的命令不要
为了绕过检查而拼接到后面。封装另检查 ReadyForQuery 是否符合预期事务状态。

这是**可信应用 SQL 的生命周期约束，不是不可信 SQL 沙箱**。例如 SELECT 可以调用
有副作用的函数或 `set_config`；允许的 DDL 也可能改变数据库对象。封装不审核函数体、
触发器、扩展、数据库权限或外部副作用，更不保证它们全部可以回滚。不要接受用户直接
提交的 SQL；业务值必须参数化，标识符使用允许列表。需要不受这些限制的管理 SQL、
LISTEN/NOTIFY 或自定义驱动注册时，使用另一个显式管理的原始连接，不与此封装共用。

### 结果分类与协议元数据

原始 `pg:query` / `simple_query` / `extended_query` 保留既有第 1–6 返回值，追加固定
第 **7** 返回值 `metadata`（成功和失败都有），不会以错误文本猜测网络故障：

- `sqlstate`：服务器 ErrorResponse 的 SQLSTATE（如 `23503`、`57014`）。
- `command_tags` / `command_tag`：全部/最后一个 CommandComplete 原始标签。
- `ready_for_query`：已收到的 `I`（空闲）、`T`（事务内）、`E`（事务失败），未收到为 nil。
- `failure_source`：`server/client/transport/timeout/protocol`；成功时为 nil。
- `transport_failure_source`：服务器错误之后又丢失连接时保留后续故障来源。
- `send_attempted`：是否尝试发送。true 不证明服务器收到或执行，也不能用于安全重试。
- `connection_usable`：当前传输仍可使用。原始驱动处于 T/E 时仍可用但不代表可提交；
  busy 拒绝时也可能为 true，但并不授予另一个调用者使用权。

封装错误字段包含 `kind/message/phase/outcome/sqlstate/metadata`。提交时：

- 收到 `CommandComplete COMMIT`：`true, value, metadata`，`outcome="committed"`。
  即使之后丢失 ReadyForQuery，仍是已确认提交；只丢弃连接，并将 `connection_usable`
  设为 false。不能把它误报成 unknown，不能重试。
- 明确的服务器 COMMIT 错误（例如延迟外键约束）或 `CommandComplete ROLLBACK`：
  `false, error`，`outcome="not_committed"`。
- COMMIT 已尝试发送，但没有上述明确证据便断线/超时：`outcome="unknown"`，
  丢弃连接且不重试。业务需凭幂等键、唯一流水号或独立查询查证。
- COMMIT 前的事务失败：不会发送 COMMIT，尝试回滚，保留主要错误与清理失败。
  普通 `db:query` 在发送后丢失结果也可能是 unknown，不意味着写入没有生效。

### 超时与清理

所有 options 都是 1–2147483647 的整数毫秒（上限避免 Skynet 定时器溢出）。`timeout` 默认取连接 timeout（未配置为 30000），
从获取队列锁后、BEGIN 前开始计时，**不包含排队时间**。每次数据库操作取连接超时与
事务剩余预算的较小值，回调返回/再次查询时检查总预算，超时后禁止 COMMIT。
这不是可抢占的 Lua 执行期限：CPU 死循环、外部 RPC/任意 yield 不能被它强制结束。
Skynet 约 10ms 精度也不构成硬实时保证。

`statement_timeout`、`idle_timeout` 默认取事务 timeout，通过 `set_config(...,true)`
仅在当前事务设置，分别限制数据库语句和空闲事务；不计队列等待，也不代替应用预算。
异常/回滚后局部设置恢复。`cleanup_timeout` 默认 `min(连接 timeout, 5000)`，为回滚
提供独立预算，以便主预算耗尽后仍能清理。无法确认空闲状态的连接会丢弃，之后的
排队调用得到未连接错误，不会自动连上新连接继续一段旧事务。

### 原始 pgmoon 与 RPC NULL

直接 `require "pgmoon"` 仍允许 BEGIN/COMMIT 和无参数简单查询，原有用法兼容。
原始连接的 busy 保护只覆盖单次操作；若业务自行管理原始事务，所有使用该连接的
入口仍必须共用同一个队列，不能只锁事务入口。回归测试保留未保护的交错示例。

本封装不是跨服务事务/RPC 接口，回调和 `tx` 只能在拥有该连接的 Skynet 服务内执行。
`pgmoon.Postgres.NULL` 是本 Lua 状态内的表身份；复制或 RPC 序列化后的普通表不是
同一个值，会被拒绝为不支持的参数。RPC 边界应由业务定义可校验的 NULL 标记，并在
接收端还原成本地哨兵；不要把任意空表或 `{"NULL"}` 自动当作 NULL。
也可传 nil 并显式保存参数个数，例如 `params.n=3`，使用
`table.unpack(params, 1, params.n)`，不能依赖 `#params` 保留尾部 nil。
直接 `db:query(sql, value, nil, nil)` 和 `tx:query` 都保留这两个 NULL 参数。

## pgvector

数据库管理员先安装服务器端 pgvector 扩展，并在目标数据库执行
`CREATE EXTENSION vector`。Lua 模块本身不会安装服务器扩展。

```lua
local vector = require "pgvector"
vector.setup_vector(pg) -- 每个连接注册一次，须在扩展存在后执行
assert(pg:query("CREATE TEMP TABLE items (id int, embedding vector(3))"))
assert(pg:query("INSERT INTO items VALUES ($1,$2)", 1, vector.new {1, 0, 0}))
local rows = assert(pg:query(
    "SELECT id, embedding FROM items ORDER BY embedding <-> $1 LIMIT 5",
    vector.new {0.9, 0.1, 0}
))
```

支持 `vector.new`（稠密向量）、`vector.halfvec` 和 `vector.sparsevec`；后两种类型
需要服务器扩展支持。`vector.sparsevec({[1]=1,[3]=2},3)` 的索引从 1 开始，最后
一个参数是维度。接收到的三种向量都能再次作为查询参数，稀疏向量按索引顺序序列化。
维度及数值必须符合数据库列类型；向量索引（HNSW/IVFFlat）的创建和参数由业务负责。

## LISTEN / NOTIFY

```lua
assert(pg:query("LISTEN app_events"))
local notification, err = pg:wait_for_notification()
-- 成功返回 {operation="notification", pid=..., channel=..., payload=...}
```

等待同样受 `settimeout` 限制，并独占连接。长期监听应使用独立连接，超时后按业务
策略重连并重新 LISTEN；不要在该连接等待期间从其他协程查询。

## 测试

项目根目录执行：

```sh
sh scripts/test-postgres.sh
```

脚本构建程序镜像及测试工具镜像，在独立 Docker 网络启动临时 PostgreSQL + pgvector
（固定镜像 digest）与协议故障服务器。使用临时密码、私有 CA 和临时数据目录，
不映射数据库端口，不连接现有业务数据库；退出后删除测试容器、网络和证书。
需要 Docker、可用网络（首次拉取镜像）和足够的镜像构建空间。

脚本还运行 `tests/protocol-regressions.lua` 中的协议回归。它使用实际驱动源码和
内存 socket，不依赖数据库、Skynet 进程或原生模块，可用 Lua 5.5 单独运行：

```sh
LUA_PATH='components/skynet-postgres/lualib/?.lua;components/skynet-postgres/lualib/?/init.lua;;' \
  lua components/skynet-postgres/tests/protocol-regressions.lua
```

`tests/transactions.lua` 另用可控连接故障验证事务状态机；共享队列的协程行为由真实
Skynet 集成测试验证。只跑状态机时，Lua 路径还需要包含 Skynet 的 `lualib/?.lua`。
提交应答后断线、明确拒绝后断线、未知提交及序列化器隔离也使用实际驱动的内存 wire
测试覆盖；这些故障注入不声称等同于真实网络中的所有断线时序。

真实数据库回归额外覆盖服务端错误包含 `read timeout` 时连接仍可复用、尾部 nil/NULL
参数、复制 NULL 标记的明确拒绝、COMMIT 时延迟外键约束失败，以及上述跨协程事务边界。
服务端明确返回的 COMMIT 错误不等同于网络断开造成的提交结果未知。

复用已构建镜像可设置 `PG_SKIP_BUILD=1 PG_TEST_IMAGE=your-image`；测试工具单独使用
`components/skynet-postgres/tests/Dockerfile.tools`，可通过 `PG_TEST_TOOLS_IMAGE` 替换，
复用时加 `PG_SKIP_TOOLS_BUILD=1`。`PG_DB_TEST_IMAGE` 可替换数据库镜像，需包含 pgvector。

增加 Windows/Wine 或 Linux 原生运行时验证：

```sh
PG_SKIP_BUILD=1 PG_WINDOWS_RUNTIME=/absolute/path/to/windows-package sh scripts/test-postgres.sh
PG_SKIP_BUILD=1 PG_NATIVE_RUNTIME=/absolute/path/to/native-runtime sh scripts/test-postgres.sh
```

Windows 测试默认复用项目 Wine 10 镜像。每次在一次性容器内创建 Wine prefix，
由容器当前用户拥有，随容器退出删除，不复用宿主目录。
两类附加测试都运行同一组真实数据库用例。Wine 通过不代表已完成 Windows 实机验证。


2026-10-22 验证结果：Linux Docker、Linux 原生运行时、Windows/Wine 均通过 32 组
真实数据库集成用例，覆盖 SCRAM、证书拒绝、DNS、参数化 SQL、NULL/JSON/数组/bytea、
事务、三种向量、通知等待、并发与重入拒绝、超时重连及畸形协议。加密已通过标准
向量测试；现有 HTTP 代理 49/49、TLS/WSS、CA 门禁、LLM mock 和 TCP Demo 回归通过。

2026-11-05 防回归验证：当前固定子模块和补丁构建的 Linux 原生运行时，在独立
PostgreSQL 16.11 + pgvector 0.8.1 上通过全部 38 组集成用例、7 组协议回归和原生
加密/编解码单元测试。临时注入错误文本误丢连接、尾部 nil 丢失、错误结果未知标记、
移除共享队列四种变更，均触发对应测试失败；测试后恢复原源码并重新通过。
本次环境没有 autoconf，构建使用 `NOUSE_JEMALLOC`/系统 malloc；没有可查询的
ca-certificates 包记录，因此仅关闭包版本检查，实际 CA 证书链的 12 条回归仍通过。
本次没有重跑 Docker、Windows/Wine 或 Windows 实机验证。

2026-11-05 方案 B 实现验证：在上述 Linux 原生运行时和独立 PostgreSQL 16.11 +
pgvector 0.8.1 上通过 **52 组真实集成、27 组协议回归、19 组事务状态机**，以及原生
加密/编解码单测。独立代码审查发现的序列化器连接泄露、错误对象格式化、晚超时连接
退休和超大超时值均已补失败回归并修复。Lua 语法、shell 语法与 diff 检查通过。
本环境没有 Docker，标准 `scripts/test-postgres.sh` 因 `docker: not found` 无法启动；
未重跑 Docker、Windows/Wine 或 Windows 实机。无自动重试、PR、合并或部署。


## CI 中的 PostgreSQL 门禁

Docker 工作流在 AMD64、ARM64 各自构建后，先检查镜像内 `pgmoon.db` 的加载与
`new` 入口，再以 `PG_SKIP_BUILD=1` 对**同一个刚构建的镜像**运行
`scripts/test-postgres.sh`，通过后才可导出供发布使用的镜像。测试失败不跳过。

Windows 工作流先构建便携包，然后在固定版本 Wine 测试镜像中，用该包的 Windows
Lua/Skynet 程序连接隔离的临时 PostgreSQL + pgvector。成功后才审计并封装 ZIP。
随后 native-test 使用 ZIP 内的 Lua 运行 `tests/postgres/` 下的原生单元测试、协议
回归和事务状态机，并在 Windows Skynet 服务内显式加载 `pgmoon.db`。
这里的真实数据库 Windows 二进制验证在 Wine 中执行，不等同于 Windows 实机数据库集成。

包审计明确要求事务模块、完整 pgmoon 依赖、`skynet.queue`、pgvector、sha2、原生
PostgreSQL 模块和三份离线测试。只把 `unit.lua`、`protocol-regressions.lua`、
`transactions.lua` 放入 ZIP 的 `tests/postgres/`，不携带数据库集成配置、测试证书、
密码或数据库夹具。临时数据库和 Wine prefix 不进入分发包。

以下检查不需要 Docker，可直接在仓库根目录运行；它们检查配置/打包门禁，不能代替
真正执行 Docker、Wine 或原生 Windows 作业：

```sh
python3 tests/test-postgres-ci.py
python3 tests/test-windows-postgres-package.py
```

2026-11-05 本地补充验证通过 6 组 CI 配置契约、3 组合成包审计（逐项覆盖 16 个必要
文件缺失和 6 种禁止夹具/配置路径）、Linux 真实服务加载及缺失事务模块的负向门禁。
先前原生运行时通过 52 组真实 PostgreSQL 集成，临时数据库已停止并删除；工作区
恢复后重新编译 Lua 5.5.1 和原生模块，重跑 27 组协议、19 组事务状态机及原生单测。
本地环境没有 Docker、Wine、PowerShell 或 Windows，完整跨平台结果以 GitHub Actions
对应提交的实际运行结果为准。现有触发条件、发布条件与权限未改变；这些修改本身
不授权发布 Docker Hub 镜像、Windows Release 或部署。
