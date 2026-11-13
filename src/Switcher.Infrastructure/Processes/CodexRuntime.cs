using System.Diagnostics;
using System.ComponentModel;
using Switcher.Core.Abstractions;
using Switcher.Core.Paths;
using Switcher.Core.Profiles;
using Switcher.Core.Switching;

namespace Switcher.Infrastructure.Processes;

/// <summary>All Codex process interaction lives here so the UI and CLI never shell out to PowerShell.</summary>
public sealed class CodexRuntime(IProcessRunner runner, SwitcherPaths paths, string? configuredExecutable = null,
    CodexExecutableResolver? executableResolver = null) : ICodexRuntime
{
    private readonly string? _configuredExecutable = configuredExecutable ?? paths.CodexExecutable;
    private readonly SwitcherPaths _paths = paths;
    private readonly CodexExecutableResolver _executableResolver = executableResolver ?? new();

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
        return (await InspectAsync(cancellationToken).ConfigureAwait(false)).CanRun;
    }

    public async Task<CodexCommandStatus> InspectAsync(CancellationToken cancellationToken)
    {
        string executable;
        try { executable = _executableResolver.Resolve(_configuredExecutable, cancellationToken); }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or ArgumentException)
        { return new(false, false, "", ex.Message); }
        try
        {
            var result = await runner.RunAsync(new ProcessRequest(executable, ["--version"], _paths.CodexHome,
                CleanEnvironment(_paths.CodexHome), TimeSpan.FromSeconds(10)), cancellationToken).ConfigureAwait(false);
            return new(true, result.ExitCode == 0 && !result.TimedOut, executable,
                result.TimedOut ? "已找到文件，但版本检查超时；请检查该程序能否运行。" : result.ExitCode == 0
                    ? "Codex CLI 可执行（本地版本检查，无需登录）。"
                    : $"已找到文件，但版本检查返回退出码 {result.ExitCode}；请检查安装是否完整。");
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or Win32Exception or TimeoutException)
        { return new(true, false, executable, "已找到文件，但无法运行；请检查访问权限、文件格式与安装完整性。"); }
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
        var executable = _executableResolver.Resolve(_configuredExecutable, cancellationToken);
        var result = await runner.RunAsync(new ProcessRequest(executable, ["login"], codexHome,
            CleanEnvironment(codexHome), Interactive: true), cancellationToken).ConfigureAwait(false);
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
        var executable = _executableResolver.Resolve(_configuredExecutable, cancellationToken);
        var home = codexHome ?? _paths.CodexHome;
        return runner.RunAsync(new ProcessRequest(executable, ["login", "status"], home,
            CleanEnvironment(home), TimeSpan.FromSeconds(30)), cancellationToken);
    }

    private static IReadOnlyDictionary<string, string?> CleanEnvironment(string home) => new Dictionary<string, string?>
    {
        ["CODEX_HOME"] = home, ["OPENAI_API_KEY"] = null, ["OPENAI_BASE_URL"] = null, ["CODEX_ACCESS_TOKEN"] = null
    };

}
