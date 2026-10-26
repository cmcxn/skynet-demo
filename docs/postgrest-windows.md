# Windows x64 PostgREST 使用与 Wine 验证

Windows ZIP 包含与 Linux 相同的 postgrest-lua、Skynet HTTP 适配层和 8 组 CRUD 测试。
无需单独安装 Lua 或 lua-http，也不需要启动原有 TCP Demo。
业务初始化为 `require('skynet_postgrest_client').new()`；两端业务代码相同。

## 在 Windows 使用

完整解压 `skynet-windows-x64.zip`，在包目录打开 CMD。
先选择一种模板，复制为私有配置（若已有配置不要覆盖）：

```bat
rem 自建 PostgREST
copy postgrest-local.example.bat postgrest-settings.bat
rem 或 CloudBase PG REST
copy postgrest-cloudbase.example.bat postgrest-settings.bat
```

编辑 `postgrest-settings.bat` 中三个变量，保留 BAT 的 `set "名称=值"` 语法：

| 变量 | 自建 PostgREST | CloudBase |
| --- | --- | --- |
| DB_REST_URL | Windows 能访问的 HTTP(S) 服务地址 | `https://<envId>.api.tcloudbasegateway.com/v1/rdb/rest` |
| DB_REST_TOKEN | 取决于自建服务鉴权，内部演示可为空 | 服务端 API Key |
| DB_TIMEOUT_TICKS | 3000（30秒） | 3000（30秒） |

Docker 内部服务名 `postgrest` 无法直接作为 Windows 主机地址。
若服务在本机 Docker，需要单独将 REST 端口绑定到宿主机回环地址，
才可用 `http://127.0.0.1:3000`；项目默认自建 Compose 不发布 REST 端口。
远程自建地址和权限应按实际部署配置。

目标须先建好 `skynet_postgrest_test_20261026(id text PRIMARY KEY, task text NOT NULL,
done boolean NOT NULL DEFAULT false)` 并授予调用方 CRUD 权限。
自建准备方式见 [Docker 指南](postgrest-docker.md)，CloudBase 建表与授权见
[SQL](../components/skynet-postgrest/tests/cloudbase-setup.sql)。

```bat
test-postgrest.bat
```

脚本设置包内 PEM 信任库，保留 HTTPS 证书链与主机名校验，直接连接目标。
配置亦可由父进程环境注入；若有私有 settings 文件，该文件中的值覆盖父进程配置。
每轮生成测试 ID，仅清理自己的测试记录并保留表。成功退出码 0，失败为非零；
缺少 URL 时退出码 2。服务端 API Key 不得放进前端；不要分享或提交私有 settings 文件。
发行 ZIP 只包含模板，构建审计拒绝私有配置及密钥文件。

## 本机构建与 Wine 复跑

```sh
bash scripts/build-windows.sh
python3 scripts/ci/windows-package.py dist/skynet-windows-x64
python3 scripts/test-postgrest-wine.py
```

Wine 脚本读取 `.local/postgrest-cloudbase.env`，默认使用已准备的
`skynet-wine-test:10.0-amd64` 镜像，可用 `POSTGREST_WINE_IMAGE` 覆盖。
它创建临时 PostgreSQL + PostgREST，从实际 ZIP 解压 Windows 包，
初始化独立 Wine prefix，通过 `wine64 cmd /c test-postgrest.bat` 顺序测试两端。
运行包不挂载仓库源码；本地一轮读取临时 Windows settings 文件，云端一轮由环境注入密钥。
结束清理临时数据库、网络及解压目录；保留 `.local/postgrest-wineprefix` 以便复用。
脱敏日志保存在 `.local/postgrest-wine-results/`，不进入发行包。

Wine 测试不能代替原生 Windows CI。现有发布工作流仍在 Windows runner 上检查包内模块、
PE/DLL 依赖、离线测试和 Demo；新增 PostgREST 模块加载与包内文件审计。
CI 不注入真实 CloudBase 密钥，在线 CRUD 是本机 Wine 验证。

## 2026-10-26 验证

- Windows x64 ZIP 完整构建成功，22 个 PE 原生文件及 DLL 依赖闭包、许可证审计通过。
- Wine 10.0 x64：自建 PostgREST 8/8，CloudBase HTTPS 8/8，命令退出码 0。
- 没有新增原生 Windows 10/11 实机验证结论。
- 本机 ZIP 产物不是 GitHub 已发布 Release；正式发布仍走现有 CI 原生验证门禁。
