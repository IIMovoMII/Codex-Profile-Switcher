using Switcher.Core.Configuration;
using Switcher.Core.Paths;
using Switcher.Core.Profiles;
using Switcher.Core.Switching;

namespace Switcher.Core.Tests;

public sealed class CoreBehaviorTests
{
    [Fact]
    public void SettingsPolicy_keeps_current_values_when_profile_requests_preserve()
    {
        var result = SettingsPolicy.Resolve(ProfileKind.Api,
            new ProfileSettings(SettingChoice<string>.Preserve(), SettingChoice<int>.Preserve(), SettingChoice<ProxyPolicy>.Preserve()),
            new GlobalSettings(ProxyPolicy.Direct, ProxyPolicy.System, 131072));

        Assert.Null(result.Model);
        Assert.Null(result.ContextWindow);
        Assert.Equal(ProxyPolicy.Preserve, result.Proxy);
    }

    [Fact]
    public void SettingsPolicy_applies_explicit_and_inherited_values()
    {
        var result = SettingsPolicy.Resolve(ProfileKind.Api,
            new ProfileSettings(SettingChoice<string>.Set("future-model"), SettingChoice<int>.Inherit(), SettingChoice<ProxyPolicy>.Inherit()),
            new GlobalSettings(ProxyPolicy.Direct, ProxyPolicy.System, 262144));

        Assert.Equal("future-model", result.Model);
        Assert.Equal(262144, result.ContextWindow);
        Assert.Equal(ProxyPolicy.System, result.Proxy);
    }

    [Fact]
    public void Registry_selects_by_id_and_rejects_ambiguous_name()
    {
        var registry = ProfileRegistry.Create(@"C:\fixture\.codex", DateTimeOffset.UtcNow);
        registry.ApiProfiles.Add(new ApiProfile { Id = "api-one", Name = "same", BaseUrl = "https://relay.example", AuthFile = "api-one.auth.dpapi" });
        registry.ApiProfiles.Add(new ApiProfile { Id = "api-two", Name = "same", BaseUrl = "https://relay.example", AuthFile = "api-two.auth.dpapi" });

        Assert.Equal("api-one", registry.Find(ProfileKind.Api, "api-one").Id);
        Assert.Throws<InvalidOperationException>(() => registry.Find(ProfileKind.Api, "same"));
        Assert.Throws<InvalidOperationException>(() => registry.GetSelected(ProfileKind.Api));
    }

    [Fact]
    public void OperationPlan_rejects_duplicate_targets_and_invalid_hashes()
    {
        var duplicate = new OperationPlan(Guid.NewGuid().ToString("N"), "test", [
            new FileMutation(@"C:\fixture\a", null, [], "a"),
            new FileMutation(@"C:\fixture\A", null, [], "b")], DateTimeOffset.UtcNow);
        Assert.Throws<InvalidDataException>(() => duplicate.Validate());

        var badHash = new OperationPlan(Guid.NewGuid().ToString("N"), "test", [
            new FileMutation(@"C:\fixture\a", "not-a-hash", [], "a")], DateTimeOffset.UtcNow);
        Assert.Throws<InvalidDataException>(() => badHash.Validate());
    }
}
