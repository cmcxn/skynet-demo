# Windows 兼容补丁来源

本项目的 `skynet-mingw.patch` 是将官方 Windows 支持回移到 Skynet v1.8.0 的组合补丁，由本次开发整理和适配。主体兼容层与 MinGW 构建规则来自上游，并非从零编写。

## 上游来源

- [cloudwu/skynet 234e134967da2f1295fc671910e47439cd47f3b1](https://github.com/cloudwu/skynet/commit/234e134967da2f1295fc671910e47439cd47f3b1)：hanxi 提交的 MinGW 交叉编译支持。提取了新增的 `3rd/compat-mingw/` 兼容层和 `mingw.mk`。
- [cloudwu/skynet 4b7addb](https://github.com/cloudwu/skynet/commit/4b7addb)：补充 `3rd/compat-mingw/sys/select.h`，内容与该提交一致。

## 本项目的适配

1. 不包含上游对 `.gitignore`、`Makefile`、`platform.mk` 的修改。原来的 Linux 构建方式保持不变，Windows 构建直接调用 `make -f mingw.mk all`。
2. 从 `mingw.mk` 的源码列表移除 `mem_info.c`，因为固定的 v1.8.0 中尚无该文件。
3. 将兼容层 `sleep()` 的实现由 `Sleep(ms)` 改为 `Sleep(seconds * 1000)`，符合 Skynet 调用方使用秒的约定；否则监控线程会频繁产生错误的死循环提示。
4. 清理补丁文本的行尾空白，不改变代码行为。

补丁只在 Windows 构建容器中的源码副本上应用，不修改宿主机的 Skynet 子模块。DLL 依赖收集、OpenSSL / lua-cjson 编译、BAT 启动与测试脚本由本项目另外编写，不属于上游补丁。

## 核对方法

下载上述两个提交的 `.patch`，可以逐项核对保留的文件和本项目的适配。也可在项目根目录验证补丁是否适用于固定源码：

```sh
git -C vendor/skynet apply --check ../../scripts/windows/skynet-mingw.patch
```

这条命令只检查，不修改源码。补丁中保留了兼容代码及 wepoll 的原始许可证；便携包的 `licenses/` 目录同时包含此说明与实际使用的补丁。
