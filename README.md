# Skynet Docker Demo

使用 `hanxi/skynet-builder` 编译官方 Skynet v1.8.0 的 Linux 版本，再将运行文件复制进 Debian trixie-slim。镜像名使用标准 Docker Hub 名称并固定 digest；运行镜像不包含 GCC / MinGW，使用非 root 用户。

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

## 源码与依赖

- Skynet: https://github.com/cloudwu/skynet ，`vendor/skynet` 为 Git 子模块，固定在 tag `v1.8.0` 的提交 `ba64be6f9fa044933c77de1317f466afbade8eaa`。
- jemalloc: 使用该 tag 指定的子模块提交 `54eaed1d8b56b1aa528be3bdd1877e59c56fa90c`。
- lua-cjson: `vendor/lua-cjson` 子模块来自 https://github.com/cloudwu/lua-cjson.git ，固定提交 `ed0db2e29d94eaeb4267430c04abf8a930d8573e`。使用 Skynet 的 Lua 5.4 头文件编译，启用多线程支持。
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

验证 JSON 编解码、拒绝无效 JSON、TLS 模块加载，以及向 `https://www.baidu.com/` 发起真实请求（需要外网连接）。

本项目通过 `patches/skynet-http-proxy-verified-tls.patch` 在构建副本中补齐 HTTP 代理及 TLS 服务端验证。固定的上游子模块提交不变；无需推送修改后的 Skynet 子模块，也不要直接在 `vendor/` 中应用补丁。Docker 和原生构建都运行相同的补丁脚本。客户端默认检查证书链、DNS 主机名/IP SAN；验证失败会终止请求，没有跳过验证开关。共享 TLS 模块的 WSS 客户端也启用相同验证，并修复 IP/主机名及握手失败清理；本次不新增 WSS 代理路由。

## HTTP 代理与 CA

原有调用不变：`httpc.get("https://www.baidu.com", "/")`。HTTP 请求使用 absolute-form；HTTPS 先对目标 `host:port` 建立 CONNECT，收到 2xx 后在同一连接上执行 TLS。目标 DNS 留给代理解析，SNI/证书检查始终使用不带端口的目标主机名。

- HTTP：依次读取 `http_proxy`、`all_proxy`、`ALL_PROXY`；为避免 CGI 请求头注入，忽略 `HTTP_PROXY`
- HTTPS：依次读取 `https_proxy`、`HTTPS_PROXY`、`all_proxy`、`ALL_PROXY`
- 小写变量存在时优先；空值表示禁用该级及后续代理回退
- `no_proxy` 优先于 `NO_PROXY`，支持逗号分隔的域名及子域边界、可选端口、IPv4/IPv6 字面量、IPv4 CIDR、单独的 `*`。不支持 IPv6 CIDR 或通配符域名。IPv6 使用地址的相同文本写法匹配
- 目前只支持 `http://` 代理；HTTPS 目标可以使用 HTTP 代理。选中的 SOCKS/HTTPS 代理配置会明确失败，不会悄悄直连
- 可设置 `httpc.proxy = false` 强制直连，或设为 `http://proxy:port` 指定代理（仍受 NO_PROXY 约束）；`nil` 使用环境配置
- `http://user:password@proxy:port` 支持 Basic 认证，用户名/密码可用百分号编码。只从代理 URL 生成 Proxy-Authorization；调用方传入的该头会被移除，避免跨隧道/直连泄漏。HTTP 代理链路本身未加密，请仅对可信网络中的代理使用认证。不要把凭据写入代码、镜像或 Git
- `httpc.timeout` 单位为 10ms，覆盖连接、CONNECT、TLS、响应及流读取的总预算；未设置则沿用上游无超时行为。流读取结束或不再需要时必须 `stream:close()`，也可使用 Lua 5.4 `<close>`。到期后连接会被中断；已返回但未消费的流也会释放连接和 TLS 资源
- OpenSSL 默认信任系统 CA，支持 `SSL_CERT_FILE`/`SSL_CERT_DIR`；也可按服务设置 `httpc.cafile`/`httpc.capath`。自签名或企业代理 CA 必须由管理员提供可信证书，不能关闭校验。独立指定 CA 文件/目录会替代默认信任来源

Compose 显式传递代理环境变量。容器中的 `127.0.0.1` 指容器自身；在 Docker Desktop 中使用宿主机代理时，按本机约定设置 `http://host.docker.internal:20890`，并确保代理允许容器访问。CA 文件必须另行以只读卷挂载到容器，并把容器内路径设为 SSL_CERT_FILE，不能直接传宿主机路径。不要将当前云环境的代理端口或 CA 文件复制到自己的机器。

## 原生构建与本地回归

需要 C 编译器、make、OpenSSL 开发包、autoconf、m4、Perl、git、patch；测试另需 Python 3 与 openssl 命令。

```sh
git submodule update --init --recursive
sh scripts/build-native.sh
RUNTIME="$PWD/.build/runtime"
LUA_PATH="$RUNTIME/lualib/?.lua;;" "$RUNTIME/3rd/lua/lua" tests/proxy-unit.lua "$RUNTIME/luaclib/client.so"
LUA_PATH="$RUNTIME/lualib/?.lua;;" "$RUNTIME/3rd/lua/lua" tests/httpc-unit.lua
python3 tests/proxy-integration.py --runtime "$RUNTIME"
LUA_PATH="$RUNTIME/lualib/?.lua;;" "$RUNTIME/3rd/lua/lua" tests/tlshelper-unit.lua
LUA_PATH="$RUNTIME/lualib/?.lua;;" "$RUNTIME/3rd/lua/lua" tests/websocket-unit.lua
sh tests/patch-application.sh
sh tests/tls-test.sh
```

构建文件放在 `.build/`，不修改子模块。可以设置 BUILD_DIR、JOBS、PLATFORM、TLS_INC、TLS_LIB；原生脚本及测试以 Linux 为基准；Mac 建议先沿用 Docker Desktop 流程，仍需在目标机器复测。

集成测试只监听回环地址，使用临时 CA/私钥，覆盖代理认证、CONNECT、直连、证书拒绝、超时与连接清理。原始 TCP demo 与真实百度请求继续使用前文测试命令；运行特性测试前必须清除旧结果，退出码本身不代表 PASS。

已知独立问题：固定版 lua-cjson 的完整上游套件存在数字扩展及诊断差异，并有合法整数溢出饱和问题；本补丁不修改它。

完整验证范围、复现命令及已知限制见 [验证记录](docs/proxy-verification.md)。
