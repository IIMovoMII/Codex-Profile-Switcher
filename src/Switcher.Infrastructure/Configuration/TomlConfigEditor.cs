using System.Text.Json;
using System.Text.RegularExpressions;
using Switcher.Core.Configuration;
using Switcher.Core.Profiles;
using Switcher.Core.Switching;

namespace Switcher.Infrastructure.Configuration;

public sealed class TomlConfigEditor : IConfigEditor
{
    public string BuildModeConfiguration(string currentText, ProfileKind targetKind, string? baseUrl, string? catalogPath, EffectiveSettings settings)
    {
        ValidateSyntax(currentText);
        if (targetKind == ProfileKind.Api && string.IsNullOrWhiteSpace(baseUrl)) throw new InvalidDataException("API 模式缺少中转地址。");
        var newline = currentText.Contains("\r\n", StringComparison.Ordinal) ? "\r\n" : "\n";
        var lines = currentText.Replace("\r\n", "\n").Split('\n').ToList();
        var managed = new HashSet<string>(StringComparer.Ordinal) { "model_provider", "openai_base_url", "model_catalog_json", "cli_auth_credentials_store" };
        var result = new List<string>();
        var top = true;
        var modelProviderIndex = -1;
        foreach (var line in lines)
        {
            if (top && line.TrimStart().StartsWith('[')) top = false;
            if (top)
            {
                var assignment = Regex.Match(line, "^\\s*([A-Za-z0-9_-]+)\\s*=");
                if (assignment.Success && managed.Contains(assignment.Groups[1].Value))
                {
                    var key = assignment.Groups[1].Value;
                    if (key == "model_provider")
                    {
                        if (modelProviderIndex >= 0) throw new InvalidDataException("config.toml 顶层存在重复的 model_provider。");
                        result.Add("model_provider = \"openai\"" + AssignmentComment(line)); modelProviderIndex = result.Count - 1;
                    }
                    // Keep a user's comment even when the managed assignment
                    // is removed, so editing modes does not erase context.
                    var comment = AssignmentComment(line);
                    if (!string.IsNullOrWhiteSpace(comment)) result.Add(comment.TrimStart());
                    continue;
                }
            }
            result.Add(line);
        }
        if (modelProviderIndex < 0)
        {
            modelProviderIndex = result.FindIndex(line => line.TrimStart().StartsWith('['));
            if (modelProviderIndex < 0) modelProviderIndex = result.Count;
            result.Insert(modelProviderIndex, "model_provider = \"openai\"");
        }
        var insert = modelProviderIndex + 1;
        if (targetKind == ProfileKind.Api)
        {
            result.Insert(insert++, $"openai_base_url = {JsonSerializer.Serialize(baseUrl)}");
            if (!string.IsNullOrWhiteSpace(catalogPath)) result.Insert(insert++, $"model_catalog_json = {JsonSerializer.Serialize(Path.GetFullPath(catalogPath))}");
        }
        result.Insert(insert, "cli_auth_credentials_store = \"file\"");

        var text = string.Join(newline, result);
        if (settings.Model is not null) text = SetTopLevel(text, "model", JsonSerializer.Serialize(settings.Model));
        if (settings.ContextWindow is not null) text = SetTopLevel(text, "model_context_window", settings.ContextWindow.Value.ToString(System.Globalization.CultureInfo.InvariantCulture));
        if (settings.Proxy != ProxyPolicy.Preserve) text = SetTableBoolean(text, "features", "respect_system_proxy", settings.Proxy == ProxyPolicy.System);
        ValidateSyntax(text);
        if (targetKind == ProfileKind.Official && (GetTopLevel(text, "openai_base_url") is not null || GetTopLevel(text, "model_catalog_json") is not null)) throw new InvalidDataException("官方配置仍包含 API 覆盖。");
        return text;
    }

    public void ValidateSyntax(string text)
    {
        try
        {
            var document = Tomlyn.Toml.Parse(text, "config.toml");
            if (document.HasErrors) throw new InvalidDataException(document.Diagnostics.ToString());
        }
        catch (Tomlyn.TomlException ex) { throw new InvalidDataException($"config.toml 语法无效：{ex.Message}", ex); }
    }

    public string? GetTopLevel(string text, string key) => GetTopLevel(text, key, out _);

    private static string? GetTopLevel(string text, string key, out string? raw)
    {
        ValidateText(text);
        var model = Tomlyn.Toml.ToModel(text);
        if (!model.TryGetValue(key, out var value)) { raw = null; return null; }
        raw = value is string str ? JsonSerializer.Serialize(str) : Convert.ToString(value, System.Globalization.CultureInfo.InvariantCulture);
        return value is string stringValue ? stringValue : raw;
    }

    private static string SetTopLevel(string text, string key, string literal)
    {
        var lines = text.Replace("\r\n", "\n").Split('\n').ToList();
        var top = true; var index = -1;
        for (var i = 0; i < lines.Count; i++)
        {
            if (top && lines[i].TrimStart().StartsWith('[')) top = false;
            if (!top) continue;
            var match = Regex.Match(lines[i], $"^\\s*{Regex.Escape(key)}\\s*=");
            if (!match.Success) continue;
            if (index >= 0) throw new InvalidDataException($"配置中存在重复字段：{key}");
            index = i; lines[i] = $"{key} = {literal}" + AssignmentComment(lines[i]);
        }
        if (index < 0)
        {
            index = lines.FindIndex(line => line.TrimStart().StartsWith('['));
            if (index < 0) index = lines.Count;
            lines.Insert(index, $"{key} = {literal}");
        }
        return string.Join(text.Contains("\r\n", StringComparison.Ordinal) ? "\r\n" : "\n", lines);
    }

    private static string SetTableBoolean(string text, string table, string key, bool value)
    {
        var lines = text.Replace("\r\n", "\n").Split('\n').ToList();
        var inTable = false; var found = false;
        for (var i = 0; i < lines.Count; i++)
        {
            var trimmed = lines[i].Trim();
            if (trimmed.StartsWith('[')) inTable = string.Equals(trimmed.Trim('[', ']').Trim(), table, StringComparison.Ordinal);
            if (!inTable) continue;
            if (Regex.IsMatch(lines[i], $"^\\s*{Regex.Escape(key)}\\s*="))
            {
                if (found) throw new InvalidDataException($"配置中存在重复字段：{table}.{key}");
                lines[i] = $"{key} = {(value ? "true" : "false")}" + AssignmentComment(lines[i]); found = true;
            }
        }
        if (!found)
        {
            if (lines.Count > 0 && lines[^1].Length > 0) lines.Add("");
            lines.Add($"[{table}]");
            lines.Add($"{key} = {(value ? "true" : "false")}");
        }
        return string.Join(text.Contains("\r\n", StringComparison.Ordinal) ? "\r\n" : "\n", lines);
    }

    private static string AssignmentComment(string line)
    {
        var quote = '\0'; var escaped = false;
        for (var i = 0; i < line.Length; i++)
        {
            var c = line[i];
            if (escaped) { escaped = false; continue; }
            if (quote == '"' && c == '\\') { escaped = true; continue; }
            if (quote != '\0') { if (c == quote) quote = '\0'; continue; }
            if (c is '"' or '\'') { quote = c; continue; }
            if (c == '#') return line[i..];
        }
        return "";
    }

    private static void ValidateText(string text)
    {
        var document = Tomlyn.Toml.Parse(text, "config.toml");
        if (document.HasErrors) throw new InvalidDataException(document.Diagnostics.ToString());
    }
}
