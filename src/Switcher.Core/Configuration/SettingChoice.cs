namespace Switcher.Core.Configuration;

using Switcher.Core.Profiles;

public enum SettingChoiceKind
{
    Inherit,
    PreserveCurrent,
    Explicit
}

public sealed record SettingChoice<T>(SettingChoiceKind Kind, T? Value = default)
{
    public static SettingChoice<T> Inherit() => new(SettingChoiceKind.Inherit);
    public static SettingChoice<T> Preserve() => new(SettingChoiceKind.PreserveCurrent);
    public static SettingChoice<T> Set(T value) => new(SettingChoiceKind.Explicit, value);
}

public enum ProxyPolicy
{
    Preserve,
    System,
    Direct
}

public sealed record ProfileSettings(
    SettingChoice<string> Model,
    SettingChoice<int> ContextWindow,
    SettingChoice<ProxyPolicy> Proxy)
{
    public static ProfileSettings Unspecified { get; } = new(
        SettingChoice<string>.Inherit(), SettingChoice<int>.Preserve(), SettingChoice<ProxyPolicy>.Preserve());
}

public sealed record GlobalSettings(
    ProxyPolicy OfficialProxy = ProxyPolicy.Preserve,
    ProxyPolicy ApiProxy = ProxyPolicy.Preserve,
    int? ContextWindow = null);

public sealed record EffectiveSettings(string? Model, int? ContextWindow, ProxyPolicy Proxy);

public static class SettingsPolicy
{
    public static EffectiveSettings Resolve(ProfileKind kind, ProfileSettings profile, GlobalSettings global)
    {
        ArgumentNullException.ThrowIfNull(profile);
        ArgumentNullException.ThrowIfNull(global);
        var inheritedProxy = kind == ProfileKind.Api ? global.ApiProxy : global.OfficialProxy;
        var proxy = profile.Proxy.Kind switch
        {
            SettingChoiceKind.Inherit => inheritedProxy,
            SettingChoiceKind.PreserveCurrent => ProxyPolicy.Preserve,
            SettingChoiceKind.Explicit => profile.Proxy.Value,
            _ => throw new InvalidOperationException("代理策略类型无效。")
        };
        var context = profile.ContextWindow.Kind switch
        {
            SettingChoiceKind.Inherit => global.ContextWindow,
            SettingChoiceKind.PreserveCurrent => null,
            SettingChoiceKind.Explicit => profile.ContextWindow.Value,
            _ => throw new InvalidOperationException("上下文策略类型无效。")
        };
        if (context is <= 0) throw new ArgumentOutOfRangeException(nameof(profile), "上下文窗口必须是正整数。 ");
        var model = profile.Model.Kind switch
        {
            SettingChoiceKind.Inherit => null,
            SettingChoiceKind.PreserveCurrent => null,
            SettingChoiceKind.Explicit => profile.Model.Value,
            _ => throw new InvalidOperationException("模型策略类型无效。")
        };
        return new EffectiveSettings(model, context, proxy);
    }
}
