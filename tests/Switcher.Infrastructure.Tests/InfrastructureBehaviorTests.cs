using System.Text;
using System.Text.Json;
using Switcher.Core.Abstractions;
using Switcher.Core.Configuration;
using Switcher.Core.Paths;
using Switcher.Core.Profiles;
using Switcher.Core.Switching;
using Switcher.Infrastructure.Configuration;
using Switcher.Infrastructure.CodexAdapters;
using Switcher.Infrastructure.Files;
using Switcher.Infrastructure.Models;
using Switcher.Infrastructure.Profiles;
using Switcher.Infrastructure.Switching;

namespace Switcher.Infrastructure.Tests;

public sealed class InfrastructureBehaviorTests
{
    [Fact]
    public void Auth_classifier_distinguishes_api_and_official_without_logging_secrets()
    {
        var classifier = new CodexAuthClassifier();
        Assert.Equal(ProfileKind.Api, classifier.Classify("{\"OPENAI_API_KEY\":\"sk-test\"}"));
        Assert.Null(classifier.Classify("{\"auth_mode\":\"chatgpt\",\"tokens\":{\"id_token\":\"bad\"}}"));
        Assert.Equal("sk-test", classifier.GetApiKey("{\"OPENAI_API_KEY\":\"sk-test\"}"));
    }

    [Fact]
    public void Toml_editor_removes_api_overrides_and_preserves_comments_and_preferences()
    {
        var editor = new TomlConfigEditor();
        const string source = "# keep this comment\r\nmodel_provider = \"relay\" # managed provider\r\nopenai_base_url = \"https://old.example\" # old relay\r\nmodel_catalog_json = \"C:/manual.json\" # user catalog\r\nmodel = \"my-model\"\r\nunknown_setting = 42\r\n[features]\r\nrespect_system_proxy = true # proxy note\r\n";
        var official = editor.BuildModeConfiguration(source, ProfileKind.Official, null, null,
            new EffectiveSettings(null, null, ProxyPolicy.Preserve));
        editor.ValidateSyntax(official);
        Assert.Null(editor.GetTopLevel(official, "openai_base_url"));
        Assert.Null(editor.GetTopLevel(official, "model_catalog_json"));
        Assert.Contains("# old relay", official);
        Assert.Contains("# user catalog", official);
        Assert.Contains("unknown_setting = 42", official);
        Assert.Contains("model = \"my-model\"", official);
    }

    [Fact]
    public void Official_cache_identity_matches_the_legacy_reference_vector()
    {
        var auth = CreateOfficialAuth("a");
        var candidates = OfficialCacheSourceVerifier.ComputeCandidatesForTesting(auth, "0.134.0");
        Assert.Contains("90d869ea2800bc1437c2ac6697f48f6bd1b32e3d16bd2ae2e93a329a4e3c56ab", candidates);
    }

    [Fact]
    public void Atomic_executor_restores_all_files_when_validation_fails()
    {
        using var fixture = new Fixture();
        var first = Path.Combine(fixture.Root, "first.txt");
        var second = Path.Combine(fixture.Root, "second.txt");
        fixture.Files.WriteAtomic(first, "old-a"u8);
        fixture.Files.WriteAtomic(second, "old-b"u8);
        var plan = new OperationPlan(Guid.NewGuid().ToString("N"), "fault", [
            new FileMutation(first, Hash("old-a"u8), "new-a"u8.ToArray(), "first", true),
            new FileMutation(second, Hash("old-b"u8), "new-b"u8.ToArray(), "second", true)], DateTimeOffset.UtcNow);

        Assert.Throws<InvalidOperationException>(() => fixture.Executor.ExecuteAsync(plan, _ => throw new InvalidOperationException("simulated failure"), CancellationToken.None).GetAwaiter().GetResult());
        Assert.Equal("old-a", Encoding.UTF8.GetString(fixture.Files.ReadAllBytes(first)));
        Assert.Equal("old-b", Encoding.UTF8.GetString(fixture.Files.ReadAllBytes(second)));
    }

    [Fact]
    public void Registry_roundtrip_preserves_unknown_json_fields()
    {
        using var fixture = new Fixture();
        var registry = ProfileRegistry.Create(fixture.Paths.CodexHome, DateTimeOffset.UtcNow);
        registry.UnknownFields = new Dictionary<string, JsonElement> { ["future_field"] = JsonDocument.Parse("{\"nullable\":null,\"array\":[1,\"x\"]}").RootElement.Clone() };
        var store = new ProfileRegistryStore(fixture.Files, fixture.Paths);
        fixture.Files.WriteAtomic(fixture.Paths.RegistryFile, store.Serialize(registry));
        var loaded = store.Load();
        Assert.True(loaded.UnknownFields!.ContainsKey("future_field"));
        Assert.Equal(JsonValueKind.Object, loaded.UnknownFields["future_field"].ValueKind);
    }

    [Fact]
    public void Official_profile_settings_can_be_saved_without_rewriting_credentials_or_unknown_fields()
    {
        using var fixture = new Fixture();
        var protector = new TestProtector();
        var registryStore = new ProfileRegistryStore(fixture.Files, fixture.Paths, protector);
        var owner = new string('a', 64);
        var profile = new OfficialProfile
        {
            Id = "official-" + owner,
            Owner = owner,
            Name = "Official fixture",
            AuthFile = "official-" + owner + ".auth.dpapi",
            UnknownFields = new Dictionary<string, JsonElement>
            {
                ["future_profile_field"] = JsonDocument.Parse("{\"preserve\":true}").RootElement.Clone()
            }
        };
        var registry = ProfileRegistry.Create(fixture.Paths.CodexHome, DateTimeOffset.UtcNow);
        registry.OfficialProfiles.Add(profile);
        registry.UnknownFields = new Dictionary<string, JsonElement>
        {
            ["future_registry_field"] = JsonDocument.Parse("[null,1]").RootElement.Clone()
        };
        registryStore.Save(registry);
        var vault = new CredentialVault(fixture.Files, protector, registryStore, fixture.Paths);
        var repository = new ProfileRepository(registryStore, vault, fixture.Paths, fixture.Files, fixture.Executor);
        var management = new ProfileManagementService(repository, new CodexAuthClassifier());

        management.UpdateSettings(ProfileKind.Official, profile.Id, new ProfileSettings(
            SettingChoice<string>.Set("future-model"), SettingChoice<int>.Preserve(), SettingChoice<ProxyPolicy>.Set(ProxyPolicy.System)));

        var updated = (OfficialProfile)registryStore.Load().Find(ProfileKind.Official, profile.Id);
        Assert.Equal("explicit", updated.ModelPolicy);
        Assert.Equal("future-model", updated.Model);
        Assert.Equal("preserve", updated.ContextWindowPolicy);
        Assert.Equal("system", updated.ProxyPolicy);
        Assert.Equal(JsonValueKind.Object, updated.UnknownFields!["future_profile_field"].ValueKind);
        Assert.Equal(JsonValueKind.Array, registryStore.Load().UnknownFields!["future_registry_field"].ValueKind);
        Assert.False(fixture.Files.FileExists(registryStore.CredentialPath(profile)));
    }

    [Fact]
    public void Reauthorization_rejects_a_different_official_identity_without_changing_credentials()
    {
        using var fixture = new Fixture();
        var protector = new TestProtector();
        var registryStore = new ProfileRegistryStore(fixture.Files, fixture.Paths, protector);
        var vault = new CredentialVault(fixture.Files, protector, registryStore, fixture.Paths);
        var repository = new ProfileRepository(registryStore, vault, fixture.Paths, fixture.Files, fixture.Executor);
        var management = new ProfileManagementService(repository, new CodexAuthClassifier());
        var profile = management.ImportOfficial("Official A", CreateOfficialAuth("reauth-original"));
        var credentialBefore = fixture.Files.ReadAllBytes(registryStore.CredentialPath(profile));

        Assert.Throws<InvalidDataException>(() => management.ReauthorizeOfficial(profile.Id, CreateOfficialAuth("reauth-other")));

        Assert.Equal(credentialBefore, fixture.Files.ReadAllBytes(registryStore.CredentialPath(profile)));
        Assert.Equal("catalog-reauth-original@example.invalid", ReadOfficialEmail(repository.ReadAuthentication(profile, ProfileKind.Official)));
        Assert.Equal(profile.Id, registryStore.Load().OfficialProfiles.Single().Id);
    }

    [Fact]
    public void Deleted_legacy_profile_is_not_recreated_by_legacy_import()
    {
        using var fixture = new Fixture();
        var protector = new TestProtector();
        var registryStore = new ProfileRegistryStore(fixture.Files, fixture.Paths, protector);
        var legacyAuth = Encoding.UTF8.GetBytes(CreateOfficialAuth("legacy-delete"));
        var legacySnapshot = Path.Combine(fixture.Paths.DataDirectory, "official.auth.dpapi");
        fixture.Files.WriteAtomic(legacySnapshot, protector.Protect(legacyAuth));
        var imported = Assert.Single(registryStore.Load().OfficialProfiles);
        var vault = new CredentialVault(fixture.Files, protector, registryStore, fixture.Paths);
        var repository = new ProfileRepository(registryStore, vault, fixture.Paths, fixture.Files, fixture.Executor);
        var management = new ProfileManagementService(repository, new CodexAuthClassifier());

        management.Remove(ProfileKind.Official, imported.Id, liveProfileId: null);

        Assert.Empty(registryStore.Load().OfficialProfiles);
        Assert.True(fixture.Files.FileExists(legacySnapshot));
        Assert.False(fixture.Files.FileExists(registryStore.CredentialPath(imported)));
    }

    [Fact]
    public async Task Startup_recovery_restores_files_after_an_interrupted_write()
    {
        using var fixture = new Fixture();
        var protector = new TestProtector();
        var transactions = new SwitchTransactionStore(fixture.Files, protector, fixture.Paths);
        var target = Path.Combine(fixture.Root, "interrupted file.json");
        var original = Encoding.UTF8.GetBytes("{\"state\":\"before\"}");
        var planned = Encoding.UTF8.GetBytes("{\"state\":\"after\"}");
        fixture.Files.WriteAtomic(target, original);
        var plan = new OperationPlan(Guid.NewGuid().ToString("N"), "interrupted write",
            [new FileMutation(target, Hash(original), planned, "synthetic state", true)], DateTimeOffset.UtcNow);
        transactions.SavePrepared(plan,
            [new JournalFile(target, true, original, true, planned, Hash(original), Hash(planned))]);
        fixture.Files.WriteAtomic(target, planned);
        var executor = new AtomicSwitchExecutor(fixture.Files, transactions);

        await executor.RecoverAsync(CancellationToken.None);

        Assert.Equal(original, fixture.Files.ReadAllBytes(target));
        Assert.False(fixture.Files.FileExists(fixture.Paths.TransactionFile));
    }

    [Fact]
    public void Operation_history_persists_recent_entries_and_redacts_credentials()
    {
        using var fixture = new Fixture();
        var store = new OperationHistoryStore(fixture.Files, fixture.Paths);

        store.Append("切换完成 refresh_token=refresh-secret sk-test-secret123 Bearer bearer-secret");
        store.Append("第二项操作完成");

        var restarted = new OperationHistoryStore(fixture.Files, fixture.Paths);
        var recent = restarted.ReadRecent();
        Assert.Equal(2, recent.Count);
        Assert.Contains("第二项操作完成", recent[1]);
        Assert.Contains("[REDACTED]", recent[0]);
        Assert.DoesNotContain("refresh-secret", string.Join(" ", recent));
        Assert.DoesNotContain("sk-test-secret123", string.Join(" ", recent));
        Assert.DoesNotContain("bearer-secret", string.Join(" ", recent));
        Assert.Single(restarted.ReadRecent(1));
    }

    [Fact]
    public void Catalog_sync_copies_complete_models_array_without_cache_metadata()
    {
        using var fixture = new Fixture();
        var auth = CreateOfficialAuth("a");
        var classifier = new CodexAuthClassifier();
        var owner = classifier.GetOfficialOwner(auth);
        var profile = new OfficialProfile { Id = "official-" + owner, Owner = owner, Name = "A", AuthFile = "official-" + owner + ".auth.dpapi" };
        var registry = ProfileRegistry.Create(fixture.Paths.CodexHome, DateTimeOffset.UtcNow);
        registry.OfficialProfiles.Add(profile);
        var registryStore = new ProfileRegistryStore(fixture.Files, fixture.Paths);
        registryStore.Save(registry);
        var model = JsonDocument.Parse("""{"slug":"future-x","display_name":"未来模型","context_window":999999,"reasoning":["low","high"],"unknown":{"empty":[],"nil":null,"number":1.25}}""").RootElement.Clone();
        var models = JsonSerializer.Serialize(new[] { model });
        var identity = "90d869ea2800bc1437c2ac6697f48f6bd1b32e3d16bd2ae2e93a329a4e3c56ab";
        using var modelDoc = JsonDocument.Parse(models);
        var cache = JsonSerializer.Serialize(new { client_version = "0.134.0", identity, user = "must-not-copy", models = modelDoc.RootElement });
        fixture.Files.WriteAtomic(fixture.Paths.ModelCacheFile, Encoding.UTF8.GetBytes(cache));
        var originalCache = fixture.Files.ReadAllBytes(fixture.Paths.ModelCacheFile);
        var service = new ModelCatalogService(fixture.Files, fixture.Paths, registryStore, new OfficialCacheSourceVerifier(), fixture.Executor, new TomlConfigEditor());

        var result = service.SyncOfficialSnapshot(auth, profile, "model_provider = \"openai\"\n", null, null);

        Assert.True(result.Succeeded, result.Message);
        Assert.Equal(originalCache, fixture.Files.ReadAllBytes(fixture.Paths.ModelCacheFile));
        using var snapshot = JsonDocument.Parse(fixture.Files.ReadAllBytes(result.Path));
        Assert.Equal(JsonValueKind.Array, snapshot.RootElement.GetProperty("models").ValueKind);
        Assert.False(snapshot.RootElement.TryGetProperty("identity", out _));
        Assert.False(snapshot.RootElement.TryGetProperty("user", out _));
        Assert.Equal("future-x", snapshot.RootElement.GetProperty("models")[0].GetProperty("slug").GetString());
        Assert.Equal(JsonValueKind.Null, snapshot.RootElement.GetProperty("models")[0].GetProperty("unknown").GetProperty("nil").ValueKind);
        Assert.Equal(1.25, snapshot.RootElement.GetProperty("models")[0].GetProperty("unknown").GetProperty("number").GetDouble());
    }

    [Fact]
    public void Invalid_or_foreign_official_cache_retains_previous_snapshot()
    {
        using var fixture = new Fixture();
        var auth = CreateOfficialAuth("a");
        var owner = new CodexAuthClassifier().GetOfficialOwner(auth);
        var profile = new OfficialProfile { Id = "official-" + owner, Owner = owner, Name = "A", AuthFile = "official-" + owner + ".auth.dpapi" };
        var registry = ProfileRegistry.Create(fixture.Paths.CodexHome, DateTimeOffset.UtcNow);
        registry.OfficialProfiles.Add(profile);
        var registryStore = new ProfileRegistryStore(fixture.Files, fixture.Paths);
        registryStore.Save(registry);
        var target = Path.Combine(fixture.Paths.ModelCatalogDirectory, profile.Id + ".json");
        var existing = Encoding.UTF8.GetBytes("{\"models\":[{\"slug\":\"previous\",\"unknown\":null}]}\n");
        fixture.Files.WriteAtomic(target, existing);
        fixture.Files.WriteAtomic(fixture.Paths.ModelCacheFile, Encoding.UTF8.GetBytes("{\"identity\":\"0000000000000000000000000000000000000000000000000000000000000000\",\"client_version\":\"0.134.0\",\"models\":[{\"slug\":\"foreign\"}]}"));
        var service = new ModelCatalogService(fixture.Files, fixture.Paths, registryStore, new OfficialCacheSourceVerifier(), fixture.Executor, new TomlConfigEditor());

        var result = service.SyncOfficialSnapshot(auth, profile, "model_provider = \"openai\"\n", null, null);

        Assert.False(result.Succeeded);
        Assert.Equal(existing, fixture.Files.ReadAllBytes(target));
    }

    [Fact]
    public void Catalog_sync_write_failure_rolls_back_and_returns_a_notice()
    {
        using var fixture = new Fixture();
        var files = new FailOnceFileSystem(fixture.Files);
        var auth = CreateOfficialAuth("a");
        var owner = new CodexAuthClassifier().GetOfficialOwner(auth);
        var profile = new OfficialProfile { Id = "official-" + owner, Owner = owner, Name = "A", AuthFile = "official-" + owner + ".auth.dpapi" };
        var registry = ProfileRegistry.Create(fixture.Paths.CodexHome, DateTimeOffset.UtcNow);
        registry.OfficialProfiles.Add(profile);
        var registryStore = new ProfileRegistryStore(files, fixture.Paths);
        registryStore.Save(registry);
        var snapshotPath = Path.Combine(fixture.Paths.ModelCatalogDirectory, profile.Id + ".json");
        var previousSnapshot = Encoding.UTF8.GetBytes("{\"models\":[{\"slug\":\"previous\"}]}\n");
        files.WriteAtomic(snapshotPath, previousSnapshot);
        using var models = JsonDocument.Parse("[{\"slug\":\"new-model\"}]");
        files.WriteAtomic(fixture.Paths.ModelCacheFile, JsonSerializer.SerializeToUtf8Bytes(new
        {
            client_version = "0.134.0",
            identity = "90d869ea2800bc1437c2ac6697f48f6bd1b32e3d16bd2ae2e93a329a4e3c56ab",
            models = models.RootElement
        }));
        var executor = new AtomicSwitchExecutor(files, new SwitchTransactionStore(files, new TestProtector(), fixture.Paths));
        var service = new ModelCatalogService(files, fixture.Paths, registryStore, new OfficialCacheSourceVerifier(), executor, new TomlConfigEditor());
        files.FailNextWritePath = fixture.Paths.RegistryFile;

        var result = service.SyncOfficialSnapshot(auth, profile, "model_provider = \"openai\"\n", null, null);

        Assert.False(result.Succeeded);
        Assert.Contains("保留已有快照", result.Message);
        Assert.Equal(previousSnapshot, files.ReadAllBytes(snapshotPath));
        Assert.False(files.FileExists(fixture.Paths.TransactionFile));
        Assert.Empty(registryStore.Load().OfficialProfiles.Single().ModelCatalogSnapshotUpdatedUtc);
    }

    [Fact]
    public void Catalog_sync_does_not_swallow_a_failure_with_pending_recovery_material()
    {
        using var fixture = new Fixture();
        var files = new FailOnceFileSystem(fixture.Files);
        var auth = CreateOfficialAuth("a");
        var owner = new CodexAuthClassifier().GetOfficialOwner(auth);
        var profile = new OfficialProfile { Id = "official-" + owner, Owner = owner, Name = "A", AuthFile = "official-" + owner + ".auth.dpapi" };
        var registry = ProfileRegistry.Create(fixture.Paths.CodexHome, DateTimeOffset.UtcNow);
        registry.OfficialProfiles.Add(profile);
        var registryStore = new ProfileRegistryStore(files, fixture.Paths);
        registryStore.Save(registry);
        var snapshotPath = Path.Combine(fixture.Paths.ModelCatalogDirectory, profile.Id + ".json");
        var previous = Encoding.UTF8.GetBytes("{\"models\":[{\"slug\":\"previous\"}]}\n");
        var external = Encoding.UTF8.GetBytes("{\"models\":[{\"slug\":\"external\"}]}\n");
        files.WriteAtomic(snapshotPath, previous);
        using var models = JsonDocument.Parse("[{\"slug\":\"new-model\"}]");
        files.WriteAtomic(fixture.Paths.ModelCacheFile, JsonSerializer.SerializeToUtf8Bytes(new
        {
            client_version = "0.134.0",
            identity = "90d869ea2800bc1437c2ac6697f48f6bd1b32e3d16bd2ae2e93a329a4e3c56ab",
            models = models.RootElement
        }));
        files.FailNextWritePath = fixture.Paths.RegistryFile;
        files.OnFailure = () => fixture.Files.WriteAtomic(snapshotPath, external);
        var executor = new AtomicSwitchExecutor(files, new SwitchTransactionStore(files, new TestProtector(), fixture.Paths));
        var service = new ModelCatalogService(files, fixture.Paths, registryStore, new OfficialCacheSourceVerifier(), executor, new TomlConfigEditor());

        var error = Assert.Throws<IOException>(() => service.SyncOfficialSnapshot(auth, profile, "model_provider = \"openai\"\n", null, null));

        Assert.Contains("拒绝覆盖恢复材料", error.Message);
        Assert.Equal(external, files.ReadAllBytes(snapshotPath));
        Assert.True(files.FileExists(fixture.Paths.TransactionFile));
    }

    [Fact]
    public void Manual_catalog_path_resolves_without_rewriting_user_file()
    {
        using var fixture = new Fixture();
        var manual = Path.Combine(fixture.Root, "custom models.json");
        var original = Encoding.UTF8.GetBytes("{\"models\":[{\"slug\":\"user-model\",\"preserve\":true}]}\n");
        fixture.Files.WriteAtomic(manual, original);
        var profile = new ApiProfile { Id = "api-one", Name = "API", BaseUrl = "https://relay.example", AuthFile = "api-one.auth.dpapi", ModelCatalogMode = "manual", ModelCatalogJson = manual };
        var store = new ProfileRegistryStore(fixture.Files, fixture.Paths);
        Assert.Equal(Path.GetFullPath(manual), store.CatalogPath(profile));
        Assert.Equal(original, fixture.Files.ReadAllBytes(manual));
        profile.ModelCatalogJson = "";
        Assert.Equal(fixture.Paths.DefaultManualModelCatalogFile, store.CatalogPath(profile));
    }

    [Fact]
    public void Api_profiles_retain_independent_manual_and_official_catalog_sources()
    {
        using var fixture = new Fixture();
        var protector = new TestProtector();
        var registryStore = new ProfileRegistryStore(fixture.Files, fixture.Paths, protector);
        var vault = new CredentialVault(fixture.Files, protector, registryStore, fixture.Paths);
        var repository = new ProfileRepository(registryStore, vault, fixture.Paths, fixture.Files, fixture.Executor);
        var profiles = new ProfileManagementService(repository, new CodexAuthClassifier());
        var manualPath = Path.Combine(fixture.Root, "manual models.json");
        var sourceId = "official-" + new string('a', 64);

        var following = profiles.AddApi(new AddApiProfile("Following", "https://relay.example", "synthetic-key-follow",
            ModelCatalogPath: manualPath, ModelCatalogMode: "official", ModelCatalogSourceOfficialId: sourceId));
        var manual = profiles.AddApi(new AddApiProfile("Manual", "https://relay.example", "synthetic-key-manual", ModelCatalogPath: manualPath));
        var saved = registryStore.Load();
        var savedFollowing = (ApiProfile)saved.Find(ProfileKind.Api, following.Id);
        var savedManual = (ApiProfile)saved.Find(ProfileKind.Api, manual.Id);

        Assert.Equal("official", savedFollowing.ModelCatalogMode);
        Assert.Equal(sourceId, savedFollowing.ModelCatalogSourceOfficialId);
        Assert.Equal(Path.GetFullPath(manualPath), registryStore.CatalogPath(savedManual));
        Assert.Equal("manual", savedManual.ModelCatalogMode);
        Assert.DoesNotContain("synthetic-key-follow", Encoding.UTF8.GetString(fixture.Files.ReadAllBytes(fixture.Paths.RegistryFile)));
        Assert.Contains("synthetic-key-follow", repository.ReadAuthentication(following, ProfileKind.Api));
    }

    [Fact]
    public void Atomic_executor_refuses_external_change_during_recovery()
    {
        using var fixture = new Fixture();
        var target = Path.Combine(fixture.Root, "external.txt");
        fixture.Files.WriteAtomic(target, "before"u8);
        var plan = new OperationPlan(Guid.NewGuid().ToString("N"), "external-change", [new FileMutation(target, Hash("before"u8), "planned"u8.ToArray(), "test", true)], DateTimeOffset.UtcNow);

        var error = Assert.Throws<IOException>(() => fixture.Executor.ExecuteAsync(plan, _ =>
        {
            fixture.Files.WriteAtomic(target, "external"u8);
            throw new InvalidOperationException("injected");
        }, CancellationToken.None).GetAwaiter().GetResult());

        Assert.Contains("拒绝覆盖", error.Message);
        Assert.Equal("external", Encoding.UTF8.GetString(fixture.Files.ReadAllBytes(target)));
        Assert.True(fixture.Files.FileExists(fixture.Paths.TransactionFile));
    }

    [Fact]
    public void Dpapi_entropy_normalizes_trailing_separators_and_is_home_scoped()
    {
        if (!OperatingSystem.IsWindows()) return;
        using var fixture = new Fixture();
        var plain = Encoding.UTF8.GetBytes("synthetic-credential");
        var first = new Switcher.Infrastructure.Security.CurrentUserDpapiProtector(fixture.Paths.CodexHome + Path.DirectorySeparatorChar);
        var same = new Switcher.Infrastructure.Security.CurrentUserDpapiProtector(fixture.Paths.CodexHome);
        var other = new Switcher.Infrastructure.Security.CurrentUserDpapiProtector(fixture.Paths.CodexHome + "-other");
        var encrypted = first.Protect(plain);
        Assert.Equal(plain, same.Unprotect(encrypted));
        Assert.ThrowsAny<System.Security.Cryptography.CryptographicException>(() => other.Unprotect(encrypted));
    }

    private static string CreateOfficialAuth(string suffix)
    {
        var claims = JsonSerializer.Serialize(new Dictionary<string, object?>
        {
            ["email"] = $"catalog-{suffix}@example.invalid",
            ["https://api.openai.com/auth"] = new Dictionary<string, object?>
            {
                ["chatgpt_account_id"] = $"catalog-account-{suffix}",
                ["chatgpt_user_id"] = $"catalog-user-{suffix}",
                ["chatgpt_plan_type"] = "plus"
            }
        });
        var payload = Convert.ToBase64String(Encoding.UTF8.GetBytes(claims)).TrimEnd('=').Replace('+', '-').Replace('/', '_');
        return JsonSerializer.Serialize(new { auth_mode = "chatgpt", tokens = new { id_token = $"test.{payload}.signature", account_id = $"catalog-account-{suffix}", access_token = "fixture-access", refresh_token = "fixture-refresh" } });
    }

    private static string Hash(ReadOnlySpan<byte> bytes) => Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(bytes)).ToLowerInvariant();

    private static string ReadOfficialEmail(string auth)
    {
        using var document = JsonDocument.Parse(auth);
        var token = document.RootElement.GetProperty("tokens").GetProperty("id_token").GetString()!;
        var payload = token.Split('.')[1].Replace('-', '+').Replace('_', '/');
        payload = payload.PadRight(payload.Length + (4 - payload.Length % 4) % 4, '=');
        using var claims = JsonDocument.Parse(Convert.FromBase64String(payload));
        return claims.RootElement.GetProperty("email").GetString()!;
    }

    private sealed class Fixture : IDisposable
    {
        public Fixture()
        {
            Root = Path.Combine(Path.GetTempPath(), "codex-switcher-test-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(Root);
            Paths = SwitcherPaths.FromEnvironment(Path.Combine(Root, "codex"), Path.Combine(Root, "data"), environment: new Dictionary<string, string?> { ["USERPROFILE"] = Root, ["LOCALAPPDATA"] = Path.Combine(Root, "local") });
            Files = new PhysicalSwitcherFileSystem();
            var protector = new TestProtector();
            var store = new SwitchTransactionStore(Files, protector, Paths);
            Executor = new AtomicSwitchExecutor(Files, store);
        }
        public string Root { get; }
        public SwitcherPaths Paths { get; }
        public PhysicalSwitcherFileSystem Files { get; }
        public AtomicSwitchExecutor Executor { get; }
        public void Dispose() { try { Directory.Delete(Root, true); } catch { } }
    }

    private sealed class TestProtector : Switcher.Core.Abstractions.ISecretProtector
    {
        public byte[] Protect(ReadOnlySpan<byte> plaintext) => plaintext.ToArray();
        public byte[] Unprotect(ReadOnlySpan<byte> ciphertext) => ciphertext.ToArray();
    }

    private sealed class FailOnceFileSystem(ISwitcherFileSystem inner) : ISwitcherFileSystem
    {
        public string? FailNextWritePath { get; set; }
        public Action? OnFailure { get; set; }
        public bool FileExists(string path) => inner.FileExists(path);
        public bool DirectoryExists(string path) => inner.DirectoryExists(path);
        public byte[] ReadAllBytes(string path) => inner.ReadAllBytes(path);
        public string ReadAllText(string path) => inner.ReadAllText(path);
        public DateTimeOffset GetLastWriteTimeUtc(string path) => inner.GetLastWriteTimeUtc(path);
        public void WriteAtomic(string path, ReadOnlySpan<byte> contents)
        {
            if (FailNextWritePath is not null && string.Equals(Path.GetFullPath(path), Path.GetFullPath(FailNextWritePath), StringComparison.OrdinalIgnoreCase))
            {
                FailNextWritePath = null;
                OnFailure?.Invoke();
                throw new IOException("injected registry write failure");
            }
            inner.WriteAtomic(path, contents);
        }
        public bool TryCreateAtomic(string path, ReadOnlySpan<byte> contents) => inner.TryCreateAtomic(path, contents);
        public void DeleteFile(string path) => inner.DeleteFile(path);
        public void CreateDirectory(string path) => inner.CreateDirectory(path);
        public IEnumerable<string> EnumerateFiles(string path, string pattern, SearchOption option) => inner.EnumerateFiles(path, pattern, option);
    }
}
