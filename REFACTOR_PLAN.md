# C# / .NET 10 实施与验证计划

## 当前任务：0.3.13 文件位置兼容与错误分类（进行中）

- 基线 `9b83495`，工作区干净。截图的 0.3.12 报错可由本机安装布局与源码对应：CLI 实际位于 `%LOCALAPPDATA%/OpenAI/Codex/bin/<版本>/codex.exe`，新版仅扫描 Programs 和 PATH，遗漏旧实现已有的 Desktop bin 与 CODEX_CLI_PATH 支持；公开 0.3.12 同样受影响。
- 新建可注入路径的 C# 发现模块，恢复 Desktop 版本目录优先、根目录和 PATH 回退、显式参数/环境路径；目录不可访问不阻断其他合法候选，不递归扫描整个 Programs。兼容 npm 的原生 CLI 文件，不执行旧脚本或联网探测。
- 回归：合成目录精确复现旧版漏查、多个 Desktop 版本和失效目录、覆盖优先/隔离、PATH/受限目录回退；用模拟 CLI 验证环境诊断、切换核验和失败回滚。开发不执行本机 Codex、真实登录或账号切换。
- 逐项位置审计记录在 `docs/zh-CN/PATH_COMPATIBILITY.md`：恢复旧模型目录/维护标记路径参数、分页库识别；位置记录或手动目录被占用时明确读取失败，权限错误不吞成缺失。项目其他版本、分页投影涉及字节偏移但未适配时明确说明并保留数据，不能声称已覆盖这些格式的写入。
- 环境检查以本地 --version 判断可执行性，无需登录；GUI/CLI 共用查找器。新增正常 EXE、临时 Desktop 安装布局且无显式命令覆盖的前端验证入口，避免测试再次绕过发现层。
- 本地构建 0 警告/错误；128 项 xUnit（Core 6、Infrastructure 105、Desktop 13、CLI 4）全部通过，无跳过。直接/传递 NuGet 依赖审计无已知漏洞。临时正常 WPF EXE 已实际点击诊断/重新检查，显示临时 Desktop 版本目录 CLI 为“已找到”，仅执行模拟 --version；未进行真实切换。证据位于忽略的 artifacts/test-0.3.13 与 artifacts/ui-0.3.13。
- 自包含安装包 `dist/0.3.13-release/Codex-Profile-Switcher-Setup-0.3.13.exe` 已生成，45,950,498 字节，SHA-256 `8cf96c3b1673b3741056d1d76838dc6a080c1371da3cfd8485f14b47b90099df`。真实 WSH/CMD 入口与隔离安装（副本 GUI/CLI、旧入口迁移/修改保护、卸载数据留存）通过；没有更改本机真实安装或快捷方式。发布与 GitHub/CI 核验仍在进行。
- 完成后同步公告和文档，构建/审计/测试、生成 0.3.13 自包含安装包并隔离验证，再发布 GitHub、核验公开更新和 CI。保留现有 0.3.12 发布物与历史。

## 当前任务：0.3.12 仓库清理与安全修复（已完成）

- 基线为 `9b48383`，开始时工作区干净。保留已有业务、数据格式、固定入口及全部有效功能，不改写 Git 历史。
- 已将 35 个旧 PowerShell 实现/旧对照材料、闲置 XAML、两张过时截图及旧 Python 启动器测试移出源码树；本机归档逐文件校验，未提交归档。历史实现仍可通过旧标签查阅。
- 当前仅保留 6 个 PowerShell 开发脚本：`build-installer.ps1` 与 `distribution-files.ps1` 负责打包和白名单，`tests/start-frontend-preview.ps1` 负责隔离预览，`test-launcher.ps1`、`test-installer.ps1`、`test-legacy-installer-upgrade.ps1` 验证入口、安装和旧版升级。保留的 C# 测试没有删除；旧启动器测试的有效检查接入当前 EXE 测试。
- 更新 Microsoft.Data.Sqlite 10.0.15，解析到 SQLitePCLRaw 2.1.13；直接与传递依赖审计未发现已知漏洞。NU1901–NU1904 作为构建错误，新增实际加载原生 SQLite >= 3.50.2 的回归，覆盖 GHSA-2m69-gcr7-jv3q。
- 三个 CI Action 升级到 Node 24，并固定已核验版本的完整提交 SHA；保留构建、行为回归、WSH/CMD、公告一致、打包和隔离安装步骤。
- 入口测试发现 CMD 在括号内提前展开 ERRORLEVEL，会把失败报告为成功；已改为分支标签，关闭延迟展开，保留参数、单次按键等待和退出码。真实 CMD 的 9 个 EXE 探针用例及 WSH 中文路径/参数/编码用例通过。
- 最终构建 0 警告/错误；97 项 xUnit（Core 6、Infrastructure 78、Desktop 11、CLI 2）通过，实际原生 SQLite 为 3.53.3。真实 WSH/CMD 在 PowerShell 7 与 Windows PowerShell 5.1 测试宿主下均通过；重定向标准输入显式去除 BOM，避免 BOM 被误当作 PAUSE 的按键。
- 本地自包含安装器 `dist/0.3.12-release/Codex-Profile-Switcher-Setup-0.3.12.exe`，45,929,529 字节，SHA-256 `2d7804862f4c987ad753044e24545bf22470eac7e380aaede1089c9a0203e0ef`。发布目录 `artifacts/publish/v0.3.12-release`；隔离安装、副本 WPF/CLI 无外部运行时启动、旧入口备份迁移、用户修改保护及卸载数据留存均通过。282 项发布清单、14 项静态文件与源码逐项一致，无 PowerShell 载荷。
- [0.3.12 Release](https://github.com/IIMovoMII/Codex-Profile-Switcher/releases/tag/v0.3.12) 已公开，源码提交/标签目标 `31b00368f3f0dbc92ea57866c61f41779619771b`，源码树与带注释标签逐项核验。GitHub 公告与内置文件一致；两项公开附件大小和 SHA-256 与已验证本地包一致，CI 未覆盖它们。
- [CI 43257811664](https://github.com/IIMovoMII/Codex-Profile-Switcher/actions/runs/43257811664) 在全新 Windows runner 中全部成功：依赖审计、97 项测试、真实 WSH/CMD、打包和隔离安装；完整日志无 NU190x、Node 20 或 warning 注释，检查 annotations 为空。
- 经当前 C# 更新服务从系统代理实际检查并回下载公开安装包，6.12 秒从 API 403 回退成功，本地 0.3.11 能检测 0.3.12；公告、下载 SHA-256 和单独回下载的校验附件均匹配。源码 PS 文件仅剩 6 个、内容约减少 94%；GitHub 当前树无旧业务/旧界面目录，语言统计缓存刷新可能延迟。
- 已保存旧日志并删除一条已修复的旧失败运行 `43212525974`；当前成功 CI 和所有有效测试保留。证据位于忽略的 `artifacts/release-0.3.12`，运行数据和归档不提交。

## 架构与功能映射

| 现有功能 | 当前实现 | 保护目标与验证 |
| --- | --- | --- |
| 初始化、导入当前身份、多官方/API 账号、增删编辑、重新授权与身份核验 | Core/Profiles、Infrastructure/Profiles | 合成认证、DPAPI 旧熵参数、未知 registry 字段、删除防复活、最新凭据、取消恢复、CLI |
| 完整切换、重新应用、进度、取消、互斥和持久日志 | Core/Switching、Infrastructure/Switching | 同类/跨类档案、计划校验、写前并发检查、写后验证、分阶段恢复和外部修改保护 |
| 模型、上下文和代理策略、个人偏好 | Core/Configuration、Infrastructure/Configuration | 继承/保留/显式设置、TOML 语法与注释、未知字段、配置及偏好保留 |
| 手动目录、指定官方账号快照、真实路径与时间 | Infrastructure/Models、Desktop/ProfileEditorViewModel | 官方缓存只读、完整 models 字段、来源隔离、无效缓存留旧快照、手动文件保护 |
| 共享聊天、增量历史、SQLite/WAL、项目投影 | Infrastructure/History、CodexAdapters | JSONL 字节保留、已适配数据库投影、无变更不建备份、提交后失败与重启恢复；分页投影偏移改写及非 state_5 项目格式当前保护性停止/跳过 |
| 账号私有桌面状态与共享项目、个人设置 | CodexAdapters/DesktopStateAdapter | JSON 形状与未知字段、私有/共享状态边界、恢复材料、配置并发保护 |
| 子进程、超时、取消与环境检查 | Infrastructure/Processes | stdout/stderr 分开、成功 stderr、失败退出码、超时/取消、特殊字符、子进程独立环境 |
| GitHub 更新与同源公告 | Infrastructure/Updates、Core/Updates | API 限流网页回退、来源限制、超时重试、SHA-256、确认下载/安装、版本 Markdown 嵌入与 Release 一致 |
| 自动定位与限量保留 | DataLocationResolver、StorageMaintenanceService | 临时路径注入、失效后手动恢复、DPAPI 原路径绑定、恢复依赖与未知/手动材料保护 |
| 中文 WPF 页面、账号抽屉与 CLI | Switcher.Desktop、Switcher.Cli | 合成档案的编辑/保存/取消、模型设置、进度、诊断、记录、更新与策略，双方共用业务核心 |
| 固定入口、自包含安装、旧版迁移与卸载 | 根目录 VBS/CMD、Inno Setup、构建白名单 | 真实 WSH/CMD、中文编码/路径、已知入口先备份迁移、未知修改保护、安装清单哈希、独立登记和卸载数据留存 |

## 关键决定

- 模块化单体：Core 管规则与流程，Infrastructure 管外部能力，WPF/CLI 共用核心。正常运行不调用 PowerShell，也不以旧脚本兜底。
- 沿用档案注册表、DPAPI CurrentUser/原 CODEX_HOME 熵参数、账号 ID、模型快照和备份格式。只修改操作拥有的字段，保留用户设置、未知 JSON 和 TOML 注释。
- 多文件流程为读取、计划、验证、持久化恢复、执行、验证、提交；历史准备与认证/配置是独立事务。取消写入后先安全收尾，遇外部变化保留恢复材料并拒绝覆盖。
- 官方模型缓存只读；身份来源确认后才写账号独立快照。同步失败不影响切换，不覆盖手动目录；快速入口沿用跳过历史和模型处理的约定。
- 运行数据、账号、聊天、日志、恢复材料及归档不得提交或打包；QQ 助手保持独立，只使用已有维护标记协调。
- 安装器只使用 distribution-files.ps1 精确白名单和独立 dotnet publish 输出。Windows x64 携带完整 .NET 10/WPF 运行时，不启用裁剪或 NativeAOT。
- 公告唯一正文是 docs/zh-CN/releases/<版本>.md：构建嵌入、安装分发、GitHub Release 和应用内展示使用同一文件。保留旧版公告供对应版本的更新回退读取。

## 已完成的界面与安装验证基线

- 0.3.8–0.3.11 的 WPF 已用临时 CODEX_HOME、合成账号和模拟 CLI 实际点击验证：账号模型设置/保存/取消、添加 API、环境检查与取消、默认策略、目录失效恢复、更新和内置公告。源码截图仅含合成账号。
- 0.3.11 通过 96 项 xUnit、真实 WSH 和隔离安装；282 项清单与 14 项静态文件和源码一致。自包含 GUI/CLI 在不存在的外部 DOTNET_ROOT 下启动；已知旧入口备份迁移、用户修改保护、重复安装及卸载留存通过。
- [0.3.11 Release](https://github.com/IIMovoMII/Codex-Profile-Switcher/releases/tag/v0.3.11) 源码标签为 `1f7fa413a3c5101e6eb2cd02153d1ffb473e29f9`；[CI 43250035003](https://github.com/IIMovoMII/Codex-Profile-Switcher/actions/runs/43250035003) 成功，遗留 NU1903 和 Node 20 提示由本次修复处理。
- 历次完整阶段记录可在 Git 历史查阅；本文件保持当前实现映射、关键决定和实际验证状态。

## 验证边界

- 开发、测试、安装只使用临时 CODEX_HOME、临时数据目录、合成 JSON/JSONL/SQLite 与模拟 CLI；不执行真实账号切换、OAuth、Codex/中转 API 或真实安装。
- 0.3.7 曾按用户明确授权备份并修复真实桌面固定启动入口；没有更换 LNK 路径，也没有操作真实账号。其余安装验证使用隔离路径与独立 CPS-Test 登记。
- 隔离测试、真实账号试用和跨机器验证分开记录；后两项未自动执行。0.3.12 不修改页面布局，沿用上述交互基线并验证新依赖和最终安装副本启动。
