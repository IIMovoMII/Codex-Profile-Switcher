namespace Switcher.Core.Paths;

public sealed record SwitcherPaths(string CodexHome, string DataDirectory, string? CodexExecutable = null)
{
    public string? ManualModelCatalogOverride { get; init; }
    public string? MonitorDataDirectory { get; init; }
    public string CodexHomeOrigin { get; init; } = "显式指定";
    public string DataDirectoryOrigin { get; init; } = "显式指定";
    public string ConfigFile => Path.Combine(CodexHome, "config.toml");
    public string AuthFile => Path.Combine(CodexHome, "auth.json");
    public string ModelCacheFile => Path.Combine(CodexHome, "models_cache.json");
    public string RegistryFile => Path.Combine(DataDirectory, "profiles.json");
    public string ProfileCredentialDirectory => Path.Combine(DataDirectory, "profiles");
    public string TransactionFile => Path.Combine(DataDirectory, "transaction.dpapi");
    public string ModelCatalogDirectory => Path.Combine(DataDirectory, "model-catalogs");
    public string DefaultManualModelCatalogFile => string.IsNullOrWhiteSpace(ManualModelCatalogOverride)
        ? Path.Combine(DataDirectory, "relay-models.json") : Path.GetFullPath(Environment.ExpandEnvironmentVariables(ManualModelCatalogOverride));
    public string SettingsFile => Path.Combine(DataDirectory, "settings.json");
    public string OperationLogFile => Path.Combine(DataDirectory, "operations.jsonl");
    public string HistoryReadyFile => Path.Combine(DataDirectory, "history-compat-ready.json");
    public string HistoryBackupsDirectory => Path.Combine(DataDirectory, "history-repair-backups");
    public string ProjectBackupsDirectory => Path.Combine(DataDirectory, "project-projection-repair");
    public string ProjectStateDatabase => Path.Combine(CodexHome, "state_5.sqlite");
    public string DesktopGlobalStateFile => Path.Combine(CodexHome, ".codex-global-state.json");
    public string DesktopRendererArchiveFile => Path.Combine(DataDirectory, "desktop-renderer-state.dpapi");
    public string StateFile => Path.Combine(DataDirectory, "state.dpapi");

    public static SwitcherPaths FromEnvironment(
        string? codexHome = null,
        string? dataDirectory = null,
        string? codexExecutable = null,
        IReadOnlyDictionary<string, string?>? environment = null)
    {
        environment ??= Environment.GetEnvironmentVariables()
            .Cast<System.Collections.DictionaryEntry>()
            .ToDictionary(e => (string)e.Key, e => e.Value?.ToString(), StringComparer.OrdinalIgnoreCase);
        string Get(string key, string fallback = "") => environment.TryGetValue(key, out var value) && !string.IsNullOrWhiteSpace(value) ? value! : fallback;
        var userProfile = Get("USERPROFILE", Environment.GetFolderPath(Environment.SpecialFolder.UserProfile));
        var localAppData = Get("LOCALAPPDATA", Path.Combine(userProfile, "AppData", "Local"));
        var home = Path.GetFullPath(Environment.ExpandEnvironmentVariables(
            codexHome ?? Get("CODEX_HOME", Path.Combine(userProfile, ".codex"))));
        var data = Path.GetFullPath(Environment.ExpandEnvironmentVariables(
            dataDirectory ?? Path.Combine(localAppData, "CodexProfileSwitcher")));
        return new SwitcherPaths(home, data, codexExecutable);
    }
}
