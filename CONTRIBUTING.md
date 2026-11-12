# 贡献指南

欢迎提交问题报告和代码改进。请先搜索已有 Issues，并说明复现条件、预期行为和实际结果。

## 架构和验证

- 业务规则、策略和操作计划放在 `src/Switcher.Core`；文件、DPAPI、SQLite、Codex 格式适配和更新下载放在 `src/Switcher.Infrastructure`。
- WPF 界面位于 `src/Switcher.Desktop`，CLI 位于 `src/Switcher.Cli`。两者调用同一业务核心。
- 正常运行时不得调用 PowerShell、加载旧 `.ps1` 或把业务逻辑放进 CMD/VBS。构建、安装编排与迁移对照测试可使用 PowerShell。
- 旧 PowerShell 实现和历史对照测试位于 `tests/legacy-powershell`，只用于维护者检查旧行为，不进入运行链或安装包。
- 使用 .NET 10 SDK 在 Windows 上运行 `dotnet build .\CodexProfileSwitcher.sln` 和 `dotnet test .\CodexProfileSwitcher.sln`。涉及安装器时再运行 `build-installer.ps1` 和隔离安装测试。
- 测试必须使用临时 `CODEX_HOME`、临时数据目录、合成账号/JSON/JSONL/SQLite 和模拟 CLI。不得执行真实账号切换、OAuth 登录或 API 请求。
- 运行改动相关测试即可；不得以编译成功代替对关键行为的断言。实际界面变更需在隔离目录中启动 WPF 并完成交互检查。

## 兼容和安全

- 保留当前档案注册表、DPAPI 熵参数、已有账号 ID、模型目录及备份格式；遇到未知结构时按功能边界停止写入或跳过可选操作。
- 不覆盖配置、目录或数据库中的无关字段。多文件操作需提供持久化恢复材料，并在检测到外部修改时拒绝覆盖。
- 日志、CLI 输出和普通错误信息不得包含 API Key、Token 或完整认证内容。测试使用 `example.invalid` 和合成路径。
- 不提交认证文件、账号快照、聊天、用户日志、用户备份、运行数据、安装包或本机路径。
- 分发文件由 `distribution-files.ps1` 中的静态白名单和独立 `dotnet publish` 输出构成；不要把仓库工作目录整体放入安装包。

## 发布

版本号以 `version.txt` 为准，并保持 `Directory.Build.props` 一致。Windows x64 安装器使用 Inno Setup 6、自包含 .NET 10 发布，不启用 trimming 或 NativeAOT。安装器、SHA-256 清单和升级验证必须来自同一份发布输出。

真实账号试用、跨机器验证与隔离测试是不同验证边界；报告时应分别说明，不得声称执行过未运行的项目。
