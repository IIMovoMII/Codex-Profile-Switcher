using System.Text.Json;
using Switcher.Core.Abstractions;
using Switcher.Core.Paths;

namespace Switcher.Infrastructure.Processes;

/// <summary>Coordinates only through the legacy maintenance marker, without loading the other application.</summary>
public sealed class MaintenanceCoordinatedLock(IOperationLock inner, ISwitcherFileSystem files, SwitcherPaths paths,
    TimeProvider? timeProvider = null) : IOperationLock
{
    private readonly TimeProvider _time = timeProvider ?? TimeProvider.System;

    public async ValueTask<IAsyncDisposable> AcquireAsync(string name, CancellationToken cancellationToken)
    {
        var lease = await inner.AcquireAsync(name, cancellationToken).ConfigureAwait(false);
        try
        {
            var explicitDirectory = !string.IsNullOrWhiteSpace(paths.MonitorDataDirectory);
            var directory = explicitDirectory
                ? Path.GetFullPath(Environment.ExpandEnvironmentVariables(paths.MonitorDataDirectory!))
                : Path.Combine(Path.GetDirectoryName(Path.TrimEndingDirectorySeparator(paths.DataDirectory))!, "CodexDesktopWeixin");
            if (!explicitDirectory && !files.FileExists(Path.Combine(directory, "settings.json"))) return lease;
            var marker = Path.Combine(directory, "maintenance.json");
            WriteMarker(marker, 180);
            return new CoordinatedLease(lease, () => WriteMarker(marker, 90));
        }
        catch { await lease.DisposeAsync().ConfigureAwait(false); throw; }
    }

    public ValueTask DisposeAsync() => inner.DisposeAsync();

    private void WriteMarker(string path, int lifetimeSeconds)
    {
        var now = _time.GetUtcNow();
        files.WriteAtomic(path, JsonSerializer.SerializeToUtf8Bytes(new
        {
            version = 1, reason = "codex_profile_switch", action = "graphical",
            created_at = now.ToString("O"), expires_at = now.AddSeconds(lifetimeSeconds).ToString("O")
        }));
    }

    private sealed class CoordinatedLease(IAsyncDisposable inner, Action complete) : IAsyncDisposable
    {
        private int _disposed;
        public async ValueTask DisposeAsync()
        {
            if (Interlocked.Exchange(ref _disposed, 1) != 0) return;
            try
            {
                try { complete(); }
                // An already-committed switch must not be reported as failed; the initial marker expires on its own.
                catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { }
            }
            finally { await inner.DisposeAsync().ConfigureAwait(false); }
        }
    }
}
