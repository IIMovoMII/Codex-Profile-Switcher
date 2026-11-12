# 图形版使用说明

当前源码版本：0.3.7，面向 Windows 10/11 x64。

本版是 C# / .NET 10 重构版，安装包见 [0.3.7 Release](https://github.com/IIMovoMII/Codex-Profile-Switcher/releases/tag/v0.3.7)。0.2.x 安装包是旧版 PowerShell 程序。

## 安装和固定入口

从 [GitHub Releases](https://github.com/IIMovoMII/Codex-Profile-Switcher/releases) 下载 `Codex-Profile-Switcher-Setup-版本.exe`。安装和卸载向导均使用简体中文。安装器默认写入当前用户的 `%LOCALAPPDATA%\Programs\CodexProfileSwitcher`，不需要管理员权限。开始菜单入口固定创建；桌面快捷方式可在安装时选择。

快捷方式始终指向 `%LOCALAPPDATA%\CodexProfileSwitcher\Launcher\CodexProfileSwitcher.vbs`。后续升级只更新该目录中的 `install-path.txt`，保持固定入口和快捷方式目标稳定。已知的 0.2.9 和 0.3.6 旧启动器会先备份再迁移；入口支持中文路径和源码目录中的发布路径指针。已知旧版 PowerShell 业务文件仅在 SHA-256 完全匹配时清理。修改过或无法识别的文件会保留并给出提示。

安装包自带 .NET 10 运行时。用户运行不需要 PowerShell、.NET SDK、Python、Node.js 或单独安装 SQLite。安装和卸载不登录账号，不改 Codex 配置；卸载不会删除 `%LOCALAPPDATA%\CodexProfileSwitcher`、`CODEX_HOME` 或聊天项目。

## 第一次使用

1. 完全退出 Codex Desktop 和 Codex CLI。
2. 已有当前认证时选择“导入当前账号”；也可以添加官方账号或 API 档案。
3. 添加官方账号会启动 Codex 原生登录流程；API 档案需要名称、HTTPS 接口地址和 API Key。
4. 保存档案后选择目标账号并切换。切换结束后完全退出并重新启动 Codex Desktop。

切换器继续使用当前 `CODEX_HOME`，默认是 `%USERPROFILE%\.codex`。认证和 `config.toml` 随当前账号切换，聊天与项目共享。运行数据和备份放在 `%LOCALAPPDATA%\CodexProfileSwitcher`。

## 账号和配置

“账号”页用于导入、添加、切换、重新应用、重命名和删除档案。删除档案会同时删除它保存的加密凭据，操作前会要求确认。官方账号可重新授权；API 档案在“设置”中编辑连接和 Key。

模型、上下文窗口和代理策略可以分别选择继承全局设置、保留当前 Codex 值或显式指定。账号配置只修改对应字段；TOML 中的注释、未知设置和个人偏好会保留。切换期间不会自动重置推理强度、模型上下文或聊天数据。

切换前应退出 Codex Desktop 和 Codex CLI。切换器会检查运行中的相关进程，不会强行结束它们。若认证或配置写入失败，事务会尝试恢复已修改文件；检测到外部并发修改时会保留恢复材料并拒绝覆盖。

## 模型目录保持

官方账号继续由 Codex 原生更新模型目录。切换器不会为官方模式设置 `model_catalog_json` 覆盖，不通过 CLI 生成模型列表，也不修改原生 `models_cache.json`。

API 档案的“模型目录”设置支持两种方式：

| 方式 | 使用的文件 | 维护方式 |
| --- | --- | --- |
| 手动维护目录 | 此 API 档案指定的 JSON 文件；未指定时使用 `%LOCALAPPDATA%\CodexProfileSwitcher\relay-models.json` | 用户自行编辑，或选择可信 Codex 安装导出的完整目录 |
| 跟随官方目录 | 此 API 档案所选官方账号的独立快照 | 离开该官方账号前，从本地缓存核验来源并同步 |

每个 API 档案可选择不同官方来源或不同手动文件。自动快照和手动文件分开保存；启用跟随方式不会覆盖原手动路径。设置页显示维护方式、实际路径、来源和更新时间，并提供打开文件/文件夹操作。

同步只读取 `CODEX_HOME\models_cache.json`。只有当前官方认证和缓存来源能对应时才读取完整 `models` 数组；模型项中的展示名称、上下文、推理档位、能力及未知字段都会保留，缓存外层的账号身份信息不会写入目录。每个官方账号使用独立快照。

缓存不存在、来源不明、内容损坏或目录为空时，保留上一次有效快照并继续切换。没有官方账号时也可长期维护手动目录，不要求登录官方。目录尚未配置时允许切换，并提示模型列表可能不完整。快速切换入口继续跳过历史检查和模型同步，只使用已有目录。

API 模型目录必须采用完整 Codex 目录 JSON 格式，顶层含 `models` 数组，数组项是完整模型对象；不能只写模型名称，也不能把普通 `/v1/models` 响应直接当成 Codex 目录。修改目录后完全退出并重启 Codex 生效。目录显示某模型不代表 API 服务端支持调用该模型。

## 环境、历史与项目

“环境与更新”页可检查 Codex 命令，执行聊天兼容准备或完整扫描，检查/修复项目归属，并查看进度与本次操作结果。项目检查默认不按当前工作目录猜测归属；显式启用目录推断时才会根据本地项目路径进行匹配。历史准备和后续账号切换分别执行；若后续切换失败，已经完成的历史整理和其备份仍保留。

修复功能会创建本地备份。发现不支持的数据库结构、无法确认的数据归属或并发修改时，切换器会跳过可选修复或停止写入，不自动覆盖未知数据。

## 更新

每次打开图形界面时，切换器会在后台检查 GitHub 最新稳定版。也可在“环境与更新”页手动检查。检查失败不会阻止已有账号管理和切换。

下载更新前会询问确认。程序只接受项目 GitHub Release 中的 HTTPS 安装包和 SHA-256 清单；安装包核验通过后再次确认，才启动安装器。更新不会静默安装。

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
- 程序不会上传聊天、项目、认证内容或 API Key。更新检查只访问 GitHub Releases。
- 安装和卸载不清理 `CODEX_HOME` 或切换器数据目录。
- 若需反馈问题，上传日志前请删除邮箱、账号 ID、用户路径、API 地址、令牌、聊天内容和项目名称。

隔离测试使用临时目录、合成认证数据和模拟 CLI，不等于真实账号登录、真实 API 调用或跨机器验证。维护者不会把真实账号试用作为自动验收步骤。
