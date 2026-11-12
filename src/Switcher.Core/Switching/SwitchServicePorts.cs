using Switcher.Core.Configuration;
using Switcher.Core.Profiles;

namespace Switcher.Core.Switching;

public interface IConfigEditor
{
    void ValidateSyntax(string configText);
    string? GetTopLevel(string configText, string key);
    string BuildModeConfiguration(string currentText, ProfileKind targetKind, string? baseUrl, string? catalogPath, EffectiveSettings settings);
}

public interface ICodexRuntime
{
    Task<IReadOnlyList<string>> FindRunningProcessNamesAsync(CancellationToken cancellationToken);
    Task<bool> IsAvailableAsync(CancellationToken cancellationToken);
    Task VerifyAuthenticationAsync(ProfileKind expectedKind, CancellationToken cancellationToken, string? codexHome = null);
    Task LoginInteractivelyAsync(string codexHome, CancellationToken cancellationToken);
    void EnsureNoAuthenticationOverrides();
    IReadOnlyList<string> GetAuthenticationOverrides();
    IReadOnlyDictionary<string, string?> GetProcessEnvironment();
}

public interface IModelCatalogProvider
{
    string ResolveApiCatalog(ApiProfile profile);
    string EnsureManualCatalogFile(ApiProfile profile);
    CatalogSyncSummary SyncOfficialSnapshot(string authJson, OfficialProfile profile, string currentConfig, string? organization, string? project);
    CatalogDisplay GetStatus(ProfileEntry profile, ProfileKind kind, string? sourceName = null);
}

public sealed record CatalogSyncSummary(bool Succeeded, string Message, string Path, int ModelCount);
public sealed record CatalogDisplay(string Mode, string Path, bool Exists, string SourceName, string UpdatedUtc, string Message);

public interface IDesktopStatePlanner
{
    DesktopStatePlan CreatePlan(ProfileKind targetKind, string? sourceAuth, string? targetAuth, string? officialAuth);
}

public interface IHistoryCompatibilityService
{
    Task<HistoryPreparationResult> PrepareAsync(bool fullScan, IProgress<SwitchProgress>? progress, CancellationToken cancellationToken);
}

public interface IProjectProjectionService
{
    Task<ProjectProjectionSummary> PrepareAsync(string? desktopOwner, bool repair, bool inferFromWorkingDirectory,
        IProgress<SwitchProgress>? progress, CancellationToken cancellationToken);
}

public sealed record HistoryPreparationResult(bool Prepared, bool Changed, string Message, int FileCount, int DatabaseCount, string BackupDirectory);
public sealed record ProjectProjectionSummary(bool Changed, string Message, int ProjectCount, int ThreadCount, int PlannedChanges, string BackupDirectory);
public sealed record DesktopCompatibilitySummary(bool Repaired, string Message, int ProjectCount, int PlannedFiles);
public sealed record DesktopStatePlan(IReadOnlyList<FileMutation> Files, int ProjectCount, bool CompletedWelcome, bool RemovedOldEnvelope);

public interface ITransactionExecutor
{
    Task ExecuteAsync(OperationPlan plan, Func<CancellationToken, Task>? afterWriteValidation, CancellationToken cancellationToken);
    Task RecoverAsync(CancellationToken cancellationToken);
}

public sealed record SwitchProgress(string Stage, string Message, int? Percent = null);
public sealed record SwitchResult(ProfileKind SourceKind, ProfileKind TargetKind, string TargetProfileId, string TargetProfileName,
    HistoryPreparationResult? History, CatalogSyncSummary? CatalogSync, IReadOnlyList<string> Notices, bool Reapplied);
