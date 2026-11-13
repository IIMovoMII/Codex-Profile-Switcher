using Switcher.Core.Abstractions;
using Switcher.Core.Paths;
using Switcher.Core.Profiles;
using Switcher.Infrastructure.Processes;
using System.Security.AccessControl;
using System.Security.Principal;

namespace Switcher.Infrastructure.Tests;

public sealed class CodexExecutableDiscoveryTests
{
    [Fact]
    public void Desktop_versioned_cli_is_found_without_path_and_preferred_over_stale_root_copy()
    {
        using var fixture = new Fixture();
        fixture.File("local/OpenAI/Codex/bin/codex.exe", daysOld: 0);
        fixture.File("local/OpenAI/Codex/bin/old-build/codex.exe", daysOld: 3);
        var expected = fixture.File("local/OpenAI/Codex/bin/new-build/codex.exe", daysOld: 1);
        fixture.File("path/codex.exe", daysOld: 0);
        Assert.Equal(expected, fixture.Resolver().Resolve());
    }

    [Fact]
    public void Discovery_rechecks_updated_and_removed_versions_and_falls_back_to_root()
    {
        using var fixture = new Fixture();
        var root = fixture.File("local/OpenAI/Codex/bin/codex.exe");
        var first = fixture.File("local/OpenAI/Codex/bin/build-a/codex.exe", 2);
        var resolver = fixture.Resolver();
        Assert.Equal(first, resolver.Resolve());
        var next = fixture.File("local/OpenAI/Codex/bin/build-b/codex.exe", 1);
        Assert.Equal(next, resolver.Resolve());
        System.IO.File.Delete(next); System.IO.File.Delete(first);
        Assert.Equal(root, resolver.Resolve());
    }

    [Fact]
    public void Explicit_and_environment_overrides_have_priority_and_invalid_override_never_escapes_isolation()
    {
        using var fixture = new Fixture();
        var explicitPath = fixture.File("manual 中文/codex.exe");
        var environmentPath = fixture.File("environment/codex.exe");
        fixture.File("local/OpenAI/Codex/bin/current/codex.exe");
        var resolver = fixture.Resolver(environmentPath);
        Assert.Equal(explicitPath, resolver.Resolve('"' + explicitPath + '"'));
        Assert.Equal(environmentPath, resolver.Resolve());
        Assert.Contains("--codex-exe", Assert.Throws<FileNotFoundException>(() => resolver.Resolve(fixture.Path("missing/codex.exe"))).Message);
        Assert.Contains("CODEX_CLI_PATH", Assert.Throws<FileNotFoundException>(() => fixture.Resolver(fixture.Path("missing/codex.exe")).Resolve()).Message);
    }

    [Theory]
    [InlineData("roaming/npm/node_modules/@openai/codex/vendor/x86_64-pc-windows-msvc/codex/codex.exe")]
    [InlineData("roaming/npm/node_modules/@openai/codex/node_modules/@openai/codex-win32-x64/vendor/x86_64-pc-windows-msvc/codex/codex.exe")]
    [InlineData("path/node_modules/@openai/codex-win32-x64/vendor/x86_64-pc-windows-msvc/codex/codex.exe")]
    public void Npm_native_binary_is_resolved_without_executing_a_cmd_or_powershell_wrapper(string relative)
    {
        using var fixture = new Fixture();
        fixture.File("path/codex.cmd");
        Assert.Equal(fixture.File(relative), fixture.Resolver().Resolve());
    }

    [Fact]
    public void Invalid_desktop_location_does_not_hide_an_existing_path_cli_and_path_order_is_preserved()
    {
        using var fixture = new Fixture();
        fixture.File("local/OpenAI/Codex/bin"); // A file where a directory was expected.
        var first = fixture.File("path/codex.exe", daysOld: 5);
        fixture.File("path-second/codex.exe", daysOld: 0);
        var searchPath = "\"" + fixture.Path("path") + "\";" + fixture.Path("path-second");
        var resolver = new CodexExecutableResolver(new(fixture.Path("local"), fixture.Path("roaming"), searchPath));
        Assert.Equal(first, resolver.Resolve());
    }

    [Fact]
    public void Existing_directory_and_failed_inspection_are_not_reported_as_missing_files()
    {
        using var fixture = new Fixture();
        var directory = fixture.Path("already exists 中文"); Directory.CreateDirectory(directory);
        Assert.Contains("指向文件夹", Assert.Throws<InvalidDataException>(() => fixture.Resolver().Resolve(directory)).Message);
        fixture.File("local/OpenAI/Codex/bin");
        var error = Assert.Throws<IOException>(() => fixture.Resolver().Resolve());
        Assert.IsNotType<FileNotFoundException>(error);
        Assert.Contains("检查失败", error.Message);
    }

    [Fact]
    public void Programs_prefers_bundled_cli_and_does_not_launch_the_desktop_gui_or_scan_other_apps()
    {
        using var fixture = new Fixture();
        fixture.File("local/Programs/Unrelated/nested/codex.exe");
        fixture.File("local/Programs/Codex/Codex.exe");
        fixture.File("local/Programs/Codex/resources/app.asar");
        Assert.Throws<FileNotFoundException>(() => fixture.Resolver().Resolve());
        var cli = fixture.File("local/Programs/Codex/resources/codex.exe");
        Assert.Equal(cli, fixture.Resolver().Resolve());
    }

    [Fact]
    public async Task Runtime_uses_discovered_cli_for_local_status_and_login_with_isolated_child_environment()
    {
        using var fixture = new Fixture();
        var cli = fixture.File("local/OpenAI/Codex/bin/current/codex.exe");
        var runner = new RecordingRunner();
        var paths = new SwitcherPaths(fixture.Path("home"), fixture.Path("data"));
        var runtime = new CodexRuntime(runner, paths, executableResolver: fixture.Resolver());
        Assert.True(await runtime.IsAvailableAsync(CancellationToken.None));
        await runtime.VerifyAuthenticationAsync(ProfileKind.Api, CancellationToken.None, fixture.Path("temporary-home"));
        await runtime.LoginInteractivelyAsync(fixture.Path("temporary-login"), CancellationToken.None);
        Assert.Equal(3, runner.Requests.Count);
        Assert.All(runner.Requests, request => Assert.Equal(cli, request.FileName));
        Assert.Equal(new[] { "--version" }, runner.Requests[0].Arguments);
        Assert.Equal(new[] { "login", "status" }, runner.Requests[1].Arguments);
        Assert.Equal(fixture.Path("home"), runner.Requests[0].Environment!["CODEX_HOME"]);
        Assert.Equal(fixture.Path("temporary-home"), runner.Requests[1].Environment!["CODEX_HOME"]);
        Assert.Equal(fixture.Path("temporary-login"), runner.Requests[2].Environment!["CODEX_HOME"]);
        Assert.True(runner.Requests[2].Interactive);
        Assert.All(runner.Requests, request => Assert.Null(request.Environment!["OPENAI_API_KEY"]));
    }

    [Fact]
    public async Task Configured_path_in_switcher_paths_is_used_and_cancellation_never_starts_a_process()
    {
        using var fixture = new Fixture();
        var explicitPath = fixture.File("explicit/codex.exe");
        var runner = new RecordingRunner();
        var runtime = new CodexRuntime(runner, new(fixture.Path("home"), fixture.Path("data"), explicitPath), executableResolver: fixture.Resolver());
        Assert.True(await runtime.IsAvailableAsync(CancellationToken.None));
        Assert.Equal(explicitPath, Assert.Single(runner.Requests).FileName);
        using var cancellation = new CancellationTokenSource(); cancellation.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => runtime.IsAvailableAsync(cancellation.Token));
        Assert.Single(runner.Requests);
    }

    [Fact]
    public void Unreadable_installation_is_reported_as_permission_failure_and_does_not_prevent_path_fallback()
    {
        using var fixture = new Fixture();
        var executable = fixture.File("local/OpenAI/Codex/bin/current/codex.exe");
        var directory = new DirectoryInfo(System.IO.Path.GetDirectoryName(System.IO.Path.GetDirectoryName(executable)!)!);
        var original = directory.GetAccessControl();
        var denied = directory.GetAccessControl();
        denied.AddAccessRule(new FileSystemAccessRule(WindowsIdentity.GetCurrent().User!, FileSystemRights.ListDirectory, AccessControlType.Deny));
        try
        {
            directory.SetAccessControl(denied);
            Assert.Throws<UnauthorizedAccessException>(() => fixture.Resolver().Resolve());
            var fallback = fixture.File("path/codex.exe");
            Assert.Equal(fallback, fixture.Resolver().Resolve());
        }
        finally
        {
            var restore = new DirectorySecurity();
            restore.SetSecurityDescriptorBinaryForm(original.GetSecurityDescriptorBinaryForm(), AccessControlSections.Access);
            directory.SetAccessControl(restore);
        }
    }

    [Fact]
    public void Existing_script_override_is_reported_as_unsupported_format_instead_of_missing()
    {
        using var fixture = new Fixture();
        var wrapper = fixture.File("manual/codex.ps1");
        Assert.Contains("文件存在", Assert.Throws<InvalidDataException>(() => fixture.Resolver().Resolve(wrapper)).Message);
    }

    [Theory]
    [InlineData(7, false)]
    [InlineData(0, true)]
    public async Task Existing_executable_with_a_failed_version_check_is_not_reported_as_a_missing_file(int exitCode, bool timedOut)
    {
        using var fixture = new Fixture();
        var executable = fixture.File("local/OpenAI/Codex/bin/current/codex.exe");
        var runtime = new CodexRuntime(new RecordingRunner(_ => new(exitCode, "", "", timedOut)),
            new(fixture.Path("home"), fixture.Path("data")), executableResolver: fixture.Resolver());
        var status = await runtime.InspectAsync(CancellationToken.None);
        Assert.True(status.Found); Assert.False(status.CanRun); Assert.Equal(executable, status.ExecutablePath);
        Assert.Contains("已找到", status.Message);
    }

    [Fact]
    public async Task Missing_cli_is_reported_unavailable_without_starting_any_process()
    {
        using var fixture = new Fixture();
        var runner = new RecordingRunner();
        var runtime = new CodexRuntime(runner, new(fixture.Path("home"), fixture.Path("data")), executableResolver: fixture.Resolver());
        Assert.False(await runtime.IsAvailableAsync(CancellationToken.None));
        await Assert.ThrowsAsync<FileNotFoundException>(() => runtime.VerifyAuthenticationAsync(ProfileKind.Api, CancellationToken.None));
        Assert.Empty(runner.Requests);
    }

    private sealed class RecordingRunner(Func<ProcessRequest, ProcessResult>? behavior = null) : IProcessRunner
    {
        public List<ProcessRequest> Requests { get; } = [];
        public Task<ProcessResult> RunAsync(ProcessRequest request, CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested(); Requests.Add(request);
            return Task.FromResult(behavior?.Invoke(request) ?? new ProcessResult(0, "", "Logged in using an API key", false));
        }
    }

    private sealed class Fixture : IDisposable
    {
        private readonly string _root = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "codex-discovery-中文 " + Guid.NewGuid().ToString("N"));
        public string Path(string relative) => System.IO.Path.Combine(_root, relative.Replace('/', System.IO.Path.DirectorySeparatorChar));
        public string File(string relative, int daysOld = 0)
        {
            var path = Path(relative); Directory.CreateDirectory(System.IO.Path.GetDirectoryName(path)!);
            System.IO.File.WriteAllText(path, "synthetic sentinel, never execute");
            System.IO.File.SetLastWriteTimeUtc(path, DateTime.UtcNow.AddDays(-daysOld)); return path;
        }
        public CodexExecutableResolver Resolver(string? cliPath = null) => new(new(Path("local"), Path("roaming"), Path("path"), cliPath));
        public void Dispose() { if (Directory.Exists(_root)) Directory.Delete(_root, true); }
    }
}
