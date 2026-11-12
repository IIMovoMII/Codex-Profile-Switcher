using Switcher.Core.Abstractions;
using Switcher.Infrastructure.Processes;

namespace Switcher.Infrastructure.Tests;

public sealed class ProcessRunnerBehaviorTests
{
    [Fact]
    public async Task Runner_captures_both_streams_and_preserves_exit_code_in_a_special_path()
    {
        var root = Path.Combine(Path.GetTempPath(), "process runner (中文) " + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            var cmd = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "System32", "cmd.exe");
            var result = await new SystemProcessRunner().RunAsync(
                new ProcessRequest(cmd, ["/d", "/c", "echo stdout marker& echo stderr marker 1>&2& exit /b 7"], root, Timeout: TimeSpan.FromSeconds(10)),
                CancellationToken.None);

            Assert.Equal(7, result.ExitCode);
            Assert.False(result.TimedOut);
            Assert.Contains("stdout marker", result.StandardOutput);
            Assert.Contains("stderr marker", result.StandardError);
        }
        finally { Directory.Delete(root, recursive: true); }
    }

    [Fact]
    public async Task Runner_does_not_treat_stderr_as_failure_when_exit_code_is_zero()
    {
        var cmd = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "System32", "cmd.exe");
        var result = await new SystemProcessRunner().RunAsync(
            new ProcessRequest(cmd, ["/d", "/c", "echo status information 1>&2& exit /b 0"], Timeout: TimeSpan.FromSeconds(10)),
            CancellationToken.None);

        Assert.Equal(0, result.ExitCode);
        Assert.False(result.TimedOut);
        Assert.Contains("status information", result.StandardError);
    }

    [Fact]
    public async Task Runner_reports_timeout_and_honors_cancellation()
    {
        var cmd = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "System32", "cmd.exe");
        const string longRunning = "for /l %i in (1,1,100000000) do @set x=%i";
        var runner = new SystemProcessRunner();

        var timed = await runner.RunAsync(new ProcessRequest(cmd, ["/d", "/c", longRunning], Timeout: TimeSpan.FromMilliseconds(200)), CancellationToken.None);
        Assert.True(timed.TimedOut);

        using var cancellation = new CancellationTokenSource(TimeSpan.FromMilliseconds(200));
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() =>
            runner.RunAsync(new ProcessRequest(cmd, ["/d", "/c", longRunning], Timeout: TimeSpan.FromSeconds(10)), cancellation.Token));
    }

    [Fact]
    public async Task Interactive_runner_passes_isolated_environment_without_using_shell_execute()
    {
        var root = Path.Combine(Path.GetTempPath(), "interactive process runner (中文) " + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            var cmd = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "System32", "cmd.exe");
            var runner = new SystemProcessRunner();
            var environment = new Dictionary<string, string?> { ["CODEX_HOME"] = root };
            var captured = await runner.RunAsync(
                new ProcessRequest(cmd, ["/d", "/c", "echo %CODEX_HOME%"], root, environment), CancellationToken.None);
            var interactive = await runner.RunAsync(
                new ProcessRequest(cmd, ["/d", "/c", "exit /b 0"], root, environment, Interactive: true), CancellationToken.None);

            Assert.Equal(root, captured.StandardOutput.Trim());
            Assert.Equal(0, interactive.ExitCode);
            Assert.Empty(interactive.StandardOutput);
            Assert.Empty(interactive.StandardError);
        }
        finally { try { Directory.Delete(root, recursive: true); } catch (IOException) { } }
    }
}
