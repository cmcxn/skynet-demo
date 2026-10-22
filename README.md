# Skynet Docker Demo

使用 `hanxi/skynet-builder` 编译官方 Skynet `master` 的固定提交 `64391f732e76507ea6615f312cb71be1fd7bfbdd`（Lua 5.5.1），再将运行文件复制进 Debian trixie-slim。镜像名使用标准 Docker Hub 名称并固定 digest；运行镜像不包含 GCC / MinGW，使用非 root 用户。

Skynet 使用 Git 子模块：`.gitmodules` 中的 `branch = master` 指定远程更新目标，父仓库仍固定具体提交，不会在每次构建时自动追随最新 master。本次升级同时将 Lua 升至 5.5.1，需完整替换 Windows 包，避免混用旧原生模块。

## 构建与启动

在本目录执行：

```sh
git submodule update --init --recursive
docker compose build
docker compose up -d
docker compose logs --tail=40
```

Demo TCP 端口映射至本机 `127.0.0.1:8888`。这是 sproto 协议服务，不是 HTTP 网页。调试端口 8000 和集群端口不映射到本机。

## 测试

```sh
docker compose exec -T skynet sh tests/run-demo.sh
```

测试使用官方 `examples/proto.lua` 协议，验证握手、写入 `docker-demo=hello-from-docker`，以及读取并核对结果。成功退出码为 0，输出三条 PASS。

Compose 保持标准输入和 TTY 打开，以支持官方控制台。自动测试使用单独编译的 `tests/client/socket.so`，复用官方客户端网络代码但禁用交互 stdin 线程，避免 EOF 提前退出或阻塞进程退出。官方 `luaclib/client.so` 保持原样。

使用官方交互客户端：

```sh
docker compose exec skynet ./3rd/lua/lua examples/client.lua
```

客户端会写入 `hello=world`；输入 `hello` 可查询，输入 `quit` 断开连接（客户端可能随后报告 Server closed）。

停止 Demo：

```sh
docker compose down
```

## 编译 Windows 便携版

在 macOS / Linux 上启动 Docker Desktop（或 Docker Engine），执行：

```sh
git submodule update --init --recursive
./scripts/build-windows.sh
```

脚本使用 Docker 内的 MinGW 交叉编译 Windows x64 程序，输出 `dist/skynet-windows-x64.zip` 和同名目录。将 ZIP 复制到其他 Windows x64 电脑，**完整解压**后双击 `start.bat` 即可启动；目标电脑无需安装 Docker、Lua、MinGW 或 OpenSSL。另开窗口双击 `client.bat` 使用交互客户端。服务运行时双击 `test.bat` 可验证 JSON、TLS 模块加载、百度 HTTPS、httpbin HTTPS JSON 解析及 TCP 握手、写入和读取。

HTTPS 检查通过 Skynet 的 `http.httpc` 发起真实请求：百度必须返回 HTTP 200 且正文非空；`https://httpbin.org/ip` 必须返回 HTTP 200，正文用 `cjson.decode` 解析，并检查和输出非空字符串 `origin`。两项检查分别报告 PASS / FAIL，每个请求超时 30 秒；网络不可达、HTTP 状态异常或 JSON 解析失败都会使测试失败。检查在单独的 Skynet 测试进程中运行，不会关闭已启动的 Demo。

只测试 HTTPS 时，双击 `test-https.bat`，无需先启动 `start.bat`。

包内包含 `skynet.exe`、Lua 解释器、全部服务与 Lua 模块、所需 DLL、示例配置及许可证。原生模块保留 `.so` 文件名，实际内容是 Windows DLL。不要只复制 EXE，所有子目录和 DLL 都需要保留。示例 TCP 端口为 8888，8000、2013、2526 也需空闲；原有示例的网络监听配置保持不变，停止服务可在启动窗口按 Ctrl+C。

Windows 构建直接使用该 Skynet `master` 提交自带的 `3rd/compat-mingw/` 和 `mingw.mk`，已移除旧的 Windows 回移补丁。保留上游尚未提供的 UDP 错误码转换和 LLM 按需读取补丁，仅应用到容器内编译副本。包含多线程 lua-cjson 与静态链接的 OpenSSL 3.5.9。首次构建需要联网安装构建依赖并下载经过 SHA256 校验的 OpenSSL 源码，后续构建复用 Docker 缓存。

当前上游已修正 Windows `sleep()` 的秒单位。Windows 示例跳过基于 POSIX stdin 的服务端控制台，交互客户端与 TCP 调试控制台仍可使用。BAT 启动文件使用 Windows 目录分隔符，以兼容配置文件的 `include`。所有原生模块都使用 Lua 5.5.1 头文件重新编译；`lua54.dll` 是上游 `mingw.mk` 保留的文件名，内部为 Lua 5.5.1，不能混用旧 DLL。

便携包同时包含 `skynet-llm` 服务、经过验证的独立 TLS 模块、CA 证书和按需读取补丁。先双击 `test-llm-offline.bat` 检查 DLL、CA、31 项协议和 6 项 SSE 测试；再把 `llm-settings.example.bat` 复制为 `llm-settings.bat`，填写自己的模型密钥，双击 `test-llm.bat` 进行真实调用。无需先启动 `start.bat`。模型结果保存在包内 `llm-real-result.json` 和 `llm-test.log`；包内没有真实密钥。Windows DNS 默认从系统网卡发现，可在私有配置中指定 `SKYNET_LLM_DNS_SERVER`（IPv4，可带端口）。新 TLS 模块使用包内 PEM 信任库，保留证书和主机名校验。编译和 PE/DLL 依赖检查在 Docker 中完成，Windows 实机运行仍需测试。

已在 Docker 内使用 Wine 10.0 x64 执行 Windows 二进制，验证离线 BAT、TLS、原有 demo/JSON/HTTPS/TCP、36 项传输测试、客户端和生命周期，以及近 32 MiB 流与取消。测试发现并补充了 Windows UDP `recvfrom` 的 Winsock 错误码转换；离线 BAT 包含对应回归程序。真实模型为 8 项通过、2 项已知 Responses 服务不兼容。Wine 测试显式指定 DNS，Windows PowerShell 自动发现部分仍需实机验证。

本机已验证的 Wine 环境固定为 `skynet-wine-test:10.0-amd64`。日常直接复用该镜像，不需要重新安装 Wine。离线备份为 `dist/skynet-wine-test-10.0-amd64.tar.gz`，不纳入 Git；镜像被删除后可以恢复：

```sh
gzip -dc dist/skynet-wine-test-10.0-amd64.tar.gz | docker load
docker run --rm skynet-wine-test:10.0-amd64 /usr/lib/wine/wine64 --version
```

需要重建时使用 `docker build --platform linux/amd64 -f Dockerfile.wine -t skynet-wine-test:10.0-amd64 .`。构建文件锁定 Debian 基底摘要及 Wine `10.0~repack-6`；其他 APT 依赖仍取构建时仓库版本，因此完整一致的恢复优先使用离线备份。镜像仅包含测试工具，Windows 包、结果、Wine prefix 和模型密钥均在运行时单独提供，不应通过 `docker commit` 保存测试容器。

Windows 兼容层直接来自 Skynet 子模块，保留的两份扩展补丁来源见 `scripts/windows/PATCH-SOURCES.md`；说明和补丁随包放入 `licenses/`。

## 源码与依赖

- Skynet: https://github.com/cloudwu/skynet ，`vendor/skynet` 为 Git 子模块，当前固定为 `master` 提交 `64391f732e76507ea6615f312cb71be1fd7bfbdd`。`.gitmodules` 中 `branch = master` 指定远程更新来源；实际版本仍由父仓库记录的 gitlink 提交决定，正常初始化不会自动跟随远端移动。
- jemalloc: 使用该提交指定的子模块提交 `81034ce1f1373e37dc865038e1bc8eeecf559ce8`。
- lua-cjson: `vendor/lua-cjson` 子模块来自 https://github.com/cloudwu/lua-cjson.git ，固定提交 `ed0db2e29d94eaeb4267430c04abf8a930d8573e`。使用 Skynet 的 Lua 5.5.1 头文件编译，启用多线程支持。
- HTTPS: 编译 `TLS_MODULE=ltls`，运行镜像包含 OpenSSL 和 CA 证书。可通过 `require "http.httpc"` 发起 HTTPS 请求。
  使用 HTTPS 的 Skynet 配置文件需设置 `enablessl = true`。
- 编译镜像: `hanxi/skynet-builder@sha256:31b04c011d8d5c28840c51adececb0a5f5ceada0f50aeb46faa205e1ce552ea9`，使用 Docker 已配置的镜像加速器。

首次克隆本项目时使用 `git clone --recurse-submodules <本项目地址>`，或克隆后运行 `git submodule update --init --recursive`，同时初始化 Skynet 和它的 jemalloc 子模块。更新后的源码在宿主机准备好，Docker 构建阶段不需要联网下载源码。许可证保留在源码目录。这是官方示例环境，simpledb 数据保存在内存，重启后丢失。

GitHub 拉取遇到网络问题时，按项目约定使用本机代理：

```sh
git -c http.proxy=http://127.0.0.1:20890 submodule update --init --recursive
```

## JSON 与 HTTPS 测试

```sh
docker compose exec -T skynet sh -c 'rm -f /tmp/skynet-features-result; ./skynet tests/config-features; test "$(cat /tmp/skynet-features-result)" = PASS'
```

验证 JSON 编解码、拒绝无效 JSON、TLS 模块加载，以及向 `https://www.baidu.com/`、`https://httpbin.org/ip` 发起真实请求并解析 IP JSON（需要外网连接）。

固定版本的上游 `ltls` 客户端没有启用服务端证书验证；本项目构建时应用下文的 TLS 补丁，强制验证证书链和目标身份。LLM 组件继续使用独立的验证型 TLS 扩展。

## Skynet 模型调用组件

`components/skynet-llm` 提供 Chat Completions、Responses、Embeddings 和 SSE，工具执行留在业务层。Docker 构建会安装 Lua 模块、管理/worker 服务和独立的 OpenSSL TLS 扩展；该扩展启用证书链及主机名校验。

使用方法见 [组件 README](components/skynet-llm/README.md)。运行 `./scripts/test-llm.sh mock` 验证本地协议、调度和 TLS 故障场景；`./scripts/test-llm.sh real` 使用 `.local/mao-models.env` 测试真实模型。`.local/` 已被 Git 与 Docker 构建排除。

## TLS 安全更新（2026-10-22）

原生 `http.httpc` / WSS 客户端通过 `patches/skynet-verified-client-tls.patch` 强制校验证书链和 DNS 主机名/IP SAN；失败时拒绝连接，不提供跳过验证开关。私有 CA 可通过 OpenSSL 的 `SSL_CERT_FILE` / `SSL_CERT_DIR` 指定。Windows 启动 BAT 默认使用包内 `certs/ca-bundle.crt`，不读取 Windows 系统证书库。

Linux 和 Windows 构建使用 `scripts/check-ca-trust.sh` 检查 Debian CA 修复版本，并离线验证 eMudhra 的 12 条公开测试链都被拒绝。固定验证时间避免证书过期造成假通过。CA 包过旧、仍接受链或检查异常都会阻止构建。证书来源与摘要见 `tests/fixtures/emudhra/README.txt`。

CA 安全更新后必须重新构建并替换旧镜像/Windows 包；已发布产物不会自动更新：

```sh
docker compose build --pull --no-cache
docker compose up -d --force-recreate
./scripts/build-windows.sh
```

测试：在具备 OpenSSL 3.5、C 编译器和 Lua 的 Linux 环境运行 `LUA=/path/to/lua sh scripts/test-tls.sh`，然后运行 `sh scripts/check-ca-trust.sh`。现有 LLM 集成测试为 `sh scripts/test-llm.sh mock`。在线站点访问失败不能替代离线信任链检查。

若运行时覆盖 `SSL_CERT_FILE` / `SSL_CERT_DIR` 或 LLM `tls.ca_file` / `tls.ca_path`，需单独审计该信任库；构建时的系统 CA 检查不覆盖运行时注入的证书。`CA_CHECK_PACKAGE=0 sh scripts/check-ca-trust.sh /path/to/public-ca-bundle.crt` 可检查独立的公共 CA 包；此检查要求保留 ISRG Root X1 作为正常信任对照，不适用于仅含私有 CA 的包。

## HTTP 代理与 TLS：改动和使用方法

原 `fix/http-proxy-verified-tls` 分支的功能已移植到当前 master（`9cae819`）；旧分支已删除，正常使用 master 构建即可。

### 改了哪些内容

| 文件或模块 | 改动及作用 |
| --- | --- |
| `patches/skynet-verified-client-tls.patch` → `http.httpc` / 新增 `http.proxy` | HTTP 正向代理、HTTPS CONNECT、代理认证、NO_PROXY；保留 GET/POST/HEAD/流式调用接口 |
| 同一补丁 → `ltls.c` / `http.tlshelper` / `http.websocket` | 强制验证证书链、DNS 主机名或 IP SAN，HTTPS 隧道仍验证目标服务器；支持自定义 CA；保留 WSS 校验 |
| 同一补丁 → `http.internal` / `http.httpc` | 请求总超时、异常和流式读取清理；保留 CONNECT 响应后预读的数据，避免握手丢字节 |
| 同一补丁 → `lua-skynet.c` | Windows 精确区分代理环境变量名称，保持小写优先及忽略 `HTTP_PROXY` 的行为 |
| `compose.yaml` | 将代理与 NO_PROXY 环境变量传入容器 |
| `scripts/apply-skynet-patches.sh` / `scripts/build-native.sh` | 对编译副本应用补丁，支持重复执行检查；Linux 原生构建包含 Lua 5.5、TLS、JSON 和 LLM |
| `scripts/check-ca-trust.sh` / CA 测试证书 | 保留已有 CA 构建门禁，拒绝问题证书链；不是 Go 运行时补丁 |
| `scripts/test-proxy.sh` / `tests/proxy-*` 等 | 代理配置、认证隔离、证书拒绝、超时与清理回归测试 |

补丁作用于构建副本，`vendor/skynet` 源码不直接修改。Linux Docker、Windows 和 Linux 原生构建使用相同的代理/TLS 补丁。仅更新仓库或设置代理变量不会改变已运行的旧程序，需重新构建并重启；完整重建命令见上面的“TLS 安全更新”。

### Docker：使用本机代理

在项目目录、启动 Compose 的同一个终端执行：

```sh
export http_proxy=http://host.docker.internal:20890
export https_proxy=http://host.docker.internal:20890
export no_proxy=localhost,127.0.0.1,::1,.internal.example
# 首次使用新代码时先构建；已有新镜像时只需重建容器。
docker compose build
docker compose up -d --force-recreate
```

`https_proxy` 的值也写 `http://`：表示先连接 HTTP 代理，再通过 CONNECT 建立到 HTTPS 目标的隧道。代理需允许 Docker 容器访问；`host.docker.internal` 是 Docker Desktop 的宿主机地址。Linux Docker Engine 需另行配置该名称或使用容器可达的宿主机地址。

关闭代理时，在同一终端执行以下命令并重建容器：

```sh
unset http_proxy https_proxy HTTPS_PROXY all_proxy ALL_PROXY no_proxy NO_PROXY
docker compose up -d --force-recreate
```

这里配置的是运行时 `http.httpc` 代理；Docker 构建过程中 APT、下载依赖所需的网络配置需单独设置。

### Linux 原生与 Windows 便携包

Linux 原生运行时在构建产物目录启动（同机代理使用 `127.0.0.1`）：

```sh
cd .build/runtime
export http_proxy=http://127.0.0.1:20890
export https_proxy=http://127.0.0.1:20890
export no_proxy=localhost,127.0.0.1,::1
./skynet examples/config
```

Windows 在完整解压的新便携包目录打开 **CMD**，设置后启动（仅影响该窗口及子进程）：

```bat
set "http_proxy=http://127.0.0.1:20890"
set "https_proxy=http://127.0.0.1:20890"
set "no_proxy=localhost,127.0.0.1,::1"
call test-https.bat
call start.bat
```

Windows 使用包内 `certs/ca-bundle.crt`；更新程序需完整替换便携包。`test-https.bat` 访问真实网站，需要外网及代理连通。

### Lua：发请求、指定代理和 CA

在启用 `enablessl = true` 的 Skynet 配置中运行服务，服务代码示例：

```lua
local skynet = require "skynet"
local httpc = require "http.httpc"

skynet.start(function()
    httpc.timeout = 3000 -- 3000 tick = 30 秒，整个请求的总预算
    httpc.proxy = nil    -- 使用环境变量；无代理配置时直连
    local headers = {}
    local ok, status, body = pcall(httpc.get, "https://httpbin.org", "/ip", headers)
    if ok then
        skynet.error("HTTP status:", status, "body:", body)
    else
        skynet.error("HTTPS 请求失败:", status)
    end
    skynet.exit()
end)
```

`httpc.get` 的第一个参数是目标协议/主机（可带端口），第二个是路径及查询串；不要把代理地址当成目标，也不要把完整 URL 填到路径参数。

其他配置可在请求前设置：

```lua
httpc.proxy = "http://127.0.0.1:20890" -- 显式代理，仍受 NO_PROXY 约束
httpc.proxy = false                    -- 强制直连
httpc.proxy = nil                      -- 恢复读取环境变量

-- 只在使用私有 CA 时配置；该文件必须在运行环境内可读。
httpc.cafile = "/etc/my-app/private-ca.pem"
httpc.capath = nil
-- 恢复默认 OpenSSL 信任库时，将 cafile、capath 都设为 nil。
```

这些是当前 Lua 服务中 `httpc` 模块的共享配置，应在服务初始化时统一设置，避免并发请求间来回修改。自定义 CA 会替换默认信任来源；域名/IP 不匹配、过期或不可信证书仍会报错，没有关闭验证的开关。流式请求使用 `httpc.request_stream`，提前结束消费时调用 `stream:close()`。

代理认证可写为 `http://user:password@proxy.example:8080`；用户名/密码中的保留字符需百分号编码，例如 `u@ser` / `p:ss` 对应 `http://u%40ser:p%3Ass@proxy.example:8080`。不要把真实凭据提交进仓库。

### 代理选择规则和边界


构建时的 `patches/skynet-verified-client-tls.patch` 同时提供原生 `http.httpc` 的 HTTP 正向代理、HTTPS CONNECT，以及现有 TLS/WSS 身份校验。TLS/CA 安全检查保持启用，WSS 仍直接连接。LLM 使用独立的 HTTP 通道，不读取这里的代理设置。

- HTTP 依次读取 `http_proxy`、`all_proxy`、`ALL_PROXY`，忽略可能来自 CGI 请求头的 `HTTP_PROXY`。
- HTTPS 依次读取 `https_proxy`、`HTTPS_PROXY`、`all_proxy`、`ALL_PROXY`。小写优先，空值停止代理回退。Windows 通过原始环境变量名称精确匹配，避免 `os.getenv` 的大小写折叠重新启用 `HTTP_PROXY`。
- `no_proxy` 优先于 `NO_PROXY`；支持域名及子域边界、端口、IPv4/IPv6 字面量、IPv4 CIDR 和单独的 `*`。不支持 IPv6 CIDR，IPv6 按文本匹配。
- `httpc.proxy = false` 强制直连；字符串指定代理（仍受 NO_PROXY 约束）；`nil` 使用环境变量。只支持 `http://` 代理，不支持的协议会报错。
- 代理 URL 支持百分号编码的 Basic 认证。认证头只发往代理，不转发到目标，也不修改调用方的请求头表。HTTP 代理传输本身不加密。
- 默认使用 OpenSSL 信任库；`httpc.cafile` / `httpc.capath` 可替换默认信任来源。自定义 CA 必须另行审计；不能跳过校验。
- `httpc.timeout` 单位为 Skynet tick（10 毫秒），限制 DNS、建连、CONNECT、TLS 和响应读取的总预算，并清理超时的闲置流。未设置时保持无限等待语义。

Compose 传递上述代理变量。Docker Desktop 访问宿主机代理应使用 `http://host.docker.internal:20890`，并确认代理允许容器访问；不要在容器内使用宿主机的 `127.0.0.1`。

### 构建和回归测试

Linux 原生构建使用与 Docker/Windows 相同的补丁，包含 Lua 5.5 和 LLM 模块，并保留 CA 安全门禁。在项目根目录执行：

```sh
sh scripts/build-native.sh
sh scripts/test-proxy.sh .build/runtime
sh scripts/test-tls.sh
sh tests/patch-application.sh
```

原生构建需要 C 编译器、make、OpenSSL 3.5 开发包、autoconf、m4、Perl 和 patch；代理集成测试另需 Python 3。原生脚本以 Debian Linux 为基准，macOS 使用 Docker。代理集成测试只访问回环地址，使用临时证书，不依赖外部代理或真实模型。


移植版本已验证：Linux Docker、Linux 原生运行时、Windows/Wine 各 49/49 个代理集成场景；TLS 25 项、LLM TLS 9 项、WSS 10 组及 LLM mock 回归通过，CA 门禁拒绝全部 12 条问题测试链。Windows/Wine 验证不能替代 Windows 实机测试。

排查时先确认已替换新构建产物，再检查容器/进程的代理变量、NO_PROXY 是否命中、代理端口是否可达。`HTTP_PROXY` 被忽略是预期行为；证书校验失败应检查目标证书或 CA 配置。LLM 走独立通道，这些代理设置不会让模型请求自动走代理。
