# skynet-llm 第一版设计

日期：2026-10-12。状态：设计范围已在对话中确认，本文待书面审阅；尚未实现。

## 1. 目标与边界

为 Skynet 项目提供可复用的模型调用组件，首先供 `mao` 使用，在 `skynet-demo` 中构建和验证。第一版支持 OpenAI 协议的 Chat Completions、Responses、Embeddings，以及前两者的 SSE 流式调用。

组件负责协议、HTTP/TLS、并发预算、排队、超时、取消、有限重试、响应校验和可观测性。业务负责提示词、会话历史、工具权限与执行、工具循环次数、数据库、记忆与检索。模型返回工具调用时，组件把调用交给业务；业务执行后可以用辅助函数生成下一次请求。

交付形式是独立的 Skynet 库加内部服务，名称为 `skynet-llm`，通过 `require "skynet_llm"` 使用。它不是 Codex 插件，也不是绑定 `mao` 的业务服务。首版只承诺 Skynet + Lua 5.4，在当前 Linux Docker 环境验收。普通 Lua、自动 Agent 循环、实时音视频、文件上传、Batch API、跨节点统一限流不在首版范围内。

Windows 构建保留现有功能；新组件的 Windows 支持需另外编译及运行验证，不根据已有 Skynet Windows 包推定兼容。首版也不提供 Responses 后台任务的查询、删除、取消接口；服务端内置工具只做协议透传，是否启用由业务和供应商能力决定。

## 2. 已有代码与提取原则

参考代码为 `/Users/mac/Documents/mao/game/src/` 下的 `ai_gateway.lua`、`embedding_client.lua`、`model_budget.lua`、`llm_audit.lua`、`ai_json.lua`。目前模型网关面向 NPC 文本输出；embedding 已有批量与维度检查；预算服务已有优先级队列，但调用方手动 acquire/release；审计绑定业务数据库。

复用这些代码的经验和行为要求，不把整个模块直接迁入组件：

| 现有职责 | 新归属 |
| --- | --- |
| HTTP 调用、认证、模型原生响应 | `skynet-llm` |
| 并发/队列预算、到期清理 | `skynet-llm` 管理服务 |
| embedding 数量、索引、维度、有限数值检查 | `skynet-llm` |
| NPC 提示词、`enable_thinking` 等供应商业务配置 | `mao` 请求构造 |
| 模型没有输出合格业务 JSON 后再问一次 | `mao` 业务重试，不算 HTTP 重试 |
| SQL 表结构、完整提示词和响应的保存策略 | `mao` 审计接收服务 |
| 工具白名单、参数校验、执行、结果和循环 | `mao` 或其他使用方 |

当前固定 Skynet v1.8.0 的 `ltls` 客户端没有证书链和主机名校验；`httpc.request_stream` 在响应头后停用了原超时。已有 HTTPS 演示不能作为组件可靠性或证书校验的验收依据。

## 3. 目录与接入方式

先在本项目的 `components/skynet-llm/` 维护独立目录，用 Docker 集成测试验证。稳定后可独立发布 Git 仓库，再由使用方通过 Git 子模块固定提交；设计阶段不创建远程仓库或新的 Git 仓库。

```text
components/skynet-llm/
  README.md
  LICENSE
  Makefile
  lualib/
    skynet_llm.lua                  # 业务入口；序列化和内部 RPC
    skynet_llm/
      config.lua                   # profile 与 capability 校验
      json.lua                     # null、array、object 的无损容器类型
      errors.lua
      tools.lua                    # 构造续接请求，不执行工具
      scheduler.lua                # 纯调度策略
      retry.lua
      protocol/
        chat.lua
        responses.lua
        embeddings.lua
      transport/
        http.lua                   # URL、DNS、HTTP framing、deadline
        tls.lua                    # Skynet socket 与 TLS 扩展适配
        sse.lua                    # 与 TCP/HTTP chunk 边界无关
  lualib-src/
    skynet_llm_tls.c               # 独立 TLS 客户端扩展
  service/
    skynet_llm.lua                 # 单节点管理服务
    skynet_llm_worker.lua          # 每个 worker 最多一个在途请求
  examples/
    chat.lua
    chat_tools.lua
    responses_tools.lua
    streaming.lua
    embeddings.lua
  tests/
    unit/
    integration/
    fixtures/
```

上层 `skynet-demo` 提供 Docker 构建、测试配置与启动脚本。组件不依赖 `/mao` 的绝对路径，不携带 Skynet 二进制或另一份 Skynet 源码。使用方把组件的 `lualib`、`service`、编译产物目录加入各自的 Lua/服务/C 模块搜索路径。衍生上游代码保留来源、许可证及修改说明。

## 4. 配置和公共接口

### 4.1 生命周期与 profile

```lua
local llm = require "skynet_llm"

local ok, err = llm.start {
    profiles = {
        main = {
            base_url = "https://api.openai.com/v1",
            api_key_env = "LLM_API_KEY",
            budget_group = "main",
            capabilities = {
                chat = true, responses = true, embeddings = true,
                chat_stream = true, responses_stream = true,
                function_tools = true,
                custom_tools = false, hosted_tools = false,
                response_state = false,
            },
        },
    },
    budgets = {
        main = { max_inflight = 4, max_queue = 64 },
    },
}
assert(ok, err and err.message)
local client = assert(llm.client("main"))
```

`start(config) -> true | nil, err` 在启动服务中调用，创建唯一的节点管理服务；同配置重复启动幂等，不同配置重复启动返回 `already_started`。首版不做运行中热更新。其他业务服务直接 `llm.client(profile) -> client | nil, err`；未启动或不存在的 profile 明确报错。`llm.stop() -> true | nil, err` 停止接收请求、取消队列和在途连接，供节点退出和测试使用。

`base_url` 必须包含完整基础路径，如 `/v1`；方法只追加 `/chat/completions`、`/responses`、`/embeddings`，统一处理末尾斜线，不猜测或补第二个 `/v1`。不接受 URL 中的账号密码、query 或 fragment。首版支持 DNS 名、IPv4 和显式端口；IPv6 在实现支持前配置校验直接拒绝。

密钥由管理服务读取环境变量并仅提供给执行请求的 worker。默认使用 `Authorization: Bearer ...`。无认证本地服务需显式配置 `auth = "none"`。可配置固定非敏感请求头；禁止覆盖 Host、Content-Length 等传输字段，敏感认证字段必须通过凭据配置。禁止把 API key 放进 URL、示例或日志。

多个 profile 使用同一个 `budget_group` 时共享并发与队列限制，避免多个模型名绕过同一后端预算。profile 与模型名分离：`model` 放在每次原生请求中。capabilities 是使用方明确声明的能力，不根据“兼容 OpenAI”的名称自动推定；未声明的能力默认关闭。组件不把 Responses 偷换成 Chat，也不静默删掉供应商不支持的字段。

### 4.2 调用形态

```lua
client:chat(body, options)              --> result | nil, err
client:responses(body, options)         --> result | nil, err
client:embeddings(body, options)        --> result | nil, err
client:chat_stream(body, options)       --> stream | nil, err
client:responses_stream(body, options)  --> stream | nil, err
```

`body` 是对应端点的原生 JSON 对象；保留未来新增字段和供应商扩展，不维护一份过时的字段白名单。只检查必要形状、互斥选项、明确禁用的能力与资源上限。流式方法设置 `stream=true`；普通方法拒绝 `stream=true`，防止把 SSE 当 JSON。Embeddings 不提供 stream。

`options` 只用于本地控制，绝不序列化进请求体：

| 字段 | 默认值 / 含义 |
| --- | --- |
| `timeout_ms` | 普通调用 30000；流式调用 120000；包含排队和所有尝试的总期限 |
| `queue_timeout_ms` | 3000；且不能超过剩余总期限 |
| `connect_timeout_ms` | 5000；DNS、TCP 与 TLS 建连阶段共享此期限 |
| `idle_timeout_ms` | 15000；等待响应头或正文网络进展的最长间隔 |
| `priority` | 2；允许 1、2、3，数字大优先 |
| `request_id` | 自动生成；业务可提供关联 ID，内部仍用独立唯一 token 标识请求 |
| `expected_dimensions` | 只适用于 Embeddings；本地预期向量长度，不发给服务端 |
| `retry` | 可覆盖 profile 的保守重试策略，但不能突破总期限 |
| `cancel_token` | 可选；由 `llm.cancel_token()` 创建，限同一业务服务使用 |

profile 可设置上述默认值与资源上限。入队前冻结请求快照，之后业务修改原 Lua table 不影响已提交请求。业务不持有预算 lease，不需要手动 release。

facade 先在业务服务内生成有大小限制的 JSON 快照，然后只发送携带长度、profile、期限的小消息申请 admission。管理服务先预留队列/流配额及请求字节预算，才允许该 token 上传一次正文；实际长度必须匹配声明。预留 1000ms 内未完成上传即释放，且不延长总期限。上传失败、取消和调用方消失都有清理路径。这样大量大请求被拒绝时，不会先把完整正文塞入管理服务邮箱；该内部握手不改变业务 API。

普通调用可以在另一个业务协程通过 `token:cancel()` 取消；流式也可复用该机制。token 在当前服务内绑定内部请求 ID，只把 ID 传入管理服务，不通过 RPC 传 Lua 对象。首版一个 token 对应一次调用，取消幂等，提交前已取消则直接返回 cancelled。未提供 token 的普通调用仍受总期限、服务退出和 stop 管理。

### 4.3 返回值、错误和 JSON 类型

```lua
result = {
    data = native_response,
    raw_json = "...",              -- 非流式成功响应的原始 JSON
    meta = {
        request_id = "...", provider_request_id = "...",
        attempts = 1, latency_ms = 123, queue_ms = 4,
        http_status = 200, assembled = false,
    },
}

err = {
    code = "timeout", stage = "read", message = "...",
    request_id = "...", http_status = 504,
    retryable = false, may_have_executed = true,
    attempts = 1,
}
```

预期网络、协议、校验及配置错误统一返回 `nil, err`，不要求业务用 `pcall` 包裹正常失败路径。`stage` 使用 `validate/queue/dns/connect/tls/write/read/decode/protocol/cancel`。错误码至少区分 `invalid_request`、`unsupported_capability`、`queue_full`、`queue_timeout`、`timeout`、`cancelled`、`http_error`、`tls_error`、`invalid_json`、`invalid_response`、`stream_interrupted`、`consumer_too_slow`、`worker_failed`。供应商错误对象可放入 `err.provider_error`，不包含密钥；错误正文受大小限制且不自动记录。

`retryable` 表示当前策略与剩余期限是否允许再试，`may_have_executed` 表示服务端可能已处理或计费，两者不是同一个意思。`meta` 只暴露请求 ID、用量等选定信息，不直接返回全部响应头。

公共 JSON 接口为 `llm.json.object(t)`、`llm.json.array(t)`、`llm.json.null`、`encode/decode`。空 `{}` 默认对象；空数组必须显式标记。解码保留 `[]`、`{}` 和 `null` 的区别；整数键稠密列表可推断为数组，混合键、稀疏数组、循环引用和非有限数字拒绝编码。

当前 lua-cjson 的全局空表开关无法同时表达空对象和空数组，因此组件采用保留容器类型的 codec，不把当前 cjson 解码结果作为唯一结构依据。JSON Schema、工具参数、`content=null` 和空列表必须能往返。跨 Skynet 服务调用传 JSON 字符串及普通元信息，在服务边界重新解码，避免序列化丢失 metatable/null 身份；业务跨服务传递原生 `data` 时也须使用该 codec。

## 5. 三种 API 的协议约定

### 5.1 Chat Completions

```lua
local res, err = client:chat({
    model = "configured-model",
    messages = llm.json.array {
        { role = "user", content = "查询订单 A123" },
    },
    tools = llm.json.array {
        { type = "function", ["function"] = {
            name = "get_order", description = "查询订单",
            strict = true,
            parameters = {
                type = "object",
                properties = { order_id = { type = "string" } },
                required = llm.json.array { "order_id" },
                additionalProperties = false,
            },
        } },
    },
    tool_choice = "auto",
    parallel_tool_calls = true,
    max_completion_tokens = 1024,
}, { timeout_ms = 30000 })
```

保留 `messages` 的原生角色和多模态内容，支持 `tools`、`tool_calls`、`tool_choice`、`parallel_tool_calls`、结构化输出、usage 及扩展字段。当前接口使用 `max_completion_tokens`；旧供应商需要的 `max_tokens` 由业务明确传入，不进行语义不明的自动换算。`response_format` 原样传递，不从内容中猜测并修复业务 JSON。

`choices[*].message.content` 可以是 null；出现工具调用时不能当作“模型没有回答”。所有 choice 及 finish_reason 均保留，工具参数保留原始字符串。`length`、拒绝回答等结果不自动重试；业务根据结果决定后续动作。

```lua
local next_body, err = llm.tools.continue_chat(original_body, res, {
    { tool_call_id = "call_123", output = '{"status":"paid"}' },
}, { choice_index = 0 })
local next_res, next_err = client:chat(next_body)
```

辅助函数深复制原请求，追加选定 choice 的完整 assistant message，再按工具调用顺序追加 `role="tool"`、`tool_call_id` 和字符串 `content`。只存在一个 choice 时可省略 `choice_index`，否则必须明确选择；索引沿用 API 的零起点。

要求选中消息的所有调用都有且只有一个结果，拒绝缺失、重复、陌生 ID；无工具调用时报错。不执行函数、不验证业务权限、不自动循环。首版辅助函数支持 function tool；新版 custom tool 的原生请求/响应可在启用能力后透传，但未支持的续接格式返回明确错误，业务可以直接构造原生请求。

Chat helper 要求选中 choice 的 finish_reason 为 tool_calls 且工具结构完整；length 或其他截断结果不能通过 helper 续接。原始失败/截断信息仍供业务决定如何重新请求。

### 5.2 Responses

端点是 **`POST /v1/responses`**。`client:responses` 保留 `input`、`instructions`、`tools`、`tool_choice`、`parallel_tool_calls`、`max_output_tokens`、`text.format`、reasoning、多模态和原生 `output`。

工具定义采用 Responses 原生形状：`{type="function", name="get_order", parameters=..., strict=true}`，不套 Chat 的 `function={...}`。不把 `output` 当成单条文本；它可能包含 message、reasoning、function_call 和其他项目。提供 `llm.responses.output_text(res) -> string` 作为便利函数，仅拼接 output message 的 output_text，原始项目仍保留。

默认补入 `store=false`，使用业务维护的上下文；不静默依赖服务端存储。只有 profile 开启 `response_state` 才允许 `store=true`、`previous_response_id` 或 `conversation`。`conversation` 与 `previous_response_id` 互斥；首版续接 helper 不管理 conversation，传入时返回 `unsupported_continuation`，业务仍可使用原生接口。`background=true` 首版明确拒绝，避免创建组件无法管理的后台任务。

```lua
local next_body, err = llm.tools.continue_responses(original_body, res, {
    { call_id = "call_123", output = '{"status":"paid"}' },
}, { mode = "replay" })
local next_res, next_err = client:responses(next_body)
```

续接有两种明确模式：

- `replay`（默认）：将原 input 规范为 input items，追加上一轮完整 output，再追加 `type="function_call_output"`、`call_id`、字符串 output。保留 reasoning（含可用的 encrypted_content）以及其顺序，不能只复制函数调用或模型文本。`store=false`，去掉历史 `previous_response_id`。
- `previous_response_id`：上一轮请求及实际响应必须表明 store=true，且有 response ID；下一次设置该 ID，input 仅包含本轮工具结果，沿用显式 store=true。原请求的 instructions、tools、模型和生成参数仍复制到新请求，不假设服务端继承这些设置。helper 是纯函数，仅检查这些局部条件；profile 的 response_state 能力统一由随后的 client:responses 调用校验。

helper 校验上一轮 response 状态为 completed、结果对应全部 function calls，使用 **`call_id`，不是 output item 的 `id`**。第一版 output 统一接受字符串，复杂结构先由业务编码 JSON。对无法保证合法 replay 的未知 output item 类型、缺少必要可重放 reasoning 内容、从状态链切换到缺乏完整历史的 replay，明确报 `unsupported_continuation`，不擅自丢项目或构造不完整上下文。

function 的 arguments 始终保留原文。`llm.tools.decode_arguments(call)` 只对完整 function call 做严格 JSON 解码，不在流式片段上解码，不把 custom tool 的自由文本当 JSON，不替业务执行 schema 或权限校验。工具定义中的 `strict` 由调用方显式给出，组件不改写 schema 或依赖供应商默认值。

### 5.3 Embeddings

```lua
local res, err = client:embeddings({
    model = "configured-embedding-model",
    input = llm.json.array { "第一段文本", "第二段文本" },
    encoding_format = "float",
    -- dimensions = 1024, -- 仅在该模型支持降维时传入
}, { expected_dimensions = 1024 })
local vectors = res and llm.embeddings.vectors(res)
```

支持原生字符串、字符串数组、token 整数数组和 token 数组批次。`input` 不接受空批次或混合类型；具体 token 数限制由模型决定，组件不内置过期模型清单。`dimensions` 是服务端可选参数；`expected_dimensions` 只在本地验收，不自动变成降维请求。

默认 `encoding_format="float"`。返回数据须与输入条数相符，index 为覆盖 `0..N-1` 的唯一整数，向量元素为有限数字且维度一致；指定 expected_dimensions 时必须相等。`res.data` 保持原始顺序，`vectors(res)` 按输入顺序返回向量列表。

显式请求 `base64` 时，对有效 base64 和解码后的 float32 做数量、有限值、维度校验；保留 `res.data` 中的原始字符串，`vectors(res)` 返回解码后的数值数组。参考 [官方 SDK 的 float32 解码](https://github.com/openai/openai-python/blob/main/src/openai/lib/_parsing/_embeddings.py)，首版目标平台按 little-endian float32 解释；非此编码的供应商应使用 float 模式，不自动猜测字节序。非法编码、重复/缺失索引或维度异常返回 `invalid_response`，不悄悄补零、截断或重发。

## 6. 流式协议与业务接口

```lua
local stream, err = client:chat_stream(body, options)
if not stream then return nil, err end
while true do
    local event, read_err = stream:next()
    if read_err then return nil, read_err end
    if not event then break end
    -- event.kind / event.data / event.raw_data
end
local result, finish_err = stream:result()
```

流式方法完成本地验证和入队后返回 handle。HTTP 错误及异步失败由 `next/result` 返回，不能把获得 handle 当成连接已成功。

- `stream:next() -> event | nil, err`：阻塞等待一个事件。成功终止且已读完队列时返回 `nil, nil`；失败终止时返回 `nil, err`。失败前已缓存的事件按顺序读出，后续调用重复返回终态错误。
- `stream:result() -> result | nil, err`：内部消费尚未读取的事件并等待终态，不要求先调用 next；已读取的片段仍计入完整结果。该行为避免消费者只取 result 时被事件背压卡住。
- `stream:cancel() -> true`：未终止时幂等取消，唤醒等待者并关闭底层连接；已产生终态时不改写原终态，但释放尚未取回的服务端事件/结果，后续取未领取的结果返回 stream_closed。已取回 facade 的结果仍可读取。只能保证本地停止接收，不能保证服务端停止计算或不计费。
- 同一个 handle 同时只能有一个 next/result 读取者；并发读取返回 `concurrent_read`，取消可由其他协程调用。handle 不可跨 Skynet 服务传递。

每个 event 为 `{kind, data, raw_data, meta}`。`kind` 是原生 Responses 事件类型或 `chat.chunk`；`data` 保留解码后的完整原生内容，`raw_data` 是 SSE data 字符串。终止标记由协议层处理，不伪装成文本。

SSE parser 支持跨 socket read 的 UTF-8/JSON、CRLF/LF、多行 data、注释、空行分隔和最终边界校验；HTTP chunk 与 SSE event 独立处理。不对不完整 JSON 尝试修复。未知合法事件透传，但不作为已知完成信号。

Chat 按 choice index、tool call index 合并 delta，可有多个交错工具调用；名称、ID、arguments 的片段按协议聚合。保留 finish_reason 和最终 usage（供应商支持时可由 body.stream_options 请求）。成功要求收到 [DONE]，且所有请求的 choice（n 默认 1）都已得到非 null 的 finish_reason；usage 的 choices=[] 尾事件允许出现在 [DONE] 之前。finish_reason 后仍给同一 choice 发送内容 delta，或 [DONE] 时缺 choice/finish_reason，返回 invalid_response；EOF 即使发生在 finish_reason 后，只要缺 [DONE] 就是 stream_interrupted。[DONE] 后立即结束读取并关闭连接，尾随字节不再交付。length 仍是完整收到的协议结果，业务根据 finish_reason 处理截断，helper 拒绝执行残缺工具参数。

Responses 保留原生类型事件，例如 output_item、output_text、function_call_arguments 的 added/delta/done；按 item ID/output index 关联，不能只处理第一个工具。`response.completed` 才是成功终态；`response.failed`、`response.incomplete`、error 事件、无终态断线均返回明确错误，部分 response 可放入 `err.partial_data` 供诊断，不自动续接或重试。非流式 Responses 对 failed/incomplete 采用同样错误约定。

Chat 流的最终 `result.data` 是按原生字段组装的响应，`meta.assembled=true`，不存在单份原始 JSON，故 `raw_json=nil`。Responses 优先使用 completed 事件的完整 response，同时保留已汇总的必要数据；也不伪造 raw_json。首版流式语义聚合保证文本、function tools、usage、refusal 和 reasoning；其他模态/新字段通过原始事件提供，不承诺未知 delta 都能重建为非流式对象。

## 7. 调度、资源上限和生命周期

```text
业务服务 facade → 节点管理服务（按 budget_group 排队）
                          → worker → HTTPS / 模型服务
业务执行工具 ← 完整工具调用/流式事件 ← 原生响应
```

管理服务拥有入队、派发、终态和预算；每个 worker 同时只执行一个请求。最大活跃 worker 数受各 budget_group 的 max_inflight 限制。队列按优先级选择，同优先级 FIFO；每等待 1000ms 提升一个有效优先级，最高为 3，达到同优先级后按原入队时间排序，避免持续高优先级请求饿死旧请求。

状态机为 `queued → connecting → sending → receiving → completed/failed/cancelled`，重试通过独立 `retry_wait` 状态回到预算队列。终态只能设置一次，每次尝试的 socket/TLS 只清理一次，预算只释放一次。重试等待不占在途槽，但请求仍计入队列容量，不得绕过排队限制。再次入队时若 max_queue 已满，则终止重试并返回最近一次失败，附 `retry_stopped="queue_full"`，不扩大队列；每次重新入队的局部排队时限重新计算，总期限不重置。

总期限从 facade 提交时开始，涵盖队列、DNS、连接、TLS、写入、读取、重试等待。所有子超时取剩余总期限与局部期限的较小值；公开单位毫秒，转换 Skynet tick 时向上取整。每个定时器校验请求 token/attempt generation，防止旧回调关闭复用 worker 的新连接。明确使用异步 DNS；不得用会阻塞整个 Skynet socket 线程的解析路径。

DNS 通过独立适配器先解析成数字 IP，再交给连接层。原 skynet.dns.resolve 的固定超时和不可取消查询不能直接作为调用 deadline：管理层到期立即结束请求、失效 token，丢弃迟到解析结果；未完成 DNS 操作计入独立有界配额（默认 16），避免不断超时后积累后台查询。连接层必须在等待完成前拥有 socket ID，才能取消尚未建立的连接；这一适配需通过连接失败与取消竞态测试，不能继续采用先阻塞 socket.open、超时后等其返回的方式。

取消、调用方退出、worker 异常和超时均需要独立清理路径。能观察到服务退出时立即清理；即使退出通知缺失，总期限和流式消费期限仍作为资源回收兜底。worker 死亡由管理服务的在途调用失败/存活检查回收；不能只依赖业务来执行 finally。失联 worker 先终止并确认其 socket 被清理，再补新 worker，不重复派发旧请求。管理服务异常重启不自动重放旧请求；旧 facade 返回服务不可用错误。

默认资源上限（profile 可调，配置必须为有限正数）：

| 资源 | 默认上限 |
| --- | --- |
| 单次请求体 / 非流式响应体 | 各 32 MiB |
| 每个 budget_group 已预留/在途请求体字节总额 | 64 MiB；提交时预占，结束时释放 |
| 响应头累计大小 | 32 KiB |
| 单个 SSE event | 1 MiB |
| 每条流未消费事件缓存 | 64 个事件且总计不超过 1 MiB |
| 每条流累计原始 data 字节及最终聚合结果 | 各不超过 32 MiB |
| 每个 budget_group 未结束消费的流数量 | 16（从入队至取走结果/取消/过期） |
| 事件缓存持续无消费时间 | 5000ms |
| 上游终止后未取走的流结果保留时间 | 30000ms |

流控采用 pull：每次 next 同时确认上一条事件已交付给 facade，并索取下一条；内部事件携带递增序号，重复确认幂等。result 在 facade 内执行同样的消费循环。不使用无界 `skynet.send` 向业务邮箱不断塞事件。缓存达到上限后暂停读取，消费恢复后继续；等待空间超时则 `consumer_too_slow` 并关闭连接。worker 独占 socket/TLS/解析器，管理服务拥有请求终态与缓存额度；取消和超时同时唤醒网络等待及消费等待。必须同时限制底层 socket 缓冲区和 HTTP/TLS 解帧缓冲区；不能为了读取一个巨大 HTTP chunk 先分配整个 chunk。主动暂停期间用消费超时管理，网络 idle 计时仅在实际等待网络输入时运行，总期限一直有效。

上游终止后先清理 socket/TLS，再释放在途槽；管理服务保存待消费事件/结果。流在入队时预占独立的 max_pending_streams 配额（默认 16），整个排队/执行/待消费过程占用它，因此上游完成时无需临时争抢结果存储槽；配额满则拒绝新的流式调用。该配额与 max_queue、max_inflight 分别校验。next 读完事件不会删除最终结果；result 把结果取回 facade 后释放服务端配额，facade 缓存终态以支持重复 result。超出保留期限而尚未取回则返回 stream_expired；原请求成功终态不因此被改写。非流式结果在 RPC 回复后释放，业务持有的 table 内存由业务管理。

## 8. HTTP/TLS 与重试

组件拥有自己的 transport，复用 Skynet socket 接口及可复用的 HTTP 头解析逻辑，自己控制增量正文 framing、连接和超时；不直接包装当前 `httpc.request_stream` 作为完整可靠层。首版 HTTP/1.1，每次请求独立连接，无连接池、无自动重定向、无隐式环境代理。发送 `Accept-Encoding: identity`；不支持的压缩返回明确协议错误，避免误解码和解压大小失控。

TLS 使用组件独立的 `skynet_llm_tls` C 扩展，采用 OpenSSL 3 客户端 API，独立模块名、metatable、context 和 userdata 生命周期。可参考 MIT 许可的 ltls memory BIO 适配方式，保留来源说明；不修改固定的 Skynet 子模块，不依赖原 ltls 的全局初始化开关，也不调用影响同进程其他模块的 OpenSSL 全局 cleanup。

扩展暴露 context/session 创建、输入密文、handshake/read/write、提取待发送密文和 close，明确区分 want_read、want_write、close_notify、异常 EOF 与 fatal error；每次 OpenSSL 操作后排空待发送密文。没有应用数据不等于流结束。每个 worker 私有 context，连接 session 不共享，所有关闭操作幂等。参考 [OpenSSL 读取契约](https://docs.openssl.org/3.0/man3/SSL_read/)。

默认启用所链接 OpenSSL 的默认信任库、证书链、有效期和 DNS 主机名/IP SAN 校验，最低 TLS 1.2；这不代表自动读取 macOS Keychain。请求分开保存 URL hostname、port、解析 IP 和 HTTP Host；SNI 使用不带端口的 DNS 名。profile.tls.ca_file/ca_path 默认补充默认信任库；显式 `use_default_ca=false` 可仅信任配置 CA，此时必须提供 CA 路径。显式路径加载失败在启动时报错，缺乏可信 CA 时握手失败，不跳过验证或回退 HTTP。[OpenSSL 信任库规则](https://docs.openssl.org/3.0/man3/SSL_CTX_load_verify_locations/)。

`http://` 仅在 profile 显式设置 `allow_http=true` 时允许，用于使用方选择的本地或私有模型服务。GitHub 下载使用本机 20890 代理的项目约定不自动应用于模型请求；首版使用直接连接。

首版重试默认最多 2 次尝试（含首次），base delay 250ms、上限 2000ms，指数退避加 full jitter；遵循合法 Retry-After 的秒数或 HTTP 日期，下次等待超过剩余期限则结束。默认可重试：明确尚未发送应用层请求的暂时连接失败、429、502/503/504。对模型不存在、认证/权限、参数/schema、证书验证、非法响应不自动重试；其他 5xx 需 profile 明确允许。

一旦请求可能已发送，连接断开/超时默认不重试，返回 `may_have_executed=true`；业务可显式开启 `retry.allow_ambiguous=true`，并承担重复执行/计费可能。收到可重试 HTTP 状态也不等于服务端保证未执行，错误元信息保留这种不确定性。流已经向业务交付任意事件后禁止自动重试；首版也不自动恢复 SSE 或使用 Last-Event-ID 续传。request_id 用于关联，不宣称供应商提供 exactly-once 语义。

## 9. 可观测性和业务接入

管理服务提供 `llm.stats()` 的节点快照：分 budget_group 的在途、排队、待消费结果、成功/失败/取消计数、重试次数、队列和调用时长汇总、审计丢弃计数。记录请求 ID、profile、API 类型、model、状态、耗时、attempts、HTTP 状态与原生 usage；不把 prompt、工具参数、向量或 API key 默认写入日志。

可选审计接收器配置为 Skynet 服务地址和命令，不能传跨服务 Lua 回调。审计在独立有界队列中交付，最多 256 条、每条最多 16 KiB；接收器不可用或繁忙时丢弃并计数，不阻塞模型返回或占用模型在途槽。完整正文审计由业务拿到结果后按自身权限和存储规则完成。

`mao` 接入时保留现有 ai_gateway 的业务入口，以适配层替换请求部分。NPC 的 prompt、优先级映射、业务 JSON 解析/修复仍留原处。embedding_client 的业务入口也可保留，底层改调用组件。迁移后对应请求只能由组件管理预算，不能外层再 acquire 同一个 model_budget，避免双重限流或死锁。数据库审计接收器继续属于 mao。

## 10. 验收标准

测试以本地可控假模型服务为主，不需要真实密钥或付费请求；真实供应商 smoke test 作为配置凭据后的单独测试，明确标注未执行或供应商限制。

1. **协议和 JSON**：三种端点 URL/认证/原生 body 正确，options 不泄露；对象/数组/null/扩展字段往返不变；错误与原始响应保留；admission 预留到期/上传失败可清理，管理服务处理延迟时并发大请求不突破正文预算。
2. **Chat 工具**：纯文本、content=null、多并行 function call、多个 choice、参数分片、工具结果关联；未知/重复/缺失 ID 被拒绝，helper 不改原请求，不执行工具。
3. **Responses**：文本/工具/reasoning 原生 output；replay 保留完整上下文；显式状态链正确使用 call_id 和 previous_response_id；failed/incomplete、不能安全 replay 和禁用能力明确失败。
4. **Embeddings**：批量、token 输入、乱序 index、缺失/重复 index、维度、NaN/Infinity、float/base64，按输入顺序返回 vectors。
5. **SSE**：任意 TCP 和 HTTP chunk 切分、跨包 UTF-8、多行 data、交错工具 delta、usage、finish_reason/[DONE] 的缺失及顺序异常、提前 EOF、非法 JSON、超大 chunk/event、慢消费者和只调用 result 都有确定结果；读完 next 后仍能领取 result，重复 result 与终态后 cancel 按约定工作。
6. **调度与资源**：高并发不超过预算，队列满立即拒绝，优先级老化生效；到期/取消/worker 故障/调用方退出后槽位和 socket 可回收；旧定时器不影响新请求；终态和清理不重复。结果保留及审计队列有界。
7. **超时和重试**：用受控时钟/服务验证 DNS/TCP/TLS/响应头/正文/退避的总期限；429/Retry-After、允许的 5xx、发送后断线不盲重试、重试回队已满；首个流事件后不重放；普通调用通过 cancel_token 可从另一协程取消。
8. **TLS**：受信 CA 成功、自签但未信任失败、过期失败、错误主机名/IP SAN 失败、显式 custom CA 成功；与 Skynet 原 ltls 同进程加载无生命周期冲突。
9. **集成**：在当前镜像实际启动 Skynet，运行五个组件示例；保留现有 TCP/JSON/HTTPS 测试通过；检查发布产物与日志无密钥。原 HTTPS 示例的验证边界仍按 README 如实描述。

完成这些验收后才称第一版可用。代码构建通过或成功请求一次模型不等于可靠性验收完成。

## 11. 设计取舍与依据

本设计选择独立组件、三个原生 API 和共享可靠传输。继续扩展 mao 内部网关更快，但会继续绑定游戏逻辑；把所有模型压成一个 `generate()` 会丢失 Responses 项目和工具续接语义；直接采用当前 httpc 省代码，但无法满足已确认的流式超时、内存上限和证书校验要求。

本地代码依据：Skynet 固定于 v1.8.0（`ba64be6f9fa044933c77de1317f466afbade8eaa`）；主要对照 `vendor/skynet/lualib/http/httpc.lua`、`http/internal.lua`、`http/tlshelper.lua`、`vendor/skynet/lualib-src/ltls.c`，以及第 2 节列出的 mao 模块。

以下官方文档于设计阶段核对；供应商和模型能力仍以具体部署为准，组件通过原生字段和能力配置保持扩展空间：

- [Chat Completions 创建接口](https://developers.openai.com/api/reference/resources/chat/subresources/completions/methods/create)
- [Function calling 与工具结果续接](https://developers.openai.com/api/docs/guides/function-calling)
- [迁移到 Responses](https://developers.openai.com/api/docs/guides/migrate-to-responses)
- [Responses 流式事件](https://developers.openai.com/api/docs/guides/streaming-responses)
- [Embeddings 创建接口](https://developers.openai.com/api/reference/resources/embeddings/methods/create)
