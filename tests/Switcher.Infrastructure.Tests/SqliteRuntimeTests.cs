using Microsoft.Data.Sqlite;

namespace Switcher.Infrastructure.Tests;

public sealed class SqliteRuntimeTests(Xunit.Abstractions.ITestOutputHelper output)
{
    [Fact]
    public void Loaded_native_engine_includes_the_GHSA_2m69_gcr7_jv3q_fix()
    {
        using var connection = new SqliteConnection("Data Source=:memory:");
        connection.Open();
        using var command = connection.CreateCommand();
        command.CommandText = "SELECT sqlite_version();";
        var actual = Assert.IsType<string>(command.ExecuteScalar());
        output.WriteLine($"Loaded native SQLite: {actual}");
        Assert.True(Version.TryParse(actual, out var version), $"Unexpected SQLite version: {actual}");
        Assert.True(version >= new Version(3, 50, 2), $"Vulnerable native SQLite loaded: {actual}");
    }
}
