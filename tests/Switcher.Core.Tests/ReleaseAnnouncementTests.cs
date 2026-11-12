using Switcher.Core.Updates;

namespace Switcher.Core.Tests;

public sealed class ReleaseAnnouncementTests
{
    [Fact]
    public void Embedded_announcement_matches_the_versioned_release_file()
    {
        var root = new DirectoryInfo(AppContext.BaseDirectory);
        while (root is not null && !File.Exists(Path.Combine(root.FullName, "CodexProfileSwitcher.sln"))) root = root.Parent;
        Assert.NotNull(root);
        var path = Path.Combine(root.FullName, "docs", "zh-CN", "releases", ReleaseAnnouncement.CurrentVersion + ".md");
        Assert.Equal(ReleaseAnnouncement.Normalize(File.ReadAllText(path)), ReleaseAnnouncement.Normalize(ReleaseAnnouncement.CurrentMarkdown));
        Assert.Contains(ReleaseAnnouncement.CurrentVersion, ReleaseAnnouncement.CurrentMarkdown);
    }

    [Fact]
    public void Display_is_plain_text_and_oversized_announcements_are_rejected()
    {
        Assert.Equal("版本\n\n• 保留设置\n![图片](https://example.invalid/image)", ReleaseAnnouncement.ForDisplay("## 版本\r\n\r\n- 保留设置\r\n![图片](https://example.invalid/image)\n"));
        Assert.Empty(ReleaseAnnouncement.Normalize(null));
        Assert.Empty(ReleaseAnnouncement.Normalize(new string('a', ReleaseAnnouncement.MaxCharacters + 1)));
    }
}
