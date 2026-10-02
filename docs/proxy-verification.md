# HTTP 代理与 TLS 验证记录

验证日期：2026-10-02 UTC。基线主仓库：`2b3ab89c0473744c38cc8e6177026932905f8f1e`。
Skynet、jemalloc、lua-cjson 的上游提交保持不变，所有依赖改动由顶层补丁在构建副本中重现。

## 本次功能

- HTTP 正向代理 absolute-form；HTTPS 在 CONNECT 2xx 后使用同一个 fd 建立 TLS
- 环境变量安全优先级、NO_PROXY 边界/端口/IP/IPv4 CIDR、Basic 代理认证隔离
- 默认证书链、DNS 主机名或 IP SAN 验证；系统及显式 CA 配置；没有关闭验证选项
- CONNECT 分段响应/剩余字节、失败清理、总超时、异步 DNS 截止时间、流错误及闲置超时释放
- 共享 TLS 辅助层的 WSS 兼容性和握手失败清理；不新增 WSS 代理功能
- Docker 与原生构建采用同一补丁；原始上游子模块保持干净

## 验证结果

- 本地回环集成：49/49。原版对最初45项仅11项通过；新增4项 DNS/闲置流截止时间在修复前0/4，通过后全部通过
- 代理配置：6组；HTTP 生命周期：7组；TLS 辅助层：1组；WebSocket 兼容性：10组
- TLS 绑定：23项，加独立 SSL_CERT_DIR 默认信任检查1项。真实内存 BIO TLS1.2/1.3，错误 CA、DNS/IP SAN、SNI、构造失败清理和握手最终消息均覆盖
- TLS 绑定 ASan/UBSan 检查通过（关闭 leak detection）。LeakSanitizer 被执行环境 ptrace 限制阻断，不能声称检查了内存泄漏
- 在父 Git 仓库内部，从干净上游源应用补丁、重复应用、六个修改文件 SHA-256 一致性检查通过
- 干净源在默认 .build 路径的原生 Linux 构建通过；同一构建目录再次完整构建也通过。默认构建使用 jemalloc。编译器 GCC14.2、OpenSSL3.5.7、Lua5.4.7
- 原始 TCP demo 三条 PASS；16个独立键值会话、8个并发工作线程通过；两次 heartbeat、quit 后 EOF、监听端口清理通过
- 真实百度：Skynet 客户端经配置的代理完成 CONNECT200、已验证 TLS、HTTP200和非空正文；一次诊断请求得到29,506字节。测试以新生成结果文件 PASS 为准，不以进程退出0代替
- 初次外网请求的10秒预算不足；观测到 CONNECT 本身约10.7秒，因此外网冒烟测试改为30秒总预算。本地短超时回归仍严格执行
- 独立代码审查发现的 WSS 接口、DNS 截止时间、闲置流释放、嵌套目录补丁及重复构建问题均已修复并增加回归

## 复现

安装 Linux 原生依赖后，在仓库根目录运行：

```sh
git submodule update --init --recursive
sh scripts/build-native.sh
RUNTIME="$PWD/.build/runtime"
LUA_PATH="$RUNTIME/lualib/?.lua;;" "$RUNTIME/3rd/lua/lua" tests/proxy-unit.lua "$RUNTIME/luaclib/client.so"
LUA_PATH="$RUNTIME/lualib/?.lua;;" "$RUNTIME/3rd/lua/lua" tests/httpc-unit.lua
LUA_PATH="$RUNTIME/lualib/?.lua;;" "$RUNTIME/3rd/lua/lua" tests/tlshelper-unit.lua
LUA_PATH="$RUNTIME/lualib/?.lua;;" "$RUNTIME/3rd/lua/lua" tests/websocket-unit.lua
sh tests/patch-application.sh
sh tests/tls-test.sh
python3 tests/proxy-integration.py --runtime "$RUNTIME"
(cd "$RUNTIME" && rm -f /tmp/skynet-features-result && ./skynet tests/config-features && test "$(cat /tmp/skynet-features-result)" = PASS)
```

代理地址和 CA 来自运行环境，未硬编码进仓库。全套本地集成只用回环地址与临时证书。真实百度测试需要运行环境允许访问目标站点。

## 限制与已有独立问题

- 当前环境没有 Docker，未执行 Docker 镜像构建/Compose运行；Dockerfile的补丁输入与原生构建一致，但容器实测仍待进行
- 未改用户 Mac，也未在 Mac 上执行复测。Docker Desktop 中访问宿主机代理需使用容器可达地址；无代理场景已在 Linux 回环集成覆盖
- 固定版本 lua-cjson 完整上游套件仍91/105通过，14失败：46–50、93–100、103。另行确认的合法 JSON 整数溢出饱和问题仍存在。本次未修改或掩盖这些基线问题，不能称整个依赖测试套件全绿
- 代理首版只支持 http://，不支持 SOCKS 或 HTTPS 代理传输、NTLM、IPv6 NO_PROXY CIDR
- 原生超时未配置时保持上游无限等待语义；调用方应设置合适预算并及时关闭流
