using System.Diagnostics;
using Switcher.Core.Abstractions;

namespace Switcher.Infrastructure.Processes;

public sealed class SystemProcessRunner : IProcessRunner
{
    public async Task<ProcessResult> RunAsync(ProcessRequest request, CancellationToken cancellationToken)
    {
        var start = new ProcessStartInfo
        {
            FileName = request.FileName,
            WorkingDirectory = request.WorkingDirectory ?? Environment.CurrentDirectory,
            UseShellExecute = false,
            RedirectStandardOutput = !request.Interactive,
            RedirectStandardError = !request.Interactive,
            CreateNoWindow = !request.Interactive
        };
        foreach (var argument in request.Arguments) start.ArgumentList.Add(argument);
        if (request.Environment is not null)
            foreach (var (key, value) in request.Environment) start.Environment[key] = value;

        using var process = new Process { StartInfo = start, EnableRaisingEvents = true };
        if (!process.Start()) throw new InvalidOperationException("外部进程未能启动。");
        var stdout = request.Interactive ? Task.FromResult("") : process.StandardOutput.ReadToEndAsync(cancellationToken);
        var stderr = request.Interactive ? Task.FromResult("") : process.StandardError.ReadToEndAsync(cancellationToken);
        using var timeout = request.Timeout is { } limit ? new CancellationTokenSource(limit) : new CancellationTokenSource();
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, timeout.Token);
        var timedOut = false;
        try { await process.WaitForExitAsync(linked.Token).ConfigureAwait(false); }
        catch (OperationCanceledException)
        {
            if (!process.HasExited)
            {
                timedOut = !cancellationToken.IsCancellationRequested && timeout.IsCancellationRequested;
                try { process.Kill(entireProcessTree: true); } catch (InvalidOperationException) { }
                await process.WaitForExitAsync(CancellationToken.None).ConfigureAwait(false);
            }
            if (cancellationToken.IsCancellationRequested) throw;
        }
        await Task.WhenAll(stdout, stderr).ConfigureAwait(false);
        return new ProcessResult(process.ExitCode, await stdout.ConfigureAwait(false), await stderr.ConfigureAwait(false), timedOut);
    }
}
