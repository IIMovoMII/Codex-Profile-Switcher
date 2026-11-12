using System.Text.Json.Nodes;
using Switcher.Core.Configuration;
using Switcher.Core.Paths;
using Switcher.Infrastructure.Configuration;

namespace Switcher.Infrastructure.Tests;
public sealed class DesktopPreferencesBehaviorTests
{
    [Fact]
    public void Preferences_preserve_unknown_values_and_reject_stale_or_invalid_writes()
    {
        var root = Path.Combine(Path.GetTempPath(), "SwitcherPreferences-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            var paths = new SwitcherPaths(Path.Combine(root, "home"), root);
            File.WriteAllText(paths.SettingsFile, "{\"future\":{\"array\":[null],\"date\":\"2026-11-12\"},\"official_proxy\":\"direct\",\"context_window\":\"100\"}");
            var store = new DesktopPreferencesStore(paths); var initial = store.Load();
            Assert.True(initial.CheckUpdatesOnStartup); Assert.Equal(ProxyPolicy.Direct, initial.OfficialProxy);
            var saved = store.Save(initial with { CheckUpdatesOnStartup = false, ApiProxy = ProxyPolicy.System, ContextWindow = "200" });
            Assert.False(saved.CheckUpdatesOnStartup);
            Assert.Equal("2026-11-12", JsonNode.Parse(File.ReadAllText(paths.SettingsFile))!["future"]!["date"]!.GetValue<string>());
            Assert.Throws<IOException>(() => store.Save(initial));
            Assert.Throws<InvalidDataException>(() => store.Save(saved with { ContextWindow = "-1" }));
            var bytes = File.ReadAllBytes(paths.SettingsFile);
            File.WriteAllText(paths.SettingsFile, "not json");
            Assert.ThrowsAny<System.Text.Json.JsonException>(() => store.Load());
            Assert.Equal("not json", File.ReadAllText(paths.SettingsFile));
            Assert.NotEmpty(bytes);
        }
        finally { Directory.Delete(root, true); }
    }
}
