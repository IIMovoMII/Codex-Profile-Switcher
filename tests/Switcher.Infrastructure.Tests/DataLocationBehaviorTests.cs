using System.Text.Json;
using Switcher.Core.Paths;
using Switcher.Infrastructure.Configuration;

namespace Switcher.Infrastructure.Tests;

public sealed class DataLocationBehaviorTests
{
    [Fact]
    public void Fresh_install_creates_default_locations_and_no_manual_selection_is_needed()
    {
        using var fixture = new Fixture();
        var result = fixture.Resolver.Resolve();
        Assert.True(result.IsValid); Assert.Equal(fixture.DefaultData, result.Paths.DataDirectory); Assert.Equal(fixture.DefaultHome, result.Paths.CodexHome);
        Assert.Contains("默认", result.Paths.DataDirectoryOrigin); Assert.Empty(Directory.GetFiles(fixture.DefaultHome));
        Assert.Empty(Directory.GetFiles(fixture.DefaultData)); Assert.False(File.Exists(fixture.Resolver.LocatorFile));
    }

    [Fact]
    public void Existing_codex_home_and_registry_path_are_found_before_manual_fallback()
    {
        using var fixture = new Fixture(); var home = Path.Combine(fixture.Root, "custom 中文 & home"); Directory.CreateDirectory(home);
        fixture.Registry(home); fixture.Environment["CODEX_HOME"] = Path.Combine(fixture.Root, "missing home");
        var result = fixture.Resolver.Resolve();
        Assert.True(result.IsValid); Assert.Equal(home, result.Paths.CodexHome); Assert.Contains("档案绑定", result.Paths.CodexHomeOrigin); Assert.Contains("跳过", result.Message);
        Assert.False(Directory.Exists(fixture.Environment["CODEX_HOME"]));
    }

    [Fact]
    public void Valid_environment_home_is_respected_but_a_different_registry_binding_is_rejected()
    {
        using var fixture = new Fixture(); var home = Path.Combine(fixture.Root, "environment home"); Directory.CreateDirectory(home); fixture.Environment["CODEX_HOME"] = home;
        var result = fixture.Resolver.Resolve(); Assert.True(result.IsValid); Assert.Equal(home, result.Paths.CodexHome); Assert.Contains("环境变量", result.Paths.CodexHomeOrigin);
        fixture.Registry(fixture.DefaultHome); var registry = File.ReadAllBytes(Path.Combine(fixture.DefaultData, "profiles.json"));
        result = fixture.Resolver.Resolve(); Assert.False(result.IsValid); Assert.Contains("解密依赖原路径", result.Message);
        Assert.Equal(registry, File.ReadAllBytes(Path.Combine(fixture.DefaultData, "profiles.json")));
    }

    [Fact]
    public void Explicit_isolation_paths_never_fall_back_to_remembered_or_real_locations()
    {
        using var fixture = new Fixture();
        var calls = new List<string>();
        var resolver = new DataLocationResolver(fixture.Environment, (path, _) => { calls.Add(path); return "synthetic inaccessible"; });
        var directory = Path.Combine(fixture.Root, "isolated unavailable");
        var result = resolver.Resolve(fixture.DefaultHome, directory);
        Assert.False(result.IsValid); Assert.True(result.ExplicitFailure); Assert.Equal(new[] { directory }, calls); Assert.False(Directory.Exists(directory));
    }

    [Fact]
    public void Unavailable_automatic_locations_require_manual_recovery_and_remember_only_verified_paths()
    {
        using var fixture = new Fixture();
        var file = Path.Combine(fixture.Root, "not a folder"); File.WriteAllText(file, "sentinel"); fixture.Environment["LOCALAPPDATA"] = file;
        var failed = fixture.Resolver.Resolve(); Assert.False(failed.IsValid); Assert.True(failed.DataUnavailable); Assert.False(failed.ExplicitFailure);
        Assert.Throws<IOException>(() => fixture.Resolver.Remember(new(fixture.DefaultHome, file)));
        var manualData = Path.Combine(fixture.Root, "manual account data"); var manualHome = Path.Combine(fixture.Root, "manual codex data");
        var selected = fixture.Resolver.Resolve(manualHome, manualData); Assert.True(selected.IsValid); fixture.Resolver.Remember(selected.Paths);
        var reloaded = fixture.Resolver.Resolve(); Assert.True(reloaded.IsValid); Assert.Equal(manualData, reloaded.Paths.DataDirectory); Assert.Equal(manualHome, reloaded.Paths.CodexHome);
        Assert.Contains("已记住", reloaded.Paths.DataDirectoryOrigin); Assert.Equal("sentinel", File.ReadAllText(file));
        using var locator = JsonDocument.Parse(File.ReadAllBytes(fixture.Resolver.LocatorFile)); Assert.Equal(3, locator.RootElement.EnumerateObject().Count());
    }

    [Fact]
    public void Existing_but_locked_location_record_is_not_ignored_as_a_fresh_install()
    {
        using var fixture = new Fixture();
        var home = Path.Combine(fixture.Root, "remembered home"); var data = Path.Combine(fixture.Root, "remembered data");
        var selected = fixture.Resolver.Resolve(home, data); fixture.Resolver.Remember(selected.Paths);
        var original = File.ReadAllBytes(fixture.Resolver.LocatorFile);
        using (var held = new FileStream(fixture.Resolver.LocatorFile, FileMode.Open, FileAccess.Read, FileShare.None))
        {
            var result = fixture.Resolver.Resolve();
            Assert.False(result.IsValid); Assert.Contains("无法读取", result.Message);
            Assert.False(Directory.Exists(fixture.DefaultData)); Assert.False(Directory.Exists(fixture.DefaultHome));
        }
        Assert.Equal(original, File.ReadAllBytes(fixture.Resolver.LocatorFile));
        Assert.True(fixture.Resolver.Resolve().IsValid);
    }

    [Fact]
    public void Damaged_registry_is_not_treated_as_a_new_empty_collection()
    {
        using var fixture = new Fixture(); Directory.CreateDirectory(fixture.DefaultData);
        var registry = Path.Combine(fixture.DefaultData, "profiles.json"); File.WriteAllText(registry, "{broken");
        var result = fixture.Resolver.Resolve(); Assert.False(result.IsValid); Assert.True(result.DataUnavailable); Assert.Equal("{broken", File.ReadAllText(registry));
    }

    [Fact]
    public void Lost_remembered_data_does_not_create_a_new_empty_collection_and_existing_default_profiles_can_be_found()
    {
        using var fixture = new Fixture(); var manualHome = Path.Combine(fixture.Root, "remembered home"); var manualData = Path.Combine(fixture.Root, "remembered data");
        var selected = fixture.Resolver.Resolve(manualHome, manualData); fixture.Resolver.Remember(selected.Paths);
        Directory.Delete(manualData);
        var lost = fixture.Resolver.Resolve(); Assert.False(lost.IsValid); Assert.True(lost.DataUnavailable); Assert.False(Directory.Exists(fixture.DefaultData));
        fixture.Registry(manualHome);
        var found = fixture.Resolver.Resolve(); Assert.True(found.IsValid); Assert.Equal(fixture.DefaultData, found.Paths.DataDirectory); Assert.Equal(manualHome, found.Paths.CodexHome);
    }

    [Fact]
    public void Missing_bound_codex_directory_cannot_silently_create_a_new_home()
    {
        using var fixture = new Fixture(); var missing = Path.Combine(fixture.Root, "offline disk", "codex"); fixture.Registry(missing);
        var result = fixture.Resolver.Resolve(); Assert.False(result.IsValid); Assert.True(result.HomeUnavailable); Assert.False(Directory.Exists(missing)); Assert.False(Directory.Exists(fixture.DefaultHome));
    }

    private sealed class Fixture : IDisposable
    {
        public string Root { get; } = Path.Combine(Path.GetTempPath(), "SwitcherLocations-" + Guid.NewGuid().ToString("N"));
        public Dictionary<string, string?> Environment { get; }
        public string DefaultHome => Path.Combine(Root, "user 中文", ".codex");
        public string DefaultData => Path.Combine(Root, "local", "CodexProfileSwitcher");
        public DataLocationResolver Resolver => new(Environment);
        public Fixture() { Directory.CreateDirectory(Root); Environment = new(StringComparer.OrdinalIgnoreCase) { ["USERPROFILE"] = Path.Combine(Root, "user 中文"), ["LOCALAPPDATA"] = Path.Combine(Root, "local"), ["APPDATA"] = Path.Combine(Root, "roaming") }; }
        public void Registry(string home) { Directory.CreateDirectory(DefaultData); File.WriteAllText(Path.Combine(DefaultData, "profiles.json"), JsonSerializer.Serialize(new { version = 1, codex_home = home })); }
        public void Dispose() { if (Directory.Exists(Root)) Directory.Delete(Root, true); }
    }
}
