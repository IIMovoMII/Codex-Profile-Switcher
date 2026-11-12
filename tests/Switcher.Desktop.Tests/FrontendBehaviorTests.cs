using System.IO;
using System.Text.Json;
using System.Threading;
using System.Windows.Threading;
using Switcher.Core.Configuration;
using Switcher.Core.Paths;
using Switcher.Core.Profiles;
using Switcher.Core.Switching;
using Switcher.Core.Updates;
using Switcher.Desktop;
using Switcher.Infrastructure;
using Switcher.Infrastructure.Models;

namespace Switcher.Desktop.Tests;

public sealed class FrontendBehaviorTests
{
    [Fact]
    public Task Manual_location_selection_is_only_available_after_a_location_becomes_invalid() => Sta(async () =>
    {
        using var fixture = new Fixture(); Directory.CreateDirectory(fixture.Paths.DataDirectory);
        var model = new MainViewModel(fixture.Host); var selected = 0; model.SelectFallbackLocations = _ => selected++;
        await model.RecheckDataLocationsCommand.ExecuteAsync(null); Assert.False(model.HasUnavailableLocations);
        model.SelectFallbackFolderCommand.Execute(null); Assert.Equal(0, selected);
        Directory.Delete(fixture.Paths.CodexHome);
        await model.RecheckDataLocationsCommand.ExecuteAsync(null); Assert.True(model.HasUnavailableLocations); Assert.Contains("不可用", model.LocationMessage);
        model.SelectFallbackFolderCommand.Execute(null); Assert.Equal(1, selected);
        Assert.False(Directory.Exists(fixture.Paths.CodexHome));
    });

    [Fact]
    public Task Cards_identify_live_authentication_instead_of_the_last_saved_pointer_and_filter_by_name_or_host() => Sta(async () =>
    {
        using var fixture = new Fixture();
        var first = fixture.Host.Profiles.AddApi(new("工作接口", "https://work.example/v1", "synthetic-key-one"));
        var second = fixture.Host.Profiles.AddApi(new("备用接口", "https://backup.example/v1", "synthetic-key-two"));
        fixture.Live("synthetic-key-one", "https://work.example/v1");
        var model = new MainViewModel(fixture.Host);
        Assert.Equal(second.Id, fixture.Host.Registry.Load().ActiveApiProfileId);
        Assert.True(model.Profiles.Single(item => item.Id == first.Id).IsCurrent);
        Assert.False(model.Profiles.Single(item => item.Id == second.Id).IsCurrent);
        Assert.Equal("工作接口 · API", model.CurrentAccount);
        model.SearchText = "backup.example";
        Assert.Equal(second.Id, Assert.Single(model.Profiles).Id);
        model.AccountFilter = "official"; Assert.Empty(model.Profiles); Assert.True(model.HasNoProfiles);
        model.AccountFilter = "all"; model.SearchText = "工作"; Assert.Equal(first.Id, Assert.Single(model.Profiles).Id);
        Assert.Equal("synthetic-key-one", JsonDocument.Parse(File.ReadAllText(fixture.Paths.AuthFile)).RootElement.GetProperty("OPENAI_API_KEY").GetString());
        await Task.CompletedTask;
    });

    [Fact]
    public Task Drawer_saves_name_and_policies_together_without_touching_live_config_credentials_or_manual_catalog() => Sta(async () =>
    {
        using var fixture = new Fixture();
        var catalog = Path.Combine(fixture.Root, "自定义目录.json");
        const string content = "{\"models\":[{\"slug\":\"custom-model-a\",\"display_name\":\"完整目录\",\"unknown\":{\"single\":[1],\"none\":null}}]}";
        File.WriteAllText(catalog, content);
        var profile = fixture.Host.Profiles.AddApi(new("旧名称", "https://work.example/v1", "synthetic-key", catalog));
        fixture.Live("synthetic-key", "https://work.example/v1");
        var auth = File.ReadAllBytes(fixture.Paths.AuthFile); var config = File.ReadAllBytes(fixture.Paths.ConfigFile);
        var protector = new Switcher.Infrastructure.Security.CurrentUserDpapiProtector(fixture.Paths.CodexHome);
        var credential = protector.Unprotect(File.ReadAllBytes(Path.Combine(fixture.Paths.ProfileCredentialDirectory, profile.AuthFile)));
        var model = new MainViewModel(fixture.Host);
        model.ModelSettingsCommand.Execute(Assert.Single(model.Profiles));
        var editor = Assert.IsType<Switcher.Desktop.ViewModels.ProfileEditorViewModel>(model.Editor);
        await Loaded(editor);
        Assert.Equal(1, editor.SelectedTab);
        Assert.Equal(catalog, editor.ResolvedCatalogPath);
        Assert.Equal("custom-model-a", Assert.Single(editor.Models).Id);
        editor.ProfileName = "新名称"; editor.ModelPolicy = "explicit"; editor.ModelId = "custom-model-a";
        editor.ContextPolicy = "preserve"; editor.ProxyPolicy = "preserve";
        await model.SaveEditorCommand.ExecuteAsync(null);
        Assert.Null(model.Editor);
        var saved = (ApiProfile)fixture.Host.Registry.Load().Find(ProfileKind.Api, profile.Id);
        Assert.Equal("新名称", saved.Name); Assert.Equal(catalog, saved.ModelCatalogJson);
        Assert.Equal(SettingChoiceKind.Explicit, saved.ToSettings().Model.Kind);
        Assert.Equal("custom-model-a", saved.ToSettings().Model.Value);
        Assert.Equal(content, File.ReadAllText(catalog));
        Assert.Equal(auth, File.ReadAllBytes(fixture.Paths.AuthFile)); Assert.Equal(config, File.ReadAllBytes(fixture.Paths.ConfigFile));
        Assert.Equal(credential, protector.Unprotect(File.ReadAllBytes(Path.Combine(fixture.Paths.ProfileCredentialDirectory, profile.AuthFile))));
    });

    [Fact]
    public Task Cancel_discards_draft_and_external_edits_are_never_overwritten() => Sta(async () =>
    {
        using var fixture = new Fixture();
        fixture.Host.Profiles.AddApi(new("接口", "https://work.example/v1", "synthetic-key"));
        var model = new MainViewModel(fixture.Host);
        var row = Assert.Single(model.Profiles); var before = File.ReadAllBytes(fixture.Paths.RegistryFile);
        model.EditProfileCommand.Execute(row); model.Editor!.ProfileName = "未保存";
        model.Confirm = (_, _) => false; model.CloseEditorCommand.Execute(null); Assert.NotNull(model.Editor);
        model.Confirm = (_, _) => true; model.CloseEditorCommand.Execute(null); Assert.Null(model.Editor);
        Assert.Equal(before, File.ReadAllBytes(fixture.Paths.RegistryFile));
        model.EditProfileCommand.Execute(row); model.Editor!.ProfileName = "本窗口";
        fixture.Host.Profiles.Rename(ProfileKind.Api, row.Id, "另一个窗口");
        await model.SaveEditorCommand.ExecuteAsync(null);
        Assert.NotNull(model.Editor); Assert.Contains("其他窗口", model.Editor.ValidationMessage);
        Assert.Equal("另一个窗口", fixture.Host.Registry.Load().Find(ProfileKind.Api, row.Id).Name);
        Assert.False(File.Exists(fixture.Paths.DefaultManualModelCatalogFile));
    });

    [Fact]
    public Task No_official_account_is_required_and_changing_catalog_mode_preserves_the_manual_path() => Sta(async () =>
    {
        using var fixture = new Fixture();
        var path = Path.Combine(fixture.Root, "manual models.json");
        File.WriteAllText(path, "{\"models\":[{\"slug\":\"custom-a\"}]} ");
        fixture.Host.Profiles.AddApi(new("接口", "https://work.example/v1", "synthetic-key", path));
        var model = new MainViewModel(fixture.Host); model.ModelSettingsCommand.Execute(Assert.Single(model.Profiles));
        var editor = model.Editor!; await Loaded(editor);
        Assert.True(editor.HasNoOfficials); Assert.Equal(path, editor.CreateRequest().ManualPath);
        editor.CatalogMode = "official";
        Assert.Throws<InvalidDataException>(() => editor.CreateRequest());
        editor.CatalogMode = "manual"; await Loaded(editor);
        Assert.Equal(path, editor.ManualPath); Assert.Single(editor.Models);
        editor.ManualPath = ""; await Loaded(editor);
        Assert.Equal(fixture.Paths.DefaultManualModelCatalogFile, editor.ResolvedCatalogPath);
        Assert.Contains("尚未配置", editor.CatalogStatus); Assert.False(File.Exists(fixture.Paths.DefaultManualModelCatalogFile));
        Assert.Equal("manual", editor.CreateRequest().CatalogMode);
    });

    [Fact]
    public Task Update_page_retries_failures_and_requires_separate_download_and_install_confirmations() => Sta(async () =>
    {
        using var fixture = new Fixture(); var updates = new FakeUpdates();
        var model = new MainViewModel(fixture.Host, updates);
        await model.CheckUpdatesCommand.ExecuteAsync(null);
        Assert.Contains("暂未完成", model.UpdateTitle); Assert.False(model.CanDownload);
        await model.CheckUpdatesCommand.ExecuteAsync(null);
        Assert.True(model.HasNewVersion); Assert.True(model.CanDownload);
        model.Confirm = (_, _) => false; await model.DownloadUpdateCommand.ExecuteAsync(null); Assert.Equal(0, updates.Downloads);
        model.Confirm = (_, _) => true; await model.DownloadUpdateCommand.ExecuteAsync(null);
        Assert.True(model.CanInstall); Assert.False(model.CanDownload); Assert.Equal(1, updates.Downloads); Assert.Equal(0, updates.Installs);
        model.Confirm = (_, _) => false; await model.InstallUpdateCommand.ExecuteAsync(null); Assert.Equal(0, updates.Installs);
        model.Confirm = (_, _) => true; await model.InstallUpdateCommand.ExecuteAsync(null); Assert.Equal(1, updates.Installs);
        Assert.False(model.IsBusy); Assert.True(model.IsIdle); Assert.NotEmpty(model.Records);
    });

    [Fact]
    public void Catalog_choices_are_a_read_only_projection_and_reject_invalid_shape()
    {
        using var fixture = new Fixture(); var path = Path.Combine(fixture.Root, "catalog.json");
        const string content = "{\"models\":[{\"slug\":\"alpha\",\"display_name\":\"甲\",\"unknown\":[null]},{\"id\":\"beta\"},{\"slug\":\"alpha\"}]}";
        File.WriteAllText(path, content);
        Assert.Equal(new[] { "alpha", "beta" }, CatalogChoiceReader.Read(path).Select(item => item.Id));
        Assert.Equal(content, File.ReadAllText(path));
        File.WriteAllText(path, "{\"models\":\"wrong\"}");
        Assert.Throws<InvalidDataException>(() => CatalogChoiceReader.Read(path));
        File.WriteAllText(path, "[]");
        Assert.Throws<InvalidDataException>(() => CatalogChoiceReader.Read(path));
    }

    [Fact]
    public Task Announcements_start_offline_sync_from_release_and_survive_check_failure() => Sta(async () =>
    {
        using var fixture = new Fixture(); var updates = new FakeUpdates();
        var model = new MainViewModel(fixture.Host, updates);
        Assert.Equal(ReleaseAnnouncement.ForDisplay(ReleaseAnnouncement.CurrentMarkdown), model.ReleaseNotesText);
        await model.CheckUpdatesCommand.ExecuteAsync(null);
        Assert.Contains("当前版本公告", model.ReleaseNotesTitle);
        await model.CheckUpdatesCommand.ExecuteAsync(null);
        Assert.Equal("新版本公告 · v9.0.0", model.ReleaseNotesTitle);
        Assert.Equal("合成版本公告\n\n• 同步 GitHub 正文", model.ReleaseNotesText);
        updates.FailNext = true; await model.CheckUpdatesCommand.ExecuteAsync(null);
        Assert.Equal("合成版本公告\n\n• 同步 GitHub 正文", model.ReleaseNotesText);
    });

    private sealed class FakeUpdates : IUpdateService
    {
        private int _checks;
        public int Downloads { get; private set; }
        public int Installs { get; private set; }
        public bool FailNext { get; set; }
        public Task<UpdateInfo> CheckAsync(CancellationToken cancellationToken = default)
        {
            if (++_checks == 1 || FailNext) { FailNext = false; throw new TimeoutException("synthetic timeout"); }
            return Task.FromResult(new UpdateInfo("0.3.8", "9.0.0", "https://github.com/example/example/releases/tag/v9.0.0", "https://github.com/example/setup.exe", "https://github.com/example/setup.exe.sha256", true, "合成更新") { ReleaseNotes = "## 合成版本公告\n\n- 同步 GitHub 正文" });
        }
        public Task<string> DownloadAndVerifyAsync(UpdateInfo update, string destinationDirectory, IProgress<SwitchProgress>? progress = null, CancellationToken cancellationToken = default)
        {
            Downloads++; return Task.FromResult(Path.Combine(destinationDirectory, "synthetic-verified.exe"));
        }
        public Task LaunchInstallerAsync(string installerPath, CancellationToken cancellationToken = default) { Installs++; return Task.CompletedTask; }
    }

    private static async Task Loaded(Switcher.Desktop.ViewModels.ProfileEditorViewModel editor)
    {
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(5));
        while (editor.IsCatalogLoading) await Task.Delay(10, timeout.Token);
    }
    private static Task Sta(Func<Task> test)
    {
        var completion = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var thread = new Thread(() =>
        {
            SynchronizationContext.SetSynchronizationContext(new DispatcherSynchronizationContext());
            Dispatcher.CurrentDispatcher.BeginInvoke(async () =>
            {
                try { await test(); completion.SetResult(); } catch (Exception ex) { completion.SetException(ex); }
                finally { Dispatcher.CurrentDispatcher.BeginInvokeShutdown(DispatcherPriority.Background); }
            });
            Dispatcher.Run();
        });
        thread.SetApartmentState(ApartmentState.STA); thread.Start(); return completion.Task;
    }
    private sealed class Fixture : IDisposable
    {
        public string Root { get; } = Path.Combine(Path.GetTempPath(), "SwitcherFrontend-" + Guid.NewGuid().ToString("N"));
        public SwitcherPaths Paths { get; }
        public ApplicationHost Host { get; }
        public Fixture() { Paths = new(Path.Combine(Root, "codex home 中文"), Path.Combine(Root, "switcher data 中文")); Directory.CreateDirectory(Paths.CodexHome); Host = ApplicationHost.Create(Paths, Path.Combine(Root, "mock-not-used.exe")); }
        public void Live(string key, string url) { File.WriteAllText(Paths.AuthFile, JsonSerializer.Serialize(new { OPENAI_API_KEY = key })); File.WriteAllText(Paths.ConfigFile, "# user preferences\r\nmodel_provider = \"openai\"\r\nopenai_base_url = " + JsonSerializer.Serialize(url) + "\r\nmodel = \"keep\"\r\n"); }
        public void Dispose() { if (Directory.Exists(Root)) Directory.Delete(Root, true); }
    }
}
