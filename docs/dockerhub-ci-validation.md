# Docker Hub CI 本地验证 — 2026-10-25

代码基线：f63f9e05b469f0213504e26df01af5cbc3a5ad9e。
隔离副本分支：codex/dockerhub-ci。原项目未修改，两个未跟踪 .DS_Store 保留。

已通过：
- actionlint v1.7.12（从官方 release 下载并校验发布的 SHA256；未安装 shellcheck）。
- Ruby YAML 解析、sh -n、git diff --check。
- tests/test-openssl-build-config.sh、tests/test-build-platform.sh 行为测试。
- docker build --load --platform linux/amd64 -t skynet-demo:ci-local .
- scripts/ci-image-check.sh skynet-demo:ci-local：ELF/动态依赖、Lua 5.5、cjson、TLS、PG、LLM 安装模块及按需读取接口，23 项 AOI 测试，TCP demo 握手/读写，非 root 用户，许可证和基础敏感路径检查。
- Dockerfile CA 门禁拒绝全部 12 条问题证书链。

测试镜像 ID：`sha256:7f4311152e3bfc1450a54bd15506e4a1411e7dd40d6f5381462d649571d72fe1`，linux/amd64，USER 1000:1000。
这是本地 image ID，不是 Docker Hub 发布 digest。

未执行：GitHub 托管 runner 实跑、Docker Hub 登录和推送、ARM64 构建测试、远端拉取验证。
未读取 secret 值，未创建 token/secret/仓库，未推送 Git 分支。
未完整运行 PostgreSQL 真实数据库、LLM mock 全量、在线模型或代理/TLS 全量集成测试；本次属于现有 runtime 的构建与离线 smoke 门禁。
CodeGraph 原项目数据库无法打开；隔离副本 sync/status 报未初始化，按仓库要求未重新初始化或扩大索引。

待确认 Docker Hub 目标及可见性、精确发布策略和基线合并选择；设置步骤见 dockerhub-ci.md。

## 用户确认后的双架构配置

用户确认目标 chenmins/skynet-demo（公开）、PR/master 构建测试、v* 与手动发布，
并批准将原有 5 个多架构提交合入 master。工作流已相应改为双原生 runner 和独立发布 job。
更新后的 actionlint、sh 语法检查及 AMD64 smoke 通过。ARM64 本地构建与托管 CI 结果见实际 Actions 运行记录。
只读 UI 核验：GitHub 无 repository/environment secrets 和 variables；Docker Hub 未登录。
没有创建或写入凭据。原 Git remote 内嵌凭据，后续通过已连接 GitHub 账号提交，不复用该 remote 的认证信息。
