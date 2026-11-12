using System.Security.Cryptography;
using System.Text;
using Switcher.Core.Abstractions;
using Switcher.Core.Configuration;
using Switcher.Core.Paths;
using Switcher.Core.Profiles;

namespace Switcher.Core.Switching;

public sealed class SwitcherService(
    SwitcherPaths paths,
    ISwitcherFileSystem files,
    IOperationLock operationLock,
    ITransactionExecutor transactions,
    IProfileRepository profiles,
    IAuthClassifier authClassifier,
    ProfileManagementService profileManagement,
    IConfigEditor configEditor,
    ICodexRuntime runtime,
    IDesktopStatePlanner desktopState,
    IModelCatalogProvider catalogs,
    IProjectProjectionService projects,
    IHistoryCompatibilityService history)
{
    private readonly AsyncLocal<IProgress<SwitchProgress>?> _progress = new();

    public string GetLiveMode()
    {
        if (!files.FileExists(paths.AuthFile) || !files.FileExists(paths.ConfigFile)) return "未设置";
        return DetermineLiveKind(files.ReadAllText(paths.AuthFile), files.ReadAllText(paths.ConfigFile)).ToLegacyValue();
    }

    /// <summary>Identifies live credentials; an active registry pointer alone is not proof.</summary>
    public ProfileEntry? GetLiveProfile()
    {
        if (!files.FileExists(paths.AuthFile) || !files.FileExists(paths.ConfigFile)) return null;
        var auth = files.ReadAllText(paths.AuthFile);
        var config = files.ReadAllText(paths.ConfigFile);
        var kind = DetermineLiveKind(auth, config);
        var registry = profiles.Load();
        if (kind == ProfileKind.Official)
        {
            var owner = authClassifier.GetOfficialOwner(auth);
            return registry.OfficialProfiles.FirstOrDefault(profile => profile.Owner == owner);
        }
        var baseUrl = configEditor.GetTopLevel(config, "openai_base_url")?.TrimEnd('/');
        var key = authClassifier.GetApiKey(auth);
        var matches = registry.ApiProfiles.Where(profile => string.Equals(profile.BaseUrl.TrimEnd('/'), baseUrl, StringComparison.OrdinalIgnoreCase))
            .Where(profile => authClassifier.GetApiKey(profiles.ReadAuthentication(profile, ProfileKind.Api)) == key).ToArray();
        return matches.FirstOrDefault(profile => profile.Id == registry.ActiveApiProfileId) ?? matches.FirstOrDefault();
    }

    public async Task<SwitchResult> SwitchAsync(ProfileKind targetKind, string? selector = null, bool quick = false,
        bool fullHistoryScan = false, IProgress<SwitchProgress>? progress = null, CancellationToken cancellationToken = default)
    {
        if (!files.FileExists(paths.AuthFile) || !files.FileExists(paths.ConfigFile))
            return await InitializeAsync(targetKind, selector, quick, fullHistoryScan, progress, cancellationToken).ConfigureAwait(false);
        using var progressScope = new ProgressScope(_progress, progress);
        await using var lease = await operationLock.AcquireAsync(paths.DataDirectory, cancellationToken).ConfigureAwait(false);
        Report("检查待恢复操作", "正在检查上次操作记录。", 3);
        await transactions.RecoverAsync(cancellationToken).ConfigureAwait(false);
        runtime.EnsureNoAuthenticationOverrides();
        if (!files.FileExists(paths.AuthFile) || !files.FileExists(paths.ConfigFile)) throw new IOException("首次初始化期间配置状态发生变化；请重新检查后再试。");
        var running = await runtime.FindRunningProcessNamesAsync(cancellationToken).ConfigureAwait(false);
        if (running.Count > 0) throw new InvalidOperationException("请先完全退出 Codex，再执行账号切换。");
        var configBefore = files.ReadAllBytes(paths.ConfigFile);
        var authBefore = files.ReadAllBytes(paths.AuthFile);
        var configText = new UTF8Encoding(false, true).GetString(configBefore);
        var authText = new UTF8Encoding(false, true).GetString(authBefore);
        configEditor.ValidateSyntax(configText);
        var sourceKind = DetermineLiveKind(authText, configText);
        var catalogSync = (CatalogSyncSummary?)null;
        HistoryPreparationResult? historyResult = null;
        var notices = new List<string>();
        if (!quick)
        {
            var projection = await projects.PrepareAsync(ResolveDesktopOwner(sourceKind, authText), true, false, progress, cancellationToken).ConfigureAwait(false);
            notices.Add(projection.Message);
            Report("历史兼容检查", "准备共享聊天和项目数据。", 10);
            historyResult = await history.PrepareAsync(fullHistoryScan, progress, cancellationToken).ConfigureAwait(false);
            if (!historyResult.Prepared) throw new InvalidOperationException(historyResult.Message);
            if (!string.IsNullOrWhiteSpace(projection.Message)) historyResult = historyResult with { Message = projection.Message + "；" + historyResult.Message };
        }

        var liveBaseUrl = sourceKind == ProfileKind.Api ? configEditor.GetTopLevel(configText, "openai_base_url") : null;
        var liveCatalogPath = sourceKind == ProfileKind.Api ? configEditor.GetTopLevel(configText, "model_catalog_json") : null;
        Report("保存当前凭据", "正在保存当前最新凭据到对应账号档案。", 25);
        var liveProfile = profileManagement.CaptureCurrent(authText, liveBaseUrl ?? "", liveCatalogPath);

        var registry = profiles.Load();
        var selected = registry.GetSelected(targetKind, selector);
        var targetAuth = profiles.ReadAuthentication(selected, targetKind);
        if (!quick && sourceKind == ProfileKind.Official && targetKind == ProfileKind.Api ||
            !quick && sourceKind == ProfileKind.Official && selected.Id != liveProfile.Id)
        {
            var outgoing = registry.OfficialProfiles.FirstOrDefault(p => p.Id == liveProfile.Id);
            if (outgoing is not null)
            {
                Report("同步官方模型目录", "正在核验并读取本地 Codex 模型缓存。", 38);
                catalogSync = catalogs.SyncOfficialSnapshot(authText, outgoing, configText,
                    runtime.GetProcessEnvironment().GetValueOrDefault("OPENAI_ORGANIZATION"),
                    runtime.GetProcessEnvironment().GetValueOrDefault("OPENAI_PROJECT"));
                notices.Add(catalogSync.Message);
            }
        }

        registry = profiles.Load();
        selected = registry.Find(targetKind, selected.Id);
        targetAuth = profiles.ReadAuthentication(selected, targetKind);
        var targetCatalogPath = targetKind == ProfileKind.Api ? catalogs.ResolveApiCatalog((ApiProfile)selected) : null;
        if (targetKind == ProfileKind.Api && (string.IsNullOrWhiteSpace(targetCatalogPath) || !files.FileExists(targetCatalogPath)))
        {
            targetCatalogPath = null;
            notices.Add("API 模型目录尚未配置；切换仍可继续，但模型列表可能不完整。");
        }
        var settings = ReadGlobalSettings().Let(global => SettingsPolicy.Resolve(targetKind, selected.ToSettings(), global));
        var baseUrl = targetKind == ProfileKind.Api ? ((ApiProfile)selected).BaseUrl : null;
        Report("生成切换计划", "校验配置、目标凭据与账号私有状态。", 50);
        var targetConfig = configEditor.BuildModeConfiguration(configText, targetKind, baseUrl, targetCatalogPath, settings);
        var targetConfigBytes = Encoding.UTF8.GetBytes(targetConfig);
        var targetAuthBytes = Encoding.UTF8.GetBytes(targetAuth);
        var officialAuth = sourceKind == ProfileKind.Official ? authText : registry.OfficialProfiles
            .FirstOrDefault(p => p.Id == registry.ActiveOfficialProfileId) is { } official ? profiles.ReadAuthentication(official, ProfileKind.Official) : null;
        var desktopPlan = desktopState.CreatePlan(targetKind, authText, targetAuth, officialAuth).Files;
        if (targetKind == ProfileKind.Api) registry.ActiveApiProfileId = selected.Id;
        else registry.ActiveOfficialProfileId = selected.Id;
        var mutations = new List<FileMutation>();
        var configHash = Convert.ToHexString(SHA256.HashData(configBefore)).ToLowerInvariant();
        var authHash = Convert.ToHexString(SHA256.HashData(authBefore)).ToLowerInvariant();
        if (targetKind == ProfileKind.Official)
        {
            mutations.Add(new FileMutation(paths.ConfigFile, configHash, targetConfigBytes, "切换 Codex 配置", true));
            mutations.Add(new FileMutation(paths.AuthFile, authHash, targetAuthBytes, "切换认证快照", true));
        }
        else
        {
            mutations.Add(new FileMutation(paths.AuthFile, authHash, targetAuthBytes, "切换认证快照", true));
            mutations.Add(new FileMutation(paths.ConfigFile, configHash, targetConfigBytes, "切换 Codex 配置", true));
        }
        mutations.AddRange(desktopPlan);
        mutations.Add(new FileMutation(paths.RegistryFile, CurrentHash(paths.RegistryFile), profiles.Serialize(registry), "更新活动档案指针", files.FileExists(paths.RegistryFile)));
        var plan = new OperationPlan(Guid.NewGuid().ToString("N"), targetKind == sourceKind ? "重新应用账号配置" : "切换账号", mutations, DateTimeOffset.UtcNow, historyResult?.Changed == true);
        plan.Validate();
        Report("执行安全切换", "正在写入认证、配置和账号专属界面状态。", 66);
        await transactions.ExecuteAsync(plan, async token =>
        {
            var writtenAuth = new UTF8Encoding(false, true).GetString(files.ReadAllBytes(paths.AuthFile));
            var writtenConfig = new UTF8Encoding(false, true).GetString(files.ReadAllBytes(paths.ConfigFile));
            var writtenKind = authClassifier.Classify(writtenAuth);
            if (writtenKind != targetKind) throw new InvalidDataException("切换后认证类型与目标档案不一致。");
            configEditor.ValidateSyntax(writtenConfig);
            var writtenMode = configEditor.GetTopLevel(writtenConfig, "openai_base_url");
            if ((targetKind == ProfileKind.Official && !string.IsNullOrWhiteSpace(writtenMode)) ||
                (targetKind == ProfileKind.Api && !string.Equals(writtenMode, baseUrl, StringComparison.Ordinal))) throw new InvalidDataException("切换后的配置与目标模式不一致。");
            await runtime.VerifyAuthenticationAsync(targetKind, token).ConfigureAwait(false);
            token.ThrowIfCancellationRequested();
        }, cancellationToken).ConfigureAwait(false);
        Report("完成", "账号切换完成；请完全退出并重新启动 Codex Desktop。", 100);
        return new SwitchResult(sourceKind, targetKind, selected.Id, selected.Name, historyResult, catalogSync, notices, sourceKind == targetKind);
    }

    public async Task<SwitchResult> InitializeAsync(ProfileKind targetKind, string? selector = null, bool quick = false,
        bool fullHistoryScan = false, IProgress<SwitchProgress>? progress = null, CancellationToken cancellationToken = default)
    {
        using var progressScope = new ProgressScope(_progress, progress);
        await using var lease = await operationLock.AcquireAsync(paths.DataDirectory, cancellationToken).ConfigureAwait(false);
        Report("检查待恢复操作", "正在检查上次操作记录。", 3);
        await transactions.RecoverAsync(cancellationToken).ConfigureAwait(false);
        runtime.EnsureNoAuthenticationOverrides();
        var running = await runtime.FindRunningProcessNamesAsync(cancellationToken).ConfigureAwait(false);
        if (running.Count > 0) throw new InvalidOperationException("请先完全退出 Codex，再执行首次设置。 ");
        if (files.FileExists(paths.AuthFile) && files.FileExists(paths.ConfigFile))
            throw new InvalidOperationException("此 CODEX_HOME 已有完整配置，请使用普通账号切换或导入当前账号。 ");
        if (files.FileExists(paths.AuthFile) != files.FileExists(paths.ConfigFile))
            throw new InvalidOperationException("当前只存在 auth.json 或 config.toml 的一部分。为保护现有设置，请先恢复缺失文件或选择另一 CODEX_HOME。 ");

        var registry = profiles.Load();
        var selected = registry.GetSelected(targetKind, selector);
        var targetAuth = profiles.ReadAuthentication(selected, targetKind);
        var configExists = files.FileExists(paths.ConfigFile);
        var configBefore = configExists ? files.ReadAllBytes(paths.ConfigFile) : [];
        var configText = configExists ? new UTF8Encoding(false, true).GetString(configBefore) : "model_provider = \"openai\"\r\ncli_auth_credentials_store = \"file\"\r\n";
        configEditor.ValidateSyntax(configText);
        HistoryPreparationResult? historyResult = null;
        var notices = new List<string>();
        if (!quick)
        {
            var projection = await projects.PrepareAsync(ResolveDesktopOwner(targetKind, targetAuth), true, false, progress, cancellationToken).ConfigureAwait(false);
            notices.Add(projection.Message);
            Report("历史兼容检查", "准备共享聊天和项目数据。", 12);
            historyResult = await history.PrepareAsync(fullHistoryScan, progress, cancellationToken).ConfigureAwait(false);
            if (!historyResult.Prepared) throw new InvalidOperationException(historyResult.Message);
            if (!string.IsNullOrWhiteSpace(projection.Message)) historyResult = historyResult with { Message = projection.Message + "；" + historyResult.Message };
        }
        var catalogPath = targetKind == ProfileKind.Api ? catalogs.ResolveApiCatalog((ApiProfile)selected) : null;
        if (targetKind == ProfileKind.Api && (string.IsNullOrWhiteSpace(catalogPath) || !files.FileExists(catalogPath)))
        {
            catalogPath = null;
            notices.Add("API 模型目录尚未配置；首次设置仍可继续，但模型列表可能不完整。 ");
        }
        var settings = SettingsPolicy.Resolve(targetKind, selected.ToSettings(), ReadGlobalSettings());
        var baseUrl = targetKind == ProfileKind.Api ? ((ApiProfile)selected).BaseUrl : null;
        var targetConfig = configEditor.BuildModeConfiguration(configText, targetKind, baseUrl, catalogPath, settings);
        var targetAuthBytes = new UTF8Encoding(false).GetBytes(targetAuth);
        var targetConfigBytes = new UTF8Encoding(false).GetBytes(targetConfig);
        if (targetKind == ProfileKind.Api) registry.ActiveApiProfileId = selected.Id;
        else registry.ActiveOfficialProfileId = selected.Id;
        var mutations = new List<FileMutation>
        {
            new(paths.ConfigFile, configExists ? Convert.ToHexString(SHA256.HashData(configBefore)).ToLowerInvariant() : null, targetConfigBytes, "初始化 Codex 配置", configExists),
            new(paths.AuthFile, null, targetAuthBytes, "初始化 Codex 认证", false),
            new(paths.RegistryFile, CurrentHash(paths.RegistryFile), profiles.Serialize(registry), "保存活动档案指针", files.FileExists(paths.RegistryFile))
        };
        var officialAuth = targetKind == ProfileKind.Official ? targetAuth : registry.OfficialProfiles.FirstOrDefault(p => p.Id == registry.ActiveOfficialProfileId) is { } official ? profiles.ReadAuthentication(official, ProfileKind.Official) : null;
        mutations.AddRange(desktopState.CreatePlan(targetKind, null, targetAuth, officialAuth).Files);
        var plan = new OperationPlan(Guid.NewGuid().ToString("N"), "首次初始化", mutations, DateTimeOffset.UtcNow, historyResult?.Changed == true);
        plan.Validate();
        try
        {
            Report("首次初始化", "正在创建配置并验证目标认证。", 55);
            await transactions.ExecuteAsync(plan, async token =>
            {
                var writtenAuth = new UTF8Encoding(false, true).GetString(files.ReadAllBytes(paths.AuthFile));
                if (authClassifier.Classify(writtenAuth) != targetKind) throw new InvalidDataException("初始化后认证类型与档案不一致。 ");
                configEditor.ValidateSyntax(files.ReadAllText(paths.ConfigFile));
                await runtime.VerifyAuthenticationAsync(targetKind, token).ConfigureAwait(false);
                token.ThrowIfCancellationRequested();
            }, cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(targetAuthBytes);
            CryptographicOperations.ZeroMemory(configBefore);
        }
        Report("完成", "首次设置完成；请完全退出并重新启动 Codex Desktop。", 100);
        return new SwitchResult(targetKind, targetKind, selected.Id, selected.Name, historyResult, null, notices, false);
    }

    public async Task<OfficialProfile> AddOfficialInteractivelyAsync(string? displayName = null, string? expectedProfileId = null,
        CancellationToken cancellationToken = default)
    {
        var lease = await operationLock.AcquireAsync(paths.DataDirectory, cancellationToken).ConfigureAwait(false);
        byte[] originalAuth = [];
        byte[] originalConfig = [];
        string? temporaryHome = null;
        OfficialProfile? profile = null;
        var initialize = false;
        var reapply = false;
        try
        {
            await transactions.RecoverAsync(cancellationToken).ConfigureAwait(false);
            runtime.EnsureNoAuthenticationOverrides();
            var running = await runtime.FindRunningProcessNamesAsync(cancellationToken).ConfigureAwait(false);
            if (running.Count > 0) throw new InvalidOperationException("添加或重新授权官方账号前请完全退出 Codex。 ");
            var hasAuth = files.FileExists(paths.AuthFile);
            var hasConfig = files.FileExists(paths.ConfigFile);
            if (hasAuth != hasConfig) throw new InvalidOperationException("当前只存在 auth.json 或 config.toml 的一部分；请先修复或选择另一个 CODEX_HOME。 ");
            originalAuth = hasAuth ? files.ReadAllBytes(paths.AuthFile) : [];
            originalConfig = hasConfig ? files.ReadAllBytes(paths.ConfigFile) : [];
            var sourceKind = hasAuth ? DetermineLiveKind(new UTF8Encoding(false, true).GetString(originalAuth), new UTF8Encoding(false, true).GetString(originalConfig)) : (ProfileKind?)null;
            var originalLiveId = sourceKind switch
            {
                ProfileKind.Official => ResolveOfficialIdFromAuth(new UTF8Encoding(false, true).GetString(originalAuth)),
                ProfileKind.Api => ResolveApiIdFromAuth(new UTF8Encoding(false, true).GetString(originalAuth), configEditor.GetTopLevel(new UTF8Encoding(false, true).GetString(originalConfig), "openai_base_url")),
                _ => null
            };
            initialize = sourceKind is null;
            reapply = sourceKind == ProfileKind.Official && !string.IsNullOrWhiteSpace(expectedProfileId) && string.Equals(originalLiveId, expectedProfileId, StringComparison.Ordinal);
            temporaryHome = Path.Combine(paths.DataDirectory, "oauth-temp", Guid.NewGuid().ToString("N"));
            CreateRestrictedDirectory(temporaryHome);
            files.WriteAtomic(Path.Combine(temporaryHome, "config.toml"), "model_provider = \"openai\"\r\ncli_auth_credentials_store = \"file\"\r\n"u8);
            Report("官方登录", "正在启动 Codex 官方登录流程。", 20);
            await runtime.LoginInteractivelyAsync(temporaryHome, cancellationToken).ConfigureAwait(false);
            var temporaryAuthPath = Path.Combine(temporaryHome, "auth.json");
            if (!files.FileExists(temporaryAuthPath)) throw new InvalidDataException("Codex 登录完成但没有生成 auth.json。 ");
            var loggedInAuth = files.ReadAllText(temporaryAuthPath);
            if (authClassifier.Classify(loggedInAuth) != ProfileKind.Official) throw new InvalidDataException("登录没有返回完整的官方 OAuth 认证。 ");
            var owner = authClassifier.GetOfficialOwner(loggedInAuth);
            await runtime.VerifyAuthenticationAsync(ProfileKind.Official, cancellationToken, temporaryHome).ConfigureAwait(false);
            var registryForCheck = profiles.Load();
            if (!string.IsNullOrWhiteSpace(expectedProfileId))
            {
                var expected = (OfficialProfile)registryForCheck.Find(ProfileKind.Official, expectedProfileId);
                if (!string.Equals(expected.Owner, owner, StringComparison.Ordinal)) throw new InvalidDataException("登录的官方身份与所选档案不同；原凭据未改变。 ");
            }
            profile = profileManagement.ImportOfficial(displayName ?? "", loggedInAuth);
            if (!string.IsNullOrWhiteSpace(expectedProfileId) && profile.Id != expectedProfileId) throw new InvalidDataException("重新授权后的官方档案标识不一致。 ");
        }
        finally
        {
            CryptographicOperations.ZeroMemory(originalAuth);
            CryptographicOperations.ZeroMemory(originalConfig);
            if (!string.IsNullOrWhiteSpace(temporaryHome))
            {
                try { if (Directory.Exists(temporaryHome)) Directory.Delete(temporaryHome, recursive: true); } catch (IOException) { }
                catch (UnauthorizedAccessException) { }
            }
            await lease.DisposeAsync().ConfigureAwait(false);
        }
        if (initialize) await InitializeAsync(ProfileKind.Official, profile.Id, quick: false, cancellationToken: cancellationToken).ConfigureAwait(false);
        else if (reapply) await SwitchAsync(ProfileKind.Official, profile.Id, quick: true, cancellationToken: cancellationToken).ConfigureAwait(false);
        return profile ?? throw new InvalidOperationException("官方档案登录未产生有效档案。 ");
    }

    public async Task<OfficialProfile> ReauthorizeOfficialAsync(string selector, CancellationToken cancellationToken = default)
    {
        var registry = profiles.Load();
        var profile = (OfficialProfile)registry.Find(ProfileKind.Official, selector);
        return await AddOfficialInteractivelyAsync(profile.Name, profile.Id, cancellationToken).ConfigureAwait(false);
    }

    public async Task<HistoryPreparationResult> PrepareHistoryAsync(bool fullScan = false, IProgress<SwitchProgress>? progress = null, CancellationToken cancellationToken = default)
    {
        await using var lease = await operationLock.AcquireAsync(paths.DataDirectory, cancellationToken).ConfigureAwait(false);
        var running = await runtime.FindRunningProcessNamesAsync(cancellationToken).ConfigureAwait(false);
        if (running.Count > 0) throw new InvalidOperationException("历史准备前请完全退出 Codex。");
        await transactions.RecoverAsync(cancellationToken).ConfigureAwait(false);
        await projects.PrepareAsync(ResolveDesktopOwnerFromLiveFiles(), true, false, progress, cancellationToken).ConfigureAwait(false);
        return await history.PrepareAsync(fullScan, progress, cancellationToken).ConfigureAwait(false);
    }

    public async Task<ProjectProjectionSummary> PrepareProjectProjectionAsync(bool repair, bool inferFromWorkingDirectory = false,
        IProgress<SwitchProgress>? progress = null, CancellationToken cancellationToken = default)
    {
        await using var lease = await operationLock.AcquireAsync(paths.DataDirectory, cancellationToken).ConfigureAwait(false);
        await transactions.RecoverAsync(cancellationToken).ConfigureAwait(false);
        if (repair)
        {
            var running = await runtime.FindRunningProcessNamesAsync(cancellationToken).ConfigureAwait(false);
            if (running.Count > 0) throw new InvalidOperationException("项目归属修复前请完全退出 Codex。 ");
        }
        return await projects.PrepareAsync(ResolveDesktopOwnerFromLiveFiles(), repair, inferFromWorkingDirectory, progress, cancellationToken).ConfigureAwait(false);
    }

    public async Task<DesktopCompatibilitySummary> PrepareDesktopStateAsync(bool repair, CancellationToken cancellationToken = default)
    {
        await using var lease = await operationLock.AcquireAsync(paths.DataDirectory, cancellationToken).ConfigureAwait(false);
        await transactions.RecoverAsync(cancellationToken).ConfigureAwait(false);
        if (repair)
        {
            var running = await runtime.FindRunningProcessNamesAsync(cancellationToken).ConfigureAwait(false);
            if (running.Count > 0) throw new InvalidOperationException("Desktop 状态修复前请完全退出 Codex。 ");
        }
        if (!files.FileExists(paths.AuthFile) || !files.FileExists(paths.ConfigFile))
            throw new InvalidOperationException("当前 CODEX_HOME 尚未同时存在 auth.json 和 config.toml。 ");
        var auth = files.ReadAllText(paths.AuthFile);
        var config = files.ReadAllText(paths.ConfigFile);
        var kind = DetermineLiveKind(auth, config);
        var registry = profiles.Load();
        var officialAuth = kind == ProfileKind.Official ? auth : registry.OfficialProfiles.FirstOrDefault(profile => profile.Id == registry.ActiveOfficialProfileId) is { } official
            ? profiles.ReadAuthentication(official, ProfileKind.Official) : null;
        var plan = desktopState.CreatePlan(kind, auth, auth, officialAuth);
        if (!repair) return new DesktopCompatibilitySummary(false, $"Desktop 状态只读检查完成：可保留或恢复 {plan.ProjectCount} 个本地项目；待写入文件 {plan.Files.Count} 个。", plan.ProjectCount, plan.Files.Count);
        if (plan.Files.Count == 0) return new DesktopCompatibilitySummary(false, "Desktop 状态已兼容，无需写入。", plan.ProjectCount, 0);
        var mutations = plan.Files.ToArray();
        var operation = new OperationPlan(Guid.NewGuid().ToString("N"), "Desktop 状态兼容修复", mutations, DateTimeOffset.UtcNow);
        await transactions.ExecuteAsync(operation, token =>
        {
            configEditor.ValidateSyntax(files.ReadAllText(paths.ConfigFile));
            if (authClassifier.Classify(files.ReadAllText(paths.AuthFile)) != kind) throw new InvalidDataException("Desktop 状态修复期间认证类型发生变化。 ");
            token.ThrowIfCancellationRequested();
            return Task.CompletedTask;
        }, cancellationToken).ConfigureAwait(false);
        return new DesktopCompatibilitySummary(true, $"Desktop 状态修复完成：已更新 {mutations.Length} 个文件；请重新启动 Codex Desktop。", plan.ProjectCount, mutations.Length);
    }

    private GlobalSettings ReadGlobalSettings()
    {
        if (!files.FileExists(paths.SettingsFile)) return new GlobalSettings();
        using var document = System.Text.Json.JsonDocument.Parse(files.ReadAllBytes(paths.SettingsFile));
        var root = document.RootElement;
        var official = ReadProxy(root, "official_proxy");
        var api = ReadProxy(root, "api_proxy");
        int? context = null;
        if (root.TryGetProperty("context_window", out var node) && node.ValueKind == System.Text.Json.JsonValueKind.String && int.TryParse(node.GetString(), out var parsed) && parsed > 0) context = parsed;
        return new GlobalSettings(official, api, context);
    }

    private static ProxyPolicy ReadProxy(System.Text.Json.JsonElement root, string name) => root.TryGetProperty(name, out var node) && node.ValueKind == System.Text.Json.JsonValueKind.String ? node.GetString() switch
    {
        "system" => ProxyPolicy.System,
        "direct" => ProxyPolicy.Direct,
        _ => ProxyPolicy.Preserve
    } : ProxyPolicy.Preserve;

    public IReadOnlyList<ProfileEntry> ListProfiles() => profiles.Load().AllProfiles().OrderBy(profile => profile.Name, StringComparer.CurrentCultureIgnoreCase).ToArray();

    public async Task<HistoryPreparationResult> DiagnoseHistoryAsync(bool fullScan = false, IProgress<SwitchProgress>? progress = null, CancellationToken cancellationToken = default)
    {
        await using var lease = await operationLock.AcquireAsync(paths.DataDirectory, cancellationToken).ConfigureAwait(false);
        var running = await runtime.FindRunningProcessNamesAsync(cancellationToken).ConfigureAwait(false);
        if (running.Count > 0) throw new InvalidOperationException("历史检查前请完全退出 Codex。 ");
        await transactions.RecoverAsync(cancellationToken).ConfigureAwait(false);
        await projects.PrepareAsync(ResolveDesktopOwnerFromLiveFiles(), true, false, progress, cancellationToken).ConfigureAwait(false);
        return await history.PrepareAsync(fullScan, progress, cancellationToken).ConfigureAwait(false);
    }

    public async Task<ProfileEntry> ImportCurrentProfileAsync(CancellationToken cancellationToken = default)
    {
        await using var lease = await operationLock.AcquireAsync(paths.DataDirectory, cancellationToken).ConfigureAwait(false);
        await transactions.RecoverAsync(cancellationToken).ConfigureAwait(false);
        cancellationToken.ThrowIfCancellationRequested();
        if (!files.FileExists(paths.AuthFile) || !files.FileExists(paths.ConfigFile))
            throw new InvalidOperationException("当前 CODEX_HOME 尚未同时存在 auth.json 和 config.toml。");
        var auth = files.ReadAllText(paths.AuthFile);
        var config = files.ReadAllText(paths.ConfigFile);
        configEditor.ValidateSyntax(config);
        var kind = DetermineLiveKind(auth, config);
        var baseUrl = kind == ProfileKind.Api ? configEditor.GetTopLevel(config, "openai_base_url") ?? "" : "";
        var catalogPath = kind == ProfileKind.Api ? configEditor.GetTopLevel(config, "model_catalog_json") : null;
        cancellationToken.ThrowIfCancellationRequested();
        return profileManagement.CaptureCurrent(auth, baseUrl, catalogPath);
    }

    public string ResolveModelCatalogPath(ProfileKind kind, string selector)
    {
        var profile = profiles.Load().Find(kind, selector);
        if (kind == ProfileKind.Api) return catalogs.ResolveApiCatalog((ApiProfile)profile);
        return catalogs.GetStatus(profile, kind).Path;
    }

    public string EnsureManualModelCatalogFile(string selector)
    {
        var profile = (ApiProfile)profiles.Load().Find(ProfileKind.Api, selector);
        return catalogs.EnsureManualCatalogFile(profile);
    }

    private string? ResolveDesktopOwner(ProfileKind kind, string authText)
    {
        if (kind == ProfileKind.Official) return authClassifier.GetOfficialOwner(authText);
        var registry = profiles.Load();
        return registry.OfficialProfiles.FirstOrDefault(profile => profile.Id == registry.ActiveOfficialProfileId)?.Owner;
    }

    private string? ResolveDesktopOwnerFromLiveFiles()
    {
        if (!files.FileExists(paths.AuthFile))
        {
            var registry = profiles.Load();
            return registry.OfficialProfiles.FirstOrDefault(profile => profile.Id == registry.ActiveOfficialProfileId)?.Owner;
        }
        var authText = files.ReadAllText(paths.AuthFile);
        return authClassifier.Classify(authText) == ProfileKind.Official
            ? authClassifier.GetOfficialOwner(authText)
            : ResolveDesktopOwner(ProfileKind.Api, authText);
    }

    private string? ResolveOfficialIdFromAuth(string authText)
    {
        var registry = profiles.Load();
        var owner = authClassifier.GetOfficialOwner(authText);
        return registry.OfficialProfiles.FirstOrDefault(profile => profile.Owner == owner)?.Id;
    }

    private string? ResolveApiIdFromAuth(string authText, string? baseUrl)
    {
        if (string.IsNullOrWhiteSpace(baseUrl)) return null;
        var keyHash = SHA256.HashData(Encoding.UTF8.GetBytes(authClassifier.GetApiKey(authText)));
        try
        {
            var registry = profiles.Load();
            foreach (var profile in registry.ApiProfiles.Where(profile => string.Equals(profile.BaseUrl, baseUrl, StringComparison.Ordinal)))
            {
                try
                {
                    var profileHash = SHA256.HashData(Encoding.UTF8.GetBytes(authClassifier.GetApiKey(profiles.ReadAuthentication(profile, ProfileKind.Api))));
                    if (CryptographicOperations.FixedTimeEquals(keyHash, profileHash)) return profile.Id;
                }
                catch (Exception ex) when (ex is IOException or InvalidDataException or CryptographicException) { }
            }
            return null;
        }
        finally { CryptographicOperations.ZeroMemory(keyHash); }
    }


    private static void CreateRestrictedDirectory(string path)
    {
        Directory.CreateDirectory(path);
        if (!OperatingSystem.IsWindows()) return;
        var identity = System.Security.Principal.WindowsIdentity.GetCurrent().User ?? throw new InvalidOperationException("无法确定当前 Windows 用户，已取消 OAuth 登录。 ");
        var security = new System.Security.AccessControl.DirectorySecurity();
        security.SetAccessRuleProtection(isProtected: true, preserveInheritance: false);
        security.AddAccessRule(new System.Security.AccessControl.FileSystemAccessRule(identity,
            System.Security.AccessControl.FileSystemRights.FullControl,
            System.Security.AccessControl.InheritanceFlags.ContainerInherit | System.Security.AccessControl.InheritanceFlags.ObjectInherit,
            System.Security.AccessControl.PropagationFlags.None, System.Security.AccessControl.AccessControlType.Allow));
        new DirectoryInfo(path).SetAccessControl(security);
    }

    private ProfileKind DetermineLiveKind(string auth, string config)
    {
        var kind = authClassifier.Classify(auth) ?? throw new InvalidDataException("当前 auth.json 认证类型不受支持或不明确。");
        var baseUrl = configEditor.GetTopLevel(config, "openai_base_url");
        if (kind == ProfileKind.Api && !string.IsNullOrWhiteSpace(baseUrl))
        {
            ProfileRegistry.ValidateRelayBaseUrl(baseUrl);
            return kind;
        }
        if (kind == ProfileKind.Official && string.IsNullOrWhiteSpace(baseUrl)) return kind;
        throw new InvalidDataException("config.toml 与 auth.json 的认证模式不一致。");
    }

    private string? CurrentHash(string path) => files.FileExists(path) ? Convert.ToHexString(SHA256.HashData(files.ReadAllBytes(path))).ToLowerInvariant() : null;
    private void Report(string stage, string message, int percent) => _progress.Value?.Report(new SwitchProgress(stage, message, percent));

    private sealed class ProgressScope : IDisposable
    {
        private readonly AsyncLocal<IProgress<SwitchProgress>?> _slot;
        private readonly IProgress<SwitchProgress>? _previous;
        public ProgressScope(AsyncLocal<IProgress<SwitchProgress>?> slot, IProgress<SwitchProgress>? current)
        {
            _slot = slot;
            _previous = slot.Value;
            slot.Value = current;
        }
        public void Dispose() => _slot.Value = _previous;
    }
}

internal static class ValueExtensions
{
    public static TResult Let<T, TResult>(this T value, Func<T, TResult> transform) => transform(value);
}
