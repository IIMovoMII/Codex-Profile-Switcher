# 图形版使用说明

当前源码及安装包版本：0.3.13，面向 Windows 10/11 x64。

本版采用 C# / .NET 10 WPF 与青绿色卡片界面，下载 [0.3.13 Release](https://github.com/IIMovoMII/Codex-Profile-Switcher/releases/tag/v0.3.13)。[本版公告](releases/0.3.13.md)与应用内一致，本次修复 Codex 安装位置漏查。0.2.x 安装包是旧版 PowerShell 程序。

## 安装和固定入口

从 [GitHub Releases](https://github.com/IIMovoMII/Codex-Profile-Switcher/releases) 下载 `Codex-Profile-Switcher-Setup-版本.exe`。安装和卸载向导均使用简体中文。安装器默认写入当前用户的 `%LOCALAPPDATA%\Programs\CodexProfileSwitcher`，不需要管理员权限。开始菜单入口固定创建；桌面快捷方式可在安装时选择。

快捷方式始终指向 `%LOCALAPPDATA%\CodexProfileSwitcher\Launcher\CodexProfileSwitcher.vbs`。后续升级只更新该目录中的 `install-path.txt`，保持固定入口和快捷方式目标稳定。已知的 0.2.9 和 0.3.6 旧启动器会先备份再迁移；入口支持中文路径和源码目录中的发布路径指针。已知旧版 PowerShell 业务文件仅在 SHA-256 完全匹配时清理。修改过或无法识别的文件会保留并给出提示。

安装包自带 .NET 10 运行时。用户运行不需要 PowerShell、.NET SDK、Python、Node.js 或单独安装 SQLite。安装和卸载不登录账号，不改 Codex 配置；卸载不会删除 `%LOCALAPPDATA%\CodexProfileSwitcher`、`CODEX_HOME` 或聊天项目。

0.3.10 提高安装器压缩率，只发布简体中文附加语言资源并保留内置英文资源。包内仍有完整 .NET/WPF 框架程序集；没有通过裁剪框架或删除功能压缩体积。更高压缩率会增加维护者打包时间，不增加用户的安装依赖。

## 第一次使用

1. 完全退出 Codex Desktop 和 Codex CLI。
2. 点击右上角“添加账号”，选择“导入当前账号”“添加 API 账号”或“登录并添加官方账号”。
3. 添加官方账号会启动 Codex 原生登录流程；API 档案需要名称、HTTPS 接口地址和 API Key。
4. 保存档案后选择目标账号并切换。切换结束后完全退出并重新启动 Codex Desktop。

切换器继续使用当前 `CODEX_HOME`，默认是 `%USERPROFILE%\.codex`。认证和 `config.toml` 随当前账号切换，聊天与项目共享。运行数据和备份放在 `%LOCALAPPDATA%\CodexProfileSwitcher`。

## 账号和配置

左侧“账号管理”使用横向账号卡片，支持名称/API 地址搜索及全部、官方、API 筛选。当前账号会核对实际认证后标记“使用中”，不会把最后选中或最后保存的档案误当成当前账号。

每张卡片的“模型设置”直接打开右侧面板的模型标签。`···` 菜单提供“编辑账号 / 重命名”“重新应用此账号”“重新授权并核验身份”（官方账号）和“删除账号”。删除档案会同时删除其加密凭据，操作前要求确认；不会删除聊天或项目。

右侧面板分为“账号信息”“模型设置”“网络与上下文”。API Key 不回填到表单；编辑时留空保留原密钥。点击“保存设置”只保存档案；下次切换或重新应用时生效。“取消”、关闭面板或 Escape 可以放弃草稿，存在未保存修改时会提示确认。

模型、上下文窗口和代理策略可以分别选择继承全局设置、保留当前 Codex 值或显式指定。账号配置只修改对应字段；TOML 中的注释、未知设置和个人偏好会保留。切换期间不会自动重置推理强度、模型上下文或聊天数据。

切换前应退出 Codex Desktop 和 Codex CLI。切换器会检查运行中的相关进程，不会强行结束它们。若认证或配置写入失败，事务会尝试恢复已修改文件；检测到外部并发修改时会保留恢复材料并拒绝覆盖。

## 模型目录保持

官方账号继续由 Codex 原生更新模型目录。切换器不会为官方模式设置 `model_catalog_json` 覆盖，不通过 CLI 生成模型列表，也不修改原生 `models_cache.json`。

API 档案的“模型设置 → 模型列表来源”支持两种方式：

| 方式 | 使用的文件 | 维护方式 |
| --- | --- | --- |
| 手动维护目录 | 此 API 档案指定的 JSON 文件；未指定时使用 `%LOCALAPPDATA%\CodexProfileSwitcher\relay-models.json` | 用户自行编辑，或选择可信 Codex 安装导出的完整目录 |
| 跟随官方目录 | 此 API 档案所选官方账号的独立快照 | 离开该官方账号前，从本地缓存核验来源并同步 |

每个 API 档案可选择不同官方来源或不同手动文件。自动快照和手动文件分开保存；启用跟随方式不会覆盖原手动路径。设置页显示维护方式、实际路径、来源和更新时间，并提供打开文件/文件夹操作。

“默认模型”可以保留当前值、沿用默认策略或为账号指定模型。本地目录中的模型可在下拉框中选择，也可以手动输入模型 ID；打开面板和刷新列表不会改写目录文件。目录不存在时显示说明，仍可保存档案。官方账号不使用 API 目录覆盖，可手动输入默认模型 ID。

同步只读取 `CODEX_HOME\models_cache.json`。只有当前官方认证和缓存来源能对应时才读取完整 `models` 数组；模型项中的展示名称、上下文、推理档位、能力及未知字段都会保留，缓存外层的账号身份信息不会写入目录。每个官方账号使用独立快照。

缓存不存在、来源不明、内容损坏或目录为空时，保留上一次有效快照并继续切换。没有官方账号时也可长期维护手动目录，不要求登录官方。目录尚未配置时允许切换，并提示模型列表可能不完整。快速切换入口继续跳过历史检查和模型同步，只使用已有目录。

API 模型目录必须采用完整 Codex 目录 JSON 格式，顶层含 `models` 数组，数组项是完整模型对象；不能只写模型名称，也不能把普通 `/v1/models` 响应直接当成 Codex 目录。修改目录后完全退出并重启 Codex 生效。目录显示某模型不代表 API 服务端支持调用该模型。

## 环境、历史与项目

左侧“诊断与维护”中，“重新检查”显示 Codex 命令、运行进程、数据位置、未完成操作、操作锁及认证环境覆盖的实际状态。聊天兼容提供“增量准备”和“完整检查并准备”；这是可能写入文件/数据库的准备操作，执行前会说明并确认。项目归属和桌面状态提供检查，检查成功后可选择“备份并修复”。项目检查默认不按当前工作目录猜测归属；目录推断仍是 CLI 显式选项。历史准备和后续账号切换分别执行；若后续切换失败，已经完成的历史整理和其备份仍保留。

修复功能会创建本地备份。发现不支持的数据库结构、无法确认的数据归属或并发修改时，切换器会跳过可选修复或停止写入，不自动覆盖未知数据。

环境检查显示命令的实际路径，通过本地 `--version` 验证可运行性，不要求先登录。文件已找到但无法启动、位置无权限与未找到候选分别提示；不会仅因登录状态异常就说没有安装。自定义 CLI 可用 `CODEX_CLI_PATH` 或 `--codex-exe` 指定原生 `.exe`，不接受 PowerShell/CMD 包装脚本。

历史库按表结构识别，覆盖 `CODEX_HOME` 和其 `sqlite` 子目录。分页历史投影如需随 JSONL 同步改写字节偏移，当前会在写入前明确停止；项目归属适配 `state_5.sqlite`，发现其他版本会说明格式尚未适配，保留原库。详细路径规则见[位置兼容说明](PATH_COMPATIBILITY.md)。

## 更新

顶部“检查更新”以及左侧“设置与更新 → 更新”均可进入更新页。默认每次启动在后台检查 GitHub 最新稳定版，可用页面中的开关调整；“重新检查”可随时重试。检查失败不会阻止账号管理和切换。未检查时不会显示虚构的新版本。

检查总时限为 25 秒。API 返回 403/429 限流时立即改用项目官方 Release 网页；暂时连接失败会有限重试后回退。页面会区分限流、连接失败和超时；系统代理出口共享未登录额度时，无需为切换器提供 GitHub Token，也不会擅自更改或绕过系统代理。

更新页显示当前版本公告，离线也可查看。检查到当前或更新的稳定版时，显示其 GitHub Release 正文；API 限流时从同一仓库相应版本标签读取公告文件。公告获取失败保留已有说明，版本检查和下载仍可用；本地版本较新时不会用旧版公告覆盖当前说明。公告作为纯文本显示，不自动加载图片或执行链接。

下载更新前会询问确认。程序只接受项目 GitHub Release 中的 HTTPS 安装包和 SHA-256 清单；安装包核验通过后再次确认，才启动安装器。更新不会静默安装。

“设置与更新”另有“默认策略”“数据位置”“关于”：分别管理可继承的默认代理与上下文策略、查看真实本地路径、查看应用版本。“操作记录”独立保存已完成和已取消操作的结果，可刷新或复制；底部“查看详情”可直接进入记录页。

## 数据位置与存储保留

账号数据默认使用 `%LOCALAPPDATA%\CodexProfileSwitcher`，聊天与项目优先沿用现有 `CODEX_HOME`，默认 `%USERPROFILE%\.codex`。应用会自动检查已记住的位置、环境变量和档案记录的原路径；设置页显示真实路径和定位来源。第一次使用会创建默认文件夹。指定位置失效时会查找有效候选；都不可用时才显示文件夹选择，支持检查磁盘连接或权限后重试。

手动选择只记住路径，不搬移或导入数据，位置记录在 `%APPDATA%\CodexProfileSwitcher\locations.json`。选取已有账号目录后仍须使用其绑定的原 `CODEX_HOME`，因为旧凭据的 DPAPI 解密依赖该路径；不会静默改绑或创建空目录替代丢失的聊天。命令行显式 `--codex-home` / `--data-dir` 始终生效，指定路径失败就报错，不回退到其他用户目录。运行中位置失效时，设置页可选择并记住有效位置，重启应用后使用。

启动及业务操作结束后会自动清理可确认已完成的历史和项目备份：每类最多 3 份，超过 14 天或合计超过 256 MB 时优先清理较旧的，每类至少保留最新 1 份。已知旧版完成备份也按此规则处理；进行中、待恢复、跨备份引用、格式不明或含用户额外文件的材料保留。没有历史变化时不产生空备份。

更新安装包仅保留最近 1 个（当前会话已校验的安装包受保护）；未完成下载和旧版检查结果超过 24 小时清理。可以在“数据位置 → 备份与更新缓存”立即检查保留策略。清理只处理切换器拥有的文件，不清理官方缓存、手动模型目录、账号、聊天或项目；其他窗口正在操作时会延后。

## 命令行

安装目录中的 `codex-switcher.cmd` 调用同目录 `Switcher.Cli.exe`。常用命令：

```text
codex-switcher.cmd status [--json]
codex-switcher.cmd profiles [--json]
codex-switcher.cmd switch --kind api|official [--profile ID] [--quick]
codex-switcher.cmd profile-add-api --name NAME --base-url HTTPS_URL [--catalog PATH]
codex-switcher.cmd profile-add-official --name NAME
codex-switcher.cmd profile-rename --kind api|official --profile ID --name NAME
codex-switcher.cmd profile-update --kind api --profile ID [--base-url URL] [--catalog PATH]
codex-switcher.cmd profile-reauth --kind api|official --profile ID
codex-switcher.cmd profile-remove --kind api|official --profile ID
codex-switcher.cmd history-scan | history-prepare
codex-switcher.cmd project-scan | project-repair
codex-switcher.cmd desktop-scan | desktop-repair
```

使用 `--codex-home PATH` 和 `--data-dir PATH` 可为隔离验证指定临时目录。添加 API 时 Key 从不回显的交互输入或标准输入读取；命令错误和日志不会输出凭据。官方登录命令只应由用户主动执行。

## 数据和安全

- 档案凭据及恢复记录使用当前 Windows 用户 DPAPI；不能直接搬到另一 Windows 用户或电脑。
- 程序不会上传聊天、项目、认证内容或 API Key。更新检查只访问 GitHub 的项目 Release 与对应版本公告。
- 安装和卸载不清理 `CODEX_HOME` 或切换器数据目录。
- 若需反馈问题，上传日志前请删除邮箱、账号 ID、用户路径、API 地址、令牌、聊天内容和项目名称。

隔离测试使用临时目录、合成认证数据和模拟 CLI，不等于真实账号登录、真实 API 调用或跨机器验证。维护者不会把真实账号试用作为自动验收步骤。
