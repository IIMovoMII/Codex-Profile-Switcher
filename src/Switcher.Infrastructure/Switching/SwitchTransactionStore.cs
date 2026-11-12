using System.Security.Cryptography;
using System.Text.Json;
using Switcher.Core.Abstractions;
using Switcher.Core.Paths;
using Switcher.Core.Switching;

namespace Switcher.Infrastructure.Switching;

public sealed record JournalFile(string Path, bool OriginalExists, byte[] OriginalBytes, bool TargetExists, byte[] TargetBytes, string OriginalHash, string TargetHash);
public sealed record SwitchJournal(string OperationId, string State, DateTimeOffset CreatedUtc, IReadOnlyList<JournalFile> Files);

public sealed class SwitchTransactionStore(ISwitcherFileSystem files, ISecretProtector protector, SwitcherPaths paths)
{
    private static readonly JsonSerializerOptions Options = new(JsonSerializerDefaults.Web);

    public void SavePrepared(OperationPlan plan, IReadOnlyList<JournalFile> journalFiles)
    {
        var journal = new SwitchJournal(plan.OperationId, "prepared", plan.CreatedUtc, journalFiles);
        var json = JsonSerializer.SerializeToUtf8Bytes(journal, Options);
        var encrypted = protector.Protect(json);
        files.WriteAtomic(paths.TransactionFile, encrypted);
        CryptographicOperations.ZeroMemory(json);
        CryptographicOperations.ZeroMemory(encrypted);
    }

    public void MarkCommitted(string operationId)
    {
        var journal = Read() ?? throw new InvalidOperationException("没有可提交的操作记录。");
        if (!string.Equals(journal.OperationId, operationId, StringComparison.Ordinal)) throw new InvalidOperationException("操作记录 ID 不一致。");
        var committed = journal with { State = "committed" };
        var json = JsonSerializer.SerializeToUtf8Bytes(committed, Options);
        var encrypted = protector.Protect(json);
        files.WriteAtomic(paths.TransactionFile, encrypted);
        CryptographicOperations.ZeroMemory(json);
        CryptographicOperations.ZeroMemory(encrypted);
        files.DeleteFile(paths.TransactionFile);
    }

    public SwitchJournal? Read()
    {
        if (!files.FileExists(paths.TransactionFile)) return null;
        var encrypted = files.ReadAllBytes(paths.TransactionFile);
        var json = protector.Unprotect(encrypted);
        try { return JsonSerializer.Deserialize<SwitchJournal>(json, Options) ?? throw new InvalidDataException("事务记录为空。"); }
        catch (JsonException ex) { throw new InvalidDataException("事务记录损坏，保留原文件供人工恢复。", ex); }
        finally { CryptographicOperations.ZeroMemory(json); }
    }

    public void Delete() => files.DeleteFile(paths.TransactionFile);
}
