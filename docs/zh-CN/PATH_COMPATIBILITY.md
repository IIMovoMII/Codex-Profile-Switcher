# 文件位置与兼容规则

## 0.3.12 为什么会误报

旧实现支持 Desktop 解压的 CLI：`%LOCALAPPDATA%\OpenAI\Codex\bin\<版本>\codex.exe`，也支持 `CODEX_CLI_PATH`。迁移到 C# 后，这两项没有进入新查找流程，0.3.12 只查 PATH 与 Programs，因此用户已安装 Desktop 仍会失败。该版本的 GitHub 安装包也包含此问题。

原有测试通过显式 `--codex-exe` 或模拟运行接口提供命令，没有覆盖“标准安装存在、PATH 没有、无任何覆盖参数”的入口。0.3.13 增加可注入环境的同一套查找器，并补上这个回归及正常 EXE 的隔离界面验证。

## CLI 查找顺序

1. 启动参数 `--codex-exe` / `-CodexExecutable`。
2. 环境变量 `CODEX_CLI_PATH`。
3. `%LOCALAPPDATA%\OpenAI\Codex\bin\<版本>\codex.exe`，按文件修改时间选择最近的版本，随后回退 bin 根目录的 `codex.exe`。
4. PATH 各目录中的原生 `codex.exe`，保留 PATH 顺序。
5. PATH 目录及 `%APPDATA%\npm` 下 `@openai/codex`、`@openai/codex-win32-x64` 的原生 Windows x64 CLI，含旧 vendor 和嵌套平台包布局。
6. `%LOCALAPPDATA%\Programs\Codex` 下已知的 resources、resources/bin 或独立原生 CLI；存在 Desktop 的 `resources/app.asar` 时不把 GUI 当 CLI。

显式路径失效就报告该路径问题，不继续选另一个账号环境。自动查找时，某个目录无权读取不会阻止其他合法候选；全部候选失败时保留访问失败的原因。版本路径不永久缓存，更新或删除目录后重新查找。查找本身不启动 Codex、不联网、不递归扫描全盘；未知自定义布局可显式指定原生 EXE。`.cmd`、`.ps1` 包装脚本不能作为原生 CLI。

## 其他文件类别对照

| 类别 | 兼容位置或规则 | 处理与验证 |
| --- | --- | --- |
| 聊天与配置 | 显式 CODEX_HOME、已记住路径、环境 CODEX_HOME、注册表绑定路径、默认 `%USERPROFILE%\.codex` | `DataLocationBehaviorTests`；无效绑定不创建替代空目录，显式隔离路径不逃逸 |
| 账号数据 | 显式路径、已记住位置、默认 `%LOCALAPPDATA%\CodexProfileSwitcher` 和 Windows 用户数据目录 | 沿用 `profiles.json` 与 `profiles/*.auth.dpapi`；旧 relay/official 快照仅在缺少注册表且符合迁移条件时导入，已有删除记录不复活 |
| 位置记录 | `%APPDATA%\CodexProfileSwitcher\locations.json` | 被占用或无权读取时提示不可读取，保留原件，不误当首次安装 |
| 手动模型目录 | 账号指定路径优先；其次 `RelayModelCatalogPath` / `--relay-model-catalog-path`；再使用数据目录的 `relay-models.json` | `LegacyLocationCompatibilityTests`、`FrontendBehaviorTests`；显示实际路径，读取失败与未配置分开，不改写手动文件 |
| 官方模型缓存与快照 | 仅实际 CODEX_HOME 的 `models_cache.json`；按官方账号写数据目录 `model-catalogs` 下独立快照 | 只读缓存、核验身份来源、完整字段保留；不跨账号或跨 CODEX_HOME 猜测缓存位置，无效来源保留旧快照 |
| 历史数据库 | CODEX_HOME 及 `sqlite` 子目录的 `*.sqlite`，识别 threads/thread_items/thread_turns/thread_history_projection_state 表 | `HistoryCompatibilityBehaviorTests`；不依赖单一库名，不把分页库漏算；需同步改写但格式未适配时先停止写入 |
| 项目数据库 | 当前适配 CODEX_HOME 下 `state_5.sqlite` | `ProjectProjectionBehaviorTests`；发现 `state_*.sqlite` 其他版本会说明格式未适配，不冒充文件缺失，不猜测写入 |
| Desktop 状态 | CODEX_HOME 的 `.codex-global-state.json` 及数据目录的 `desktop-renderer-state.dpapi` | 已有适配器、账号私有/共享状态测试；未知结构保留，凭据解密继续使用原 CODEX_HOME 熵参数 |
| 独立助手维护标记 | `MonitorDataDir` / `--monitor-data-dir`；默认数据目录旁的 `CodexDesktopWeixin` 仅在已有 settings.json 时启用 | 只写已有维护协议的 maintenance.json，不加载其他项目源码；自定义数据目录需用显式参数协调不相邻的安装 |
| SQLite 引擎 | 自包含发布携带 Microsoft.Data.Sqlite 的原生库 | 不再寻找外部 sqlite3.exe，不需要用户另装工具；原生引擎版本有实际加载测试 |
| 切换器入口 | 固定 VBS、install-path.txt 和正式发布输出 | 真实 WSH/CMD、隔离安装验证；不是递归搜索同名 EXE，已修改启动器保留并提示 |

账号、聊天、目录、配置和数据库属于不同格式，分别由对应模块负责；不会用“全盘找一个同名文件”替代身份和来源核验。

## 防止同类回归

- 每种文件明确候选位置、优先级、显式覆盖、格式验证、权限失败和未找到的边界，新增或迁移位置规则时更新上表。
- 测试必须至少有一项不传显式路径的成功案例，同时验证旧位置、更新后变化、失效候选、权限/占用、格式不支持及回退；不要让所有测试绕过发现层。
- 环境检查与业务共用定位模块，显示实际路径。文件存在但启动失败、不可读取或格式不支持，不显示成“文件不存在”。
- 历史关联格式未适配时不写入；重要认证核验失败则恢复切换事务。保留已完成的独立历史准备与备份。

这些规则覆盖已知布局；未来 Codex 改变目录或格式时，需要新增适配和回归，不能把未知布局等同于用户没有安装。
