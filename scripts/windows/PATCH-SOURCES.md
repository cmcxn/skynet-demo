# Windows 兼容代码与补丁来源

当前 Skynet 子模块固定在官方 master 提交 `64391f732e76507ea6615f312cb71be1fd7bfbdd`，包含 Lua 5.5.1。`3rd/compat-mingw/` 和 `mingw.mk` 直接使用此提交中的官方实现；此前回移到 v1.8.0 的 `skynet-mingw.patch` 已移除。官方源码已包含 `mem_info.c` 和以秒为单位的 `sleep()` 实现，无需旧适配。

MinGW 支持的上游来源为 [234e134](https://github.com/cloudwu/skynet/commit/234e134967da2f1295fc671910e47439cd47f3b1)，后续兼容头文件来自 [4b7addb](https://github.com/cloudwu/skynet/commit/4b7addb)。构建使用当前 master 中整套实现，不再单独摘取这些提交。

## 仍需保留的本项目补丁

- `scripts/windows/skynet-mingw-udp.patch`：本项目在 Wine 回归中编写。上游仅转换 TCP `recv` 的 Winsock 错误，UDP `recvfrom` 未转换。补丁增加 `WSARecvFrom` 包装，复用已有错误码映射，将 `WSAEWOULDBLOCK` 转换为 `EAGAIN`。离线测试中的 `test-udp-errno.c` 验证此行为。
- `components/skynet-llm/patches/skynet-socket-flow-control.patch`：本项目编写的 LLM 按需读取扩展，每次读取最多 128 KiB，支持仅注册连接通知的重放。最初针对 v1.8.0，现在已移植到上述 master 提交，并保留上游 `request_init()` 初始化逻辑。这不是官方 MinGW 支持的一部分。

补丁依次应用到容器内的源码副本，宿主机子模块保持干净。DLL 依赖收集、OpenSSL / lua-cjson 编译、BAT 测试脚本由本项目另外编写。Windows 实机仍需验证；Wine 测试不等同于 Windows 实机测试。

## 核对方法

在项目根目录只检查补丁适用性：

```sh
git -C vendor/skynet apply --check ../../scripts/windows/skynet-mingw-udp.patch
git -C vendor/skynet apply --check ../../components/skynet-llm/patches/skynet-socket-flow-control.patch
```

便携包 `licenses/` 保存上游许可证、本说明和实际使用的补丁。后续升级 master 固定提交时，需重新审阅补丁并重跑 Linux 与 Wine 回归；`.gitmodules` 的 `branch = master` 仅指定远程更新目标，真正版本仍由父仓库的子模块提交号固定。

## 客户端 TLS 身份校验

`patches/skynet-verified-client-tls.patch` 从本仓库 `origin/fix/http-proxy-verified-tls` 的 TLS 修复中提取并适配当前 Skynet，未包含代理功能。为原生 HTTPS/WSS 启用证书链和 DNS/IP 校验，修复握手失败的资源清理和最终握手报文处理。Linux、Windows 构建均应用此补丁，宿主机子模块不变。
