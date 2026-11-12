using System.Net;
using System.Security.Cryptography;
using System.Text;
using Switcher.Core.Updates;
using Switcher.Infrastructure.Updates;

namespace Switcher.Infrastructure.Tests;

public sealed class UpdateServiceBehaviorTests
{
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
