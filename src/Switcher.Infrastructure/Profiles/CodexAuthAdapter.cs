using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Switcher.Core.Profiles;

namespace Switcher.Infrastructure.Profiles;

public sealed record AuthIdentity(ProfileKind? Kind, string AuthMode, string? OfficialOwner, string? AccountId, string? Email);

public sealed class CodexAuthClassifier : IAuthClassifier
{
    public ProfileKind? Classify(string authenticationJson) => CodexAuthAdapter.Inspect(authenticationJson).Kind;
    public string GetApiKey(string authenticationJson) => CodexAuthAdapter.GetApiKey(authenticationJson);
    public string GetOfficialOwner(string authenticationJson) => CodexAuthAdapter.Inspect(authenticationJson).OfficialOwner ?? throw new InvalidDataException("官方账号身份无法确认。");
}

public static class CodexAuthAdapter
{
    public static AuthIdentity Inspect(string authJson)
    {
        using var document = JsonDocument.Parse(authJson);
        var root = document.RootElement;
        if (root.ValueKind != JsonValueKind.Object) throw new InvalidDataException("auth.json 顶层必须是 JSON 对象。");
        var apiKey = ReadString(root, "OPENAI_API_KEY");
        var authMode = ReadString(root, "auth_mode") ?? "";
        var hasTokens = root.TryGetProperty("tokens", out var tokens) && tokens.ValueKind is not JsonValueKind.Null and not JsonValueKind.Undefined;
        var hasCompleteTokens = hasTokens && !string.IsNullOrWhiteSpace(ReadString(tokens, "id_token")) &&
            !string.IsNullOrWhiteSpace(ReadString(tokens, "access_token")) && !string.IsNullOrWhiteSpace(ReadString(tokens, "refresh_token"));
        var hasKey = !string.IsNullOrWhiteSpace(apiKey);
        if (hasKey && (hasTokens || authMode == "chatgpt")) return new AuthIdentity(null, authMode, null, null, null);
        if (!hasKey && authMode == "chatgpt" && hasCompleteTokens)
        {
            var account = ReadString(tokens, "account_id");
            var owner = GetDesktopOwner(root, tokens, out var email);
            if (string.IsNullOrEmpty(owner))
            {
                var identity = !string.IsNullOrEmpty(account) ? "opaque-account:" + account : authJson;
                owner = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(identity))).ToLowerInvariant();
            }
            return new AuthIdentity(ProfileKind.Official, authMode, owner, account, email);
        }
        if (hasKey && !hasTokens && authMode != "chatgpt") return new AuthIdentity(ProfileKind.Api, authMode, null, null, null);
        return new AuthIdentity(null, authMode, null, null, null);
    }

    public static string GetApiKey(string authJson)
    {
        using var document = JsonDocument.Parse(authJson);
        return ReadString(document.RootElement, "OPENAI_API_KEY") ?? throw new InvalidDataException("auth.json 中缺少 API Key。");
    }

    public static string BuildApiAuth(string apiKey) => JsonSerializer.Serialize(new Dictionary<string, string> { ["OPENAI_API_KEY"] = apiKey });

    private static string? GetDesktopOwner(JsonElement root, JsonElement tokens, out string? email)
    {
        email = null;
        foreach (var tokenName in new[] { "id_token", "access_token" })
        {
            try
            {
                var token = ReadString(tokens, tokenName);
                var parts = token?.Split('.');
                if (parts is not { Length: 3 }) continue;
                var payload = parts[1].Replace('-', '+').Replace('_', '/');
                payload = payload.PadRight((payload.Length + 3) / 4 * 4, '=');
                using var claimsDoc = JsonDocument.Parse(Convert.FromBase64String(payload));
                var claims = claimsDoc.RootElement;
                email = ReadString(claims, "email");
                if (email is null && claims.TryGetProperty("https://api.openai.com/profile", out var profile)) email = ReadString(profile, "email");
                if (!claims.TryGetProperty("https://api.openai.com/auth", out var ns)) continue;
                var userId = ReadString(ns, "chatgpt_user_id");
                var accountId = ReadString(tokens, "account_id") ?? ReadString(ns, "chatgpt_account_id");
                if (string.IsNullOrWhiteSpace(userId) || string.IsNullOrWhiteSpace(accountId)) continue;
                var json = JsonSerializer.Serialize(new[] { userId, accountId });
                return Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(json))).ToLowerInvariant();
            }
            catch (Exception ex) when (ex is JsonException or FormatException or ArgumentException) { }
        }
        _ = root;
        return null;
    }

    private static string? ReadString(JsonElement element, string propertyName)
    {
        return element.ValueKind == JsonValueKind.Object && element.TryGetProperty(propertyName, out var value) &&
               value.ValueKind == JsonValueKind.String ? value.GetString() : null;
    }
}
