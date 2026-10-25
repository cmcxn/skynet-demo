# GitHub Actions 与 Docker Hub

目标：公开仓库 `docker.io/chenmins/skynet-demo`。

## 触发与标签

- Pull request、master push：在 ubuntu-24.04（AMD64）和 ubuntu-24.04-arm（ARM64）分别构建并运行离线 smoke，不登录或发布。
- `v*` 标签 push：标签必须指向默认分支可达的提交；双架构测试全部成功后发布。
- 手动 Docker image：默认 publish=false；仅在默认分支选择 publish=true 才发布。
- 每次发布生成 `sha-<完整提交 SHA>` 多架构标签，以及两个 `sha-<SHA>-amd64/arm64` 架构标签。
- 版本触发另外生成原始 `v*` 标签；不创建 latest，也不自动选择版本号。

使用示例：`docker pull chenmins/skynet-demo:sha-<实际提交 SHA>`，可按需指定 `--platform linux/amd64` 或 `linux/arm64`。
发布 summary 提供 manifest digest。标签可能被授权人员重建，部署固定 digest 才能锁定实际产物。

## 首次安全设置

1. 登录 Docker Hub 的 chenmins 账号，创建或确认 skynet-demo 仓库并设置 Public。
2. 创建专用、最小必要读写权限的 Docker Hub access token。不要复用已曝光 token。
3. GitHub 仓库 Settings → Secrets and variables → Actions → New repository secret：名称 `DOCKERHUB_TOKEN`，在 GitHub 安全表单输入 token。不要通过聊天传递。
4. 登录用户名默认 chenmins。如使用另一个有该仓库写权限的服务账号，设置 Actions Variable `DOCKERHUB_USERNAME`；不需要 DOCKERHUB_IMAGE 或 DOCKERHUB_PUBLISH_ENABLED。
5. master 双架构 CI 通过后，在 Actions → Docker image → Run workflow，选择 master 和 publish=true，首次发布 SHA 标签；无需先创建语义版本号。
6. 检查 publish job 成功、Hub 标签与 digest，并确认 manifest 同时包含 linux/amd64 和 linux/arm64。

2026-10-25 检查时，GitHub 仓库无 Actions secrets/variables，Hub 匿名 API 返回 404、浏览器未登录。
因此 token 和目标公开状态仍需设置/核实；不能把构建成功当成发布成功。

## 安全与构建边界

所有 Actions 固定官方仓库完整 SHA；contents:read，checkout 不持久保存凭据。
不使用 pull_request_target；PR 构建任务没有发布 secret。两个架构各自导出已测试的镜像，
发布任务下载本次运行的 artifact，推送这些镜像并按 digest 聚合，不重新构建未测试产物。
只在独立发布 job 引用 Docker Hub token，登录后不执行仓库脚本。
发布前检查目标已存在且公开。Artifact 保留一天，仅在发布运行中上传。

依赖由 gitlink 固定；脚本初始化顶层依赖，只递归初始化 Skynet 的依赖，不追随远端 master。
.dockerignore 排除 .git、本地配置和宿主二进制。运行镜像包含许可证并使用非 root 用户。
Smoke 检查 ELF、动态依赖、模块加载、AOI、TCP demo、许可证和常见敏感路径；不替代全面秘密扫描或完整业务集成测试。

官方参考：
- https://docs.docker.com/build/ci/github-actions/multi-platform/
- https://docs.github.com/en/actions/reference/runners/github-hosted-runners
- https://docs.github.com/en/actions/reference/security/secure-use
- https://docs.docker.com/security/access-tokens/
- https://docs.github.com/en/actions/how-tos/write-workflows/choose-what-workflows-do/use-secrets
