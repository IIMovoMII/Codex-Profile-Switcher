using System.Text.RegularExpressions;

namespace Switcher.Core.Updates;

public static class ReleaseAnnouncement
{
    public const int MaxCharacters = 64 * 1024;
    public static string CurrentVersion => typeof(ReleaseAnnouncement).Assembly.GetName().Version?.ToString(3) ?? "0.0.0";
    public static string CurrentMarkdown { get; } = ReadEmbedded();

    private static string ReadEmbedded()
    {
        using var stream = typeof(ReleaseAnnouncement).Assembly.GetManifestResourceStream("Switcher.Core.ReleaseNotes.md")
            ?? throw new InvalidDataException("安装包缺少当前版本公告。");
        using var reader = new StreamReader(stream);
        return reader.ReadToEnd();
    }

    public static string Normalize(string? markdown) =>
        markdown is not null && markdown.Length <= MaxCharacters ? markdown.ReplaceLineEndings("\n").Trim() : "";

    // The desktop displays text only; remote Markdown never loads images, HTML, or executable links.
    public static string ForDisplay(string markdown)
    {
        var text = Normalize(markdown);
        text = Regex.Replace(text, @"(?m)^#{1,6}\s+", "", RegexOptions.None, TimeSpan.FromSeconds(1));
        text = Regex.Replace(text, @"(?m)^[-*]\s+", "• ", RegexOptions.None, TimeSpan.FromSeconds(1));
        return text;
    }
}
