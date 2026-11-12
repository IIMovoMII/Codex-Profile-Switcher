# 旧版 PowerShell 对照材料

本目录保存旧版 PowerShell 实现及其迁移期回归测试，仅供维护者核对旧行为。正式运行链为 `src/Switcher.Core`、`src/Switcher.Infrastructure`、`src/Switcher.Desktop` 和 `src/Switcher.Cli`；安装包不包含本目录，也不会从这里加载代码。

旧测试在 `tests` 子目录中，旧实现位于本目录根部。它们只使用临时夹具和模拟 CLI，不用于真实账号切换。新功能和正式回归以 `tests/Switcher.*.Tests` 中的 xUnit 测试为准。
