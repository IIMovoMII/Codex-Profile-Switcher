namespace Switcher.Core.Profiles;

public enum ProfileKind
{
    Api,
    Official
}

public static class ProfileKindExtensions
{
    public static string ToLegacyValue(this ProfileKind kind) => kind switch
    {
        ProfileKind.Api => "api",
        ProfileKind.Official => "official",
        _ => throw new ArgumentOutOfRangeException(nameof(kind))
    };

    public static bool TryParseLegacy(string? value, out ProfileKind kind)
    {
        if (string.Equals(value, "api", StringComparison.Ordinal)) { kind = ProfileKind.Api; return true; }
        if (string.Equals(value, "official", StringComparison.Ordinal)) { kind = ProfileKind.Official; return true; }
        kind = default;
        return false;
    }
}
