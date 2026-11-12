using System.Diagnostics;
using System.ComponentModel;
using Switcher.Core.Abstractions;
using Switcher.Core.Paths;
using Switcher.Core.Profiles;
using Switcher.Core.Switching;

namespace Switcher.Infrastructure.Processes;

/// <summary>All Codex process interaction lives here so the UI and CLI never shell out to PowerShell.</summary>
public sealed class CodexRuntime(IProcessRunner runner, SwitcherPaths paths, string? configuredExecutable = null) : ICodexRuntime
{
    private readonly string? _configuredExecutable = configuredExecutable;
    private readonly SwitcherPaths _paths = paths;

    public async Task<IReadOnlyList<string>> FindRunningProcessNamesAsync(CancellationToken cancellationToken)
    {
        await Task.Yield();
        cancellationToken.ThrowIfCancellationRequested();
        var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var processName in new[] { "codex", "codex-desktop", "Codex" })
        {
            try
            {
                foreach (var process in Process.GetProcessesByName(processName))
                {
                    using (process) names.Add(process.ProcessName);
                }
            }
            catch (ArgumentException) { }
        }
        return names.OrderBy(name => name, StringComparer.OrdinalIgnoreCase).ToArray();
    }

    public async Task<bool> IsAvailableAsync(CancellationToken cancellationToken)
    {
        try
        {
            var result = await RunStatusAsync(cancellationToken).ConfigureAwait(false);
            return result.ExitCode == 0;
        }
        catch (Exception ex) when (ex is IOException or Win32Exception or TimeoutException)
        {
            return false;
        }
    }

    public async Task VerifyAuthenticationAsync(ProfileKind expectedKind, CancellationToken cancellationToken, string? codexHome = null)
    {
        var result = await RunStatusAsync(cancellationToken, codexHome).ConfigureAwait(false);
        if (result.TimedOut) throw new TimeoutException("Codex 登录状态检查超时。");
        if (result.ExitCode != 0) throw new InvalidOperationException("Codex 登录状态检查失败；认证文件未提交。 ");
        var output = result.StandardOutput + Environment.NewLine + result.StandardError;
        ProfileKind? actual = output.Contains("ChatGPT", StringComparison.OrdinalIgnoreCase) ? ProfileKind.Official :
            output.Contains("API key", StringComparison.OrdinalIgnoreCase) ? ProfileKind.Api : null;
        if (actual != expectedKind) throw new InvalidDataException($"Codex 未确认预期的 {expectedKind.ToLegacyValue()} 认证；认证文件未提交。 ");
    }

    public async Task LoginInteractivelyAsync(string codexHome, CancellationToken cancellationToken)
    {
        var executable = ResolveExecutable();
        var result = await runner.RunAsync(new ProcessRequest(executable, ["login"], codexHome,
            new Dictionary<string, string?>
            {
                ["CODEX_HOME"] = codexHome,
                ["OPENAI_API_KEY"] = null,
                ["OPENAI_BASE_URL"] = null,
                ["CODEX_ACCESS_TOKEN"] = null
            }, Interactive: true), cancellationToken).ConfigureAwait(false);
        if (result.ExitCode != 0) throw new InvalidOperationException($"codex login 已退出，退出码为 {result.ExitCode}。 ");
    }

    public void EnsureNoAuthenticationOverrides()
    {
        var overrides = GetAuthenticationOverrides();
        if (overrides.Count > 0)
            throw new InvalidOperationException($"当前进程存在 {string.Join(", ", overrides)} 环境变量覆盖，请清除后再切换。 ");
    }

    public IReadOnlyList<string> GetAuthenticationOverrides() =>
        new[] { "OPENAI_API_KEY", "OPENAI_BASE_URL", "CODEX_ACCESS_TOKEN" }
            .Where(name => !string.IsNullOrWhiteSpace(Environment.GetEnvironmentVariable(name)))
            .ToArray();

    public IReadOnlyDictionary<string, string?> GetProcessEnvironment() => new Dictionary<string, string?>(StringComparer.OrdinalIgnoreCase)
    {
        ["OPENAI_ORGANIZATION"] = Environment.GetEnvironmentVariable("OPENAI_ORGANIZATION"),
        ["OPENAI_PROJECT"] = Environment.GetEnvironmentVariable("OPENAI_PROJECT")
    };

    private Task<ProcessResult> RunStatusAsync(CancellationToken cancellationToken, string? codexHome = null)
    {
        var executable = ResolveExecutable();
        var home = codexHome ?? _paths.CodexHome;
        return runner.RunAsync(new ProcessRequest(executable, ["login", "status"], home,
            new Dictionary<string, string?>
            {
                ["CODEX_HOME"] = home,
                ["OPENAI_API_KEY"] = null,
                ["OPENAI_BASE_URL"] = null,
                ["CODEX_ACCESS_TOKEN"] = null
            }, TimeSpan.FromSeconds(30)), cancellationToken);
    }

    private string ResolveExecutable()
    {
        if (!string.IsNullOrWhiteSpace(_configuredExecutable))
        {
            var configured = Path.GetFullPath(_configuredExecutable);
            if (File.Exists(configured)) return configured;
            throw new FileNotFoundException("找不到配置的 Codex 可执行文件。", configured);
        }
        var candidates = new List<string>();
        var local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        if (!string.IsNullOrWhiteSpace(local))
            candidates.AddRange(Directory.Exists(Path.Combine(local, "Programs"))
                ? Directory.EnumerateFiles(Path.Combine(local, "Programs"), "codex.exe", SearchOption.AllDirectories)
                : []);
        var path = Environment.GetEnvironmentVariable("PATH")?.Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries)
            .Select(folder => Path.Combine(folder, "codex.exe"))
            .Where(File.Exists) ?? [];
        candidates.AddRange(path);
        var resolved = candidates.OrderByDescending(File.GetLastWriteTimeUtc).FirstOrDefault();
        return resolved ?? throw new FileNotFoundException("在 PATH 或本机 Codex 安装目录中找不到 codex.exe。");
    }
}
