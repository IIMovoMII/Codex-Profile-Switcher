using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Switcher.Core.Paths;
using Switcher.Core.Profiles;
using Switcher.Infrastructure.CodexAdapters;
using Switcher.Infrastructure.Files;
using Switcher.Infrastructure.Profiles;
using Switcher.Core.Abstractions;

namespace Switcher.Infrastructure.Tests;

public sealed class DesktopStateAdapterBehaviorTests
{
    [Fact]
    public void Official_account_state_is_private_projects_are_shared_and_unknown_preferences_survive()
    {
        var root = Path.Combine(Path.GetTempPath(), "desktop-state-adapter-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            var paths = SwitcherPaths.FromEnvironment(Path.Combine(root, "codex home"), Path.Combine(root, "switcher data"));
            var files = new PhysicalSwitcherFileSystem();
            var adapter = new DesktopStateAdapter(files, new TestProtector(), paths);
            var authA = CreateOfficialAuth("desktop-a");
            var authB = CreateOfficialAuth("desktop-b");
            var ownerA = new CodexAuthClassifier().GetOfficialOwner(authA);
            var ownerB = new CodexAuthClassifier().GetOfficialOwner(authB);
            var globalPath = paths.DesktopGlobalStateFile;
            files.WriteAtomic(globalPath, JsonSerializer.SerializeToUtf8Bytes(new Dictionary<string, object?>
            {
                ["electron-persisted-atom-state"] = new Dictionary<string, object?>
                {
                    ["account-selection"] = "account-a",
                    ["thread-sort-key"] = "updated_at"
                },
                ["local-projects"] = new Dictionary<string, object?> { ["project-a"] = new Dictionary<string, object?> { ["name"] = "A" } },
                ["project-order"] = new[] { "project-a" },
                ["future-user-preference"] = new Dictionary<string, object?> { ["value"] = "keep" }
            }));

            Apply(adapter.CreatePlan(ProfileKind.Official, authA, authB, authA).Files, files);
            var afterAtoB = JsonNode.Parse(files.ReadAllBytes(globalPath))!;
            Assert.Null(afterAtoB["electron-persisted-atom-state"]!["account-selection"]);
            Assert.Equal("updated_at", afterAtoB["electron-persisted-atom-state"]!["thread-sort-key"]!.GetValue<string>());
            Assert.NotNull(afterAtoB["local-projects"]!["project-a"]);
            Assert.Equal("keep", afterAtoB["future-user-preference"]!["value"]!.GetValue<string>());

            afterAtoB["electron-persisted-atom-state"]!["account-selection"] = "account-b";
            afterAtoB["local-projects"]!["project-b"] = JsonNode.Parse("{\"name\":\"B\"}");
            files.WriteAtomic(globalPath, Encoding.UTF8.GetBytes(afterAtoB.ToJsonString()));
            Apply(adapter.CreatePlan(ProfileKind.Official, authB, authA, authA).Files, files);

            var afterBtoA = JsonNode.Parse(files.ReadAllBytes(globalPath))!;
            Assert.Equal("account-a", afterBtoA["electron-persisted-atom-state"]!["account-selection"]!.GetValue<string>());
            Assert.NotNull(afterBtoA["local-projects"]!["project-a"]);
            Assert.NotNull(afterBtoA["local-projects"]!["project-b"]);
            Assert.Equal("keep", afterBtoA["future-user-preference"]!["value"]!.GetValue<string>());

            var archive = JsonNode.Parse(files.ReadAllBytes(paths.DesktopRendererArchiveFile))!;
            Assert.NotNull(archive["profiles"]![ownerA]);
            Assert.NotNull(archive["profiles"]![ownerB]);
            Assert.Equal("account-b", archive["profiles"]![ownerB]!["atoms"]!["account-selection"]!.GetValue<string>());
        }
        finally { try { Directory.Delete(root, recursive: true); } catch (IOException) { } }
    }

    private static void Apply(IEnumerable<Switcher.Core.Switching.FileMutation> mutations, PhysicalSwitcherFileSystem files)
    {
        foreach (var mutation in mutations)
        {
            if (mutation.TargetBytes is null) files.DeleteFile(mutation.Path);
            else files.WriteAtomic(mutation.Path, mutation.TargetBytes);
        }
    }

    private static string CreateOfficialAuth(string suffix)
    {
        var claims = JsonSerializer.Serialize(new Dictionary<string, object?>
        {
            ["email"] = $"desktop-{suffix}@example.invalid",
            ["https://api.openai.com/auth"] = new Dictionary<string, object?>
            {
                ["chatgpt_account_id"] = $"desktop-account-{suffix}",
                ["chatgpt_user_id"] = $"desktop-user-{suffix}",
                ["chatgpt_plan_type"] = "plus"
            }
        });
        var payload = Convert.ToBase64String(Encoding.UTF8.GetBytes(claims)).TrimEnd('=').Replace('+', '-').Replace('/', '_');
        return JsonSerializer.Serialize(new { auth_mode = "chatgpt", tokens = new { id_token = $"test.{payload}.signature", account_id = $"desktop-account-{suffix}", access_token = "synthetic-access", refresh_token = "synthetic-refresh" } });
    }

    private sealed class TestProtector : ISecretProtector
    {
        public byte[] Protect(ReadOnlySpan<byte> plaintext) => plaintext.ToArray();
        public byte[] Unprotect(ReadOnlySpan<byte> ciphertext) => ciphertext.ToArray();
    }
}
