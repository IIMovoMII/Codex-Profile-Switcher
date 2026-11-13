using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Switcher.Core.Abstractions;
using Switcher.Core.Configuration;
using Switcher.Core.Paths;
using Switcher.Core.Profiles;
using Switcher.Core.Switching;
using Switcher.Infrastructure.Configuration;
using Switcher.Infrastructure.Files;
using Switcher.Infrastructure.Models;
using Switcher.Infrastructure.Profiles;
using Switcher.Infrastructure.Security;
using Switcher.Infrastructure.Switching;
using Switcher.Infrastructure.Processes;

namespace Switcher.Infrastructure.Tests;

public sealed class SwitcherServiceBehaviorTests
{
    [Fact]
    public async Task Api_to_official_switch_removes_api_catalog_and_keeps_unrelated_preferences()
    {
        using var fixture = new Fixture();
        var api = fixture.Management.AddApi(new AddApiProfile("Relay A", "https://relay-a.example", "synthetic-api-key"));
        var official = fixture.Management.ImportOfficial("Official A", CreateOfficialAuth("switch-a"));
        fixture.Files.WriteAtomic(fixture.Paths.AuthFile, Encoding.UTF8.GetBytes(CreateApiAuth("synthetic-api-key")));
        fixture.Files.WriteAtomic(fixture.Paths.ConfigFile, Encoding.UTF8.GetBytes(
            "# preserve comment\r\nmodel_provider = \"relay\"\r\nopenai_base_url = \"https://relay-a.example\"\r\nmodel_catalog_json = \"C:/manual.json\"\r\nmodel = \"user-choice\"\r\nmodel_reasoning_effort = \"high\"\r\nunknown_setting = 42\r\n"));

        var result = await fixture.Service.SwitchAsync(ProfileKind.Official, official.Id, quick: true);

        Assert.Equal(ProfileKind.Api, result.SourceKind);
        Assert.Equal(ProfileKind.Official, result.TargetKind);
        Assert.Equal(official.Id, result.TargetProfileId);
        Assert.Equal(CreateOfficialAuth("switch-a"), fixture.Files.ReadAllText(fixture.Paths.AuthFile));
        var config = fixture.Files.ReadAllText(fixture.Paths.ConfigFile);
        Assert.Null(fixture.Config.GetTopLevel(config, "openai_base_url"));
        Assert.Null(fixture.Config.GetTopLevel(config, "model_catalog_json"));
        Assert.Contains("# preserve comment", config);
        Assert.Contains("model = \"user-choice\"", config);
        Assert.Contains("model_reasoning_effort = \"high\"", config);
        Assert.Contains("unknown_setting = 42", config);
        Assert.Equal(0, fixture.Catalogs.SyncCount);
        Assert.Equal(api.Id, fixture.Registry.Load().ActiveApiProfileId);
        Assert.Equal(official.Id, fixture.Registry.Load().ActiveOfficialProfileId);
    }

    [Fact]
    public async Task Official_to_api_switch_saves_outgoing_credentials_and_uses_the_selected_manual_catalog()
    {
        using var fixture = new Fixture();
        var officialAuth = CreateOfficialAuth("switch-b");
        var official = fixture.Management.ImportOfficial("Official B", officialAuth);
        var catalogPath = Path.Combine(fixture.Root, "relay models.json");
        fixture.Files.WriteAtomic(catalogPath, "{\"models\":[{\"slug\":\"synthetic-model\"}]}"u8);
        var api = fixture.Management.AddApi(new AddApiProfile("Relay B", "https://relay-b.example", "synthetic-api-key-b", catalogPath));
        fixture.Files.WriteAtomic(fixture.Paths.AuthFile, Encoding.UTF8.GetBytes(officialAuth));
        fixture.Files.WriteAtomic(fixture.Paths.ConfigFile, "model_provider = \"openai\"\r\nmodel = \"keep-model\"\r\n"u8);

        var result = await fixture.Service.SwitchAsync(ProfileKind.Api, api.Id, quick: false);

        Assert.Equal(ProfileKind.Official, result.SourceKind);
        Assert.Equal(ProfileKind.Api, result.TargetKind);
        Assert.Equal(api.Id, result.TargetProfileId);
        Assert.Equal(CreateApiAuth("synthetic-api-key-b"), fixture.Files.ReadAllText(fixture.Paths.AuthFile));
        var config = fixture.Files.ReadAllText(fixture.Paths.ConfigFile);
        Assert.Equal("https://relay-b.example", fixture.Config.GetTopLevel(config, "openai_base_url"));
        Assert.Equal(Path.GetFullPath(catalogPath), fixture.Config.GetTopLevel(config, "model_catalog_json"));
        Assert.Contains("model = \"keep-model\"", config);
        Assert.True(result.History?.Prepared);
        Assert.Equal(1, fixture.Catalogs.SyncCount);
        Assert.Equal(officialAuth, fixture.Profiles.ReadAuthentication(official, ProfileKind.Official));
        Assert.Equal(official.Id, fixture.Registry.Load().ActiveOfficialProfileId);
        Assert.Equal(api.Id, fixture.Registry.Load().ActiveApiProfileId);
    }

    [Fact]
    public async Task Official_to_api_switch_saves_latest_live_tokens_instead_of_the_imported_snapshot()
    {
        using var fixture = new Fixture();
        var importedAuth = CreateOfficialAuth("fresh-tokens");
        var official = fixture.Management.ImportOfficial("Official refreshed", importedAuth);
        var api = fixture.Management.AddApi(new AddApiProfile("Relay refreshed", "https://relay-refresh.example", "synthetic-api-key"));
        var currentAuth = JsonNode.Parse(importedAuth)!;
        currentAuth["tokens"]!["access_token"] = "latest-live-access";
        currentAuth["tokens"]!["refresh_token"] = "latest-live-refresh";
        var liveAuth = currentAuth.ToJsonString();
        fixture.Files.WriteAtomic(fixture.Paths.AuthFile, Encoding.UTF8.GetBytes(liveAuth));
        fixture.Files.WriteAtomic(fixture.Paths.ConfigFile, "model_provider = \"openai\"\n"u8);

        await fixture.Service.SwitchAsync(ProfileKind.Api, api.Id, quick: true);

        var savedAuth = fixture.Profiles.ReadAuthentication(official, ProfileKind.Official);
        Assert.Equal("latest-live-access", JsonNode.Parse(savedAuth)!["tokens"]!["access_token"]!.GetValue<string>());
        Assert.Equal("latest-live-refresh", JsonNode.Parse(savedAuth)!["tokens"]!["refresh_token"]!.GetValue<string>());
        Assert.NotEqual(importedAuth, savedAuth);
    }

    [Fact]
    public async Task Official_to_official_reapply_keeps_each_synthetic_identity_separate()
    {
        using var fixture = new Fixture();
        var firstAuth = CreateOfficialAuth("same-type-first");
        var first = fixture.Management.ImportOfficial("Official first", firstAuth);
        var secondAuth = CreateOfficialAuth("same-type-second");
        var second = fixture.Management.ImportOfficial("Official second", secondAuth);
        fixture.Files.WriteAtomic(fixture.Paths.AuthFile, Encoding.UTF8.GetBytes(firstAuth));
        fixture.Files.WriteAtomic(fixture.Paths.ConfigFile, "model_provider = \"openai\"\nmodel = \"keep-current\"\n"u8);

        var result = await fixture.Service.SwitchAsync(ProfileKind.Official, second.Id, quick: true);

        Assert.True(result.Reapplied);
        Assert.Equal(secondAuth, fixture.Files.ReadAllText(fixture.Paths.AuthFile));
        Assert.Equal(firstAuth, fixture.Profiles.ReadAuthentication(first, ProfileKind.Official));
        Assert.Equal(secondAuth, fixture.Profiles.ReadAuthentication(second, ProfileKind.Official));
        Assert.Equal(second.Id, fixture.Registry.Load().ActiveOfficialProfileId);
        Assert.Contains("model = \"keep-current\"", fixture.Files.ReadAllText(fixture.Paths.ConfigFile));
    }

    [Fact]
    public async Task Same_type_reapply_targets_an_independent_api_profile()
    {
        using var fixture = new Fixture();
        fixture.Management.AddApi(new AddApiProfile("Relay current", "https://current.example", "key-current"));
        var target = fixture.Management.AddApi(new AddApiProfile("Relay target", "https://target.example", "key-target"));
        fixture.Files.WriteAtomic(fixture.Paths.AuthFile, Encoding.UTF8.GetBytes(CreateApiAuth("key-current")));
        fixture.Files.WriteAtomic(fixture.Paths.ConfigFile, "model_provider = \"relay\"\nopenai_base_url = \"https://current.example\"\n"u8);

        var result = await fixture.Service.SwitchAsync(ProfileKind.Api, target.Id, quick: true);

        Assert.True(result.Reapplied);
        Assert.Equal("https://target.example", fixture.Config.GetTopLevel(fixture.Files.ReadAllText(fixture.Paths.ConfigFile), "openai_base_url"));
        Assert.Equal(CreateApiAuth("key-target"), fixture.Files.ReadAllText(fixture.Paths.AuthFile));
        Assert.Equal(target.Id, fixture.Registry.Load().ActiveApiProfileId);
        Assert.Null(result.History);
    }

    [Fact]
    public async Task Discovered_desktop_cli_is_used_by_the_actual_post_write_verification_without_a_path_override()
    {
        using var fixture = new Fixture();
        var api = fixture.Management.AddApi(new AddApiProfile("API discovery", "https://discovery.example.invalid", "synthetic-key"));
        var oldAuth = CreateOfficialAuth("discovery");
        fixture.Files.WriteAtomic(fixture.Paths.AuthFile, Encoding.UTF8.GetBytes(oldAuth));
        fixture.Files.WriteAtomic(fixture.Paths.ConfigFile, "model_provider = \"openai\"\n"u8);
        var local = Path.Combine(fixture.Root, "local");
        var executable = Path.Combine(local, "OpenAI", "Codex", "bin", "current-build", "codex.exe");
        fixture.Files.WriteAtomic(executable, "mock file, never execute"u8);
        var runner = new VerifyingRunner(request =>
        {
            Assert.Equal(executable, request.FileName);
            Assert.Equal(new[] { "login", "status" }, request.Arguments);
            Assert.Equal(fixture.Paths.CodexHome, request.Environment!["CODEX_HOME"]);
            Assert.Equal(CreateApiAuth("synthetic-key"), fixture.Files.ReadAllText(fixture.Paths.AuthFile));
            Assert.Equal("https://discovery.example.invalid", fixture.Config.GetTopLevel(fixture.Files.ReadAllText(fixture.Paths.ConfigFile), "openai_base_url"));
        });
        var runtime = new CodexRuntime(runner, fixture.Paths, executableResolver: new(new(local, Path.Combine(fixture.Root, "roaming"), "")));
        fixture.Runtime.Verification = runtime.VerifyAuthenticationAsync;
        var result = await fixture.Service.SwitchAsync(ProfileKind.Api, api.Id, quick: true);
        Assert.Equal(api.Id, result.TargetProfileId); Assert.Equal(1, runner.Calls);
        Assert.False(fixture.Files.FileExists(fixture.Paths.TransactionFile));
    }

    [Fact]
    public async Task Missing_cli_during_real_runtime_verification_restores_credentials_config_and_registry_pointer()
    {
        using var fixture = new Fixture();
        var old = fixture.Management.AddApi(new AddApiProfile("API old", "https://old.example.invalid", "old-key"));
        var target = fixture.Management.AddApi(new AddApiProfile("API target", "https://target.example.invalid", "target-key"));
        var registry = fixture.Registry.Load(); registry.ActiveApiProfileId = old.Id; fixture.Registry.Save(registry);
        var oldAuth = Encoding.UTF8.GetBytes(CreateApiAuth("old-key"));
        var oldConfig = "# keep\nmodel_provider = \"relay\"\nopenai_base_url = \"https://old.example.invalid\"\nmodel = \"user-choice\"\n"u8.ToArray();
        fixture.Files.WriteAtomic(fixture.Paths.AuthFile, oldAuth); fixture.Files.WriteAtomic(fixture.Paths.ConfigFile, oldConfig);
        var runner = new VerifyingRunner(_ => throw new InvalidOperationException("No process may run"));
        var runtime = new CodexRuntime(runner, fixture.Paths, executableResolver: new(new(Path.Combine(fixture.Root, "empty-local"), null, "")));
        fixture.Runtime.Verification = runtime.VerifyAuthenticationAsync;
        await Assert.ThrowsAsync<FileNotFoundException>(() => fixture.Service.SwitchAsync(ProfileKind.Api, target.Id, quick: true));
        Assert.Equal(oldAuth, fixture.Files.ReadAllBytes(fixture.Paths.AuthFile));
        Assert.Equal(oldConfig, fixture.Files.ReadAllBytes(fixture.Paths.ConfigFile));
        Assert.Equal(old.Id, fixture.Registry.Load().ActiveApiProfileId);
        Assert.False(fixture.Files.FileExists(fixture.Paths.TransactionFile)); Assert.Equal(0, runner.Calls);
    }

    [Fact]
    public async Task Failed_post_write_verification_restores_auth_and_config()
    {
        using var fixture = new Fixture();
        var api = fixture.Management.AddApi(new AddApiProfile("Relay rollback", "https://rollback.example", "rollback-api-key"));
        var oldAuth = CreateApiAuth("rollback-api-key");
        const string oldConfig = "# original\nmodel_provider = \"relay\"\nopenai_base_url = \"https://rollback.example\"\nunknown_setting = \"keep\"\n";
        fixture.Files.WriteAtomic(fixture.Paths.AuthFile, Encoding.UTF8.GetBytes(oldAuth));
        fixture.Files.WriteAtomic(fixture.Paths.ConfigFile, Encoding.UTF8.GetBytes(oldConfig));
        fixture.Runtime.FailVerification = true;

        await Assert.ThrowsAsync<InvalidOperationException>(() => fixture.Service.SwitchAsync(ProfileKind.Api, api.Id, quick: true));

        Assert.Equal(oldAuth, fixture.Files.ReadAllText(fixture.Paths.AuthFile));
        Assert.Equal(oldConfig, fixture.Files.ReadAllText(fixture.Paths.ConfigFile));
        Assert.False(fixture.Files.FileExists(fixture.Paths.TransactionFile));
    }

    [Fact]
    public async Task First_api_setup_creates_only_isolated_codex_files_and_allows_missing_catalog()
    {
        using var fixture = new Fixture();
        var api = fixture.Management.AddApi(new AddApiProfile("Relay first", "https://first.example", "first-api-key"));

        var result = await fixture.Service.InitializeAsync(ProfileKind.Api, api.Id, quick: true);

        Assert.True(fixture.Files.FileExists(fixture.Paths.AuthFile));
        Assert.True(fixture.Files.FileExists(fixture.Paths.ConfigFile));
        Assert.Contains("模型列表可能不完整", string.Join(" ", result.Notices));
        Assert.Equal(ProfileKind.Api, new CodexAuthClassifier().Classify(fixture.Files.ReadAllText(fixture.Paths.AuthFile)));
        Assert.Equal("https://first.example", fixture.Config.GetTopLevel(fixture.Files.ReadAllText(fixture.Paths.ConfigFile), "openai_base_url"));
        Assert.False(fixture.Files.FileExists(Path.Combine(fixture.Paths.CodexHome, "models_cache.json")));
    }

    [Fact]
    public async Task Cancelled_synthetic_oauth_leaves_live_auth_and_config_byte_identical()
    {
        using var fixture = new Fixture();
        fixture.Management.AddApi(new AddApiProfile("Relay before cancelled login", "https://cancel.example", "cancel-test-key"));
        var originalAuth = Encoding.UTF8.GetBytes(CreateApiAuth("live-api-key"));
        var originalConfig = Encoding.UTF8.GetBytes("# keep current API\r\nmodel_provider = \"relay\"\r\nopenai_base_url = \"https://live.example\"\r\nunknown = [1, \"future\"]\r\n");
        fixture.Files.WriteAtomic(fixture.Paths.AuthFile, originalAuth);
        fixture.Files.WriteAtomic(fixture.Paths.ConfigFile, originalConfig);
        fixture.Runtime.LoginFailure = new OperationCanceledException("synthetic user cancellation");

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => fixture.Service.AddOfficialInteractivelyAsync());

        Assert.Equal(originalAuth, fixture.Files.ReadAllBytes(fixture.Paths.AuthFile));
        Assert.Equal(originalConfig, fixture.Files.ReadAllBytes(fixture.Paths.ConfigFile));
        Assert.Empty(fixture.Registry.Load().OfficialProfiles);
        var oauthDirectory = Path.Combine(fixture.Paths.DataDirectory, "oauth-temp");
        Assert.True(Directory.Exists(oauthDirectory));
        Assert.Empty(Directory.GetFileSystemEntries(oauthDirectory));
        Assert.False(fixture.Files.FileExists(fixture.Paths.TransactionFile));
    }

    private static string CreateApiAuth(string key) => JsonSerializer.Serialize(new Dictionary<string, string> { ["OPENAI_API_KEY"] = key });

    private static string CreateOfficialAuth(string suffix)
    {
        var claims = JsonSerializer.Serialize(new Dictionary<string, object?>
        {
            ["email"] = $"switch-{suffix}@example.invalid",
            ["https://api.openai.com/auth"] = new Dictionary<string, object?>
            {
                ["chatgpt_account_id"] = $"switch-account-{suffix}",
                ["chatgpt_user_id"] = $"switch-user-{suffix}",
                ["chatgpt_plan_type"] = "plus"
            }
        });
        var payload = Convert.ToBase64String(Encoding.UTF8.GetBytes(claims)).TrimEnd('=').Replace('+', '-').Replace('/', '_');
        return JsonSerializer.Serialize(new { auth_mode = "chatgpt", tokens = new { id_token = $"test.{payload}.signature", account_id = $"switch-account-{suffix}", access_token = "synthetic-access", refresh_token = "synthetic-refresh" } });
    }

    private sealed class Fixture : IDisposable
    {
        private readonly TestProtector _protector = new();
        public Fixture()
        {
            Root = Path.Combine(Path.GetTempPath(), "codex-switch-service-test-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(Root);
            Paths = SwitcherPaths.FromEnvironment(Path.Combine(Root, "codex home"), Path.Combine(Root, "switcher data"));
            Files = new PhysicalSwitcherFileSystem();
            Registry = new ProfileRegistryStore(Files, Paths, _protector);
            var vault = new CredentialVault(Files, _protector, Registry, Paths);
            var executor = new AtomicSwitchExecutor(Files, new SwitchTransactionStore(Files, _protector, Paths));
            Profiles = new ProfileRepository(Registry, vault, Paths, Files, executor);
            Management = new ProfileManagementService(Profiles, new CodexAuthClassifier());
            Config = new TomlConfigEditor();
            Catalogs = new TestCatalogProvider(Paths);
            Runtime = new TestCodexRuntime(Files, Paths);
            var projects = new TestProjects();
            var history = new TestHistory();
            Service = new SwitcherService(Paths, Files, new TestLock(), executor, Profiles, new CodexAuthClassifier(), Management,
                Config, Runtime, new EmptyDesktopStatePlanner(), Catalogs, projects, history);
        }

        public string Root { get; }
        public SwitcherPaths Paths { get; }
        public PhysicalSwitcherFileSystem Files { get; }
        public ProfileRegistryStore Registry { get; }
        public ProfileRepository Profiles { get; }
        public ProfileManagementService Management { get; }
        public TomlConfigEditor Config { get; }
        public TestCatalogProvider Catalogs { get; }
        public TestCodexRuntime Runtime { get; }
        public SwitcherService Service { get; }
        public void Dispose() { try { Directory.Delete(Root, recursive: true); } catch (IOException) { } }
    }

    private sealed class TestProtector : ISecretProtector
    {
        public byte[] Protect(ReadOnlySpan<byte> plaintext) => plaintext.ToArray();
        public byte[] Unprotect(ReadOnlySpan<byte> ciphertext) => ciphertext.ToArray();
    }

    private sealed class TestLock : IOperationLock
    {
        public ValueTask<IAsyncDisposable> AcquireAsync(string name, CancellationToken cancellationToken) => ValueTask.FromResult<IAsyncDisposable>(new Releaser());
        public ValueTask DisposeAsync() => ValueTask.CompletedTask;
        private sealed class Releaser : IAsyncDisposable { public ValueTask DisposeAsync() => ValueTask.CompletedTask; }
    }

    private sealed class TestCodexRuntime(ISwitcherFileSystem files, SwitcherPaths paths) : ICodexRuntime
    {
        public Func<ProfileKind, CancellationToken, string?, Task>? Verification { get; set; }
        public bool FailVerification { get; set; }
        public Exception LoginFailure { get; set; } = new InvalidOperationException("interactive login must not run in tests");
        public Task<IReadOnlyList<string>> FindRunningProcessNamesAsync(CancellationToken cancellationToken) => Task.FromResult<IReadOnlyList<string>>([]);
        public Task<bool> IsAvailableAsync(CancellationToken cancellationToken) => Task.FromResult(true);
        public Task VerifyAuthenticationAsync(ProfileKind expectedKind, CancellationToken cancellationToken, string? codexHome = null)
        {
            if (Verification is not null) return Verification(expectedKind, cancellationToken, codexHome);
            if (FailVerification) throw new InvalidOperationException("synthetic verification failure");
            var currentHome = codexHome ?? paths.CodexHome;
            var auth = files.ReadAllText(Path.Combine(currentHome, "auth.json"));
            if (new CodexAuthClassifier().Classify(auth) != expectedKind) throw new InvalidDataException("synthetic identity mismatch");
            return Task.CompletedTask;
        }
        public Task LoginInteractivelyAsync(string codexHome, CancellationToken cancellationToken) => Task.FromException(LoginFailure);
        public void EnsureNoAuthenticationOverrides() { }
        public IReadOnlyList<string> GetAuthenticationOverrides() => [];
        public IReadOnlyDictionary<string, string?> GetProcessEnvironment() => new Dictionary<string, string?>();
    }

    private sealed class VerifyingRunner(Action<ProcessRequest> verify) : IProcessRunner
    {
        public int Calls { get; private set; }
        public Task<ProcessResult> RunAsync(ProcessRequest request, CancellationToken cancellationToken)
        {
            Calls++; verify(request); return Task.FromResult(new ProcessResult(0, "Logged in using an API key", "", false));
        }
    }

    private sealed class EmptyDesktopStatePlanner : IDesktopStatePlanner
    {
        public DesktopStatePlan CreatePlan(ProfileKind targetKind, string? sourceAuth, string? targetAuth, string? officialAuth) => new([], 0, false, false);
    }

    private sealed class TestCatalogProvider(SwitcherPaths paths) : IModelCatalogProvider
    {
        public int SyncCount { get; private set; }
        public string ResolveApiCatalog(ApiProfile profile) => string.IsNullOrWhiteSpace(profile.ModelCatalogJson) ? paths.DefaultManualModelCatalogFile : Path.GetFullPath(profile.ModelCatalogJson);
        public string EnsureManualCatalogFile(ApiProfile profile) => ResolveApiCatalog(profile);
        public CatalogSyncSummary SyncOfficialSnapshot(string authJson, OfficialProfile profile, string currentConfig, string? organization, string? project)
        {
            SyncCount++;
            return new CatalogSyncSummary(true, "synthetic snapshot", Path.Combine(paths.ModelCatalogDirectory, profile.Id + ".json"), 1);
        }
        public CatalogDisplay GetStatus(ProfileEntry profile, ProfileKind kind, string? sourceName = null) => new("test", "", false, "", "", "");
    }

    private sealed class TestProjects : IProjectProjectionService
    {
        public Task<ProjectProjectionSummary> PrepareAsync(string? desktopOwner, bool repair, bool inferFromWorkingDirectory, IProgress<SwitchProgress>? progress, CancellationToken cancellationToken) =>
            Task.FromResult(new ProjectProjectionSummary(false, "synthetic project check", 0, 0, 0, ""));
    }

    private sealed class TestHistory : IHistoryCompatibilityService
    {
        public Task<HistoryPreparationResult> PrepareAsync(bool fullScan, IProgress<SwitchProgress>? progress, CancellationToken cancellationToken) =>
            Task.FromResult(new HistoryPreparationResult(true, false, "synthetic history prepared", 0, 0, ""));
    }
}
