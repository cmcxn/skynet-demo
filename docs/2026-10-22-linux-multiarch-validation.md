# Linux 多架构验证记录

日期：2026-10-22。分支：`codex/multiarch-docker`。分析起点：`733d6ad`。

用户范围：先完成 skynet-demo，不接入 mao；全部只做本地分支和提交，不推送。

## 环境和固定依赖

- 主机 macOS ARM64，Docker daemon `aarch64/linux`；AMD64 执行由 Docker 仿真。
- 固定 builder digest `sha256:31b04c011d8d5c28840c51adececb0a5f5ceada0f50aeb46faa205e1ce552ea9` 的 manifest 实测含两个平台。
- 固定 pgvector fixture digest `sha256:7b822b0aac60967beb1ea5e576b8602c94c300a157d187f385ae3e0da199b90a` 的 manifest 实测含两个平台。
- 源码 gitlink 见 [使用指南](linux-multiarch.md)。Pluto 无关的嵌套旧 Skynet 通过 SSH 拉取失败；本轮实际使用的顶层 AOI 源码、Skynet、cjson 和 jemalloc 已取得固定版本，不依赖该嵌套仓库。

## 测试先行和代码审查

- OpenSSL resolver：先观察缺少脚本导致 RED，再验证 pkg-config、两种 multiarch triplet、显式覆盖、链接失败与 trap/临时资源清理 GREEN。
- Docker 入口：先观察缺少 wrapper 导致 RED，再通过 fake Docker 验证 daemon 平台默认、显式平台、标签隔离、skip 拒绝异架构和自定义镜像。
- wrapper 参数修复：先观察 `--platform` 能覆盖环境选择导致 RED，修复后拒绝平台/标签参数，保留常规构建参数。
- Compose：先观察不接受镜像/平台环境变量导致 RED，修复后两平台与无环境变量的兼容测试通过。
- 独立审查已检查 Docker context、TLS 策略和平台传播；真实镜像测试结果在下表独立记录。

## 实际验证

| 项目 | ARM64 | AMD64 |
| --- | --- | --- |
| Docker build | 通过，固定 builder | 通过，固定 builder，仿真 |
| ELF / 动态依赖 / 安装版模块 | 通过 | 通过 |
| 官方 TCP demo | 握手及 set/get 通过 | 握手及 set/get 通过 |
| LLM mock / 安装版 / 流控 | 通过 | 通过 |
| PostgreSQL / pgvector 故障测试 | 通过 | 通过 |
| TLS / CA / HTTP 代理回归 | 通过，代理 49/49 | 通过，代理 49/49 |

结果来自本轮实际命令，不以历史 README 结果代替。真实供应商模型和 Windows 实机不属于本轮 Linux 多架构验收。


### 验证细节

- 两平台均通过 standalone 与 Skynet AOI 测试（各 23 项）、PG/pgvector 安装版集成、LLM 协议 31 项、SSE 6 项及 transport 集成 36 项（包含安装版回归）。
- 原生模块先验证 ELF machine 与动态依赖；`ltls.c` 在启用 SSL 的真实 Skynet 服务内加载，另验证 PG/LLM 模块及 socket read-limit 接口。服务以超时和新建 PASS 标记确认完成。
- TLS 回归覆盖 CA 拒绝链、身份验证、HTTP/WSS 资源清理；两平台构建期间 CA gate 均拒绝 12 个异常证书链。代理测试工具镜像补齐 Python 后执行完整场景，不把缺少测试工具视为产品通过。
- Docker 默认地址池已耗尽，使用未占用的 `10.253.201.0/24` 至 `10.253.204.0/24` 为两个架构的 PG/LLM 分别创建临时网络。测试退出自动清理，未删除已有项目网络。
- 行为测试 `tests/test-openssl-build-config.sh`、`tests/test-build-platform.sh`、`tests/test-compose-platform.sh` 均通过；独立最终审查未发现实质问题。

本机 runtime 镜像：

- ARM64 `skynet-demo:master-64391f7-arm64`：`sha256:c57792dcf778eb7705d1ae1695f1c7dae5638ef60c1ee036ea44b58ac0ef4d02`
- AMD64 `skynet-demo:master-64391f7-amd64`：`sha256:85bae686f8ab6599e22542c944093334577b7fc4791a887f54bf1601b858d830`

AMD64 结果只证明 Apple Silicon Docker 仿真环境中的功能正确性；x86 实机性能、真实供应商模型和 Windows 实机仍需各自验收。本轮未修改 mao 服务接入，也未推送代码或镜像。


### 本地分阶段提交

- `c9c68a7`：目标架构 OpenSSL 探测与编译验证。
- `cb2cdd7`：平台入口、架构标签、Compose 与测试隔离。
- `850bbea`：外部 LLM 报告目录在全新 checkout 下的修复。
- `7e47290`：测试网络可选独立子网与回归。
- 本记录及安装版运行检查随后单独提交。
