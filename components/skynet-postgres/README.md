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

`timeout` 和 `pg:settimeout(ms)` 单位均为毫秒，必须为正整数，默认 30000。
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

## 事务

BEGIN 到 COMMIT/ROLLBACK 必须在同一个连接上，且整个事务由业务队列串行保护：

```lua
local queue = require "skynet.queue"
local serial = queue() -- 在服务初始化时建立，所有使用该连接的调用共用它

local function update_score(pg, player_id, score)
    return serial(function()
        assert(pg:query("BEGIN"))
        local ok, err = pcall(function()
            assert(pg:query("UPDATE players SET score=$1 WHERE id=$2", score, player_id))
            assert(pg:query("COMMIT"))
        end)
        if not ok then
            pg:query("ROLLBACK") -- 网络已断开时也可能失败，不能覆盖原错误
            return nil, err
        end
        return true
    end)
end
```

这里的超时按每次 `query` 计算，不是整个事务的总预算。数据库还可配置
`statement_timeout`、`idle_in_transaction_session_timeout` 等服务端约束。

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

复用已构建镜像可设置 `PG_SKIP_BUILD=1 PG_TEST_IMAGE=your-image`；测试工具单独使用
`components/skynet-postgres/tests/Dockerfile.tools`，可通过 `PG_TEST_TOOLS_IMAGE` 替换，
复用时加 `PG_SKIP_TOOLS_BUILD=1`。`PG_DB_TEST_IMAGE` 可替换数据库镜像，需包含 pgvector。

增加 Windows/Wine 或 Linux 原生运行时验证：

```sh
PG_SKIP_BUILD=1 PG_WINDOWS_RUNTIME=/absolute/path/to/windows-package sh scripts/test-postgres.sh
PG_SKIP_BUILD=1 PG_NATIVE_RUNTIME=/absolute/path/to/native-runtime sh scripts/test-postgres.sh
```

Windows 测试默认复用项目 Wine 10 镜像，prefix 保存在 `.local/postgres-wineprefix/`。
两类附加测试都运行同一组真实数据库用例。Wine 通过不代表已完成 Windows 实机验证。


2026-10-22 验证结果：Linux Docker、Linux 原生运行时、Windows/Wine 均通过 32 组
真实数据库集成用例，覆盖 SCRAM、证书拒绝、DNS、参数化 SQL、NULL/JSON/数组/bytea、
事务、三种向量、通知等待、并发与重入拒绝、超时重连及畸形协议。加密已通过标准
向量测试；现有 HTTP 代理 49/49、TLS/WSS、CA 门禁、LLM mock 和 TCP Demo 回归通过。
