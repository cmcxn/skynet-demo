# Windows x64 自动构建与下载

工作流 `Windows portable package` 复用项目现有 `scripts/build-windows.sh` 和
`Dockerfile.windows`：在 Linux Docker 内使用 MinGW 交叉编译，随后在独立
`windows-2022` x64 runner 解压 ZIP 并实际运行；Wine 不作为 Windows 原生测试证据。

## 触发及发布

- PR/master push：构建、原生 Windows 测试，保留 `windows-x64-package` artifact 7 天，不创建 Release。
- 默认分支手动运行，publish=true：发布 `windows-<12位提交SHA>` 独立 prerelease。
- 默认分支历史上的 `v*` 标签：发布独立 `windows-v*` prerelease。
- 不自动创建 v1.0、不设置 latest、不修改或覆盖既有 Release/资产。重跑已有 release 会停止，需显式决定后续版本。
- 仅 release job 获得 contents:write，使用临时 GITHUB_TOKEN，不需要新增 PAT。
- Docker 工作流不变；master push 仍仅测试 Linux 镜像，Windows 手动发布不触发 Docker 发布。

下载 Release 内 `skynet-windows-x64.zip` 和 `.sha256`，校验 SHA256 后完整解压。
运行 `start.bat` 启动、另开 `client.bat`；需要空闲 TCP 8888、8000、2013、2526。
包内有 README.txt、BUILD-INFO.json、RELEASE-NOTES.txt、CA 来源及 licenses。
目标电脑不需要 Docker、MinGW、Lua、OpenSSL。二进制未签名，不应关闭系统安全保护。

## 验证范围

打包审计检查所有 EXE/DLL/SO 均为 PE x64、非系统 DLL 依赖闭包、许可证和常见私有配置/缓存排除。
原生 Windows job 验证 ZIP checksum、源码 SHA、cjson/sproto/lpeg/TLS、LLM TLS/CA、UDP 错误码、
协议/SSE、AOI、Skynet 服务内 PG/LLM/TLS 加载及 socket 扩展、TCP demo 启动/读写/强制停止/重启。
测试解压副本，发布 ZIP 保持原始 checksum，不把测试产物打回包内。

仅声称 Windows x64；未新增 ARM64/32位包。托管 Windows Server 2022 验证不等同于所有 Windows 10/11
电脑兼容性保证。在线 HTTPS、真实模型、真实 PostgreSQL/pgvector、GUI 双击、Ctrl+C 停机未作为本流水线门禁。
模型测试仍需用户自行配置私有 llm-settings.bat，可能产生费用，流水线不运行它。

构建器 digest、OpenSSL 3.5.9 源码 SHA256、子模块 gitlink 和 Actions SHA 均固定；APT 包仍来自构建时 Debian 仓库，
所以相同源码重建不保证 ZIP 位级一致，发布的 SHA256 才标识实际文件。

PostgREST 已纳入便携包和模块加载审计，在线自建/CloudBase CRUD 的 Wine 复跑见 [Windows PostgREST 指南](postgrest-windows.md)。发行包不携带私有 `postgrest-settings.bat` 或真实 API Key。
