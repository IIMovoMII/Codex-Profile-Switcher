namespace Switcher.Infrastructure.Processes;

/// <summary>Only installation locations are inspected; discovery never starts Codex.</summary>
public sealed class CodexExecutableResolver(CodexExecutableLocations? locations = null)
{
    private readonly CodexExecutableLocations _locations = locations ?? CodexExecutableLocations.FromEnvironment();

    public string Resolve(string? configuredExecutable = null, CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var probe = new Probe();
        if (!string.IsNullOrWhiteSpace(configuredExecutable))
            return RequireExplicit(configuredExecutable, "--codex-exe");
        if (!string.IsNullOrWhiteSpace(_locations.CliPath))
            return RequireExplicit(_locations.CliPath, "CODEX_CLI_PATH");

        var desktopBin = Combine(_locations.LocalApplicationData, "OpenAI", "Codex", "bin");
        // Desktop extracts each CLI build into its own directory. Prefer those over the old root copy.
        var versioned = probe.Newest(probe.Directories(desktopBin).Select(directory => Path.Combine(directory, "codex.exe")));
        if (versioned is not null) return versioned;
        var rootCopy = probe.Existing(Combine(desktopBin, "codex.exe"));
        if (rootCopy is not null) return rootCopy;

        var pathFolders = (_locations.SearchPath ?? "").Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries);
        foreach (var folder in pathFolders)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var native = probe.Existing(Combine(folder.Trim().Trim('"'), "codex.exe"));
            if (native is not null) return native;
        }

        // npm exposes a .cmd wrapper; run its native x64 CLI directly, without a shell.
        foreach (var folder in pathFolders.Concat(new[] { Combine(_locations.RoamingApplicationData, "npm") }))
        {
            cancellationToken.ThrowIfCancellationRequested();
            var native = FindNpmNative(probe, folder.Trim().Trim('"'));
            if (native is not null) return native;
        }

        // Only inspect Codex's own installation folders, not every application under Programs.
        var programs = Combine(_locations.LocalApplicationData, "Programs");
        foreach (var install in new[] { Combine(programs, "Codex"), Combine(programs, "codex") }.Distinct(StringComparer.OrdinalIgnoreCase))
        {
            var bundled = probe.Existing(Combine(install, "resources", "codex.exe")) ?? probe.Existing(Combine(install, "resources", "bin", "codex.exe"));
            if (bundled is not null) return bundled;
            // A Desktop GUI also named Codex.exe must not be launched as the CLI.
            if (probe.Existing(Combine(install, "resources", "app.asar")) is null)
            {
                var standalone = probe.Existing(Combine(install, "codex.exe"));
                if (standalone is not null) return standalone;
            }
        }

        probe.ThrowIfInaccessible();
        throw new FileNotFoundException("在已检查的 Desktop bin、PATH、npm 与 Programs/Codex 位置中未找到 Codex CLI；这不代表电脑上没有安装。可使用 --codex-exe / CODEX_CLI_PATH 指定原生 codex.exe。");
    }

    private static string RequireExplicit(string value, string source)
    {
        string fullPath;
        try { fullPath = Path.GetFullPath(Environment.ExpandEnvironmentVariables(value.Trim().Trim('"'))); }
        catch (Exception ex) when (ex is ArgumentException or NotSupportedException)
        { throw new InvalidDataException($"{source} 指定的路径无效，请修正后重试。", ex); }
        FileAttributes attributes;
        try { attributes = File.GetAttributes(fullPath); }
        catch (Exception ex) when (ex is FileNotFoundException or DirectoryNotFoundException)
        { throw new FileNotFoundException($"找不到 {source} 指定的 Codex 可执行文件；请修正此路径后重试。", ex); }
        if ((attributes & FileAttributes.Directory) != 0)
            throw new InvalidDataException($"{source} 指定的路径存在，但指向文件夹；请选择原生 codex.exe 文件。");
        if (!Path.GetExtension(fullPath).Equals(".exe", StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException($"{source} 指向的文件存在，但需要原生 .exe；不能使用 PowerShell 或 CMD 包装脚本。");
        return fullPath;
    }

    private static string? FindNpmNative(Probe probe, string folder)
    {
        foreach (var package in new[]
        {
            Combine(folder, "node_modules", "@openai", "codex"),
            Combine(folder, "node_modules", "@openai", "codex-win32-x64")
        })
        {
            foreach (var vendor in new[] { Combine(package, "vendor"), Combine(package, "node_modules", "@openai", "codex-win32-x64", "vendor") })
            {
                var native = probe.Existing(Combine(vendor, "x86_64-pc-windows-msvc", "codex", "codex.exe"));
                if (native is not null) return native;
            }
        }
        return null;
    }

    private sealed class Probe
    {
        private bool _inaccessible;
        private bool _inspectionFailed;
        public string? Newest(IEnumerable<string> candidates) => candidates
            .Select(Existing).OfType<string>()
            .Select(path => (Path: path, Modified: LastWrite(path)))
            .OrderByDescending(candidate => candidate.Modified)
            .ThenBy(candidate => candidate.Path, StringComparer.OrdinalIgnoreCase)
            .Select(candidate => candidate.Path).FirstOrDefault();

        private static DateTime LastWrite(string path)
        {
            try { return File.GetLastWriteTimeUtc(path); }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { return DateTime.MinValue; }
        }

        public IEnumerable<string> Directories(string path)
        {
            if (string.IsNullOrWhiteSpace(path)) return [];
            // One level only: a version directory may itself be a junction; no recursive link traversal.
            try { return Directory.GetDirectories(path, "*", new EnumerationOptions { IgnoreInaccessible = false, AttributesToSkip = 0 }); }
            catch (UnauthorizedAccessException) { _inaccessible = true; return []; }
            catch (DirectoryNotFoundException) { return []; }
            catch (Exception ex) when (ex is IOException or ArgumentException or NotSupportedException) { _inspectionFailed = true; return []; }
        }

        public string? Existing(string path)
        {
            if (string.IsNullOrWhiteSpace(path)) return null;
            try { return (File.GetAttributes(path) & FileAttributes.Directory) == 0 ? Path.GetFullPath(path) : null; }
            catch (UnauthorizedAccessException) { _inaccessible = true; return null; }
            catch (Exception ex) when (ex is FileNotFoundException or DirectoryNotFoundException) { return null; }
            catch (Exception ex) when (ex is IOException or ArgumentException or NotSupportedException) { _inspectionFailed = true; return null; }
        }

        public void ThrowIfInaccessible()
        {
            if (_inaccessible) throw new UnauthorizedAccessException("部分 Codex 安装位置无法读取，不能确认文件是否存在；请检查目录权限或显式指定可访问的 codex.exe。");
            if (_inspectionFailed) throw new IOException("部分 Codex 安装位置检查失败，不能确认文件是否存在；请检查路径是否有效、磁盘是否可用，或显式指定 codex.exe。");
        }
    }

    private static string Combine(string? root, params string[] parts)
    {
        if (string.IsNullOrWhiteSpace(root)) return "";
        try { return Path.Combine(new[] { root }.Concat(parts).ToArray()); }
        catch (Exception ex) when (ex is ArgumentException or NotSupportedException) { return ""; }
    }
}

public sealed record CodexExecutableLocations(string LocalApplicationData, string? RoamingApplicationData, string? SearchPath, string? CliPath = null)
{
    public static CodexExecutableLocations FromEnvironment()
    {
        static string Get(string name, string fallback) => Environment.GetEnvironmentVariable(name) is { } value && !string.IsNullOrWhiteSpace(value) ? value : fallback;
        var user = Get("USERPROFILE", Environment.GetFolderPath(Environment.SpecialFolder.UserProfile));
        return new(Get("LOCALAPPDATA", Path.Combine(user, "AppData", "Local")), Get("APPDATA", Path.Combine(user, "AppData", "Roaming")),
            Environment.GetEnvironmentVariable("PATH"), Environment.GetEnvironmentVariable("CODEX_CLI_PATH"));
    }
}
