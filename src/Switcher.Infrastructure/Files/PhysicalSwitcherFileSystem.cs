using Switcher.Core.Abstractions;

namespace Switcher.Infrastructure.Files;

public sealed class PhysicalSwitcherFileSystem : ISwitcherFileSystem
{
    public bool FileExists(string path)
    {
        try { return (File.GetAttributes(path) & FileAttributes.Directory) == 0; }
        catch (FileNotFoundException) { return false; }
        catch (DirectoryNotFoundException) { return false; }
    }
    public bool DirectoryExists(string path) => Directory.Exists(path);
    public byte[] ReadAllBytes(string path) => File.ReadAllBytes(path);
    public string ReadAllText(string path) => File.ReadAllText(path, new System.Text.UTF8Encoding(false, true));
    public DateTimeOffset GetLastWriteTimeUtc(string path) => File.GetLastWriteTimeUtc(path);
    public void CreateDirectory(string path) => Directory.CreateDirectory(path);
    public IEnumerable<string> EnumerateFiles(string path, string pattern, SearchOption option) => Directory.EnumerateFiles(path, pattern, option);
    public void DeleteFile(string path) { if (File.Exists(path)) File.Delete(path); }

    public void WriteAtomic(string path, ReadOnlySpan<byte> contents)
    {
        var fullPath = Path.GetFullPath(path);
        var directory = Path.GetDirectoryName(fullPath) ?? throw new IOException("目标文件没有父目录。");
        Directory.CreateDirectory(directory);
        var temporary = Path.Combine(directory, $".{Path.GetFileName(fullPath)}.{Guid.NewGuid():N}.tmp");
        try
        {
            using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None, 81920, FileOptions.WriteThrough))
            {
                stream.Write(contents);
                stream.Flush(flushToDisk: true);
            }
            if (File.Exists(fullPath))
            {
                try { File.Replace(temporary, fullPath, null, ignoreMetadataErrors: true); }
                catch (PlatformNotSupportedException) { File.Move(temporary, fullPath, overwrite: true); }
            }
            else File.Move(temporary, fullPath);
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }

    public bool TryCreateAtomic(string path, ReadOnlySpan<byte> contents)
    {
        var fullPath = Path.GetFullPath(path);
        var directory = Path.GetDirectoryName(fullPath) ?? throw new IOException("目标文件没有父目录。");
        Directory.CreateDirectory(directory);
        var temporary = Path.Combine(directory, $".{Path.GetFileName(fullPath)}.{Guid.NewGuid():N}.tmp");
        try
        {
            using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None, 81920, FileOptions.WriteThrough))
            {
                stream.Write(contents);
                stream.Flush(flushToDisk: true);
            }
            try { File.Move(temporary, fullPath, overwrite: false); return true; }
            catch (IOException) when (File.Exists(fullPath)) { return false; }
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }
}
