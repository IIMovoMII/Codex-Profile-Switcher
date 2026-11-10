# 贡献指南

欢迎提交问题报告和代码改进。提交前先搜索已有 Issues，并说明发生条件、预期行为和实际结果。

## 本地验证

- 在 Windows PowerShell 5.1 上运行 GUI 和服务相关测试。
- UI 回调、档案、历史或数据库行为变化时运行 tests 目录中相应的 test-*.ps1 隔离套件。
- 更新检查变化需运行 tests/test-codex-updates.ps1。
- 构建安装器前确认版本号在 version.txt 与 Inno Setup 定义中一致。

测试必须使用临时 CODEX_HOME 和数据目录。不得把隔离测试的危险绕过参数带到真实账号操作中。

## 隐私要求

不要提交认证文件、API Key、DPAPI 文件、账号快照、真实聊天、项目路径、操作日志或本机备份。不要把用户目录、仓库绝对路径、邮箱或账号标识写入测试夹具。测试数据请使用 example.invalid 和临时目录。

分发文件由 distribution-files.ps1 白名单决定。新增运行时文件时同时更新白名单、测试和使用说明。

## 更新发布

稳定版通过 GitHub Release 发布，安装包与 .sha256 文件作为同一 Release 的附件。应用只会安装与 GitHub 返回版本号匹配、且 SHA-256 校验通过的项目安装器。
