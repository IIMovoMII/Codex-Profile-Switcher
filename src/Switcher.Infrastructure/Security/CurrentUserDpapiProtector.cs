using System.Security.Cryptography;
using System.Text;
using Switcher.Core.Abstractions;

namespace Switcher.Infrastructure.Security;

public sealed class CurrentUserDpapiProtector : ISecretProtector
{
    public const string EntropyLabel = "CodexProfileSwitcher/v1";
    private readonly byte[] _entropy;

    public CurrentUserDpapiProtector(string codexHome)
    {
        // The legacy PowerShell implementation normalized CODEX_HOME before
        // deriving entropy. Keep that exact value or old snapshots cannot be
        // decrypted after switching implementations.
        var normalizedHome = Path.TrimEndingDirectorySeparator(Path.GetFullPath(codexHome));
        _entropy = Encoding.UTF8.GetBytes($"{EntropyLabel}|{normalizedHome}");
    }

    public byte[] Protect(ReadOnlySpan<byte> plaintext)
    {
        EnsureWindows();
        return ProtectedData.Protect(plaintext.ToArray(), _entropy, DataProtectionScope.CurrentUser);
    }

    public byte[] Unprotect(ReadOnlySpan<byte> ciphertext)
    {
        EnsureWindows();
        return ProtectedData.Unprotect(ciphertext.ToArray(), _entropy, DataProtectionScope.CurrentUser);
    }

    private static void EnsureWindows()
    {
        if (!OperatingSystem.IsWindows()) throw new PlatformNotSupportedException("Windows DPAPI 仅支持 Windows。");
    }
}
