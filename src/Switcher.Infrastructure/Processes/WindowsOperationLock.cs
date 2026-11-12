using System.Collections.Concurrent;
using System.Security.Cryptography;
using System.Text;
using Switcher.Core.Abstractions;

namespace Switcher.Infrastructure.Processes;

public sealed class WindowsOperationLock : IOperationLock
{
    private static readonly ConcurrentDictionary<string, SemaphoreSlim> LocalLocks = new(StringComparer.OrdinalIgnoreCase);

    public ValueTask DisposeAsync() => ValueTask.CompletedTask;

    public async ValueTask<IAsyncDisposable> AcquireAsync(string name, CancellationToken cancellationToken)
    {
        var normalized = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(name))).ToLowerInvariant();
        var local = LocalLocks.GetOrAdd(normalized, static _ => new SemaphoreSlim(1, 1));
        await local.WaitAsync(cancellationToken).ConfigureAwait(false);
        Semaphore? semaphore = null;
        try
        {
            if (!OperatingSystem.IsWindows()) throw new PlatformNotSupportedException("切换互斥锁仅支持 Windows。");
            semaphore = new Semaphore(1, 1, $"Local\\CodexProfileSwitcher-{normalized}");
            var wait = await Task.Run(() => WaitHandle.WaitAny([semaphore, cancellationToken.WaitHandle]), CancellationToken.None).ConfigureAwait(false);
            if (wait == 1) cancellationToken.ThrowIfCancellationRequested();
            if (wait != 0) throw new InvalidOperationException("无法获得操作互斥锁。");
            return new Lease(local, semaphore);
        }
        catch
        {
            semaphore?.Dispose();
            local.Release();
            throw;
        }
    }

    private sealed class Lease(SemaphoreSlim local, Semaphore semaphore) : IAsyncDisposable
    {
        private int _disposed;
        public ValueTask DisposeAsync()
        {
            if (Interlocked.Exchange(ref _disposed, 1) == 0)
            {
                try { semaphore.Release(); } finally { semaphore.Dispose(); local.Release(); }
            }
            return ValueTask.CompletedTask;
        }
    }
}
