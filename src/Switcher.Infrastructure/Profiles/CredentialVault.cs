using System.Text;
using System.Security.Cryptography;
using Switcher.Core.Abstractions;
using Switcher.Core.Paths;
using Switcher.Core.Profiles;
using Switcher.Infrastructure.Files;

namespace Switcher.Infrastructure.Profiles;

public sealed class CredentialVault(ISwitcherFileSystem files, ISecretProtector protector, ProfileRegistryStore registry, SwitcherPaths paths)
{
    public string Read(ProfileEntry profile, ProfileKind kind)
    {
        var path = registry.CredentialPath(profile);
        if (!files.FileExists(path)) throw new FileNotFoundException("档案凭据文件不存在。", path);
        var plaintext = protector.Unprotect(files.ReadAllBytes(path));
        try
        {
            var text = new UTF8Encoding(false, true).GetString(plaintext);
            var identity = CodexAuthAdapter.Inspect(text);
            if (identity.Kind != kind) throw new InvalidDataException("档案凭据类型与档案记录不一致。");
            if (kind == ProfileKind.Official && !string.Equals(identity.OfficialOwner, ((OfficialProfile)profile).Owner, StringComparison.Ordinal))
                throw new InvalidDataException("官方档案凭据身份与档案记录不一致。");
            return text;
        }
        finally { CryptographicOperations.ZeroMemory(plaintext); }
    }

    public byte[] ProtectText(string text)
    {
        var bytes = Encoding.UTF8.GetBytes(text);
        try { return protector.Protect(bytes); }
        finally { CryptographicOperations.ZeroMemory(bytes); }
    }

    public void Save(ProfileEntry profile, ProfileKind kind, string authJson)
    {
        var identity = CodexAuthAdapter.Inspect(authJson);
        if (identity.Kind != kind) throw new InvalidDataException("认证类型与目标档案不一致。");
        if (kind == ProfileKind.Official && !string.Equals(identity.OfficialOwner, ((OfficialProfile)profile).Owner, StringComparison.Ordinal))
            throw new InvalidDataException("新认证身份与目标官方档案不一致。");
        files.CreateDirectory(Path.GetDirectoryName(registry.CredentialPath(profile))!);
        var encrypted = ProtectText(authJson);
        files.WriteAtomic(registry.CredentialPath(profile), encrypted);
        CryptographicOperations.ZeroMemory(encrypted);
    }

    public string ReadLegacySnapshot(string fileName, ProfileKind expectedKind)
    {
        var path = Path.Combine(paths.DataDirectory, fileName);
        if (!files.FileExists(path)) throw new FileNotFoundException("旧档案认证快照不存在。", path);
        var plain = protector.Unprotect(files.ReadAllBytes(path));
        try
        {
            var auth = new UTF8Encoding(false, true).GetString(plain);
            if (CodexAuthAdapter.Inspect(auth).Kind != expectedKind) throw new InvalidDataException("旧认证快照类型不匹配。");
            return auth;
        }
        finally { CryptographicOperations.ZeroMemory(plain); }
    }
}
