namespace Switcher.Core.Switching;

public sealed record OperationPlan(
    string OperationId,
    string OperationName,
    IReadOnlyList<FileMutation> Mutations,
    DateTimeOffset CreatedUtc,
    bool HasHistoryPreparation = false)
{
    public void Validate()
    {
        if (!Guid.TryParseExact(OperationId, "N", out _)) throw new InvalidDataException("操作计划 ID 无效。");
        if (Mutations.Count == 0) throw new InvalidDataException("操作计划没有文件变更。");
        var paths = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var mutation in Mutations)
        {
            if (string.IsNullOrWhiteSpace(mutation.Path) || !Path.IsPathFullyQualified(mutation.Path)) throw new InvalidDataException("操作计划包含无效文件路径。");
            if (!paths.Add(Path.GetFullPath(mutation.Path))) throw new InvalidDataException("操作计划包含重复目标文件。");
            if (mutation.ExpectedSha256 is not null && !System.Text.RegularExpressions.Regex.IsMatch(mutation.ExpectedSha256, "^[a-f0-9]{64}$")) throw new InvalidDataException("操作计划包含无效的并发校验值。");
        }
    }
}
