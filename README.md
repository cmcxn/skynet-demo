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

Skynet v1.8.0 的原生 TLS 客户端没有启用服务端证书验证；安装 CA 证书不会自动改变这一行为。当前测试证明 TLS 加密请求可用，不证明证书及主机名验证已启用。
