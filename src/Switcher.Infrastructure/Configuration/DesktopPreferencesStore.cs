using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Nodes;
using Switcher.Core.Configuration;
using Switcher.Core.Paths;
using Switcher.Infrastructure.Files;

namespace Switcher.Infrastructure.Configuration;

public sealed record DesktopPreferences(bool CheckUpdatesOnStartup, ProxyPolicy OfficialProxy, ProxyPolicy ApiProxy, string ContextWindow, string? Revision);

/// <summary>Edits only switcher preferences, preserving older and unknown settings.</summary>
public sealed class DesktopPreferencesStore(SwitcherPaths paths)
{
    public DesktopPreferences Load()
    {
        var bytes = File.Exists(paths.SettingsFile) ? File.ReadAllBytes(paths.SettingsFile) : null;
        var root = bytes is null ? new JsonObject() : JsonNode.Parse(bytes) as JsonObject ?? throw new InvalidDataException("切换器设置必须是 JSON 对象。");
        string Read(string key) => root[key] is JsonValue value && value.TryGetValue<string>(out var text) ? text : "";
        ProxyPolicy Proxy(string key) => Read(key) switch { "system" => ProxyPolicy.System, "direct" => ProxyPolicy.Direct, _ => ProxyPolicy.Preserve };
        var update = !(root["check_updates_on_startup"] is JsonValue setting && setting.TryGetValue<bool>(out var enabled) && !enabled);
        return new DesktopPreferences(update, Proxy("official_proxy"), Proxy("api_proxy"), Read("context_window"), bytes is null ? null : Convert.ToHexString(SHA256.HashData(bytes)));
    }

    public DesktopPreferences Save(DesktopPreferences preferences)
    {
        if (!string.IsNullOrWhiteSpace(preferences.ContextWindow) && (!int.TryParse(preferences.ContextWindow, out var context) || context <= 0))
            throw new InvalidDataException("默认上下文窗口必须留空或填写正整数。");
        // A separate handle coordinates settings editors without blocking the authentication transaction.
        Directory.CreateDirectory(paths.DataDirectory);
        using var lease = new FileStream(paths.SettingsFile + ".lock", FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
        var current = Load();
        if (current.Revision != preferences.Revision) throw new IOException("设置已被其他窗口修改，请重新读取后保存。");
        var root = File.Exists(paths.SettingsFile) ? JsonNode.Parse(File.ReadAllBytes(paths.SettingsFile)) as JsonObject : new JsonObject();
        if (root is null) throw new InvalidDataException("切换器设置格式无效。");
        root["check_updates_on_startup"] = preferences.CheckUpdatesOnStartup;
        root["official_proxy"] = preferences.OfficialProxy.ToString().ToLowerInvariant();
        root["api_proxy"] = preferences.ApiProxy.ToString().ToLowerInvariant();
        root["context_window"] = preferences.ContextWindow.Trim();
        new PhysicalSwitcherFileSystem().WriteAtomic(paths.SettingsFile, JsonSerializer.SerializeToUtf8Bytes(root, new JsonSerializerOptions { WriteIndented = true }));
        return Load();
    }
}
