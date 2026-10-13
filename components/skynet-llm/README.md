# skynet-llm

Skynet + Lua 5.4 模型调用组件，支持原生 Chat Completions、Responses、Embeddings 和 Chat/Responses SSE。业务负责工具执行、提示词和会话历史；组件负责模型协议、预算队列、超时、取消、有限重试及 HTTPS 证书校验。

首版在 Linux Docker 中构建和验证。`skynet_llm_tls` 链接 OpenSSL 3，编译时使用运行 Skynet 的 Lua 头文件。Windows x64 便携测试包可通过仓库根目录 `scripts/build-windows.sh` 交叉编译，包含独立 TLS DLL、CA 和测试入口；Windows 实机运行与 macOS 原生构建尚未验证，动态库不能跨平台复制。Skynet Git 子模块检出无需修改。

Skynet v1.8.0 中依赖 Lua 处理 DATA 后再暂停的流控，不能阻止 socket 线程提前积压数据。本仓库 Dockerfile 在编译副本上应用 `patches/skynet-1.8-socket-flow-control.patch`，为模型连接增加按需读取模式：连接建立时就暂停读取，注册 Lua socket 时重放 OPEN 通知且保持暂停；每次许可只接收一批最多 128 KiB 的数据，在投递 DATA 消息前再次暂停；Lua 消费完这批数据后才发下一次许可。普通 socket 仍使用原有读取模式，没有全局 64 KiB 读取限制。最终补丁已通过近 32 MiB 流、多次暂停恢复、延迟 Lua 消费和取消测试及独立复核。

该补丁由本次开发编写，针对固定的 Skynet v1.8.0 提交 `ba64be6f9fa044933c77de1317f466afbade8eaa`，是本组件的非官方扩展；不是下载的现成开源修复，也不是 Skynet 上游发布的补丁。它改动 socket 核心、C/Lua 接口及 Lua socket 适配共六个上游文件，Git 子模块检出保持原样。接入其他项目时需使用配套镜像或移植并验证同等接口；缺少私有读取接口会返回 `unsupported_capability`，不会退回无界读取。升级 Skynet 时需重新审阅、移植和测试补丁。补丁及许可证随镜像放在 `/skynet/licenses/`。

## 接入

把 `lualib/?.lua` 加入项目 `lua_path`、`service/?.lua` 加入 `luaservice`、`luaclib/?.so` 加入 `lua_cpath`。本仓库 Dockerfile 已编译和安装这些文件。独立编译：

```sh
make -C components/skynet-llm LUA_INC=/path/to/skynet/3rd/lua
```

在业务启动服务内初始化一次，其他服务调用 `llm.client("main")` 获取客户端：

```lua
local llm = require "skynet_llm"
assert(llm.start {
    profiles = {
        main = {
            base_url = "https://your-model-server/v1",
            api_key_env = "LLM_API_KEY",
            budget_group = "shared",
            capabilities = {
                chat = true, chat_stream = true,
                responses = true, responses_stream = true,
                embeddings = true, function_tools = true,
            },
        },
    },
    budgets = {shared = {max_inflight = 4, max_queue = 64}},
})
local client = assert(llm.client("main"))
local result, err = client:chat({
    model = "your-chat-model",
    messages = llm.json.array {{role="user", content="你好"}},
    max_completion_tokens = 256,
}, {timeout_ms=30000})
if not result then
    -- err.code / stage / http_status / may_have_executed
    return nil, err
end
local assistant_message = result.data.choices[1].message
```

`base_url` 包含 `/v1` 等基础路径，组件只追加对应端点后缀。API key 从环境变量读取，不能直接写在 profile 中。默认 Bearer 认证；无认证服务显式用 `auth="none"`。HTTP 需要显式 `allow_http=true`。供应商能力必须明确开启，组件不会把不支持的 Responses 自动转换成 Chat。

同一后端的不同 profile 可使用相同 budget_group，共享并发额度。每次请求尝试创建一个私有 worker，清理连接后退出；每个 budget_group 默认最多同时四个请求，超出的请求进入最多 64 项的队列。worker 不复用。优先级 1/2/3，等待时间增加时提升优先级。

## API

```lua
client:chat(body, options)              -- result | nil, err
client:responses(body, options)         -- result | nil, err
client:embeddings(body, options)        -- result | nil, err
client:chat_stream(body, options)       -- stream | nil, err
client:responses_stream(body, options)  -- stream | nil, err
llm.stats()                            -- 节点统计
llm.stop()                             -- 停止并清理节点组件
```

body 是原生 API 请求，保留供应商扩展和原生响应。Responses 使用 `/responses`、顶层 function tool、`text.format`；Chat 使用 `/chat/completions`、嵌套 function tool、`response_format`，两套形状不混用。Responses 默认 `store=false`，状态链需启用 `capabilities.response_state`。

result 包含 `data`（完整原生响应）、`raw_json`（非流式原始 JSON）和 `meta`（关联 ID、供应商 request ID、attempts、排队/总耗时）。工具调用时 content 可以为 null，必须检查 tool_calls/output 项目，不能只读取文本。

本地 options 包含 timeout_ms、queue_timeout_ms、connect_timeout_ms、idle_timeout_ms、priority、request_id、expected_dimensions、retry、cancel_token。这些字段不会发给模型。总超时覆盖排队、DNS、连接、TLS、正文和重试等待。

```lua
local token = llm.cancel_token()
skynet.fork(function()
    local result, err = client:chat(body, {cancel_token=token})
    -- 使用结果
end)
-- 另一个同服务协程需要终止时：
token:cancel()
```

token 只使用一次，不能跨 Skynet 服务传递。取消停止本地接收，不保证供应商停止计算或计费。

## 工具结果续接

```lua
local calls = result.data.choices[1].message.tool_calls
local outputs = {}
for _, call in ipairs(calls or {}) do
    local args = assert(llm.tools.decode_arguments(call))
    -- 业务检查工具名称、权限、schema 后执行。
    local value = business_execute(call["function"].name, args)
    outputs[#outputs+1] = {tool_call_id=call.id, output=llm.json.encode(value)}
end
local next_body, err = llm.tools.continue_chat(body, result, outputs)
local next_result, next_err = client:chat(next_body)
```

Chat helper 保留完整 assistant message，并追加 role=tool；多个 choice 时要传 `{choice_index=0}`。Responses 使用 `llm.tools.continue_responses(body,result,outputs,{mode="replay"})`，outputs 为 `{call_id=...,output="..."}` 列表。`call_id` 与 output item 的 id 不同。replay 保留原 input 和完整 output，包括可重放 reasoning；状态链模式为 `mode="previous_response_id"`，需要显式存储和有效 response ID。

helper 要求所有调用都有且仅有一个对应结果，不执行工具，也不自动循环。function arguments 保留原始字符串，完整后才能 decode。custom/hosted tools 可显式开启原生透传能力；首版续接 helper 仅处理 function tools。

## 流式和 embedding

```lua
local stream, err = client:chat_stream(body, {timeout_ms=120000})
while stream do
    local event, read_err = stream:next()
    if read_err then return nil, read_err end
    if not event then break end
    -- event.kind / data / raw_data
end
local complete, finish_err = stream:result()
```

也可只调用 `stream:result()`，它会消费全部事件并聚合结果；不需要先 next。`stream:cancel()` 幂等。一个 stream 只有一个读取者。Chat 收到全部 choice 的 finish_reason 和 `[DONE]` 才成功；Responses 需要 completed，failed/incomplete 不当成功。首个事件交付后不会自动重放请求。流式结果不伪造 raw_json。

```lua
local res, err = client:embeddings({
    model="your-embedding-model",
    input=llm.json.array {"第一段", "第二段"},
    encoding_format="float",
}, {expected_dimensions=2560})
local vectors = res and llm.embeddings.vectors(res)
```

校验数量、唯一连续 index、有限数值和维度。原生 data 顺序保留，vectors 按输入顺序排列；base64 float32 也可解码。`dimensions` 是服务端降维请求，expected_dimensions 仅为本地检查。

`llm.json.array{}` 表示空数组，`llm.json.object{}` 表示空对象，`llm.json.null` 表示 null。普通空表默认对象；稠密整数列表推断为数组。JSON encode/decode 抛出编码错误，正常模型调用会捕获并返回 nil,err。跨 Skynet RPC 传 JSON 字符串，避免 metatable/null 类型丢失。

`skynet_llm.json` 当前是纯 Lua codec，统一上述类型、数值精度和有界编码约定。仓库中的 `vendor/lua-cjson` 是供现有项目使用的通用 C JSON 库；组件目前没有通过它编码或解码。后续可替换内部 codec，但必须保留公共类型和 RPC 契约，不能直接把两者的 `require` 名称互换。

## TLS、重试与限制

默认校验证书链、有效期、DNS 主机名/IP SAN，最低 TLS 1.2。信任库来自 OpenSSL 默认路径，不自动读取 macOS Keychain。私有 CA 用 `tls={ca_file="..."}`；仅信任该 CA 可加 `use_default_ca=false`。不提供跳过验证或 HTTPS 失败后降级 HTTP。

首版 IPv4，异步 UDP A 查询；不支持 IPv6、DNS-over-TCP、HTTP 重定向、环境代理、响应压缩或连接池。DNS/socket/TLS 均由单次请求持有，结束清理；不使用 Skynet 原有不可取消的同步域名解析路径。

DNS 默认读取 `/etc/resolv.conf`；可用进程环境变量 `SKYNET_LLM_DNS_SERVER=IPv4[:port]` 显式指定解析器，缺省端口 53，非法值返回 DNS 错误。Windows 测试 BAT 从系统网卡发现 IPv4 DNS 并设置此变量，也允许 `llm-settings.bat` 手动覆盖。Windows 测试使用包内 CA 和 `SSL_CERT_FILE`，不自动读取 Windows 证书库。双击 `test-llm-offline.bat` 可先验证原生 TLS 加载、CA 和协议解析；真实模型测试使用 `test-llm.bat`，报告不会把供应商不兼容算作通过。

默认最多两次尝试，重试尚未发出请求的连接失败、429、502/503/504，遵循 Retry-After 和总期限。发送后断线/超时不默认重发，错误会标记 may_have_executed。只有业务明确允许 `retry.allow_ambiguous=true` 才考虑这种重试；request_id 不等于供应商的幂等保证。

默认请求/响应各 32 MiB、响应头 32 KiB、SSE event 1 MiB、未消费事件 64 条且合计 1 MiB、流聚合 32 MiB。慢消费者超过 5 秒终止；流终态结果保留 30 秒，领取后保存在 facade。profile.limits 可调整有限上限。审计只发送有界元信息，业务自行决定完整正文是否存储。

## Docker 测试

在仓库根目录运行：

```sh
./scripts/test-llm.sh mock  # 构建、本地 HTTP/TLS 故障夹具、单元/集成和五个示例
./scripts/test-llm.sh real # 使用本地凭据测试真实模型
./scripts/test-llm.sh all
```

真实测试配置为 `.local/mao-models.env`（权限 0600），字段为 LLM_API_KEY、LLM_BASE_URL、LLM_MODEL、EMBEDDING_BASE_URL、EMBEDDING_MODEL。该目录同时被 Git 和 Docker 构建排除。不要将密钥写入已跟踪的配置、Dockerfile 或命令行参数。测试地址和模型名称从 mao 配置选择，有效密钥由用户另行提供；本组件运行不依赖 mao 目录。

已构建时可加 `LLM_SKIP_BUILD=1`。每轮 mock 使用独立的本地 CA 和配置，结束后清理，避免并行测试互相覆盖证书。安装版 client 和 transport 以 UID 1000 运行，使用镜像内的 Lua、服务和 TLS 扩展；发布镜像也使用非 root 用户。真实 smoke test 会产生少量模型请求。

真实测试汇总在 `.local/llm-results/real.json`，只记录状态、模型名、向量维度等信息。开始前移除旧报告；运行异常且未生成新报告时会明确提示。只有全部检查为 `PASS` 才返回成功，`FAIL`、`INCOMPATIBLE` 或 `UNSUPPORTED` 都返回非零状态。

2026-10-12 的最终 Docker 验证通过：31 项协议测试、6 项 SSE 测试、35 项源码模式 transport 测试、35 项安装版 transport 测试，client、lifecycle、安装版 client 及五个示例全部通过。原有 TCP demo、lua-cjson 和 HTTPS 示例回归通过；安装文件、补丁和许可证与镜像产物一致。协议、运行时和传输层均完成独立审阅。

详细接口与验收边界见 `docs/superpowers/specs/2026-10-12-skynet-llm-design.md`。目前还未把 mao 的业务网关切换到本组件。

最终镜像对 mao 配置所指模型服务的实测记录为 8 项 `PASS`、2 项 `INCOMPATIBLE`，真实测试按预期退出 1：`Qwen3.8-27B` 的 Chat、Chat SSE、function tools、Chat 工具续接、Chat 工具流、非流式 Responses 和 Responses function tools 可用；`qwen3-embedding:4b` 返回 2560 维向量。该服务的 Responses SSE 缺少 `output_index` / `content_index`，reasoning 的 `encrypted_content` 为空，因此标准流聚合和无状态 reasoning 工具续接被组件拒绝。不能把这些能力当作通过。标准 Responses 流与完整 reasoning 续接由本地协议夹具验证。后端修复前，业务可使用已通过的 Chat 工具续接。
