# 本机网络约定

- 在这台电脑上从 GitHub 拉取代码遇到连接失败、超时等网络问题时，使用本机代理服务器 `127.0.0.1:20890` 重试。
- 优先对单次命令设置代理，避免修改 Git 全局配置。代理协议按本机服务实际支持的协议确认。
- Docker 容器内访问该本机代理时，使用 `host.docker.internal:20890`，并确认代理允许容器访问。

## CodeGraph 使用与同步

- 本项目已启用 CodeGraph。理解、查找代码或准备修改代码时，优先使用 `codegraph_explore`，并指定 `projectPath=/Users/mac/Documents/skynet-demo`；也可在项目目录运行 `codegraph explore`。
- 完成文件变更后运行 `codegraph sync .`，再用 `codegraph status .` 确认索引状态。
- 当前索引未覆盖的文件或 Git 子模块，在 CodeGraph 查询确认没有结果后再直接读取；不要因查不到符号而擅自改变索引范围或重新初始化。
