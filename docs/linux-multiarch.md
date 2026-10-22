# Linux ARM64 与 AMD64 Docker

两种 Linux 架构共用 Dockerfile、Lua 源码、组件 API 和配置结构，分别编译镜像中的 Skynet 与原生模块。macOS ARM 的 Mach-O、Linux ARM64 的 ELF、Linux AMD64 的 ELF 不能混用。Windows/Wine 仍是独立的 x64 路线。

## 固定源码

构建只需要以下子模块，不需要 Pluto 内部另一个旧 Skynet 子模块：

```sh
git submodule update --init vendor/skynet vendor/lua-cjson vendor/pluto
git -C vendor/skynet submodule update --init 3rd/jemalloc
```

gitlink 固定 Skynet `64391f732e76507ea6615f312cb71be1fd7bfbdd`、cjson `ed0db2e29d94eaeb4267430c04abf8a930d8573e`、Pluto `0fdadf37ed121cb3e8c86d8cfa08ec00f0f84738`、jemalloc `81034ce1f1373e37dc865038e1bc8eeecf559ce8`。不能将拉取远程 master 当作复现这些版本。

## 构建

```sh
SKYNET_PLATFORM=linux/arm64 sh scripts/build-linux.sh
SKYNET_PLATFORM=linux/amd64 sh scripts/build-linux.sh
```

本地标签分别是 `skynet-demo:master-64391f7-arm64` 与 `skynet-demo:master-64391f7-amd64`。省略 `SKYNET_PLATFORM` 时读取 Docker daemon 的架构，支持远程 daemon；不会以 macOS 的 `uname` 推断远程目标。自定义标签使用 `SKYNET_IMAGE`，常规 buildx 参数如 `--no-cache`、`--build-arg` 可以继续传给脚本；平台与标签参数只能通过环境变量选择。

构建器 digest 同时提供 ARM64 和 AMD64。Dockerfile 在目标环境中调用 `scripts/openssl-build-config.sh`：优先 pkg-config，回退编译器 multiarch，显式 `TLS_INC`/`TLS_LIB` 覆盖优先，随后实际编译链接 OpenSSL 探针。native 构建共用同一探测脚本；探针不执行目标二进制。

Apple Silicon 上 `linux/amd64` 一般由 Docker 仿真执行。镜像和 ELF 架构可以验证，但不等于已经在 x86 实机上验证性能或稳定性。

## 运行

只启动一种架构即可，两个实例不能同时占用本机 8888：

```sh
SKYNET_PLATFORM=linux/arm64 SKYNET_IMAGE=skynet-demo:master-64391f7-arm64 docker compose up -d --no-build
docker compose exec -T skynet sh tests/run-demo.sh
```

AMD64 时替换上述两个 `arm64`。原来的无环境变量 `docker compose build/up` 仍沿用 daemon 默认平台和原镜像标签；不会自动选择带架构后缀的镜像。这里的 8888 是 TCP sproto demo，不是 mao 网页服务。

## 验证

无需 Docker daemon 的行为测试：

```sh
sh tests/test-openssl-build-config.sh
sh tests/test-build-platform.sh
```

Compose 配置测试只需要 Docker Compose 和 Python3，不会启动服务：

```sh
sh tests/test-compose-platform.sh
```

安装版 ELF、依赖、组件加载检查：

```sh
docker run --rm --platform linux/arm64 -e SKYNET_ARCH=arm64 \
  -v "$PWD:/workspace:ro" --entrypoint sh \
  skynet-demo:master-64391f7-arm64 /workspace/tests/linux-runtime-check.sh
```

AMD64 时同时替换平台、环境变量和标签后缀。检查覆盖 skynet、Lua、全部 cservice/luaclib/client 模块的 ELF 架构和动态依赖，并在真实 Skynet 服务内加载 PG/LLM 与按需读取接口。单独的 Lua 进程不能代替服务上下文加载检查。

LLM mock 与真实临时 PG 测试：

```sh
SKYNET_PLATFORM=linux/arm64 sh scripts/test-llm.sh mock
SKYNET_PLATFORM=linux/arm64 sh scripts/test-postgres.sh
```

这些测试也会构建镜像。已有 runtime 时可设置 `LLM_SKIP_BUILD=1 LLM_TEST_IMAGE=...` 或 `PG_SKIP_BUILD=1 PG_TEST_IMAGE=...`；工具镜像也必须提前构建，PG 跳过工具构建使用 `PG_SKIP_TOOLS_BUILD=1`。默认 runtime/build/tools 标签均含架构后缀，skip 模式检查 runtime/tools 架构，拒绝混用。PG fixture 使用独立临时数据库、证书和网络，不读取已有游戏数据。

真实模型测试仍是显式 `real` 模式，需要本地凭据，可能产生调用费用。结果分别保存为 `.local/llm-results/arm64/real.json` 和 `.local/llm-results/amd64/real.json`，可用 `LLM_RESULTS_DIR` 指定独立目录；不会把供应商协议不兼容算作通过。

本轮实际结果见 [验证记录](2026-10-22-linux-multiarch-validation.md)。只构建和提交本地分支，不推送、不发布 manifest；后续发布聚合镜像之前须分别验证两个平台。

若本机已有大量 Docker 网络、默认地址池耗尽，可给测试指定未占用子网，例如 `PG_TEST_SUBNET=10.253.201.0/24` 与 `LLM_TEST_SUBNET=10.253.202.0/24`。两组并行测试应使用不同子网；测试仍只清理自己创建的网络，不需要删除其他项目网络。

TLS 与 HTTP 代理完整回归需要构建阶段中的编译器和 Python 测试工具，不能用精简 runtime 替代：

```sh
docker build --platform linux/arm64 --target build -t skynet-llm-build:dev-arm64 .
docker build --platform linux/arm64 -f components/skynet-llm/tests/Dockerfile.tools \
  --build-arg LLM_BUILD_IMAGE=skynet-llm-build:dev-arm64 -t skynet-llm-test-tools:dev-arm64 .
docker run --rm --platform linux/arm64 -v "$PWD:/workspace:ro" -w /workspace \
  -e LUA=/out/3rd/lua/lua --entrypoint sh skynet-llm-test-tools:dev-arm64 scripts/test-tls.sh
docker run --rm --platform linux/arm64 -v "$PWD:/workspace:ro" -w /workspace \
  --entrypoint sh skynet-llm-test-tools:dev-arm64 scripts/test-proxy.sh /out
```

AMD64 时替换命令中的全部 `arm64`。
