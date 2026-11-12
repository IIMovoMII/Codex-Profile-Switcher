using System.Buffers.Binary;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using Switcher.Core.Profiles;
using Switcher.Infrastructure.Profiles;

namespace Switcher.Infrastructure.Models;

public interface IOfficialCacheSourceVerifier
{
    bool IsMatch(string authJson, JsonElement cache, string? organization, string? project);
}

/// <summary>Matches Codex's local-only models-cache-v1 identity envelope. Unknown auth/provider layouts fail closed.</summary>
public sealed class OfficialCacheSourceVerifier : IOfficialCacheSourceVerifier
{
    private const string AuthNamespace = "https://api.openai.com/auth";
    private readonly record struct IdentityClaims(string AccountId, string? UserId, string? Email, string Plan, bool IsFedRamp);

    public bool IsMatch(string authJson, JsonElement cache, string? organization, string? project)
    {
        if (CodexAuthAdapter.Inspect(authJson).Kind != ProfileKind.Official) return false;
        if (!TryString(cache, "identity", out var cachedIdentity) || !TryString(cache, "client_version", out var clientVersion) ||
            !Regex.IsMatch(cachedIdentity, "^[a-f0-9]{64}$") || string.IsNullOrWhiteSpace(clientVersion)) return false;
        if (!TryReadClaims(authJson, out var claims)) return false;
        return ComputeCandidates(claims, clientVersion, organization, project).Contains(cachedIdentity, StringComparer.Ordinal);
    }

    public static IReadOnlySet<string> ComputeCandidatesForTesting(string authJson, string clientVersion, string? organization = null, string? project = null)
    {
        if (!TryReadClaims(authJson, out var claims)) return new HashSet<string>(StringComparer.Ordinal);
        return ComputeCandidates(claims, clientVersion, organization, project);
    }

    private static HashSet<string> ComputeCandidates(IdentityClaims claims, string clientVersion, string? organization, string? project)
    {
        var planRaw = claims.Plan;
        var accountPlanVariant = GetPlanVariant(planRaw);
        string accountPlan = accountPlanVariant is null ? "Some(Unknown)" : $"Some({accountPlanVariant})";
        string rawPlan = planRaw.Length == 0 ? "None" : $"Some({RustDebug(planRaw switch { "hc" => "enterprise", "education" => "edu", _ => planRaw.ToLowerInvariant() })})";
        var output = new HashSet<string>(StringComparer.Ordinal);
        foreach (var residency in new[] { "", "us" })
        {
            var fields = new List<byte[]>
            {
                Utf8("models-cache-v1"), Utf8("OpenAI"), Utf8("https://chatgpt.com/backend-api/codex"), UInt64(0),
                new byte[] { 1 }, new byte[] { 0 }, Utf8("Some(Chatgpt)"), Utf8($"Some({RustDebug(claims.AccountId)})"),
                Utf8(claims.UserId is null ? "None" : $"Some({RustDebug(claims.UserId)})"),
                Utf8(claims.Email is null ? "None" : $"Some({RustDebug(claims.Email)})"),
                Utf8(accountPlan), Utf8(rawPlan), new byte[] { (byte)(claims.IsFedRamp ? 1 : 0) }
            };
            var headers = new SortedDictionary<string, string>(StringComparer.Ordinal)
            {
                ["version"] = clientVersion
            };
            if (!string.IsNullOrEmpty(organization)) headers["openai-organization"] = organization;
            if (!string.IsNullOrEmpty(project)) headers["openai-project"] = project;
            if (residency.Length > 0) headers["x-openai-internal-codex-residency"] = residency;
            var headerFields = new List<byte[]> { UInt64((ulong)headers.Count) };
            foreach (var (name, value) in headers) { headerFields.Add(Utf8(name)); headerFields.Add(Utf8(value)); }
            fields.AddRange(headerFields);

            using var stream = new MemoryStream();
            foreach (var field in fields)
            {
                WriteUInt64(stream, (ulong)field.Length);
                stream.Write(field);
            }
            output.Add(Convert.ToHexString(SHA256.HashData(stream.ToArray())).ToLowerInvariant());
        }
        return output;
    }

    private static bool TryReadClaims(string authJson, out IdentityClaims claims)
    {
        claims = default;
        try
        {
            using var authDoc = JsonDocument.Parse(authJson);
            var root = authDoc.RootElement;
            if (!TryObject(root, "tokens", out var tokens) || !TryString(tokens, "id_token", out var idToken)) return false;
            var parts = idToken.Split('.');
            if (parts.Length != 3) return false;
            var payload = parts[1].Replace('-', '+').Replace('_', '/').PadRight((parts[1].Length + 3) / 4 * 4, '=');
            using var claimsDoc = JsonDocument.Parse(Convert.FromBase64String(payload));
            var tokenClaims = claimsDoc.RootElement;
            if (!TryObject(tokenClaims, AuthNamespace, out var nameSpace)) return false;
            var accountId = ReadString(tokens, "account_id");
            var userId = ReadString(nameSpace, "chatgpt_user_id");
            if (string.IsNullOrEmpty(userId)) userId = ReadString(nameSpace, "user_id");
            var email = ReadString(tokenClaims, "email");
            if (string.IsNullOrEmpty(email) && TryObject(tokenClaims, "https://api.openai.com/profile", out var profile)) email = ReadString(profile, "email");
            if (string.IsNullOrEmpty(accountId) || (string.IsNullOrEmpty(userId) && string.IsNullOrEmpty(email))) return false;
            var plan = ReadString(nameSpace, "chatgpt_plan_type") ?? "";
            var fedRamp = nameSpace.TryGetProperty("chatgpt_account_is_fedramp", out var fedRampNode) && fedRampNode.ValueKind == JsonValueKind.True;
            claims = new IdentityClaims(accountId, EmptyToNull(userId), EmptyToNull(email), plan, fedRamp);
            return true;
        }
        catch (Exception ex) when (ex is JsonException or FormatException or ArgumentException or InvalidOperationException) { return false; }
    }

    private static string? GetPlanVariant(string plan) => plan.ToLowerInvariant() switch
    {
        "free" => "Free", "go" => "Go", "plus" => "Plus", "pro" => "Pro", "prolite" => "ProLite", "promax" => "ProMax", "team" => "Team",
        "self_serve_business_prolite" => "SelfServeBusinessProLite", "self_serve_business_usage_based" => "SelfServeBusinessUsageBased",
        "business" => "Business", "ent26" => "Ent26", "enterprise_cbp_automation" => "EnterpriseCbpAutomation",
        "enterprise_cbp_usage_based" => "EnterpriseCbpUsageBased", "enterprise" or "hc" => "Enterprise",
        "education" or "edu" => "Edu", "edu_plus" => "EduPlus", "edu_pro" => "EduPro", "sci" => "Sci", "sci_plus" => "SciPlus",
        _ => null
    };

    private static string RustDebug(string value)
    {
        var builder = new StringBuilder(value.Length + 2).Append('"');
        foreach (var c in value)
        {
            switch (c)
            {
                case '\0': builder.Append("\\0"); break;
                case '\t': builder.Append("\\t"); break;
                case '\n': builder.Append("\\n"); break;
                case '\r': builder.Append("\\r"); break;
                case '"': builder.Append("\\\""); break;
                case '\\': builder.Append("\\\\"); break;
                default:
                    if (char.IsControl(c)) builder.Append("\\u{").Append(((int)c).ToString("x")).Append('}');
                    else builder.Append(c);
                    break;
            }
        }
        return builder.Append('"').ToString();
    }

    private static void WriteUInt64(Stream stream, ulong value)
    {
        Span<byte> bytes = stackalloc byte[8];
        BinaryPrimitives.WriteUInt64LittleEndian(bytes, value);
        stream.Write(bytes);
    }

    private static byte[] UInt64(ulong value)
    {
        var bytes = new byte[8]; BinaryPrimitives.WriteUInt64LittleEndian(bytes, value); return bytes;
    }

    private static byte[] Utf8(string value) => Encoding.UTF8.GetBytes(value);
    private static bool TryObject(JsonElement element, string name, out JsonElement value)
    {
        value = default;
        return element.ValueKind == JsonValueKind.Object && element.TryGetProperty(name, out value) && value.ValueKind == JsonValueKind.Object;
    }
    private static bool TryString(JsonElement element, string name, out string value)
    {
        value = "";
        if (element.ValueKind != JsonValueKind.Object || !element.TryGetProperty(name, out var node) || node.ValueKind != JsonValueKind.String) return false;
        value = node.GetString() ?? ""; return true;
    }
    private static string? ReadString(JsonElement element, string name) => TryString(element, name, out var value) ? value : null;
    private static string? EmptyToNull(string? value) => string.IsNullOrEmpty(value) ? null : value;
}
