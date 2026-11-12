namespace Switcher.Core.Switching;

public sealed record FileMutation(string Path, string? ExpectedSha256, byte[]? TargetBytes, string Purpose, bool? ExpectedExists = null)
{
    public bool DeletesFile => TargetBytes is null;
}
