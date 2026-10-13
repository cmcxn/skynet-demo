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

Windows 构建仍使用项目固定的 Skynet v1.8.0，兼容代码回移自官方提交 [234e134](https://github.com/cloudwu/skynet/commit/234e134967da2f1295fc671910e47439cd47f3b1) 及 [4b7addb](https://github.com/cloudwu/skynet/commit/4b7addb)，仅在容器内应用补丁。包含多线程 lua-cjson 与静态链接的 OpenSSL 3.5.9；HTTPS 行为与下文描述的 v1.8.0 TLS 客户端一致。首次构建需要联网安装构建依赖并下载经过 SHA256 校验的 OpenSSL 源码，后续构建复用 Docker 缓存。

回移代码修正了 Windows `sleep()` 的秒单位；Windows 示例跳过基于 POSIX stdin 的服务端控制台，交互客户端与 TCP 调试控制台仍可使用。BAT 启动文件使用 Windows 目录分隔符，以兼容配置文件的 `include`。

兼容补丁是从上游提取并适配的组合补丁，详细来源与本项目修改见 `scripts/windows/PATCH-SOURCES.md`；说明和补丁也会随包放入 `licenses/`。

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

验证 JSON 编解码、拒绝无效 JSON、TLS 模块加载，以及向 `https://www.baidu.com/`、`https://httpbin.org/ip` 发起真实请求并解析 IP JSON（需要外网连接）。

Skynet v1.8.0 的原生 TLS 客户端没有启用服务端证书验证；安装 CA 证书不会自动改变这一行为。当前测试证明 TLS 加密请求可用，不证明证书及主机名验证已启用。

## Skynet 模型调用组件

`components/skynet-llm` 提供 Chat Completions、Responses、Embeddings 和 SSE，工具执行留在业务层。Docker 构建会安装 Lua 模块、管理/worker 服务和独立的 OpenSSL TLS 扩展；该扩展启用证书链及主机名校验。

使用方法见 [组件 README](components/skynet-llm/README.md)。运行 `./scripts/test-llm.sh mock` 验证本地协议、调度和 TLS 故障场景；`./scripts/test-llm.sh real` 使用 `.local/mao-models.env` 测试真实模型。`.local/` 已被 Git 与 Docker 构建排除。


便携包同时包含 `skynet-llm` 服务、经过验证的独立 TLS 模块、CA 证书和按需读取补丁。先双击 `test-llm-offline.bat` 检查 DLL、CA、31 项协议和 6 项 SSE 测试；再把 `llm-settings.example.bat` 复制为 `llm-settings.bat`，填写自己的模型密钥，双击 `test-llm.bat` 进行真实调用。无需先启动 `start.bat`。模型结果保存在包内 `llm-real-result.json` 和 `llm-test.log`；包内没有真实密钥。Windows DNS 默认从系统网卡发现，可在私有配置中指定 `SKYNET_LLM_DNS_SERVER`（IPv4，可带端口）。新 TLS 模块使用包内 PEM 信任库，保留证书和主机名校验。编译和 PE/DLL 依赖检查在 Docker 中完成，Windows 实机运行仍需测试。

已在 Docker 内使用 Wine 10.0 x64 执行 Windows 二进制，验证离线 BAT、TLS、原有 demo/JSON/HTTPS/TCP、36 项传输测试、客户端和生命周期，以及近 32 MiB 流与取消。测试发现并补充了 Windows UDP `recvfrom` 的 Winsock 错误码转换；离线 BAT 包含对应回归程序。真实模型为 8 项通过、2 项已知 Responses 服务不兼容。Wine 测试显式指定 DNS，Windows PowerShell 自动发现部分仍需实机验证。

本机已验证的 Wine 环境固定为 `skynet-wine-test:10.0-amd64`。日常直接复用该镜像，不需要重新安装 Wine。离线备份为 `dist/skynet-wine-test-10.0-amd64.tar.gz`，不纳入 Git；镜像被删除后可以恢复：

```sh
gzip -dc dist/skynet-wine-test-10.0-amd64.tar.gz | docker load
docker run --rm skynet-wine-test:10.0-amd64 /usr/lib/wine/wine64 --version
```

需要重建时使用 `docker build --platform linux/amd64 -f Dockerfile.wine -t skynet-wine-test:10.0-amd64 .`。构建文件锁定 Debian 基底摘要及 Wine `10.0~repack-6`；其他 APT 依赖仍取构建时仓库版本，因此完整一致的恢复优先使用离线备份。镜像仅包含测试工具，Windows 包、结果、Wine prefix 和模型密钥均在运行时单独提供，不应通过 `docker commit` 保存测试容器。
