# C# / .NET 10 重构计划

## 0.3.11 GitHub 发布与公告同步（已完成）

- 用户已授权并完成 GitHub 源码和安装包发布；完整保留此前 0.3.8–0.3.10 有效功能，稳定版 0.3.11 使已装本地 0.3.10 的用户也可检测到更新；未执行真实安装或账号操作。
- 发布公告以 `docs/zh-CN/releases/0.3.11.md` 为唯一正文，嵌入应用供离线显示，并直接用作 GitHub Release body；在线检查显示同版本的 Release 公告，限流回退时读取相应标签的公告文件，公告不可用不阻断更新检查。
- 同步 README、安装说明、贡献说明与变更记录，补充公告行为测试；重新构建、完整回归、隔离安装验证后提交发布。安装包和 SHA-256 作为 Release 附件，不提交运行数据、归档和构建输出。
- 本地最终验证：构建 0 警告/错误，96 项 xUnit（Core 6、Infrastructure 77、Desktop 11、CLI 2）全部通过。实际 WPF 已打开内置 0.3.11 公告，README 示例为合成账号。282 项发布清单和 14 项静态文件与源码一致；真实 WSH、隔离安装副本 GUI/CLI、已知旧入口备份迁移、修改入口保护和卸载留存通过。
- 公开安装器 `dist/0.3.11-release/Codex-Profile-Switcher-Setup-0.3.11.exe`，45,875,523 字节；SHA-256 `7f89e571d7ea83fc88aa0585432da644c1beae31972753df797e0342670308f6`。发布目录 `artifacts/publish/v0.3.11-release`；先提交源码和标签，再核验草稿附件后公开。证据位于 `artifacts/release-0.3.11`，不提交运行或测试材料。
- [v0.3.11 Release](https://github.com/IIMovoMII/Codex-Profile-Switcher/releases/tag/v0.3.11) 的源码与标签目标为 `1f7fa413a3c5101e6eb2cd02153d1ffb473e29f9`。Git HTTPS 连接重置后采用 Git Data API，源码树、提交和带注释标签 SHA 与本地完全相同，无强推。60 项提交变更的敏感模式和禁止数据路径扫描通过。
- 公开公告与内置 Markdown 完全一致；系统代理下 3.73 秒完成 API 403 后网页回退，确认本地 0.3.10 可发现 0.3.11。通过相同 C# 更新服务实际回下载完整公开安装器并验证 SHA-256；公开校验附件也单独下载并逐字节匹配。
- [GitHub Actions 43250035003](https://github.com/IIMovoMII/Codex-Profile-Switcher/actions/runs/43250035003) 全部成功：构建、96 项测试、WSH、公告一致、打包和隔离安装。CI 未覆盖已上传附件，结束后再次核对公告及两项资产 digest 不变。干净 CI 仍报告既有 SQLitePCLRaw.lib.e_sqlite3 2.1.11 的 NU1903 / GHSA-2m69-gcr7-jv3q 告警，未抑制或声称已修复；Node 20 Action 的迁移提示不影响此次结果。

## 0.3.10 安装包体积优化（本地交付）

- 基线：保留全部 0.3.8/0.3.9 未提交功能；0.3.9 正式安装器 47,658,658 字节，发布文件 149,598,492 字节。主要体积来自自包含的 .NET/WPF 运行时。
- 采用 SDK 支持的语言资源筛选及 Inno Setup 更高压缩率；默认继续携带运行时，不启用 WPF 不支持的裁剪或 NativeAOT，不手工删除框架程序集。
- 顺序：确认发布和压缩选项 → 构建并比较真实大小 → 隔离安装验证 WPF/CLI、固定入口、升级及卸载保留 → 更新说明和交付 SHA-256。
- 验证只用临时 CODEX_HOME、数据目录与模拟 CLI；不切换真实账号、不安装到真实目录、不自动推送或发布。
- 已完成：GUI/CLI 发布统一使用 `SatelliteResourceLanguages=zh-Hans`，仅减少 144 个其他语言附加资源，保留内置英文、简体中文及所有框架程序集。安装器采用 `lzma2/ultra64` solid 和独立压缩进程。
- 实测：安装器由 47,658,658 降至 45,821,991 字节（45.45 → 43.70 MiB，减少 3.85%）；发布文件由 149,598,492 降至 141,497,291 字节，减少 8,101,201 字节。另测 128 MiB 字典和 273 fast bytes，仅多省 216,212 字节；最终采用 64 MiB 字典，避免为微小收益增加安装解压内存和打包成本。比较产物位于 `artifacts/size-0.3.10`，不进入发布白名单。
- 验证：两项 `dotnet publish` 编译及 Inno 构建无警告/错误；280 项发布清单、12 项静态文件与源码一致。增强安装测试验证完整运行时、WPF/SQLite 和简体中文资源；子进程显式把 DOTNET_ROOT/X64 指向不存在的隔离目录，已安装副本的 GUI/CLI 仍正常启动。真实 WSH 入口/中文路径/参数/退出码、0.2.9/0.3.6 旧入口备份迁移、用户修改保护、重复安装、独立卸载登记及卸载保留均通过。本轮未修改 C# 业务逻辑，没有重复运行上轮 86 项业务回归。
- 最终包 `dist/0.3.10/Codex-Profile-Switcher-Setup-0.3.10.exe`，SHA-256 `05747107ece723903150a2b5815a7c9e3cc2bceb257d2a2dd3e524d806f72479`；发布目录 `artifacts/publish/v0.3.10`，固定发布指针已更新。文档和版本已同步；未提交、推送、发布 Release、真实安装或真实账号/跨机器试用。

## 0.3.9 更新连接、存储与目录定位

- 保留当前未提交的 0.3.8 界面及有效功能；本轮不提交、推送或操作真实账号/安装。
- 已定位：系统代理出口的 GitHub API 返回 403、`X-RateLimit-Remaining: 0`；同一代理的官方 Release 网页返回 200，直连 API 返回 200。修复为限时 API 检查、识别限流并回退官方 Release 网页，保留来源限制与 SHA-256 验证，显示具体失败原因。
- 存储：无历史修改时不创建备份；已完成备份按数量/大小清理，待恢复、未知格式和用户手动目录保留。更新缓存限量，过期未完成下载自动清理；GUI/CLI 共用策略。
- 目录：默认账号目录和现有 CODEX_HOME 自动解析，参考档案绑定路径及已记住的位置；不可用时才提供手动选择。不移动数据、不改变 DPAPI 的路径绑定、不把显式隔离路径回退到真实环境。
- 实现：`GitHubUpdateService` 增加独立请求/总体时限、403/429 分类、官方 Release 页面与资产链接解析；仍用系统代理，不接收 GitHub Token。`DataLocationResolver` 为 GUI/CLI 共用目录入口，保留显式路径优先与 DPAPI 原路径绑定；新增失效目录恢复窗口和记忆位置。`StorageMaintenanceService` 按完成状态、来源与文件清单识别可清理材料，保护事务、跨备份引用、外部路径、链接与手动文件；无变更历史扫描不生成空备份。
- 已验证：86 项 xUnit（Core 4、Infrastructure 70、Desktop 10、CLI 2）；实际系统代理的 API 403 限流后 3.6 秒回退成功。真实 WSH 中文路径/固定入口/参数/退出码通过。WPF 合成预览实际点击数据位置、更新检查、运行中目录失效、恢复窗口、重新识别和保存位置；已核对记忆文件只含版本与两个路径。启动阶段失效恢复窗也实际显示。
- 原生文件夹选择器已实际打开、导航和取消；自动化工具对嵌套原生窗口的元素索引/焦点返回不稳定，未把最终“选择文件夹”提交当作成功。路径选择后的校验、匹配及记忆由隔离行为测试覆盖。仅停止本轮合成预览进程，临时移动的合成目录已恢复；没有真实用户数据写入/清理。
- 最终同源码自包含 x64 包 `dist/0.3.9-final/Codex-Profile-Switcher-Setup-0.3.9.exe`，SHA-256 `1de6bb6e8472029e65d4a3f22b958615ad465242775d17e89174491fa9fe1a6d`。隔离安装验证 SHA-256、424 项发布清单、12 项静态白名单、安装副本 WPF/CLI、已知旧入口备份迁移、修改入口保护、独立卸载登记及卸载留存。发布输出 `artifacts/publish/v0.3.9-final`，固定入口的发布指针已更新。自动安全审查以 `blocked by policy` 拒绝删除本轮两个中间构建目录，未提供更具体原因；保留 `dist/0.3.9` 与 `artifacts/publish/v0.3.9`，它们不作为最终交付；未尝试绕过审查。
- 当前实现/测试/文档/本地安装包均已落实，无待实现核心 TODO。本轮没有提交、推送、发布 Release 或安装到真实环境；未执行真实账号及跨机器试用。验证材料位于 `artifacts/storage-0.3.9`，界面边界如上。

## 0.3.8 界面重构（本地交付）

- 基线：`33c8535`，工作区干净；按用户提供的五张设计图实现青绿色玻璃质感、Windows 窗口控制、左侧导航、横向账号卡片及右侧账号抽屉。
- 页面映射：账号管理 → 搜索/筛选、添加菜单、行内切换/模型设置/管理菜单；账号抽屉 → 基本信息、模型与目录、网络和上下文；诊断 → 环境、聊天兼容、项目与桌面工具；操作记录 → 持久日志；设置 → 更新、默认策略、数据位置、关于。
- 继续调用现有 C# 核心；账号保存与应用分开；模型来源不联网探测；历史准备按钮明确写入语义；示例图中的账号、进程和更新状态均绑定实际数据。
- 步骤：共用样式与图标 → 页面/抽屉 ViewModel → 真实功能接线 → 隔离回归与真实 WPF 点击 → 文档、0.3.8 安装包及隔离安装验证。
- 验证边界：仅临时 CODEX_HOME、临时数据、合成档案和模拟 CLI；不执行真实切换、OAuth、真实安装或自动发布。
- 实现：`Themes/Light.xaml` 与 `Controls/SymbolIcon` 统一配色、圆角控件和矢量图标；`Views` 包含账号、诊断、记录、设置和右侧账号编辑面板。`ProfileEditorViewModel` 管理草稿及本地模型选择；`MainViewModel` 调用现有 Core，后台工作和进度更新分离。API 名称、连接和策略一次保存，保存前校验档案未被外部更改。
- 新增兼容能力：按实际认证而非注册表最后选中指针显示当前账号；默认策略与自动检查更新偏好只编辑自有设置字段并保留未知内容；模型列表只读投影不会改写手动文件。旧 VBS/CMD 和业务数据格式保持兼容。
- 构建与回归：`dotnet build` 成功；最终 `dotnet test` 58/58（Core 4、Infrastructure 43、Desktop 9、CLI 2），WSH 固定入口测试通过。新增测试覆盖搜索筛选、当前身份、编辑/取消、并发拒绝覆盖、手动目录保护、目录读取/非法结构、默认设置未知字段和更新失败重试/两次确认。
- 实际 GUI：临时 CODEX_HOME、合成官方/API 档案与模拟 CLI；已点击账号模型设置、指定模型并保存、添加 API 菜单、取消编辑、环境检查、取消进行中的检查、默认策略保存、更新/记录导航。最后一次发布副本截图复验收到物理 Esc 停止信号，已停止后续电脑自动操作；没有真实账号操作或真实 OAuth/API 请求。
- 安装验证：最终自包含 x64 包 `dist/0.3.8-ui/Codex-Profile-Switcher-Setup-0.3.8.exe`，SHA-256 `2c082e85f63de08822f6587dfc3bdbbe271c753e0e8ba511cda2c52ac878bf20`。`test-installer.ps1` 验证 SHA-256、424 项发布清单、安装副本 WPF 启动/关闭、CLI、旧 0.2.9/0.3.6 固定入口备份迁移、修改过的入口保护、卸载及数据留存。测试使用独立临时目录和独立 `CPS-Test-…` 卸载登记；正式安装标识不变。
- 最终发布目录 `artifacts/publish/v0.3.8-ui`；12 个白名单静态文件与源码一致，发布指针已更新到该目录。本地截图/测试日志/TRX 位于 `artifacts/ui-0.3.8`；均不分发、不提交。本轮未提交、推送或发布 Release；0.3.7 仍为公开稳定版。

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
