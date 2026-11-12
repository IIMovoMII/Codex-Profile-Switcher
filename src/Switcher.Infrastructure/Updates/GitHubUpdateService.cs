using System.Collections.Concurrent;
using System.Diagnostics;
using System.Net;
using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.RegularExpressions;
using Switcher.Core.Switching;
using Switcher.Core.Updates;

namespace Switcher.Infrastructure.Updates;

public sealed class GitHubUpdateService : IUpdateService
{
    private const string Repository = "IIMovoMII/Codex-Profile-Switcher";
    private const long MaxInstallerBytes = 250L * 1024 * 1024;
    private readonly HttpClient _http;
    private readonly string _currentVersion;
    private readonly TimeSpan _checkTimeout;
    private readonly TimeSpan _requestTimeout;
    private readonly ConcurrentDictionary<string, string> _verified = new(StringComparer.OrdinalIgnoreCase);

    public GitHubUpdateService(HttpClient? httpClient = null, string? currentVersion = null, TimeSpan? checkTimeout = null, TimeSpan? requestTimeout = null)
    {
        var assemblyVersion = typeof(GitHubUpdateService).Assembly.GetName().Version;
        _currentVersion = currentVersion ?? (assemblyVersion is null ? "0.0.0" : $"{assemblyVersion.Major}.{assemblyVersion.Minor}.{assemblyVersion.Build}");
        _http = httpClient ?? new HttpClient { Timeout = TimeSpan.FromMinutes(3) };
        _http.DefaultRequestHeaders.UserAgent.Clear();
        _http.DefaultRequestHeaders.UserAgent.Add(new ProductInfoHeaderValue("CodexProfileSwitcher", _currentVersion));
        _checkTimeout = checkTimeout ?? TimeSpan.FromSeconds(25);
        _requestTimeout = requestTimeout ?? TimeSpan.FromSeconds(5);
    }

    public async Task<UpdateInfo> CheckAsync(CancellationToken cancellationToken = default)
    {
        using var budget = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        budget.CancelAfter(_checkTimeout);
        try { return await CheckCoreAsync(budget.Token, cancellationToken).ConfigureAwait(false); }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        { throw new HttpRequestException("GitHub 更新检查超时；请检查系统代理或稍后重试。未更改当前应用。"); }
    }

    private async Task<UpdateInfo> CheckCoreAsync(CancellationToken cancellationToken, CancellationToken callerCancellationToken)
    {
        var endpoint = new Uri($"https://api.github.com/repos/{Repository}/releases/latest");
        var apiFailure = "GitHub API 暂不可用";
        for (var attempt = 0; attempt < 3; attempt++)
        {
            try
            {
                using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
                timeout.CancelAfter(_requestTimeout);
                using var response = await _http.GetAsync(endpoint, HttpCompletionOption.ResponseHeadersRead, timeout.Token).ConfigureAwait(false);
                if (response.StatusCode is HttpStatusCode.Forbidden or HttpStatusCode.TooManyRequests)
                {
                    apiFailure = response.StatusCode == HttpStatusCode.TooManyRequests ||
                        response.Headers.TryGetValues("X-RateLimit-Remaining", out var remaining) && remaining.Contains("0")
                        ? $"GitHub API 限流（HTTP {(int)response.StatusCode}；系统代理可能共享请求额度）"
                        : "GitHub API 拒绝访问（HTTP 403）";
                    break; // Repeating an exhausted API request cannot replenish its quota.
                }
                if (response.StatusCode == HttpStatusCode.NotFound) { apiFailure = "GitHub API 未找到公开发行版（HTTP 404）"; break; }
                response.EnsureSuccessStatusCode();
                if (response.RequestMessage?.RequestUri != endpoint) throw new InvalidDataException("GitHub API 重定向来源无效。");
                using var document = JsonDocument.Parse(await ReadBoundedAsync(response, timeout.Token).ConfigureAwait(false));
                var root = document.RootElement;
                var tag = root.TryGetProperty("tag_name", out var tagNode) ? tagNode.GetString() : null;
                var html = root.TryGetProperty("html_url", out var urlNode) ? urlNode.GetString() : null;
                if (string.IsNullOrWhiteSpace(tag) || string.IsNullOrWhiteSpace(html) || !IsReleaseUrl(html, tag) || !TryVersion(tag, out var version) ||
                    root.TryGetProperty("draft", out var draft) && draft.ValueKind == JsonValueKind.True ||
                    root.TryGetProperty("prerelease", out var prerelease) && prerelease.ValueKind == JsonValueKind.True)
                    throw new InvalidDataException("GitHub 更新信息来源或版本格式无效。");
                string? installer = null; string? checksum = null;
                if (root.TryGetProperty("assets", out var assets) && assets.ValueKind == JsonValueKind.Array)
                    foreach (var asset in assets.EnumerateArray())
                    {
                        var name = asset.TryGetProperty("name", out var nameNode) ? nameNode.GetString() ?? "" : "";
                        var download = asset.TryGetProperty("browser_download_url", out var downloadNode) ? downloadNode.GetString() : null;
                        if (download is null || !IsRepositoryAsset(download, tag)) continue;
                        if (name.StartsWith("Codex-Profile-Switcher-Setup-", StringComparison.OrdinalIgnoreCase) && name.EndsWith(".exe", StringComparison.OrdinalIgnoreCase)) installer = download;
                        else if (name.StartsWith("Codex-Profile-Switcher-Setup-", StringComparison.OrdinalIgnoreCase) && name.EndsWith(".exe.sha256", StringComparison.OrdinalIgnoreCase)) checksum = download;
                    }
                var notes = root.TryGetProperty("body", out var body) && body.ValueKind == JsonValueKind.String ? body.GetString() : null;
                return CreateInfo(version, html, installer, checksum) with { ReleaseNotes = ReleaseAnnouncement.Normalize(notes) };
            }
            catch (Exception ex) when (ex is HttpRequestException or OperationCanceledException or IOException or InvalidDataException or JsonException or InvalidOperationException)
            {
                if (cancellationToken.IsCancellationRequested) throw;
                apiFailure = DescribeFailure(ex, "GitHub API");
                if (ex is not HttpRequestException && ex is not OperationCanceledException ||
                    ex is HttpRequestException { StatusCode: { } status } && (int)status < 500) break;
                if (attempt < 2) await Task.Delay(TimeSpan.FromMilliseconds(150 * (attempt + 1)), cancellationToken).ConfigureAwait(false);
            }
        }
        try { return await CheckReleasePageAsync(apiFailure, cancellationToken, callerCancellationToken).ConfigureAwait(false); }
        catch (Exception ex) when (ex is HttpRequestException or OperationCanceledException or IOException or InvalidDataException or InvalidOperationException)
        {
            if (cancellationToken.IsCancellationRequested) throw;
            throw new HttpRequestException($"{apiFailure}；{DescribeFailure(ex, "官方发布页")}。请检查系统代理，或打开 GitHub 发布页。");
        }
    }

    private async Task<UpdateInfo> CheckReleasePageAsync(string apiFailure, CancellationToken cancellationToken, CancellationToken callerCancellationToken)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(_requestTimeout + _requestTimeout);
        using var response = await _http.GetAsync($"https://github.com/{Repository}/releases/latest", HttpCompletionOption.ResponseHeadersRead, timeout.Token).ConfigureAwait(false);
        response.EnsureSuccessStatusCode();
        var release = response.RequestMessage?.RequestUri;
        var prefix = $"/{Repository}/releases/tag/";
        if (release is null || release.Scheme != "https" || release.Host != "github.com" || !release.AbsolutePath.StartsWith(prefix, StringComparison.Ordinal))
            throw new InvalidDataException("官方发布页重定向来源无效");
        var tag = Uri.UnescapeDataString(release.AbsolutePath[prefix.Length..]);
        if (!IsReleaseUrl(release.ToString(), tag) || !TryVersion(tag, out var version)) throw new InvalidDataException("官方发布页版本无效");

        // GitHub's expanded-assets page is public and does not consume REST API quota.
        using var assets = await _http.GetAsync($"https://github.com/{Repository}/releases/expanded_assets/{Uri.EscapeDataString(tag)}", HttpCompletionOption.ResponseHeadersRead, timeout.Token).ConfigureAwait(false);
        assets.EnsureSuccessStatusCode();
        if (assets.RequestMessage?.RequestUri?.AbsoluteUri != $"https://github.com/{Repository}/releases/expanded_assets/{Uri.EscapeDataString(tag)}")
            throw new InvalidDataException("官方安装包列表来源无效");
        var page = System.Text.Encoding.UTF8.GetString(await ReadBoundedAsync(assets, timeout.Token).ConfigureAwait(false));
        var expected = $"Codex-Profile-Switcher-Setup-{version}.exe";
        string? installer = null; string? checksum = null;
        foreach (Match match in Regex.Matches(page, "href\\s*=\\s*[\"'](?<url>[^\"']+)[\"']", RegexOptions.IgnoreCase, TimeSpan.FromSeconds(1)))
        {
            if (!Uri.TryCreate(release, WebUtility.HtmlDecode(match.Groups["url"].Value), out var uri) || !IsRepositoryAsset(uri.ToString(), tag)) continue;
            var name = Uri.UnescapeDataString(Path.GetFileName(uri.AbsolutePath));
            if (name == expected) installer = uri.ToString();
            if (name == expected + ".sha256") checksum = uri.ToString();
        }
        var result = CreateInfo(version, release.ToString(), installer, checksum) with
        {
            ReleaseNotes = await ReadVersionNotesAsync(tag, version, cancellationToken, callerCancellationToken).ConfigureAwait(false)
        };
        return result with { Message = result.Message + $" {apiFailure}，已改用官方发布页检查。" };
    }

    private async Task<string> ReadVersionNotesAsync(string tag, Version version, CancellationToken cancellationToken, CancellationToken callerCancellationToken)
    {
        var endpoint = new Uri($"https://raw.githubusercontent.com/{Repository}/refs/tags/{Uri.EscapeDataString(tag)}/docs/zh-CN/releases/{version}.md");
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(_requestTimeout);
        try
        {
            using var response = await _http.GetAsync(endpoint, HttpCompletionOption.ResponseHeadersRead, timeout.Token).ConfigureAwait(false);
            response.EnsureSuccessStatusCode();
            if (response.RequestMessage?.RequestUri != endpoint) return "";
            return ReleaseAnnouncement.Normalize(System.Text.Encoding.UTF8.GetString(await ReadBoundedAsync(response, timeout.Token).ConfigureAwait(false)));
        }
        catch (Exception ex) when (ex is HttpRequestException or IOException or InvalidDataException or OperationCanceledException)
        {
            callerCancellationToken.ThrowIfCancellationRequested();
            return ""; // Optional announcement failures never invalidate a verified update result.
        }
    }

    private UpdateInfo CreateInfo(Version version, string release, string? installer, string? checksum)
    {
        var current = new Version(Normalize(_currentVersion));
        var message = version < current ? $"公开稳定版为 {version}，当前版本较新。" : version == current ? "当前已经是最新版本。" :
            installer is not null && checksum is not null ? $"发现新版本 {version}。" : $"发现新版本 {version}，但发行版缺少受支持的安装包或 SHA-256 清单。";
        return new(_currentVersion, version.ToString(), release, installer, checksum, version > current, message);
    }

    private static async Task<byte[]> ReadBoundedAsync(HttpResponseMessage response, CancellationToken token)
    {
        const int maxBytes = 2 * 1024 * 1024;
        if (response.Content.Headers.ContentLength > maxBytes) throw new InvalidDataException("更新响应过大");
        await using var input = await response.Content.ReadAsStreamAsync(token).ConfigureAwait(false);
        using var output = new MemoryStream();
        var buffer = new byte[8192]; int count;
        while ((count = await input.ReadAsync(buffer, token).ConfigureAwait(false)) > 0)
        {
            if (output.Length + count > maxBytes) throw new InvalidDataException("更新响应过大");
            output.Write(buffer, 0, count);
        }
        return output.ToArray();
    }

    private static string DescribeFailure(Exception error, string source) => error switch
    {
        OperationCanceledException => source + "连接超时",
        HttpRequestException { StatusCode: { } status } => $"{source}返回 HTTP {(int)status}",
        InvalidDataException or JsonException or InvalidOperationException => source + "返回无效或不可信的更新信息",
        _ => source + "连接失败（请检查网络或系统代理）"
    };

    private static bool IsReleaseUrl(string value, string tag) => Uri.TryCreate(value, UriKind.Absolute, out var uri) &&
        uri.Scheme == "https" && uri.Host == "github.com" && uri.IsDefaultPort && string.IsNullOrEmpty(uri.UserInfo) &&
        uri.AbsolutePath == $"/{Repository}/releases/tag/{Uri.EscapeDataString(tag)}" && string.IsNullOrEmpty(uri.Query) && string.IsNullOrEmpty(uri.Fragment);
    private static bool IsRepositoryAsset(string value, string tag) => Uri.TryCreate(value, UriKind.Absolute, out var uri) &&
        uri.Scheme == "https" && uri.Host == "github.com" && uri.IsDefaultPort && string.IsNullOrEmpty(uri.UserInfo) &&
        uri.AbsolutePath.StartsWith($"/{Repository}/releases/download/{Uri.EscapeDataString(tag)}/", StringComparison.Ordinal) &&
        string.IsNullOrEmpty(uri.Query) && string.IsNullOrEmpty(uri.Fragment);

    public async Task<string> DownloadAndVerifyAsync(UpdateInfo update, string destinationDirectory, IProgress<SwitchProgress>? progress = null, CancellationToken cancellationToken = default)
    {
        var releaseTag = Uri.TryCreate(update.ReleaseUrl, UriKind.Absolute, out var releaseUri) ? Uri.UnescapeDataString(releaseUri.Segments.Last()) : "";
        if (!update.IsNewer || string.IsNullOrWhiteSpace(update.InstallerUrl) || string.IsNullOrWhiteSpace(update.ChecksumUrl) ||
            !IsReleaseUrl(update.ReleaseUrl, releaseTag) || !IsRepositoryAsset(update.InstallerUrl, releaseTag) ||
            !IsRepositoryAsset(update.ChecksumUrl, releaseTag) || update.ChecksumUrl != update.InstallerUrl + ".sha256")
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
            try { Storage.StorageMaintenanceService.CleanDownloads(destinationDirectory, target); }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { /* Cache cleanup must not invalidate a verified download. */ }
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
        uri.IsDefaultPort && string.IsNullOrEmpty(uri.UserInfo) &&
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
