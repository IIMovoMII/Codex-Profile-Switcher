# 贡献指南

欢迎提交问题报告和代码改进。请先搜索已有 Issues，并说明复现条件、预期行为和实际结果。

## 架构和验证

- 业务规则、策略和操作计划放在 `src/Switcher.Core`；文件、DPAPI、SQLite、Codex 格式适配和更新下载放在 `src/Switcher.Infrastructure`。
- WPF 界面位于 `src/Switcher.Desktop`，CLI 位于 `src/Switcher.Cli`。两者调用同一业务核心。
- WPF 共用配色、控件模板和矢量图标分别位于 `Themes`、`Controls`，四个主页面与账号抽屉位于 `Views`。账号草稿由 `ProfileEditorViewModel` 管理，保存前验证原档案未被其他窗口修改；页面不得直接写入认证、配置或数据库。
- 正常运行时不得调用 PowerShell、加载旧 `.ps1` 或把业务逻辑放进 CMD/VBS。构建、安装编排与迁移对照测试可使用 PowerShell。
- 旧 PowerShell 实现、旧界面及旧对照测试已移出当前源码树。需要查阅时使用旧版本标签；不要把旧业务脚本重新放回生产运行链。
- 使用 .NET 10 SDK 在 Windows 上运行 `dotnet build .\CodexProfileSwitcher.sln` 和 `dotnet test .\CodexProfileSwitcher.sln`。涉及安装器时再运行 `build-installer.ps1` 和隔离安装测试。
- 测试必须使用临时 `CODEX_HOME`、临时数据目录、合成账号/JSON/JSONL/SQLite 和模拟 CLI。不得执行真实账号切换、OAuth 登录或 API 请求。
- 运行改动相关测试即可；不得以编译成功代替对关键行为的断言。实际界面变更需在隔离目录中启动 WPF 并完成交互检查。
- 保持直接与传递 NuGet 依赖审计启用，NU1901–NU1904 作为构建错误处理；不要通过忽略告警或删除有效测试来掩盖漏洞。原生 SQLite 的最低安全版本由加载实际引擎的回归测试验证。
- 可在构建后运行 `tests/start-frontend-preview.ps1 -DotNetPath <SDK的dotnet.exe>`：它在临时目录生成合成账号、模型目录与模拟 CLI，禁用启动更新检查，并显式传递临时 CODEX_HOME/数据位置。测试产物仅在 `artifacts`，不可把预览凭据或个人路径加入文档截图。

## 兼容和安全

- 保留当前档案注册表、DPAPI 熵参数、已有账号 ID、模型目录及备份格式；遇到未知结构时按功能边界停止写入或跳过可选操作。
- 位置与格式的兼容范围见 [PATH_COMPATIBILITY.md](docs/zh-CN/PATH_COMPATIBILITY.md)。迁移或新增文件类别时列出旧版位置、候选顺序、显式覆盖及访问/格式错误；GUI 和业务共用定位结果。不得把所有读取异常吞成“不存在”，不得通过全盘寻找同名文件绕过来源核验。
- 自动发现回归至少包含不传 `--codex-exe` 等覆盖的成功用例，以及版本目录变动、候选失效、权限/占用、格式未适配与回退。仅用显式路径或 mock 核心接口的测试不能覆盖发现层。
- 不覆盖配置、目录或数据库中的无关字段。多文件操作需提供持久化恢复材料，并在检测到外部修改时拒绝覆盖。
- 日志、CLI 输出和普通错误信息不得包含 API Key、Token 或完整认证内容。测试使用 `example.invalid` 和合成路径。
- 不提交认证文件、账号快照、聊天、用户日志、用户备份、运行数据、安装包或本机路径。
- 分发文件由 `distribution-files.ps1` 中的静态白名单和独立 `dotnet publish` 输出构成；不要把仓库工作目录整体放入安装包。

## 发布

每个版本只维护 `docs/zh-CN/releases/<版本>.md` 一份完整公告。Core 构建按 `Version` 自动嵌入，分发白名单同时携带该文件；创建 GitHub Release 时用 `gh release create ... --notes-file <该文件>`，不得另外手写不同内容。在线公告从 Release body 获取，限流回退读取对应标签的同一文件。发布流水线验证正文一致，后续修订也需同步版本文件和发布正文。

版本号以 `version.txt` 为准，并保持 `Directory.Build.props` 一致。Windows x64 安装器使用 Inno Setup 6、自包含 .NET 10 发布，不启用 trimming 或 NativeAOT。安装器、SHA-256 清单和升级验证必须来自同一份发布输出。

发布通过 SDK 的 `SatelliteResourceLanguages=zh-Hans` 保留简体中文附加资源，内置英文资源不受影响；GUI 和 CLI 使用相同选项。Inno Setup 采用 `lzma2/ultra64`、solid 压缩和独立压缩进程，打包约需 742 MB 压缩器内存，安装解压字典约 64 MB。不要手工删除框架 DLL 或更改自包含约定来追求包大小；安装测试必须验证运行时、中文资源及未安装 SDK 时的 EXE 启动。

真实账号试用、跨机器验证与隔离测试是不同验证边界；报告时应分别说明，不得声称执行过未运行的项目。

`tests/test-installer.ps1` 使用独立临时安装目录、启动器、CODEX_HOME、数据目录和每次随机的安装登记标识；不创建真实快捷方式。安装副本必须能正常启动和关闭 WPF，再验证旧入口备份迁移、卸载和运行数据留存。

更新连接、目录定位与保留策略集中在 `GitHubUpdateService`、`DataLocationResolver` 和 `StorageMaintenanceService`。更新测试使用模拟 HTTP，定位测试注入临时环境和访问错误，清理测试覆盖恢复依赖、旧版清单、外部路径和未完成操作；不要用真实运行数据做清理验收。GUI 预览可运行 `tests/start-frontend-preview.ps1 -DotNetPath <SDK路径> -AutomaticLocations`，使用临时环境验证默认定位。

历史格式适配集中在 `HistoryJournal`、`PaginatedHistoryAdapter` 与 `HistoryCompatibilityService`。改动须覆盖合成原生分页、UTF-8 字节边界、逻辑/分段身份、父段继承、部分游标、独立/合并 SQLite 及 WAL；同时断言界面 ID、文字、ordinal、未知字段不变。不能只看文件总长度，也不能删除遇到未知结构时停止写入的断言。故障验证应覆盖提交前后、取消、持久恢复记录重启和外部改动，普通切换回归必须连接实际历史服务；历史完成而认证失败时保留历史结果。

`-AutomaticExecutable` 会把模拟 CLI 放入临时 Desktop bin 版本目录，删除子进程中的 `CODEX_CLI_PATH`、隔离 PATH，并通过正常 WPF EXE 启动；配合 `-AutomaticLocations` 可实际点击环境检查，验证全部自动定位链，没有调用本机 Codex。
