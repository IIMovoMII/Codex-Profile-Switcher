using System.Text.Json;

namespace Switcher.Infrastructure.Models;

public sealed record CatalogModelChoice(string Id, string DisplayName)
{
    public string Label => string.IsNullOrWhiteSpace(DisplayName) || DisplayName == Id ? Id : $"{DisplayName} · {Id}";
}

/// <summary>A read-only projection for the model selector; it never rewrites a catalog.</summary>
public static class CatalogChoiceReader
{
    public static IReadOnlyList<CatalogModelChoice> Read(string path)
    {
        if (!File.Exists(path)) return [];
        if (new FileInfo(path).Length > 32 * 1024 * 1024) throw new InvalidDataException("模型目录过大，暂不加载下拉列表；仍可输入模型 ID。");
        using var document = JsonDocument.Parse(File.ReadAllBytes(path));
        if (document.RootElement.ValueKind != JsonValueKind.Object || !document.RootElement.TryGetProperty("models", out var models) || models.ValueKind != JsonValueKind.Array)
            throw new InvalidDataException("需要包含完整 models 数组的 Codex 模型目录。");
        var result = new List<CatalogModelChoice>();
        foreach (var model in models.EnumerateArray())
        {
            if (model.ValueKind != JsonValueKind.Object) throw new InvalidDataException("模型目录的每个项目必须是对象。");
            string ReadText(string name) => model.TryGetProperty(name, out var node) && node.ValueKind == JsonValueKind.String ? node.GetString() ?? "" : "";
            var id = ReadText("slug");
            if (string.IsNullOrWhiteSpace(id)) id = ReadText("id");
            if (!string.IsNullOrWhiteSpace(id)) result.Add(new CatalogModelChoice(id, ReadText("display_name")));
        }
        return result.DistinctBy(item => item.Id, StringComparer.Ordinal).ToArray();
    }
}
