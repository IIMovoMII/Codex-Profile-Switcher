using Switcher.Core.Switching;

namespace Switcher.Core.Updates;

public sealed record UpdateInfo(string CurrentVersion, string LatestVersion, string ReleaseUrl, string? InstallerUrl, string? ChecksumUrl, bool IsNewer, string Message);

public interface IUpdateService
{
    Task<UpdateInfo> CheckAsync(CancellationToken cancellationToken = default);
    Task<string> DownloadAndVerifyAsync(UpdateInfo update, string destinationDirectory, IProgress<SwitchProgress>? progress = null, CancellationToken cancellationToken = default);
    Task LaunchInstallerAsync(string installerPath, CancellationToken cancellationToken = default);
}
