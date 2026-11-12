using System.Security.Cryptography;
using Switcher.Core.Abstractions;
using Switcher.Core.Switching;

namespace Switcher.Infrastructure.Switching;

public sealed class AtomicSwitchExecutor(ISwitcherFileSystem files, SwitchTransactionStore transactions) : ITransactionExecutor
{
    public Task ExecuteAsync(OperationPlan plan, CancellationToken cancellationToken) => ExecuteAsync(plan, null, cancellationToken);

    public async Task ExecuteAsync(OperationPlan plan, Func<CancellationToken, Task>? afterWriteValidation, CancellationToken cancellationToken)
    {
        plan.Validate();
        var journalFiles = new List<JournalFile>();
        foreach (var mutation in plan.Mutations)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var exists = files.FileExists(mutation.Path);
            var original = exists ? files.ReadAllBytes(mutation.Path) : [];
            var currentHash = Hash(original, exists);
            var expectedExists = mutation.ExpectedExists ?? (mutation.ExpectedSha256 is not null);
            if (exists != expectedExists || (exists && mutation.ExpectedSha256 is not null && !string.Equals(currentHash, mutation.ExpectedSha256, StringComparison.OrdinalIgnoreCase)))
                throw new IOException($"文件在计划生成后发生变化：{Path.GetFileName(mutation.Path)}");
            var target = mutation.TargetBytes ?? [];
            journalFiles.Add(new JournalFile(mutation.Path, exists, original, mutation.TargetBytes is not null, target,
                Hash(original, exists), Hash(target, mutation.TargetBytes is not null)));
        }
        transactions.SavePrepared(plan, journalFiles);
        try
        {
            foreach (var item in journalFiles)
            {
                cancellationToken.ThrowIfCancellationRequested();
                if (!item.TargetExists) files.DeleteFile(item.Path);
                else files.WriteAtomic(item.Path, item.TargetBytes);
            }
            foreach (var item in journalFiles)
            {
                var exists = files.FileExists(item.Path);
                var written = exists ? files.ReadAllBytes(item.Path) : [];
                if (!string.Equals(Hash(written, exists), item.TargetHash, StringComparison.OrdinalIgnoreCase)) throw new IOException($"写入后验证失败：{Path.GetFileName(item.Path)}");
            }
            if (afterWriteValidation is not null) await afterWriteValidation(cancellationToken).ConfigureAwait(false);
            transactions.MarkCommitted(plan.OperationId);
        }
        catch
        {
            await RecoverAsync(CancellationToken.None).ConfigureAwait(false);
            throw;
        }
    }

    public Task RecoverAsync(CancellationToken cancellationToken)
    {
        var journal = transactions.Read();
        if (journal is null) return Task.CompletedTask;
        if (journal.State == "committed") { transactions.Delete(); return Task.CompletedTask; }
        foreach (var item in journal.Files)
        {
            var currentExists = files.FileExists(item.Path);
            var current = currentExists ? files.ReadAllBytes(item.Path) : [];
            var currentHash = Hash(current, currentExists);
            if (currentHash == item.OriginalHash) continue;
            if (currentHash != item.TargetHash) throw new IOException($"发现外部修改，拒绝覆盖恢复材料：{Path.GetFileName(item.Path)}");
            if (!item.OriginalExists) files.DeleteFile(item.Path); else files.WriteAtomic(item.Path, item.OriginalBytes);
        }
        transactions.Delete();
        return Task.CompletedTask;
    }

    private static string Hash(ReadOnlySpan<byte> bytes, bool exists) => exists ? Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant() : "missing";
}
