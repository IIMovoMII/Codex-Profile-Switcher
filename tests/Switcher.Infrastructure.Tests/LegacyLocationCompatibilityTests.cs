using System.Text.Json;
using Switcher.Core.Abstractions;
using Switcher.Core.Paths;
using Switcher.Core.Profiles;
using Switcher.Infrastructure.Files;
using Switcher.Infrastructure.Profiles;
using Switcher.Infrastructure.Processes;
using Switcher.Infrastructure.Models;

namespace Switcher.Infrastructure.Tests;

public sealed class LegacyLocationCompatibilityTests
{
    [Fact]
    public void Legacy_catalog_override_is_used_only_for_profiles_without_their_own_manual_path()
    {
        using var fixture = new Fixture();
        var custom = Path.Combine(fixture.Root, "custom model catalog.json");
        var actual = "{\"models\":[{\"slug\":\"synthetic\",\"unknown\":[null]}]}";
        File.WriteAllText(custom, actual);
        var paths = fixture.Paths with { ManualModelCatalogOverride = custom };
        var store = new ProfileRegistryStore(new PhysicalSwitcherFileSystem(), paths);
        var profile = new ApiProfile { Id = "api-synthetic", Name = "synthetic", AuthFile = "synthetic.auth.dpapi" };
        Assert.Equal(custom, store.CatalogPath(profile));
        Assert.Equal(actual, File.ReadAllText(custom));
        profile.ModelCatalogJson = Path.Combine(fixture.Root, "account-specific.json");
        Assert.Equal(profile.ModelCatalogJson, store.CatalogPath(profile));
        Assert.False(File.Exists(paths.DefaultManualModelCatalogFile + ".tmp"));
    }

    [Fact]
    public void Existing_but_locked_manual_catalog_reports_read_failure_instead_of_an_empty_or_missing_catalog()
    {
        using var fixture = new Fixture();
        var path = Path.Combine(fixture.Root, "manual catalog.json");
        const string original = "{\"models\":[{\"slug\":\"synthetic\"}]}"; File.WriteAllText(path, original);
        using (var held = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.None))
            Assert.Throws<IOException>(() => CatalogChoiceReader.Inspect(path));
        var read = CatalogChoiceReader.Inspect(path);
        Assert.True(read.Exists); Assert.NotNull(read.Updated); Assert.Single(read.Models);
        Assert.Equal(original, File.ReadAllText(path));
    }

    [Fact]
    public async Task Default_marker_directory_is_opt_in_by_existing_settings_and_uses_the_legacy_format()
    {
        using var fixture = new Fixture();
        var monitor = Path.Combine(fixture.Root, "CodexDesktopWeixin");
        var file = Path.Combine(monitor, "maintenance.json");
        var inner = new TestLock(); var coordinated = new MaintenanceCoordinatedLock(inner, new PhysicalSwitcherFileSystem(), fixture.Paths);
        await using (await coordinated.AcquireAsync("synthetic", CancellationToken.None)) { Assert.False(Directory.Exists(monitor)); }
        Directory.CreateDirectory(monitor); File.WriteAllText(Path.Combine(monitor, "settings.json"), "{}");
        await using (await coordinated.AcquireAsync("synthetic", CancellationToken.None)) { AssertMarker(file, 180); }
        AssertMarker(file, 90); Assert.Equal(2, inner.Released);
    }

    [Fact]
    public async Task Explicit_marker_directory_is_honored_and_failure_releases_the_operation_lock()
    {
        using var fixture = new Fixture();
        var monitor = Path.Combine(fixture.Root, "explicit monitor");
        var inner = new TestLock();
        var coordinated = new MaintenanceCoordinatedLock(inner, new PhysicalSwitcherFileSystem(), fixture.Paths with { MonitorDataDirectory = monitor });
        await using (await coordinated.AcquireAsync("synthetic", CancellationToken.None)) { AssertMarker(Path.Combine(monitor, "maintenance.json"), 180); }
        AssertMarker(Path.Combine(monitor, "maintenance.json"), 90);
        var invalid = Path.Combine(fixture.Root, "file-not-directory"); File.WriteAllText(invalid, "sentinel");
        var failing = new MaintenanceCoordinatedLock(inner, new PhysicalSwitcherFileSystem(), fixture.Paths with { MonitorDataDirectory = invalid });
        await Assert.ThrowsAnyAsync<IOException>(async () => await failing.AcquireAsync("synthetic", CancellationToken.None));
        Assert.Equal(2, inner.Released); Assert.Equal("sentinel", File.ReadAllText(invalid));
    }

    private static void AssertMarker(string path, int lifetime)
    {
        using var document = JsonDocument.Parse(File.ReadAllBytes(path)); var root = document.RootElement;
        Assert.Equal(1, root.GetProperty("version").GetInt32()); Assert.Equal("codex_profile_switch", root.GetProperty("reason").GetString());
        Assert.Equal(TimeSpan.FromSeconds(lifetime), root.GetProperty("expires_at").GetDateTimeOffset() - root.GetProperty("created_at").GetDateTimeOffset());
    }
    private sealed class TestLock : IOperationLock
    {
        public int Released { get; private set; }
        public ValueTask<IAsyncDisposable> AcquireAsync(string name, CancellationToken token) => ValueTask.FromResult<IAsyncDisposable>(new Lease(this));
        public ValueTask DisposeAsync() => ValueTask.CompletedTask;
        private sealed class Lease(TestLock owner) : IAsyncDisposable { public ValueTask DisposeAsync() { owner.Released++; return ValueTask.CompletedTask; } }
    }
    private sealed class Fixture : IDisposable
    {
        public string Root { get; } = Path.Combine(Path.GetTempPath(), "location-compat-" + Guid.NewGuid().ToString("N"));
        public SwitcherPaths Paths => new(Path.Combine(Root, "home"), Path.Combine(Root, "data"));
        public Fixture() => Directory.CreateDirectory(Root);
        public void Dispose() => Directory.Delete(Root, true);
    }
}
