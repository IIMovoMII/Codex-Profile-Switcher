namespace Switcher.Cli.Tests;

public sealed class CliSmokeTests
{
    [Theory]
    [InlineData("-RelayModelCatalogPath", "-MonitorDataDir")]
    [InlineData("--relay-model-catalog-path", "--monitor-data-dir")]
    public void Legacy_location_options_are_retained_by_cli_parser(string catalogOption, string monitorOption)
    {
        var type = System.Reflection.Assembly.Load("Switcher.Cli").GetType("Switcher.Cli.CliOptions", throwOnError: true)!;
        var args = new[] { "status", catalogOption, "D:\\synthetic 目录\\catalog.json", monitorOption, "D:\\synthetic monitor" };
        var parsed = type.GetMethod("Parse")!.Invoke(null, new object[] { args });
        Assert.Equal(args[2], type.GetProperty("RelayModelCatalogPath")!.GetValue(parsed));
        Assert.Equal(args[4], type.GetProperty("MonitorDataDirectory")!.GetValue(parsed));
    }

    [Fact]
    public async Task Cli_uses_isolated_paths_hides_api_keys_and_preserves_command_exit_codes()
    {
        var root = Path.Combine(Path.GetTempPath(), "codex cli (中文) " + Guid.NewGuid().ToString("N"));
        var home = Path.Combine(root, "codex home");
        var data = Path.Combine(root, "switcher data");
        Directory.CreateDirectory(home);
        Directory.CreateDirectory(data);
        const string syntheticKey = "synthetic-cli-api-key-never-print";
        try
        {
            var help = await RunCliAsync(["--help"]);
            Assert.Equal(0, help.ExitCode);
            Assert.Contains("profile-add-api", help.StandardOutput);
            Assert.Contains("history-prepare", help.StandardOutput);

            var common = new[] { "--codex-home", home, "--data-dir", data };
            var authFile = Path.Combine(root, "synthetic-auth.json");
            var syntheticAuth = CreateOfficialAuth();
            await File.WriteAllTextAsync(authFile, syntheticAuth);
            var imported = await RunCliAsync(["profile-add-official", "--name", "合成官方", "--auth-file", authFile, .. common]);
            Assert.Equal(0, imported.ExitCode);
            Assert.DoesNotContain(syntheticAuth, imported.StandardOutput + imported.StandardError, StringComparison.Ordinal);

            var status = await RunCliAsync(["status", "--json", .. common]);
            Assert.Equal(0, status.ExitCode);
            using (var document = System.Text.Json.JsonDocument.Parse(status.StandardOutput))
            {
                Assert.Equal(Path.GetFullPath(home), document.RootElement.GetProperty("codex_home").GetString());
                Assert.Equal(Path.GetFullPath(data), document.RootElement.GetProperty("data_directory").GetString());
            }

            var listedOfficial = await RunCliAsync(["profiles", "--json", .. common]);
            using var officialDocument = System.Text.Json.JsonDocument.Parse(listedOfficial.StandardOutput);
            var officialId = officialDocument.RootElement[0].GetProperty("Id").GetString();
            Assert.StartsWith("official-", officialId);

            var added = await RunCliAsync(["profile-add-api", "--name", "合成 CLI", "--base-url", "https://relay.example.invalid/v1", "--catalog-mode", "official", "--source-official", officialId!, .. common], syntheticKey);
            Assert.True(added.ExitCode == 0, $"CLI add failed ({added.ExitCode}): {added.StandardError} {added.StandardOutput}");
            Assert.DoesNotContain(syntheticKey, added.StandardOutput + added.StandardError, StringComparison.Ordinal);

            var profiles = await RunCliAsync(["profile-list", "--json", .. common]);
            Assert.Equal(0, profiles.ExitCode);
            Assert.DoesNotContain(syntheticKey, profiles.StandardOutput + profiles.StandardError, StringComparison.Ordinal);
            using var profileDocument = System.Text.Json.JsonDocument.Parse(profiles.StandardOutput);
            var profileId = profileDocument.RootElement.EnumerateArray().Single(item => item.GetProperty("kind").GetString() == "api").GetProperty("Id").GetString();
            Assert.StartsWith("api-", profileId);

            var removed = await RunCliAsync(["profile-remove", "--kind", "api", "--profile", profileId!, .. common]);
            Assert.Equal(0, removed.ExitCode);
            var removedOfficial = await RunCliAsync(["profile-remove", "--kind", "official", "--profile", officialId!, .. common]);
            Assert.Equal(0, removedOfficial.ExitCode);
            var empty = await RunCliAsync(["profiles", "--json", .. common]);
            Assert.Equal(0, empty.ExitCode);
            Assert.Equal("[]", empty.StandardOutput.Trim());
            Assert.DoesNotContain(syntheticKey, empty.StandardOutput + empty.StandardError, StringComparison.Ordinal);
            Assert.False(File.Exists(Path.Combine(home, "auth.json")));
            Assert.False(File.Exists(Path.Combine(home, "config.toml")));
        }
        finally { try { Directory.Delete(root, recursive: true); } catch (IOException) { } }
    }

    [Fact]
    public async Task Project_scan_command_uses_only_the_requested_temporary_codex_home()
    {
        var root = Path.Combine(Path.GetTempPath(), "codex-cli-project-scan-" + Guid.NewGuid().ToString("N"));
        var home = Path.Combine(root, "codex home");
        var data = Path.Combine(root, "isolated data");
        Directory.CreateDirectory(home);
        try
        {
            using (var connection = new Microsoft.Data.Sqlite.SqliteConnection(new Microsoft.Data.Sqlite.SqliteConnectionStringBuilder
            {
                DataSource = Path.Combine(home, "state_5.sqlite"), Mode = Microsoft.Data.Sqlite.SqliteOpenMode.ReadWriteCreate, Pooling = false
            }.ConnectionString))
            {
                connection.Open();
                using var command = connection.CreateCommand();
                command.CommandText = "CREATE TABLE projects(id TEXT PRIMARY KEY,name TEXT NOT NULL,position INTEGER NOT NULL,updated_at_ms INTEGER NOT NULL); CREATE TABLE project_roots(project_id TEXT NOT NULL,position INTEGER NOT NULL,path TEXT NOT NULL); CREATE TABLE threads(id TEXT PRIMARY KEY,cwd TEXT,project_id TEXT,archived INTEGER,agent_role TEXT,source TEXT); INSERT INTO projects VALUES('p','Project',0,1); INSERT INTO threads VALUES('t','D:\\Project',NULL,0,NULL,'vscode');";
                command.ExecuteNonQuery();
            }

            var originalOut = Console.Out;
            var originalError = Console.Error;
            using var stdout = new StringWriter();
            using var stderr = new StringWriter();
            try
            {
                Console.SetOut(stdout);
                Console.SetError(stderr);
                var cliAssembly = System.Reflection.Assembly.Load("Switcher.Cli");
                var entry = cliAssembly.GetType("Switcher.Cli.Program", throwOnError: true)!
                    .GetMethod("Main", System.Reflection.BindingFlags.Public | System.Reflection.BindingFlags.Static)!;
                var arguments = new[] { "project-scan", "--codex-home", home, "--data-dir", data, "--json" };
                var task = (Task<int>)entry.Invoke(null, new object[] { arguments })!;
                Assert.Equal(0, await task);
            }
            finally
            {
                Console.SetOut(originalOut);
                Console.SetError(originalError);
            }
            Assert.Contains("\"ProjectCount\": 1", stdout.ToString());
            Assert.True(Directory.Exists(home));
            Assert.False(File.Exists(Path.Combine(home, "auth.json")));
            Assert.False(File.Exists(Path.Combine(home, "config.toml")));
        }
        finally { try { Directory.Delete(root, recursive: true); } catch (IOException) { } }
    }

    private static async Task<CliResult> RunCliAsync(string[] args, string? standardInput = null)
    {
        var executable = Path.Combine(AppContext.BaseDirectory, "Switcher.Cli.exe");
        Assert.True(File.Exists(executable), $"CLI apphost is missing from {AppContext.BaseDirectory}");
        var start = new System.Diagnostics.ProcessStartInfo(executable)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true
        };
        foreach (var argument in args) start.ArgumentList.Add(argument);
        using var process = new System.Diagnostics.Process { StartInfo = start };
        Assert.True(process.Start());
        if (standardInput is not null) await process.StandardInput.WriteLineAsync(standardInput);
        process.StandardInput.Close();
        var stdout = process.StandardOutput.ReadToEndAsync();
        var stderr = process.StandardError.ReadToEndAsync();
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(20));
        try { await process.WaitForExitAsync(timeout.Token); }
        catch
        {
            if (!process.HasExited) process.Kill(entireProcessTree: true);
            await process.WaitForExitAsync();
            throw;
        }
        await Task.WhenAll(stdout, stderr);
        return new CliResult(process.ExitCode, await stdout, await stderr);
    }

    private sealed record CliResult(int ExitCode, string StandardOutput, string StandardError);

    private static string CreateOfficialAuth()
    {
        var claims = System.Text.Json.JsonSerializer.Serialize(new Dictionary<string, object?>
        {
            ["email"] = "synthetic-cli@example.invalid",
            ["https://api.openai.com/auth"] = new Dictionary<string, object?>
            {
                ["chatgpt_account_id"] = "synthetic-cli-account",
                ["chatgpt_user_id"] = "synthetic-cli-user",
                ["chatgpt_plan_type"] = "plus"
            }
        });
        var payload = Convert.ToBase64String(System.Text.Encoding.UTF8.GetBytes(claims)).TrimEnd('=').Replace('+', '-').Replace('/', '_');
        return System.Text.Json.JsonSerializer.Serialize(new
        {
            auth_mode = "chatgpt",
            tokens = new { id_token = $"synthetic.{payload}.signature", account_id = "synthetic-cli-account", access_token = "synthetic-access", refresh_token = "synthetic-refresh" }
        });
    }
}
