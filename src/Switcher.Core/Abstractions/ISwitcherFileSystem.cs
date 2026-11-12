namespace Switcher.Core.Abstractions;

public interface ISwitcherFileSystem
{
    bool FileExists(string path);
    bool DirectoryExists(string path);
    byte[] ReadAllBytes(string path);
    string ReadAllText(string path);
    DateTimeOffset GetLastWriteTimeUtc(string path);
    void WriteAtomic(string path, ReadOnlySpan<byte> contents);
    bool TryCreateAtomic(string path, ReadOnlySpan<byte> contents);
    void DeleteFile(string path);
    void CreateDirectory(string path);
    IEnumerable<string> EnumerateFiles(string path, string pattern, SearchOption option);
}
