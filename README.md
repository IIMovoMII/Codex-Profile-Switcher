# Codex Profile Switcher

[![Windows](https://img.shields.io/badge/platform-Windows%2010%2F11-3d6f58)](https://github.com/IIMovoMII/Codex-Profile-Switcher/releases)
[![Latest release](https://img.shields.io/github/v/tag/IIMovoMII/Codex-Profile-Switcher?label=latest)](https://github.com/IIMovoMII/Codex-Profile-Switcher/releases)
[![License: MIT](https://img.shields.io/badge/license-MIT-527e69.svg)](LICENSE.txt)

**A Windows desktop application for managing and switching Codex OAuth accounts and API profiles while preserving a shared local workspace.**

面向 Windows 的 Codex 账号与 API 管理工具。管理多个官方账号和 API 连接，沿用现有 Codex 聊天、项目和工作目录。

## 安装

从 [GitHub Releases](https://github.com/IIMovoMII/Codex-Profile-Switcher/releases) 下载 `Codex-Profile-Switcher-Setup-版本.exe`。安装器面向当前 Windows 用户，不要求管理员权限。安装时可选择创建桌面快捷方式；桌面和开始菜单快捷方式都使用固定启动入口。

当前 C# / .NET 10 重构版为 [0.3.7](https://github.com/IIMovoMII/Codex-Profile-Switcher/releases/tag/v0.3.7)。请使用对应版本安装包；0.2.x 是旧版 PowerShell 程序。

安装和卸载向导使用简体中文，安装包自带 .NET 10 运行时。日常运行不需要 .NET SDK、PowerShell、Python、Node.js 或额外 SQLite 安装。

## 功能

- 添加、导入、编辑、重命名、删除和重新授权官方/API 档案。
- 切换与重新应用账号配置；保留账号独立模型、上下文、代理策略以及“继承”和“保留当前值”的语义。
- API 模型目录可使用独立的官方账号快照或指定的手动 JSON 文件；官方账号继续使用 Codex 原生目录更新。
- 共享聊天和项目，隔离账号专属界面状态，保留用户偏好。
- 历史兼容准备、增量处理、项目投影、环境检查和可取消的操作进度。
- 启动时检查 GitHub 稳定版；下载后校验 SHA-256，用户确认后才运行安装程序。

## 首次使用

1. 安装并打开“Codex 账号切换”。
2. 已有登录信息时选择“导入当前账号”；也可以添加官方账号或 API 档案。
3. 切换前退出 Codex Desktop 和 Codex CLI；切换完成后重新启动 Codex。

图形界面通过根目录固定入口 `CodexProfileSwitcher.vbs` 启动。`Codex切换.vbs` 和 `start.vbs` 保留为兼容入口；`codex-switcher.cmd` 提供命令行程序。升级会更新固定入口的路径指针，不更换快捷方式目标。

详细用法、模型目录格式和数据边界见[图形版使用说明](docs/zh-CN/INSTALL.md)。

## 数据与隐私

- 档案凭据和备份保存在 `%LOCALAPPDATA%\CodexProfileSwitcher`，使用当前 Windows 用户的 DPAPI 保护。
- 聊天和项目沿用现有 `CODEX_HOME`；安装和卸载不会清理这两个数据目录。
- 更新检查访问 GitHub Releases。安装包必须与对应 Release 的 SHA-256 清单匹配后才可启动。
- 请勿提交认证文件、API Key、账号快照、真实聊天、运行日志或本机备份。

## 开发

项目使用 C#、.NET 10、WPF、CommunityToolkit.Mvvm、System.Text.Json、Microsoft.Data.Sqlite、Windows DPAPI、xUnit 和 Inno Setup 6。正常运行的业务逻辑全部由 C# 实现；PowerShell 只用于构建/安装编排，以及 `tests/legacy-powershell` 中的历史行为对照。

```powershell
dotnet build .\CodexProfileSwitcher.sln
dotnet test .\CodexProfileSwitcher.sln
.\build-installer.ps1
```

构建安装包需要 .NET 10 SDK 和 Inno Setup 6。安装器采用自包含 Windows x64 发布，不启用 trimming 或 NativeAOT。功能映射、关键决定和隔离验证状态见 [REFACTOR_PLAN.md](REFACTOR_PLAN.md)；贡献要求见 [CONTRIBUTING.md](CONTRIBUTING.md)。

当前源码版本为 **0.3.7**。隔离测试不等于真实账号登录、真实 API 使用或跨机器验证。项目采用 [MIT License](LICENSE.txt)。
