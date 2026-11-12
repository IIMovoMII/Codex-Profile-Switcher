namespace Switcher.Core.Abstractions;

public sealed record ProcessRequest(
    string FileName,
    IReadOnlyList<string> Arguments,
    string? WorkingDirectory = null,
    IReadOnlyDictionary<string, string?>? Environment = null,
    TimeSpan? Timeout = null,
    bool Interactive = false);

public sealed record ProcessResult(int ExitCode, string StandardOutput, string StandardError, bool TimedOut);

public interface IProcessRunner
{
    Task<ProcessResult> RunAsync(ProcessRequest request, CancellationToken cancellationToken);
}
