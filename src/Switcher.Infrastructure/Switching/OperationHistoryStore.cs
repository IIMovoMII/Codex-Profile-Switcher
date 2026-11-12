using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using Switcher.Core.Abstractions;
using Switcher.Core.Paths;
using Switcher.Core.Switching;

namespace Switcher.Infrastructure.Switching;

public sealed class OperationHistoryStore(ISwitcherFileSystem files, SwitcherPaths paths) : IOperationHistory
{
    private const int MaximumEntries = 1000;
    private static readonly UTF8Encoding Utf8 = new(false, true);
    private static readonly JsonSerializerOptions JsonOptions = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase };
    private static readonly Regex SecretAssignment = new(@"(?i)\b(api[_ -]?key|access[_ -]?token|refresh[_ -]?token|id[_ -]?token)\b\s*[:=]\s*[^\s,;]+", RegexOptions.Compiled);
    private static readonly Regex BearerSecret = new(@"(?i)\bBearer\s+[^\s,;]+", RegexOptions.Compiled);
    private static readonly Regex ApiKey = new(@"\bsk-[A-Za-z0-9_-]{8,}\b", RegexOptions.Compiled);

    public IReadOnlyList<string> ReadRecent(int count = 200)
    {
        if (count <= 0) return [];
        return ReadEntries().TakeLast(Math.Min(count, MaximumEntries))
            .Select(entry => $"{entry.AtUtc.ToLocalTime():yyyy-MM-dd HH:mm:ss}  {entry.Message}").ToArray();
    }

    public void Append(string message)
    {
        if (string.IsNullOrWhiteSpace(message)) return;
        var entries = ReadEntries();
        entries.Add(new PersistedEntry(DateTimeOffset.UtcNow, SanitizeMessage(message)));
        if (entries.Count > MaximumEntries) entries.RemoveRange(0, entries.Count - MaximumEntries);
        var contents = string.Join(Environment.NewLine, entries.Select(entry => JsonSerializer.Serialize(entry, JsonOptions))) + Environment.NewLine;
        files.WriteAtomic(paths.OperationLogFile, Utf8.GetBytes(contents));
    }

    private List<PersistedEntry> ReadEntries()
    {
        if (!files.FileExists(paths.OperationLogFile)) return [];
        var contents = Utf8.GetString(files.ReadAllBytes(paths.OperationLogFile));
        var entries = new List<PersistedEntry>();
        foreach (var line in contents.Split('\n', StringSplitOptions.RemoveEmptyEntries))
        {
            try
            {
                var entry = JsonSerializer.Deserialize<PersistedEntry>(line.TrimEnd('\r'), JsonOptions);
                if (entry is not null && !string.IsNullOrWhiteSpace(entry.Message)) entries.Add(entry);
            }
            catch (JsonException) { }
        }
        return entries.TakeLast(MaximumEntries).ToList();
    }

    public static string SanitizeMessage(string message)
    {
        var normalized = message.Replace('\r', ' ').Replace('\n', ' ');
        normalized = SecretAssignment.Replace(normalized, match => match.Groups[1].Value + "=[REDACTED]");
        normalized = BearerSecret.Replace(normalized, "Bearer [REDACTED]");
        normalized = ApiKey.Replace(normalized, "[REDACTED]");
        return normalized.Length <= 1200 ? normalized : normalized[..1200];
    }

    private sealed record PersistedEntry(DateTimeOffset AtUtc, string Message);
}
