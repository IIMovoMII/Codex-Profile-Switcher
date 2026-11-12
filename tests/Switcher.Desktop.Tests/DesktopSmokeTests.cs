using Switcher.Core.Profiles;
using Switcher.Core.Switching;
using Switcher.Desktop;

namespace Switcher.Desktop.Tests;

public sealed class DesktopSmokeTests
{
    [Fact]
    public void Desktop_project_targets_wpf_on_windows()
    {
        Assert.True(OperatingSystem.IsWindows());
    }

    [Fact]
    public void Catalog_row_exposes_actual_path_source_and_local_update_time()
    {
        var profile = new ApiProfile { Id = "api-one", Name = "Relay", ModelCatalogMode = "official" };
        var updated = DateTimeOffset.Parse("2026-11-12T02:03:04+00:00");
        var row = new ProfileRowViewModel(profile, ProfileKind.Api,
            new CatalogDisplay("跟随官方目录", @"C:\isolated\model catalog.json", true, "官方测试账号", updated.ToString("O"), "目录可用"));

        Assert.Equal(@"C:\isolated\model catalog.json", row.CatalogPath);
        Assert.Equal("官方测试账号", row.CatalogSource);
        Assert.Equal(updated.ToLocalTime().ToString("yyyy-MM-dd HH:mm:ss"), row.CatalogUpdated);
        Assert.Contains("来源：官方测试账号", row.CatalogMessage);
    }

    [Fact]
    public void Catalog_row_names_manual_maintenance_when_no_source_is_present()
    {
        var profile = new ApiProfile { Id = "api-one", Name = "Relay", ModelCatalogMode = "manual" };
        var row = new ProfileRowViewModel(profile, ProfileKind.Api,
            new CatalogDisplay("手动维护目录", @"C:\isolated\relay-models.json", false, "", "", "尚未配置目录，模型列表可能不完整"));

        Assert.Equal("手动维护文件", row.CatalogSource);
        Assert.Equal("未找到", row.CatalogUpdated);
        Assert.Equal(@"C:\isolated\relay-models.json", row.CatalogPath);
    }
}
