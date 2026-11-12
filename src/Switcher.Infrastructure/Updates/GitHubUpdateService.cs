using System.Collections.Concurrent;
using System.Diagnostics;
using System.Net;
using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text.Json;
using Switcher.Core.Switching;
using Switcher.Core.Updates;

namespace Switcher.Infrastructure.Updates;

public sealed class GitHubUpdateService : IUpdateService
{
    private const string Repository = "IIMovoMII/Codex-Profile-Switcher";
    private const long MaxInstallerBytes = 250L * 1024 * 1024;
    private readonly HttpClient _http;
    private readonly string _currentVersion;
    private readonly ConcurrentDictionary<string, string> _verified = new(StringComparer.OrdinalIgnoreCase);

    public GitHubUpdateService(HttpClient? httpClient = null, string? currentVersion = null)
    {
        var assemblyVersion = typeof(GitHubUpdateService).Assembly.GetName().Version;
        _currentVersion = currentVersion ?? (assemblyVersion is null ? "0.0.0" : $"{assemblyVersion.Major}.{assemblyVersion.Minor}.{assemblyVersion.Build}");
        _http = httpClient ?? new HttpClient { Timeout = TimeSpan.FromMinutes(3) };
        _http.DefaultRequestHeaders.UserAgent.Clear();
        _http.DefaultRequestHeaders.UserAgent.Add(new ProductInfoHeaderValue("CodexProfileSwitcher", _currentVersion));
    }

    public async Task<UpdateInfo> CheckAsync(CancellationToken cancellationToken = default)
    {
        var endpoint = new Uri($"https://api.github.com/repos/{Repository}/releases/latest");
        Exception? lastError = null;
        for (var attempt = 0; attempt < 3; attempt++)
        {
            try
            {
                using var response = await _http.GetAsync(endpoint, cancellationToken).ConfigureAwait(false);
                if (response.StatusCode == HttpStatusCode.NotFound) return new UpdateInfo(_currentVersion, _currentVersion, $"https://github.com/{Repository}/releases", null, null, false, "GitHub 尚无公开发行版。");
                if (response.StatusCode == HttpStatusCode.TooManyRequests || (int)response.StatusCode >= 500)
                {
                    response.EnsureSuccessStatusCode();
                }
                response.EnsureSuccessStatusCode();
                using var document = JsonDocument.Parse(await response.Content.ReadAsByteArrayAsync(cancellationToken).ConfigureAwait(false));
                var root = document.RootElement;
                var tag = root.TryGetProperty("tag_name", out var tagNode) ? tagNode.GetString() : null;
                var html = root.TryGetProperty("html_url", out var urlNode) ? urlNode.GetString() : null;
                if (string.IsNullOrWhiteSpace(tag) || string.IsNullOrWhiteSpace(html) || !IsGitHubUrl(html) || !TryVersion(tag, out var version))
                    throw new InvalidDataException("GitHub 更新信息来源或版本格式无效。");
                string? installer = null; string? checksum = null;
                if (root.TryGetProperty("assets", out var assets) && assets.ValueKind == JsonValueKind.Array)
                    foreach (var asset in assets.EnumerateArray())
                    {
                        var name = asset.TryGetProperty("name", out var nameNode) ? nameNode.GetString() ?? "" : "";
                        var download = asset.TryGetProperty("browser_download_url", out var downloadNode) ? downloadNode.GetString() : null;
                        if (download is null || !IsGitHubUrl(download)) continue;
                        if (name.StartsWith("Codex-Profile-Switcher-Setup-", StringComparison.OrdinalIgnoreCase) && name.EndsWith(".exe", StringComparison.OrdinalIgnoreCase)) installer = download;
                        else if (name.StartsWith("Codex-Profile-Switcher-Setup-", StringComparison.OrdinalIgnoreCase) && name.EndsWith(".exe.sha256", StringComparison.OrdinalIgnoreCase)) checksum = download;
                    }
                var isNewer = version > new Version(Normalize(_currentVersion));
                var message = !isNewer ? "当前已经是最新版本。" : installer is not null && checksum is not null ? $"发现新版本 {version}。" : $"发现新版本 {version}，但发行版缺少受支持的安装包或 SHA-256 清单。";
                return new UpdateInfo(_currentVersion, version.ToString(), html, installer, checksum, isNewer, message);
            }
            catch (Exception ex) when (ex is HttpRequestException or TaskCanceledException or IOException)
            {
                if (cancellationToken.IsCancellationRequested) throw;
                lastError = ex;
                if (attempt < 2) await Task.Delay(TimeSpan.FromMilliseconds(400 * (attempt + 1)), cancellationToken).ConfigureAwait(false);
            }
        }
        throw new HttpRequestException("GitHub 更新检查失败，已重试 3 次。", lastError);
    }

    public async Task<string> DownloadAndVerifyAsync(UpdateInfo update, string destinationDirectory, IProgress<SwitchProgress>? progress = null, CancellationToken cancellationToken = default)
    {
        if (!update.IsNewer || string.IsNullOrWhiteSpace(update.InstallerUrl) || string.IsNullOrWhiteSpace(update.ChecksumUrl) ||
            !IsGitHubUrl(update.InstallerUrl) || !IsGitHubUrl(update.ChecksumUrl))
            throw new InvalidOperationException("没有同时具备 GitHub 安装包和 SHA-256 清单的可验证更新。");
        Directory.CreateDirectory(destinationDirectory);
        var installerUri = new Uri(update.InstallerUrl);
        var fileName = Path.GetFileName(installerUri.AbsolutePath);
        if (string.IsNullOrWhiteSpace(fileName) || fileName.Contains("..", StringComparison.Ordinal) ||
            !fileName.StartsWith("Codex-Profile-Switcher-Setup-", StringComparison.OrdinalIgnoreCase) || !fileName.EndsWith(".exe", StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException("GitHub 更新文件名无效。");
        var target = Path.Combine(destinationDirectory, fileName);
        var temporary = target + ".partial-" + Guid.NewGuid().ToString("N");
        try
        {
            using (var response = await _http.GetAsync(update.InstallerUrl, HttpCompletionOption.ResponseHeadersRead, cancellationToken).ConfigureAwait(false))
            {
                EnsureTrustedFinalUri(response, "更新下载");
                response.EnsureSuccessStatusCode();
                if (response.Content.Headers.ContentLength is > MaxInstallerBytes) throw new InvalidDataException("更新包大于允许的大小。");
                await using var input = await response.Content.ReadAsStreamAsync(cancellationToken).ConfigureAwait(false);
                await using var output = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None, 65536, FileOptions.WriteThrough);
                var buffer = new byte[65536]; long total = 0; var length = response.Content.Headers.ContentLength;
                int read;
                while ((read = await input.ReadAsync(buffer, cancellationToken).ConfigureAwait(false)) > 0)
                {
                    total += read;
                    if (total > MaxInstallerBytes) throw new InvalidDataException("更新包大于允许的大小。");
                    await output.WriteAsync(buffer.AsMemory(0, read), cancellationToken).ConfigureAwait(false);
                    progress?.Report(new SwitchProgress("下载更新", $"已下载 {total / 1024d / 1024d:0.0} MB。", length is > 0 ? (int)Math.Min(99, total * 100 / length.Value) : null));
                }
                await output.FlushAsync(cancellationToken).ConfigureAwait(false);
            }

            string checksumText;
            using (var response = await _http.GetAsync(update.ChecksumUrl, cancellationToken).ConfigureAwait(false))
            {
                EnsureTrustedFinalUri(response, "SHA-256 清单下载");
                response.EnsureSuccessStatusCode();
                checksumText = await response.Content.ReadAsStringAsync(cancellationToken).ConfigureAwait(false);
            }
            var expected = FindChecksum(checksumText, fileName);
            string actual;
            await using (var downloadedFile = File.OpenRead(temporary))
                actual = Convert.ToHexString(await SHA256.HashDataAsync(downloadedFile, cancellationToken).ConfigureAwait(false)).ToLowerInvariant();
            if (!string.Equals(expected, actual, StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("更新包 SHA-256 校验失败。");
            if (File.Exists(target))
            {
                await using var existing = File.OpenRead(target);
                var existingHash = Convert.ToHexString(await SHA256.HashDataAsync(existing, cancellationToken).ConfigureAwait(false)).ToLowerInvariant();
                if (!string.Equals(existingHash, actual, StringComparison.OrdinalIgnoreCase)) throw new IOException("目标目录已有内容不同的同名安装包；未覆盖该文件。");
                File.Delete(temporary);
            }
            else File.Move(temporary, target);
            _verified[Path.GetFullPath(target)] = actual;
            progress?.Report(new SwitchProgress("下载更新", "安装包已下载并通过校验。", 100));
            return target;
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }

    public Task LaunchInstallerAsync(string installerPath, CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var fullPath = Path.GetFullPath(installerPath);
        if (!File.Exists(fullPath)) throw new FileNotFoundException("安装包不存在。", fullPath);
        if (!_verified.TryGetValue(fullPath, out var expected)) throw new InvalidOperationException("只能启动本次会话中通过 GitHub SHA-256 校验的安装包。");
        using var file = File.OpenRead(fullPath);
        var actual = Convert.ToHexString(SHA256.HashData(file)).ToLowerInvariant();
        if (!string.Equals(expected, actual, StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("安装包在校验后发生变化，拒绝启动。");
        Process.Start(new ProcessStartInfo(fullPath) { UseShellExecute = true });
        return Task.CompletedTask;
    }

    private static bool IsGitHubUrl(string value) => Uri.TryCreate(value, UriKind.Absolute, out var uri) && uri.Scheme == Uri.UriSchemeHttps &&
        (uri.Host.Equals("github.com", StringComparison.OrdinalIgnoreCase) ||
         uri.Host.Equals("objects.githubusercontent.com", StringComparison.OrdinalIgnoreCase) ||
         uri.Host.Equals("release-assets.githubusercontent.com", StringComparison.OrdinalIgnoreCase));
    private static string Normalize(string value) => value.Trim().TrimStart('v', 'V');
    private static bool TryVersion(string value, out Version version) => Version.TryParse(Normalize(value), out version!) && version.Major >= 0 && version.Minor >= 0;
    private static string FindChecksum(string text, string fileName)
    {
        foreach (var line in text.Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries))
        {
            var fields = line.Split([' ', '\t'], StringSplitOptions.RemoveEmptyEntries);
            if (fields.Length < 2 || !string.Equals(Path.GetFileName(fields[1].TrimStart('*')), fileName, StringComparison.OrdinalIgnoreCase)) continue;
            if (fields[0].Length == 64 && fields[0].All(Uri.IsHexDigit)) return fields[0];
        }
        throw new InvalidDataException("SHA-256 清单中没有匹配安装包文件名的校验值。");
    }
    private static void EnsureTrustedFinalUri(HttpResponseMessage response, string purpose)
    {
        if (response.RequestMessage?.RequestUri is not { } finalUri || !IsGitHubUrl(finalUri.ToString())) throw new InvalidDataException($"{purpose}重定向来源无效。");
    }
}
