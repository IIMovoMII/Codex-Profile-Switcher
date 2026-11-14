# C# / .NET 10 实施与验证计划

## 当前任务：0.3.16 GitHub 发布（已完成）

- 用户反馈本机切换暂时正常，明确授权推送源码与安装包；该反馈是用户本机试用结果，不扩展为跨机器验证。再次运行 196 项 xUnit（6/173/13/4）全部通过无跳过，真实 WSH/CMD 回归通过。
- [0.3.16 Release](https://github.com/IIMovoMII/Codex-Profile-Switcher/releases/tag/v0.3.16) 已公开并设为最新稳定版，源码和带注释标签目标 `6deed6685a75ee0cf92878df519e0cf5f15ad633` 与远端一致。0.3.15 的继承历史修复随本版一起发布；README、安装说明、变更记录、内置及在线同源公告已同步。
- 正式包 `dist/0.3.16-release-final/Codex-Profile-Switcher-Setup-0.3.16.exe`，45,960,239 字节，SHA-256 `f8862e32bbfb95ac89ae339c199ce2694646d4da0f2e0211bc2d3f668e1cbfd8`；283 项清单及 15 项静态文件逐项匹配。清理测试编译缓存后重建，程序与本机已验收版本逐字节一致，仅三份发布说明变化；最终隔离安装、真实固定入口、旧入口迁移/备份、旧文件保护及卸载留存均通过。
- [CI 43570502988](https://github.com/IIMovoMII/Codex-Profile-Switcher/actions/runs/43570502988) 的全新 Windows 构建、依赖审计、196 项测试、WSH/CMD、打包和隔离安装全部成功，0 警告/错误、无跳过，annotations=0。CI 完成后两项发布资产大小/digest 和公告仍与本地一致；公开安装器与校验附件已回下载并逐字节匹配，未被 CI 重建包覆盖。证据 `artifacts/release-0.3.16`。
- 运行数据、维护备份、日志及构建产物未进入源码提交；安装器及校验清单仅作为 Release 附件。本轮没有再次更新或操作真实安装，没有替用户执行账号切换、OAuth 或 Codex API 请求。后续本机修复继续先备份、直接维护已安装版本并验收入口。

## 当前任务：0.3.16 安装入口与旧文件清理（已直接修复本机）

- 保留前轮 0.3.15 未提交变更。用户实际安装后复现找不到程序，核对载荷 283 项无缺失或改动，根因是固定入口未清除安装器路径末尾 CRLF；新增红灯测试复现，修复首尾空白/BOM 并拒绝多路径。上轮验收未执行安装后的真实固定入口，已补齐。
- 新增已知 0.3.7–0.3.15 入口的 SHA-256 迁移/备份；以原始发行脚本为测试夹具并锁定字节。构建生成退役公告的版本及 SHA-256 白名单，只删除原版旧说明，保留修改、未知文件和目录链接。安装回归实际启动固定入口 WPF、核对版本登记与旧公告/用户文件处理。
- 196 项 xUnit、实际 WSH/CMD 和隔离安装/入口迁移/卸载留存通过；包/载荷 283 项和 15 项静态文件一致。本地内部包 45,962,702 字节，SHA-256 `5881a879529c4361ae2487ec22c34be18cab1990ba59e7d1b5c2117576dbf6f5`，证据 `artifacts/test-0.3.16`。
- 用户要求以后直接修复已装程序，本轮已先备份再将 D 盘安装升级为 0.3.16，卸载登记同步正确。原版旧公告已清除，安装目录除卸载组件和清单外无额外文件。两个桌面快捷方式和 LOCALAPPDATA 兼容入口均已修复，实际从两个桌面入口启动，电脑操作确认版本/账号列表正常，窗口留给用户。
- 已在 AGENTS 登记后续本机维护方式。未真实切换账号、OAuth/API、关闭 Codex、提交/推送或公开发布。下列 0.3.15 记录为上轮交付边界，本机版本现已更新。

## 当前任务：0.3.15 多段会话元数据兼容（本地完成，尚未发布/真实安装）

- 基线 7073fdd，受跟踪工作区无未提交修改。截图出现“同一历史文件含有不同会话身份”；先只读检查元数据形状与旧版边界，核实是有效继承/恢复结构还是身份冲突，不删除保护断言或改写真实聊天。
- 根据已验证的来源设计会话/物理投影映射，使用合成夹具覆盖多段元数据、分页游标、继承、冲突拒绝、重复执行、故障恢复和普通切换。同步检查相似的首段/唯一身份假设。
- 本轮完成本地修复、相关与全套测试、中文说明、0.3.15 自包含安装器及隔离安装验证；不依据本文件追认发布或真实安装授权，不执行真实账号切换、OAuth 或 Codex API。
- 只读核对定位为分页子代理复制父会话元数据与历史前缀；首条子代理元数据拥有物理文件，父元数据为继承内容，其 history_base 与子文件游标无关。父、派生、session_id、thread_spawn 来源、连续 ordinal 和 subagent_history_start_ordinal 共同校验后才接受多身份前缀，边界后的其他会话事件仍拒绝。
- provider 关联只收集每个本地文件的首条真实身份，沿用所有记录的原有 provider/模型输入标识转换及字节映射；复制的前缀不能证明子代理 UI 项目来源。普通/分段文件名核验、就绪缓存版本 4（恢复清单仍版本 3）已接入。
- 最终 Release 构建 0 警告/错误；196 项 xUnit（Core 6、Infrastructure 173、Desktop 13、CLI 4）全通过、无跳过，比 0.3.14 新增 35 项继承、冲突、单/双文件投影、缓存升级、普通切换与故障/重启恢复回归；真实 WSH/CMD 入口通过。
- 只读内存规划曾完整通过本机 58 个 JSONL 和关联库，首轮文件哈希无变化。后续并发核对确实被活动历史增长触发偏移保护（读取后文件由 253877241 增至 253901067 字节，游标已到新末尾）；没有为通过验证关闭 Codex、绕过保护或实际写入。不能把运行中读取视为退出后的真实切换验收。
- 包 `dist/0.3.15-local/Codex-Profile-Switcher-Setup-0.3.15.exe`，45,964,191 字节，SHA-256 `2d3c7e9c1c1e066a081d182c9f8dcab13bf1943c344903ecc6a5321f8d0ac4a3`；283 项发布清单及 15 项静态文件与源码匹配，EXE 版本 0.3.15.0。隔离安装副本的校验、CLI/WPF 启停、自包含运行时、固定入口升级/用户修改保护、卸载与数据留存通过；证据 `artifacts/test-0.3.15`。
- 根目录源码入口指向 `artifacts/publish/v0.3.15-local`。本机 D 盘已安装副本仍为 0.3.14，本轮未真实升级、未提交/推送或公开发布，也未执行真实账号切换、OAuth、Codex API 或跨机器试用；README/安装说明明确区分本地 0.3.15 与公开 0.3.14。保留本轮开始时已有的未提交计划材料。

## 当前任务：0.3.14 分页历史兼容与迁移回归（已完成并公开）

- 基线 `8809ad9`，工作区干净。0.3.13 的分页库保护性拦截阻断正常切换；本轮补齐已知分页索引的正式 C# 适配，不能仅移除拦截或用快速切换掩盖问题。
- 对照旧历史实现与合成夹具，明确 JSONL 字节映射、thread_items/thread_turns/thread_history_projection_state 及 threads 元数据的同步规则；保留未知列和无关账号/线程。检查同类 JSON 字节位置、缓存指纹、库格式/恢复遗漏。
- 分阶段恢复记录覆盖 JSONL 与所有数据库投影；执行前检查并发变化，部分失败/中断/取消可恢复，遇外部变化停止覆盖。历史准备仍独立于后续认证切换。
- 增加合成原生分页数据、UTF-8/CRLF/BOM、多个数据库/WAL、增量、故障/中断/外部变化与完整切换的隔离回归。已完成构建、测试、文档、0.3.14 自包含包及隔离验收，按既有授权同步 GitHub 与公告并验证公开更新。
- 已接入 HistoryJournal 字节边界映射与 PaginatedHistoryAdapter：原生项目来源核验、游标/轮次偏移、逻辑/分段身份、本地父段继承、未知字段保留；版本 3 恢复计划兼容版本 2，回退前先检查所有来源。修复 UTF-8 字节/字符索引混用、BOM/空白布局、WAL 指纹和新备份版本保留遗漏。
- 最终本地构建 0 警告/错误，161 项 xUnit（Core 6、Infrastructure 138、Desktop 13、CLI 4）全部通过，无跳过；其中新增 29 项分页回归、3 项连接实际历史服务的完整切换与 1 项新备份保留回归。覆盖总长度不变但中间偏移已变、空投影表的并发插入、WAL 备份/回退和已持久化计划的重启恢复状态。直接/传递依赖无已知漏洞，真实 WSH/CMD 入口验证通过。证据 artifacts/test-0.3.14。
- 自包含安装器已生成并通过隔离安装：dist/0.3.14-release/Codex-Profile-Switcher-Setup-0.3.14.exe，45,944,639 字节，SHA-256 `0ec162123baafa223126960bcc59e06dccbfebedd526e531be396525a3359818`；发布目录 artifacts/publish/v0.3.14-release。283 项载荷清单、15 项静态文件与源码匹配；副本 WPF/CLI 启动、旧固定入口升级/修改保护、卸载和数据留存均通过。未修改本机真实安装、快捷方式或账号。源码隐私扫描通过，无运行数据或归档提交。
- [0.3.14 Release](https://github.com/IIMovoMII/Codex-Profile-Switcher/releases/tag/v0.3.14) 已公开；源码与标签目标 `fcf50233369e617c2c14934d53e520c579cc83e3`，远端分支、带注释标签及目标 SHA 已核对。公告与内置来源、两项资产大小/digest 与本地一致，CI 完成后仍未被覆盖。
- [CI 43438085933](https://github.com/IIMovoMII/Codex-Profile-Switcher/actions/runs/43438085933) 全新 Windows 构建、161 项测试、WSH/CMD、打包和隔离安装全部成功；无 NU190x、Node 20 或 warning/error 注释，annotations=0。使用发布的 C# 更新代码，以旧版 0.3.13 检查 0.3.14，5.57 秒从 GitHub API 403 回退发布页成功，公告与内置文件一致；实际下载完整公开安装器并核对 SHA-256，校验附件逐字节一致。首次下载曾因 TLS 流中断失败，临时包已清理，重试后成功；未修改用户代理。证据 artifacts/release-0.3.14。
- 验证使用合成目录与模拟运行接口，恢复测试重放真实生成的恢复清单和部分提交状态；未执行真实账号切换、OAuth、Codex API、真实安装或跨机器试用。未来未知偏移、来源冲突及无法核验的旧布局仍保护性停止，不能声称所有未来格式自动支持。

## 当前任务：0.3.13 文件位置兼容与错误分类（已完成）

- 基线 `9b83495`，工作区干净。截图的 0.3.12 报错可由本机安装布局与源码对应：CLI 实际位于 `%LOCALAPPDATA%/OpenAI/Codex/bin/<版本>/codex.exe`，新版仅扫描 Programs 和 PATH，遗漏旧实现已有的 Desktop bin 与 CODEX_CLI_PATH 支持；公开 0.3.12 同样受影响。
- 新建可注入路径的 C# 发现模块，恢复 Desktop 版本目录优先、根目录和 PATH 回退、显式参数/环境路径；目录不可访问不阻断其他合法候选，不递归扫描整个 Programs。兼容 npm 的原生 CLI 文件，不执行旧脚本或联网探测。
- 回归：合成目录精确复现旧版漏查、多个 Desktop 版本和失效目录、覆盖优先/隔离、PATH/受限目录回退；用模拟 CLI 验证环境诊断、切换核验和失败回滚。开发不执行本机 Codex、真实登录或账号切换。
- 逐项位置审计记录在 `docs/zh-CN/PATH_COMPATIBILITY.md`：恢复旧模型目录/维护标记路径参数、分页库识别；位置记录或手动目录被占用时明确读取失败，权限错误不吞成缺失。项目其他版本、分页投影涉及字节偏移但未适配时明确说明并保留数据，不能声称已覆盖这些格式的写入。
- 环境检查以本地 --version 判断可执行性，无需登录；GUI/CLI 共用查找器。新增正常 EXE、临时 Desktop 安装布局且无显式命令覆盖的前端验证入口，避免测试再次绕过发现层。
- 本地构建 0 警告/错误；128 项 xUnit（Core 6、Infrastructure 105、Desktop 13、CLI 4）全部通过，无跳过。直接/传递 NuGet 依赖审计无已知漏洞。临时正常 WPF EXE 已实际点击诊断/重新检查，显示临时 Desktop 版本目录 CLI 为“已找到”，仅执行模拟 --version；未进行真实切换。证据位于忽略的 artifacts/test-0.3.13 与 artifacts/ui-0.3.13。
- 自包含安装包 `dist/0.3.13-release/Codex-Profile-Switcher-Setup-0.3.13.exe` 已生成，45,950,498 字节，SHA-256 `8cf96c3b1673b3741056d1d76838dc6a080c1371da3cfd8485f14b47b90099df`。283 项发布清单、15 项静态文件与源码逐项匹配。真实 WSH/CMD 入口与隔离安装（副本 GUI/CLI、旧入口迁移/修改保护、卸载数据留存）通过；没有更改本机真实安装或快捷方式。
- [0.3.13 Release](https://github.com/IIMovoMII/Codex-Profile-Switcher/releases/tag/v0.3.13) 已公开，源码/标签目标 `1c4fe5f0889838cec05ee6b5e0c6822854601db1`，远端分支、标签及解引用 SHA 与本地一致。GitHub 两项附件大小/digest 和公告与本地相同，CI 没有覆盖已验收附件。
- [CI 43402804223](https://github.com/IIMovoMII/Codex-Profile-Switcher/actions/runs/43402804223) 的全新 Windows 构建、128 项测试、WSH/CMD、打包及隔离安装全部成功；无 NU190x、Node 20 或 warning 注释，annotations 为 0。当前 C# 更新服务在 9.33 秒内回退系统代理 GitHub API 403，旧 0.3.12 检测到 0.3.13，公告一致；实际回下载完整公开安装器与 SHA-256 匹配，单独回下载的校验附件字节也一致。证据位于忽略的 artifacts/release-0.3.13。保留 0.3.12 发布物与历史。

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
| 共享聊天、增量历史、SQLite/WAL、项目投影 | Infrastructure/History、CodexAdapters | JSONL 字节布局、原生分页游标/轮次/分段继承、界面来源、WAL 增量、无变更不建备份、提交后失败与重启恢复；未知偏移/来源及非 state_5 项目格式保护性停止/跳过 |
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
