# C# / .NET 10 重构计划

## 基线与约束

- 本文件所在的仓库目录为唯一项目根目录；开始时基线为 `d60a4c8`，未提交工作区干净。本轮变更保留在原工作区，没有 reset、clean 或覆盖旧发布包。
- 已按要求读取维护说明、状态、README、安装说明和贡献指南。账号与备份仍使用 `%LOCALAPPDATA%\CodexProfileSwitcher`；聊天与项目沿用用户现有 `CODEX_HOME`。
- 全部行为测试使用临时目录、合成凭据与数据库；没有执行真实账号切换、OAuth、API 调用或真实用户安装。
- 使用本机临时 .NET 10 SDK 与 Inno Setup 6。发布目标为 Windows x64、自包含运行时，不启用 trimming 或 NativeAOT。

## 功能对照

| 功能范围 | 新实现 | 验证证据 |
| --- | --- | --- |
| 首次初始化、当前账号导入、多官方/API 档案、增删改名、重新授权及凭据加密 | `Switcher.Core/Profiles`、`Switcher.Infrastructure/Profiles` | 合成认证、身份核验、未知 registry 字段、删除防复活、实时 OAuth token 保存、取消恢复与 CLI 导入/删除测试 |
| 同类/跨类切换、重新应用、失败恢复、写前检查和操作日志 | `Switcher.Core/Switching`、`Switcher.Infrastructure/Switching` | 双向与同类档案行为、写后验证回滚、并发变化拒绝覆盖、持久化恢复记录测试 |
| 模型、上下文、代理的继承/保留/显式策略及局部 TOML 编辑 | Core `Configuration`、Infrastructure `TomlConfigEditor` | 注释、未知字段、官方移除 API 覆盖、个人偏好保留与策略测试 |
| 官方原生目录、按账号校验并隔离的快照、API 手动文件 | `Switcher.Infrastructure/Models/ModelCatalogService` | 完整未知字段、来源隔离、手动文件保护、坏缓存保留旧快照、事务恢复错误测试；WPF 显示真实路径与维护方式 |
| 共享聊天/项目、账号私有 renderer 状态、SQLite 项目投影 | `CodexAdapters`、`History/ProjectProjectionService` | 双官方账号状态隔离、共享项目与未知偏好；SQLite/WAL 备份、归属投影、并发保护测试 |
| 历史 JSONL 增量、数据库兼容、取消和进程中断恢复 | `Switcher.Infrastructure/History/HistoryCompatibilityService` | JSONL 与 SQLite 备份、重复准备、部分写入回滚、重启恢复及外部修改拒绝覆盖测试 |
| 环境检查、互斥锁、子进程、更新重试/下载/校验 | `Processes`、`Updates`、Desktop 环境页 | stderr/退出码、超时、取消、独立环境、更新暂时错误、恶意 URL、SHA-256 和下载变更测试 |
| 公共 CLI、参数兼容、固定入口 | `Switcher.Cli`、根目录 VBS/CMD | CLI 状态、档案操作、合成 API Key stdin 隐藏、JSON、退出码和临时 CODEX_HOME；安装测试核验固定入口 |
| 中文 WPF、进度、取消、账号/模型/环境/更新页 | `Switcher.Desktop` | ViewModel 单测与本轮隔离真实窗口交互验收 |
| 自包含 x64 安装、桌面入口选项、旧入口迁移和卸载 | `installer`、`build-installer.ps1`、`distribution-files.ps1` | SHA-256 清单、精确分发清单、隔离安装/重复安装/旧入口迁移/用户修改保护/卸载留存测试 |

## 实施决定

- GUI 与 CLI 共用 Core 服务；外部文件、进程、DPAPI、SQLite、Codex 格式及更新能力通过 Infrastructure 接口组合。
- 档案注册表、凭据封套、模型目录和备份沿用兼容结构。切换器只编辑拥有的配置字段；未知 JSON 字段保留。
- 多文件写入采用读取状态、计划校验、持久化恢复材料、执行、验证和提交。历史事务与认证/配置事务分开，外部改动时保留恢复材料。
- 安装器只从精确静态白名单和 dotnet publish 结果组包。识别旧固定启动器后先备份再升级；未知自定义内容保留并提示。后续更新使用固定入口路径指针。
- 0.3.6 安装器按 SHA-256 清理已知 0.2.9 发布的 11 个 PowerShell 文件；被改动或不在白名单中的文件保留并提示，目录扫描跳过 reparse point。
- 旧 PowerShell 实现、SQLite helper、`CodexPortableHistory.cs` 和对应的 21 个旧回归脚本已收在 `tests/legacy-powershell`；默认入口和发布白名单不引用这些材料。

## 阶段状态

1. [x] 建立 .NET 10 solution、Core、Infrastructure、WPF、CLI 与 xUnit 工程。
2. [x] 迁入账号、凭据、配置策略、TOML 编辑和实时凭据保存。
3. [x] 迁入完整切换计划、互斥锁、原子文件操作、恢复日志、取消收尾与并发保护。
4. [x] 迁入模型目录、聊天历史、SQLite/WAL、项目投影和账号私有 Desktop 状态。
5. [x] 实现共用业务核心的 CLI、中文 WPF 管理界面、进度/取消和 GitHub 更新流程。
6. [x] 完成兼容入口、自包含安装器、文档、隔离 UI 与安装验收。

## 验证边界

- 0.3.7 修复已授权的真实桌面固定入口：先保留原始字节备份，再更新为 EXE 启动器，桌面 LNK 未改动。使用临时数据和不存在的 Codex 可执行路径，通过该 LNK 的实际目标/参数启动并看到 `v0.3.7` WPF；没有真实账号切换。
- 0.3.7 中文安装向导实测“选择目标位置”和桌面入口任务页，随后取消退出；另在中文临时路径进行完整安装测试，覆盖 0.2.9 和 0.3.6 启动器备份迁移、用户改动保护和卸载保留。真实 WSH 测试覆盖 UTF-8/UTF-16 中文路径、源码发布指针、三个入口和退出码。`dotnet build/test` 继续通过 0 警告/错误和 51 项测试。
- GitHub 发布包为 `dist/0.3.7-release/Codex-Profile-Switcher-Setup-0.3.7.exe`，SHA-256 `2c2512ae1da05e0a2befb0d37def56b6e608b79ef48e4977a2f8e95d1876db52`。发布输出 `artifacts/publish/v0.3.7-release`，424 项清单通过安装校验，12 个静态白名单文件与最终说明一致。本地较早构建保留，以下 0.3.6 记录为上一轮验收证据。
- `dotnet build CodexProfileSwitcher.sln` 通过，0 警告、0 错误；`dotnet test CodexProfileSwitcher.sln --no-build` 通过 51 项：Core 4、CLI 2、Desktop 3、Infrastructure 42。
- WPF 隔离安装副本已真实启动并点击：添加 API、保存合成档案、查看实际模型目录/说明、打开编辑窗后取消、运行环境检查并确认完成状态。启动检查更新已关闭，Codex 可执行路径指向不存在的临时文件。
- 隔离安装集成测试通过：423 项发布清单逐文件校验、无 PowerShell 文件、安装、旧入口迁移和备份、重复安装保留用户修改、卸载保留模拟数据。
- `tests/test-legacy-installer-upgrade.ps1` 验证旧 `0.2.9` 到 `0.3.6`：11 个已知未改动脚本均清理；附加模拟用户改动时保留该文件并写出告警。两种情形均成功卸载并清理临时目录。
- 最终本地包：`dist/0.3.6-final-source/Codex-Profile-Switcher-Setup-0.3.6.exe`，SHA-256 `a2ff3a93b4fb96e3651d99cd039e0031cfef9b2b82319d7fb35dc62031311002`；自包含发布输出在 `artifacts/publish/v0.3.6-final-source`。423 项清单均通过安装包内哈希校验，11 个静态白名单文件与源码一致，清单无 PowerShell 文件。
- WPF 实际交互验收针对本次重构的界面及业务代码完成；0.3.6 重建改变程序集版本标记和安装迁移逻辑，界面源码没有变化。0.3.6 安装器集成测试另行验证最终包安装、CLI 启动、固定入口、升级保留和卸载。
- `src` 生产代码扫描未发现 PowerShell 运行时调用；`git diff --check` 无空白错误。没有执行真实账号切换、OAuth、Codex/中转 API 请求、真实用户目录安装、桌面快捷方式写入或跨机器验证；没有提交、推送或发布 Release。`0.3.6` 尚未发布到 GitHub。
