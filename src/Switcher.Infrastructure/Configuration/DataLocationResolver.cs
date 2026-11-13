using System.Text.Json;
using System.Text.RegularExpressions;
using Switcher.Core.Paths;
using Switcher.Infrastructure.Files;

namespace Switcher.Infrastructure.Configuration;

public sealed record LocationResolution(SwitcherPaths Paths, string Message, bool DataUnavailable = false, bool HomeUnavailable = false, bool ExplicitFailure = false)
{
    public bool IsValid => !DataUnavailable && !HomeUnavailable;
}

/// <summary>Locates existing data without moving it or changing the CODEX_HOME DPAPI binding.</summary>
public sealed class DataLocationResolver
{
    private readonly IReadOnlyDictionary<string, string?> _environment;
    private readonly Func<string, bool, string?> _probe;
    private readonly string? _alternateLocal;

    public DataLocationResolver(IReadOnlyDictionary<string, string?>? environment = null, Func<string, bool, string?>? probe = null)
    {
        _environment = environment ?? Environment.GetEnvironmentVariables().Cast<System.Collections.DictionaryEntry>()
            .ToDictionary(item => (string)item.Key, item => item.Value?.ToString(), StringComparer.OrdinalIgnoreCase);
        _probe = probe ?? ProbeDirectory;
        _alternateLocal = environment is null ? Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData) : null;
    }

    private string Get(string name, string fallback = "") => _environment.TryGetValue(name, out var value) && !string.IsNullOrWhiteSpace(value) ? value! : fallback;
    private string UserDirectory => Get("USERPROFILE", Environment.GetFolderPath(Environment.SpecialFolder.UserProfile));
    public string LocatorFile => Path.Combine(Get("APPDATA", Path.Combine(UserDirectory, "AppData", "Roaming")), "CodexProfileSwitcher", "locations.json");

    public LocationResolution Resolve(string? codexHome = null, string? dataDirectory = null, string? codexExecutable = null)
    {
        // Explicit launch arguments are authoritative, including in isolated tests. Never escape them to a real profile.
        var explicitData = dataDirectory is not null; var explicitHome = codexHome is not null;
        var defaultData = Path.Combine(Get("LOCALAPPDATA", Path.Combine(UserDirectory, "AppData", "Local")), "CodexProfileSwitcher");
        var defaultHome = Path.Combine(UserDirectory, ".codex");
        (string Home, string Data) saved;
        try { saved = explicitData || explicitHome ? ("", "") : ReadRemembered(); }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        { return new(new(defaultHome, defaultData, codexExecutable), "已保存的数据位置记录无法读取；请检查文件权限或占用情况。原文件已保留，不会按首次安装创建空目录。", true); }
        var dataCandidates = new List<(string Path, string Origin, bool Create)>();
        if (explicitData) dataCandidates.Add((dataDirectory!, "启动参数 --data-dir", true));
        else
        {
            if (saved.Data.Length > 0) dataCandidates.Add((saved.Data, "自动找到已记住的数据目录", false));
            dataCandidates.Add((defaultData, "默认：%LOCALAPPDATA%\\CodexProfileSwitcher", saved.Data.Length == 0));
            if (!string.IsNullOrWhiteSpace(_alternateLocal) && File.Exists(Path.Combine(_alternateLocal, "CodexProfileSwitcher", "profiles.json")))
                dataCandidates.Add((Path.Combine(_alternateLocal, "CodexProfileSwitcher"), "自动找到 Windows 用户数据目录", false));
        }
        var data = Select(dataCandidates);
        if (data.Error is not null)
            return new(new(defaultHome, data.Path, codexExecutable), "账号数据目录不可用：" + data.Error, true, false, explicitData);
        string? registeredHome;
        try { registeredHome = ReadRegistryHome(data.Path); }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or JsonException or InvalidDataException)
        { return new(new(defaultHome, data.Path, codexExecutable), "账号目录的档案注册表无法读取；已保留原文件，请选择原有的有效目录。", true, false, explicitData); }
        if (!explicitData && saved.Data.Length > 0 && data.Skipped && registeredHome is null)
            return new(new(defaultHome, data.Path, codexExecutable), "已记住的账号目录失效，未找到包含档案的替代位置；请选择原数据文件夹，避免误显示为空账号列表。", true);

        var environmentHome = Get("CODEX_HOME");
        var homeCandidates = new List<(string Path, string Origin, bool Create)>();
        if (explicitHome) homeCandidates.Add((codexHome!, "启动参数 --codex-home", true));
        else
        {
            if (saved.Home.Length > 0) homeCandidates.Add((saved.Home, "自动找到已记住的 Codex 目录", false));
            if (environmentHome.Length > 0) homeCandidates.Add((environmentHome, "环境变量 CODEX_HOME", false));
            if (!string.IsNullOrWhiteSpace(registeredHome)) homeCandidates.Add((registeredHome, "自动找到档案绑定的 CODEX_HOME", false));
            homeCandidates.Add((defaultHome, "默认：%USERPROFILE%\\.codex", registeredHome is null && environmentHome.Length == 0 && saved.Home.Length == 0));
        }
        var home = Select(homeCandidates);
        var paths = new SwitcherPaths(home.Path, data.Path, codexExecutable) { CodexHomeOrigin = home.Origin, DataDirectoryOrigin = data.Origin };
        if (home.Error is not null) return new(paths, "Codex 聊天与项目目录不可用：" + home.Error, false, true, explicitHome);
        if (registeredHome is not null && !PathsEqual(registeredHome, home.Path))
            return new(paths, "当前 CODEX_HOME 与档案绑定的目录不一致。凭据解密依赖原路径；请选择与该目录匹配的账号数据目录，或恢复原 Codex 目录。不会自动移动或重加密数据。", true, true, explicitData || explicitHome);
        return new(paths, "已自动定位数据目录，无需手动配置。" + (home.Skipped || data.Skipped ? " 已跳过失效位置，沿用有效目录。" : ""));
    }

    public LocationResolution Verify(SwitcherPaths paths)
    {
        var dataError = _probe(paths.DataDirectory, false); var homeError = _probe(paths.CodexHome, false);
        if (dataError is not null || homeError is not null) return new(paths,
            string.Join("；", new[] { dataError is null ? null : "账号数据目录不可用：" + dataError, homeError is null ? null : "Codex 目录不可用：" + homeError }.Where(item => item is not null)), dataError is not null, homeError is not null);
        try
        {
            var bound = ReadRegistryHome(paths.DataDirectory);
            if (bound is not null && !PathsEqual(bound, paths.CodexHome)) return new(paths, "档案绑定的 CODEX_HOME 不一致，已停止目录操作。", true, true);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or JsonException or InvalidDataException)
        { return new(paths, "档案注册表无法读取，已保留原文件。", true); }
        return new(paths, "目录检查通过，当前默认或自动找到的位置可用。");
    }

    public void Remember(SwitcherPaths paths)
    {
        var verified = Verify(paths);
        if (!verified.IsValid) throw new IOException(verified.Message);
        new PhysicalSwitcherFileSystem().WriteAtomic(LocatorFile, JsonSerializer.SerializeToUtf8Bytes(new { version = 1, codex_home = paths.CodexHome, data_directory = paths.DataDirectory }));
    }

    private (string Home, string Data) ReadRemembered()
    {
        try
        {
            if (!new PhysicalSwitcherFileSystem().FileExists(LocatorFile) || new FileInfo(LocatorFile).Length > 16384) return ("", "");
            using var document = JsonDocument.Parse(File.ReadAllBytes(LocatorFile)); var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object || !root.TryGetProperty("version", out var version) || version.GetInt32() != 1) return ("", "");
            string Read(string name) => root.TryGetProperty(name, out var node) && node.ValueKind == JsonValueKind.String ? node.GetString() ?? "" : "";
            return (Read("codex_home"), Read("data_directory"));
        }
        catch (Exception ex) when (ex is JsonException or InvalidOperationException or FormatException) { return ("", ""); }
    }

    private (string Path, string Origin, string? Error, bool Skipped) Select(IEnumerable<(string Path, string Origin, bool Create)> candidates)
    {
        var last = (Path: "", Origin: "尚未找到", Error: (string?)"没有有效候选目录", Skipped: false);
        foreach (var candidate in candidates)
        {
            try
            {
                var path = Normalize(candidate.Path);
                var error = _probe(path, candidate.Create);
                if (error is null) return (path, candidate.Origin, null, last.Skipped);
                last = (path, candidate.Origin, error, true);
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException)
            { last = (candidate.Path, candidate.Origin, "路径格式无效或无法访问", true); }
        }
        return last;
    }

    private string Normalize(string path)
    {
        var expanded = Regex.Replace(path.Trim(), "%([^%]+)%", match => Get(match.Groups[1].Value, match.Value));
        if (!Path.IsPathFullyQualified(expanded) || Regex.IsMatch(expanded, "%[^%]+%")) throw new ArgumentException("需要完整且可解析的路径。");
        return Path.TrimEndingDirectorySeparator(Path.GetFullPath(expanded));
    }

    private static string? ReadRegistryHome(string directory)
    {
        var path = Path.Combine(directory, "profiles.json");
        if (!new PhysicalSwitcherFileSystem().FileExists(path)) return null;
        using var document = JsonDocument.Parse(File.ReadAllBytes(path));
        if (document.RootElement.ValueKind != JsonValueKind.Object || !document.RootElement.TryGetProperty("codex_home", out var home) || home.ValueKind != JsonValueKind.String || string.IsNullOrWhiteSpace(home.GetString()) || !Path.IsPathFullyQualified(home.GetString()!))
            throw new InvalidDataException("档案缺少有效的 CODEX_HOME 绑定。");
        return home.GetString();
    }

    private static bool PathsEqual(string first, string second) => string.Equals(Path.TrimEndingDirectorySeparator(Path.GetFullPath(first)), Path.TrimEndingDirectorySeparator(Path.GetFullPath(second)), StringComparison.OrdinalIgnoreCase);

    private static string? ProbeDirectory(string path, bool create)
    {
        try
        {
            if (create) Directory.CreateDirectory(path);
            if ((File.GetAttributes(path) & FileAttributes.Directory) == 0) return "路径存在，但指向文件而不是文件夹";
            using var entries = Directory.EnumerateFileSystemEntries(path).GetEnumerator(); entries.MoveNext();
            using var probe = new FileStream(Path.Combine(path, ".switcher-access-" + Guid.NewGuid().ToString("N") + ".tmp"), FileMode.CreateNew, FileAccess.Write, FileShare.None, 1, FileOptions.DeleteOnClose);
            return null;
        }
        catch (UnauthorizedAccessException) { return "没有读写权限"; }
        catch (Exception ex) when (ex is FileNotFoundException or DirectoryNotFoundException) { return "目录不存在或所在磁盘不可用"; }
        catch (IOException) { return "目录或磁盘不可读写"; }
        catch (ArgumentException) { return "路径格式无效"; }
    }
}
