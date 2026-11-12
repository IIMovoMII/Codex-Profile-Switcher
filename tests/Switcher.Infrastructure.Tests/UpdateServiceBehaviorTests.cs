using System.Net;
using System.Security.Cryptography;
using System.Text;
using Switcher.Core.Updates;
using Switcher.Infrastructure.Updates;

namespace Switcher.Infrastructure.Tests;

public sealed class UpdateServiceBehaviorTests
{
    [Theory]
    [InlineData(HttpStatusCode.Forbidden)]
    [InlineData(HttpStatusCode.TooManyRequests)]
    public async Task Rate_limit_falls_back_to_official_release_page_without_repeating_exhausted_api(HttpStatusCode status)
    {
        var apiCalls = 0; var pageCalls = 0;
        using var client = new HttpClient(new DelegateHandler((request, _) =>
        {
            if (request.RequestUri!.Host == "api.github.com")
            {
                apiCalls++; var response = Response(request, status); response.Headers.Add("X-RateLimit-Remaining", "0"); return Task.FromResult(response);
            }
            pageCalls++;
            return Task.FromResult(ReleasePage(request));
        }));
        var result = await new GitHubUpdateService(client, "0.3.0").CheckAsync();
        Assert.Equal(1, apiCalls); Assert.Equal(3, pageCalls); Assert.True(result.IsNewer);
        Assert.Equal("0.4.0", result.LatestVersion); Assert.EndsWith("0.4.0.exe", result.InstallerUrl);
        Assert.Equal(result.InstallerUrl + ".sha256", result.ChecksumUrl); Assert.Contains("限流", result.Message); Assert.Contains("官方发布页", result.Message);
        Assert.Equal("## 合成公告\n\n- 保留模型目录", result.ReleaseNotes);
    }

    [Fact]
    public async Task Api_timeouts_are_bounded_and_can_use_the_release_page()
    {
        var apiCalls = 0;
        using var client = new HttpClient(new DelegateHandler(async (request, token) =>
        {
            if (request.RequestUri!.Host != "api.github.com") return ReleasePage(request);
            apiCalls++; await Task.Delay(Timeout.InfiniteTimeSpan, token); throw new InvalidOperationException("unreachable");
        }));
        var result = await new GitHubUpdateService(client, "0.3.0", requestTimeout: TimeSpan.FromMilliseconds(30)).CheckAsync();
        Assert.Equal(3, apiCalls); Assert.True(result.IsNewer); Assert.Contains("超时", result.Message);
    }

    [Fact]
    public async Task Overall_timeout_and_user_cancellation_are_distinct_and_never_report_latest()
    {
        using var client = new HttpClient(new DelegateHandler(async (_, token) => { await Task.Delay(Timeout.InfiniteTimeSpan, token); throw new InvalidOperationException(); }));
        var service = new GitHubUpdateService(client, "0.3.0", checkTimeout: TimeSpan.FromMilliseconds(70));
        var error = await Assert.ThrowsAsync<HttpRequestException>(() => service.CheckAsync());
        Assert.Contains("超时", error.Message); Assert.DoesNotContain("最新", error.Message);
        using var cancellation = new CancellationTokenSource(); cancellation.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => service.CheckAsync(cancellation.Token));
    }

    [Theory]
    [InlineData("https://evil.invalid/releases/tag/v0.4.0")]
    [InlineData("https://github.com/other/other/releases/tag/v0.4.0")]
    [InlineData("https://github.com/IIMovoMII/Codex-Profile-Switcher/releases/tag/invalid")]
    public async Task Fallback_rejects_untrusted_or_invalid_release_destinations(string destination)
    {
        using var client = new HttpClient(new DelegateHandler((request, _) => Task.FromResult(request.RequestUri!.Host == "api.github.com" ? Response(request, HttpStatusCode.Forbidden) :
            Response(new HttpRequestMessage(HttpMethod.Get, destination), HttpStatusCode.OK, "untrusted"))));
        var error = await Assert.ThrowsAsync<HttpRequestException>(() => new GitHubUpdateService(client, "0.3.0").CheckAsync());
        Assert.Contains("不可信", error.Message);
    }

    [Fact]
    public async Task Malformed_api_response_uses_fallback_and_external_assets_are_ignored()
    {
        using var client = new HttpClient(new DelegateHandler((request, _) => Task.FromResult(request.RequestUri!.Host == "api.github.com" ? Response(request, HttpStatusCode.OK, "not json") :
            request.RequestUri.AbsolutePath.Contains("expanded_assets", StringComparison.Ordinal) ? Response(request, HttpStatusCode.OK, "<a href='https://evil.invalid/Codex-Profile-Switcher-Setup-0.4.0.exe'>wrong</a>") : ReleasePage(request))));
        var result = await new GitHubUpdateService(client, "0.3.0").CheckAsync();
        Assert.True(result.IsNewer); Assert.Null(result.InstallerUrl); Assert.Null(result.ChecksumUrl); Assert.Contains("缺少", result.Message);
    }

    private static HttpResponseMessage ReleasePage(HttpRequestMessage request)
    {
        const string release = "https://github.com/IIMovoMII/Codex-Profile-Switcher/releases/tag/v0.4.0";
        const string asset = "/IIMovoMII/Codex-Profile-Switcher/releases/download/v0.4.0/Codex-Profile-Switcher-Setup-0.4.0.exe";
        if (request.RequestUri!.Host == "raw.githubusercontent.com") return Response(request, HttpStatusCode.OK, "## 合成公告\n\n- 保留模型目录\n");
        return request.RequestUri.AbsolutePath.Contains("expanded_assets", StringComparison.Ordinal)
            ? Response(request, HttpStatusCode.OK, $"<a href='{asset}'>installer</a><a href=\"{asset}.sha256\">sha256</a><a href='https://evil.invalid/wrong.exe'>wrong</a>")
            : Response(new HttpRequestMessage(HttpMethod.Get, release), HttpStatusCode.OK, "synthetic release page");
    }

    [Fact]
    public async Task Api_announcement_is_the_release_body_and_does_not_need_an_extra_request()
    {
        var calls = 0;
        using var client = new HttpClient(new DelegateHandler((request, _) =>
        {
            calls++;
            const string json = """{"tag_name":"v0.4.0","html_url":"https://github.com/IIMovoMII/Codex-Profile-Switcher/releases/tag/v0.4.0","body":"## 新公告\r\n\r\n- 完整正文\r\n","assets":[]}""";
            return Task.FromResult(Response(request, HttpStatusCode.OK, json));
        }));
        var result = await new GitHubUpdateService(client, "0.3.0").CheckAsync();
        Assert.Equal(1, calls); Assert.Equal("## 新公告\n\n- 完整正文", result.ReleaseNotes);
        Assert.True(result.IsNewer);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task Announcement_timeout_preserves_verified_metadata_but_user_cancel_still_cancels(bool cancelByUser)
    {
        using var cancellation = new CancellationTokenSource();
        using var client = new HttpClient(new DelegateHandler(async (request, token) =>
        {
            if (request.RequestUri!.Host == "api.github.com") return Response(request, HttpStatusCode.Forbidden);
            if (request.RequestUri.Host != "raw.githubusercontent.com") return ReleasePage(request);
            if (cancelByUser) cancellation.Cancel();
            await Task.Delay(Timeout.InfiniteTimeSpan, token); throw new InvalidOperationException();
        }));
        var service = new GitHubUpdateService(client, "0.3.0", checkTimeout: TimeSpan.FromMilliseconds(300));
        if (cancelByUser) await Assert.ThrowsAnyAsync<OperationCanceledException>(() => service.CheckAsync(cancellation.Token));
        else
        {
            var result = await service.CheckAsync(cancellation.Token);
            Assert.True(result.IsNewer); Assert.NotNull(result.InstallerUrl); Assert.Empty(result.ReleaseNotes);
        }
    }

    [Theory]
    [InlineData("404")]
    [InlineData("timeout")]
    [InlineData("redirect")]
    [InlineData("oversize")]
    public async Task Optional_announcement_failure_never_discards_the_verified_update(string failure)
    {
        using var client = new HttpClient(new DelegateHandler(async (request, token) =>
        {
            if (request.RequestUri!.Host == "api.github.com") return Response(request, HttpStatusCode.Forbidden);
            if (request.RequestUri.Host != "raw.githubusercontent.com") return ReleasePage(request);
            Assert.Equal("/IIMovoMII/Codex-Profile-Switcher/refs/tags/v0.4.0/docs/zh-CN/releases/0.4.0.md", request.RequestUri.AbsolutePath);
            if (failure == "timeout") { await Task.Delay(Timeout.InfiniteTimeSpan, token); throw new InvalidOperationException(); }
            if (failure == "redirect") return Response(new HttpRequestMessage(HttpMethod.Get, "https://evil.invalid/notes.md"), HttpStatusCode.OK, "untrusted");
            if (failure == "oversize") return Response(request, HttpStatusCode.OK, new string('x', ReleaseAnnouncement.MaxCharacters + 1));
            return Response(request, HttpStatusCode.NotFound);
        }));
        var result = await new GitHubUpdateService(client, "0.3.0", requestTimeout: TimeSpan.FromMilliseconds(100)).CheckAsync();
        Assert.True(result.IsNewer); Assert.NotNull(result.InstallerUrl); Assert.NotNull(result.ChecksumUrl); Assert.Empty(result.ReleaseNotes);
    }

    [Fact]
    public async Task Check_retries_transient_errors_and_ignores_untrusted_asset_urls()
    {
        var calls = 0;
        using var client = new HttpClient(new DelegateHandler((request, _) =>
        {
            calls++;
            if (calls < 3) return Task.FromResult(Response(request, HttpStatusCode.ServiceUnavailable));
            const string json = """{"tag_name":"v0.4.0","html_url":"https://github.com/IIMovoMII/Codex-Profile-Switcher/releases/tag/v0.4.0","assets":[{"name":"Codex-Profile-Switcher-Setup-0.4.0.exe","browser_download_url":"https://evil.invalid/setup.exe"},{"name":"Codex-Profile-Switcher-Setup-0.4.0.exe.sha256","browser_download_url":"https://github.com/IIMovoMII/Codex-Profile-Switcher/releases/download/v0.4.0/setup.sha256"}]}""";
            return Task.FromResult(Response(request, HttpStatusCode.OK, json));
        }));
        var service = new GitHubUpdateService(client, "0.3.0");

        var result = await service.CheckAsync();

        Assert.Equal(3, calls);
        Assert.True(result.IsNewer);
        Assert.Null(result.InstallerUrl);
        Assert.NotNull(result.ChecksumUrl);
        Assert.Contains("缺少", result.Message);
    }

    [Fact]
    public async Task Download_rejects_untrusted_redirects_and_removes_partial_files()
    {
        var bytes = Encoding.UTF8.GetBytes("synthetic installer bytes");
        var handler = new DelegateHandler((request, _) =>
        {
            var response = new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(bytes) };
            response.RequestMessage = new HttpRequestMessage(HttpMethod.Get, "https://evil.invalid/setup.exe");
            return Task.FromResult(response);
        });
        using var client = new HttpClient(handler);
        var service = new GitHubUpdateService(client, "0.3.0");
        var folder = Path.Combine(Path.GetTempPath(), "updates (isolated) " + Guid.NewGuid().ToString("N"));
        var update = CreateUpdate("https://github.com/IIMovoMII/Codex-Profile-Switcher/releases/download/v0.4.0/Codex-Profile-Switcher-Setup-0.4.0.exe");

        try
        {
            await Assert.ThrowsAsync<InvalidDataException>(() => service.DownloadAndVerifyAsync(update, folder));
            Assert.Empty(Directory.EnumerateFiles(folder));
        }
        finally { if (Directory.Exists(folder)) Directory.Delete(folder, recursive: true); }
    }

    [Fact]
    public async Task Download_rejects_other_repositories_before_sending_a_request_or_creating_files()
    {
        var calls = 0;
        using var client = new HttpClient(new DelegateHandler((request, _) => { calls++; return Task.FromResult(Response(request, HttpStatusCode.OK)); }));
        var folder = Path.Combine(Path.GetTempPath(), "SwitcherUntrustedDownload-" + Guid.NewGuid().ToString("N"));
        var error = await Assert.ThrowsAsync<InvalidOperationException>(() => new GitHubUpdateService(client, "0.3.0").DownloadAndVerifyAsync(
            CreateUpdate("https://github.com/other/other/releases/download/v0.4.0/Codex-Profile-Switcher-Setup-0.4.0.exe"), folder));
        Assert.Contains("可验证更新", error.Message); Assert.Equal(0, calls); Assert.False(Directory.Exists(folder));
    }

    [Fact]
    public async Task Download_requires_filename_matching_sha256_and_detects_post_verification_changes()
    {
        var bytes = Encoding.UTF8.GetBytes("synthetic installer bytes");
        var hash = Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();
        var handler = new DelegateHandler((request, _) =>
        {
            if (request.RequestUri!.AbsolutePath.EndsWith(".exe.sha256", StringComparison.Ordinal))
                return Task.FromResult(Response(request, HttpStatusCode.OK, hash + "  Codex-Profile-Switcher-Setup-0.4.0.exe\n"));
            return Task.FromResult(Response(request, HttpStatusCode.OK, bytes));
        });
        using var client = new HttpClient(handler);
        var service = new GitHubUpdateService(client, "0.3.0");
        var folder = Path.Combine(Path.GetTempPath(), "updates verified " + Guid.NewGuid().ToString("N"));

        try
        {
            var path = await service.DownloadAndVerifyAsync(CreateUpdate("https://github.com/IIMovoMII/Codex-Profile-Switcher/releases/download/v0.4.0/Codex-Profile-Switcher-Setup-0.4.0.exe"), folder);
            Assert.Equal(bytes, await File.ReadAllBytesAsync(path));
            await File.WriteAllTextAsync(path, "changed after verification");
            await Assert.ThrowsAsync<InvalidDataException>(() => service.LaunchInstallerAsync(path));
        }
        finally { if (Directory.Exists(folder)) Directory.Delete(folder, recursive: true); }
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task Download_timeout_or_wrong_hash_never_leaves_a_partial_installer(bool timeout)
    {
        using var client = new HttpClient(new DelegateHandler(async (request, token) =>
        {
            if (timeout) await Task.Delay(Timeout.InfiniteTimeSpan, token);
            return Response(request, HttpStatusCode.OK, request.RequestUri!.AbsolutePath.EndsWith("sha256", StringComparison.Ordinal) ? new string('0', 64) + "  Codex-Profile-Switcher-Setup-0.4.0.exe" : "installer");
        })) { Timeout = TimeSpan.FromMilliseconds(60) };
        var service = new GitHubUpdateService(client, "0.3.0");
        var directory = Path.Combine(Path.GetTempPath(), "SwitcherDownloadFailure-" + Guid.NewGuid().ToString("N"));
        try
        {
            var task = service.DownloadAndVerifyAsync(CreateUpdate("https://github.com/IIMovoMII/Codex-Profile-Switcher/releases/download/v0.4.0/Codex-Profile-Switcher-Setup-0.4.0.exe"), directory);
            if (timeout) await Assert.ThrowsAnyAsync<OperationCanceledException>(() => task);
            else await Assert.ThrowsAsync<InvalidDataException>(() => task);
            Assert.Empty(Directory.EnumerateFiles(directory));
        }
        finally { if (Directory.Exists(directory)) Directory.Delete(directory, true); }
    }

    private static UpdateInfo CreateUpdate(string installerUrl) => new("0.3.0", "0.4.0",
        "https://github.com/IIMovoMII/Codex-Profile-Switcher/releases/tag/v0.4.0", installerUrl,
        installerUrl + ".sha256", true, "synthetic update");

    private static HttpResponseMessage Response(HttpRequestMessage request, HttpStatusCode status, string? content = null)
    {
        var response = new HttpResponseMessage(status) { RequestMessage = request };
        if (content is not null) response.Content = new StringContent(content, Encoding.UTF8, "application/json");
        return response;
    }

    private static HttpResponseMessage Response(HttpRequestMessage request, HttpStatusCode status, byte[] content)
    {
        var response = new HttpResponseMessage(status) { RequestMessage = request, Content = new ByteArrayContent(content) };
        return response;
    }

    private sealed class DelegateHandler(Func<HttpRequestMessage, CancellationToken, Task<HttpResponseMessage>> handler) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) => handler(request, cancellationToken);
    }
}
