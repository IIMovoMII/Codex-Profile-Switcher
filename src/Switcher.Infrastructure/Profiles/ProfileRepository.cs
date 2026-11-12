using System.Security.Cryptography;
using Switcher.Core.Paths;
using Switcher.Core.Profiles;
using Switcher.Core.Switching;
using Switcher.Infrastructure.Switching;

namespace Switcher.Infrastructure.Profiles;

public sealed class ProfileRepository(
    ProfileRegistryStore registryStore,
    CredentialVault vault,
    SwitcherPaths paths,
    Switcher.Core.Abstractions.ISwitcherFileSystem files,
    AtomicSwitchExecutor executor) : IProfileRepository
{
    public ProfileRegistry Load() => registryStore.Load();
    public byte[] Serialize(ProfileRegistry registry) => registryStore.Serialize(registry);
    public void Save(ProfileRegistry registry) => registryStore.Save(registry);
    public string ReadAuthentication(ProfileEntry profile, ProfileKind kind) => vault.Read(profile, kind);
    public string GetCredentialPath(ProfileEntry profile) => registryStore.CredentialPath(profile);
    public string GetModelCatalogPath(ApiProfile profile) => registryStore.CatalogPath(profile);

    public void SaveProfile(ProfileRegistry registry, ProfileEntry profile, ProfileKind kind, string authenticationJson)
    {
        var identity = CodexAuthAdapter.Inspect(authenticationJson);
        if (identity.Kind != kind) throw new InvalidDataException("认证类型与档案类型不一致。");
        if (kind == ProfileKind.Official && !string.Equals(identity.OfficialOwner, ((OfficialProfile)profile).Owner, StringComparison.Ordinal)) throw new InvalidDataException("官方认证身份与档案不匹配。");
        var credentialPath = registryStore.CredentialPath(profile);
        var encrypted = vault.ProtectText(authenticationJson);
        try
        {
            var plan = BuildPlan("保存账号档案", registry,
            [
                new FileMutation(credentialPath, CurrentHash(credentialPath), encrypted, "保存 DPAPI 认证快照", files.FileExists(credentialPath)),
                new FileMutation(paths.RegistryFile, CurrentHash(paths.RegistryFile), registryStore.Serialize(registry), "保存档案注册表", files.FileExists(paths.RegistryFile))
            ]);
            executor.ExecuteAsync(plan, CancellationToken.None).GetAwaiter().GetResult();
        }
        finally { CryptographicOperations.ZeroMemory(encrypted); }
    }

    public void DeleteProfile(ProfileRegistry registry, ProfileEntry profile, ProfileKind kind)
    {
        var path = registryStore.CredentialPath(profile);
        var plan = BuildPlan("删除账号档案",
            registry,
            [
                new FileMutation(paths.RegistryFile, CurrentHash(paths.RegistryFile), registryStore.Serialize(registry), "更新档案注册表", files.FileExists(paths.RegistryFile)),
                new FileMutation(path, CurrentHash(path), null, "删除档案 DPAPI 凭据", files.FileExists(path))
            ]);
        executor.ExecuteAsync(plan, CancellationToken.None).GetAwaiter().GetResult();
        _ = kind;
    }

    private OperationPlan BuildPlan(string name, ProfileRegistry registry, IReadOnlyList<FileMutation> mutations)
    {
        registry.Validate(paths.CodexHome);
        var plan = new OperationPlan(Guid.NewGuid().ToString("N"), name, mutations, DateTimeOffset.UtcNow);
        plan.Validate();
        return plan;
    }

    private string? CurrentHash(string path) => files.FileExists(path) ? Convert.ToHexString(SHA256.HashData(files.ReadAllBytes(path))).ToLowerInvariant() : null;
}
