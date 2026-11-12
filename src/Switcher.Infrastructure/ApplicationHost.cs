using Switcher.Core.Paths;
using Switcher.Core.Profiles;
using Switcher.Core.Switching;
using Switcher.Core.Abstractions;
using Switcher.Infrastructure.CodexAdapters;
using Switcher.Infrastructure.Configuration;
using Switcher.Infrastructure.Files;
using Switcher.Infrastructure.History;
using Switcher.Infrastructure.Models;
using Switcher.Infrastructure.Processes;
using Switcher.Infrastructure.Profiles;
using Switcher.Infrastructure.Security;
using Switcher.Infrastructure.Switching;
using Switcher.Infrastructure.Updates;

namespace Switcher.Infrastructure;

/// <summary>Composition root shared by the command line and WPF applications.</summary>
public sealed class ApplicationHost
{
    private ApplicationHost(
        SwitcherPaths paths,
        SwitcherService service,
        ProfileManagementService profileManagement,
        ProfileRegistryStore registry,
        IModelCatalogProvider catalogs,
        IProjectProjectionService projects,
        ICodexRuntime runtime,
        IConfigEditor configEditor,
        IOperationLock operationLock,
        IOperationHistory operationHistory,
        HistoryCompatibilityService history,
        ISwitcherFileSystem files)
    {
        Paths = paths;
        Service = service;
        Profiles = profileManagement;
        Registry = registry;
        Catalogs = catalogs;
        Projects = projects;
        Updates = new GitHubUpdateService();
        Runtime = runtime;
        ConfigEditor = configEditor;
        OperationLock = operationLock;
        OperationHistory = operationHistory;
        History = history;
        Files = files;
    }

    public SwitcherPaths Paths { get; }
    public SwitcherService Service { get; }
    public ProfileManagementService Profiles { get; }
    public ProfileRegistryStore Registry { get; }
    public IModelCatalogProvider Catalogs { get; }
    public IProjectProjectionService Projects { get; }
    public Switcher.Core.Updates.IUpdateService Updates { get; }
    public ICodexRuntime Runtime { get; }
    public IConfigEditor ConfigEditor { get; }
    public IOperationLock OperationLock { get; }
    public IOperationHistory OperationHistory { get; }
    public HistoryCompatibilityService History { get; }
    public bool HasPendingRecovery => Files.FileExists(Paths.TransactionFile) || History.HasPendingRecovery;
    private ISwitcherFileSystem Files { get; }

    public static ApplicationHost Create(SwitcherPaths? paths = null, string? codexExecutable = null)
    {
        paths ??= SwitcherPaths.FromEnvironment(codexExecutable: codexExecutable);
        var files = new PhysicalSwitcherFileSystem();
        var protector = new CurrentUserDpapiProtector(paths.CodexHome);
        var registryStore = new ProfileRegistryStore(files, paths, protector);
        var vault = new CredentialVault(files, protector, registryStore, paths);
        var transactionStore = new SwitchTransactionStore(files, protector, paths);
        var executor = new AtomicSwitchExecutor(files, transactionStore);
        var repository = new ProfileRepository(registryStore, vault, paths, files, executor);
        var classifier = new CodexAuthClassifier();
        var profileManagement = new ProfileManagementService(repository, classifier);
        var processRunner = new SystemProcessRunner();
        var runtime = new CodexRuntime(processRunner, paths, codexExecutable);
        var config = new TomlConfigEditor();
        var cacheVerifier = new OfficialCacheSourceVerifier();
        var catalogs = new ModelCatalogService(files, paths, registryStore, cacheVerifier, executor, config);
        var history = new HistoryCompatibilityService(files, paths);
        var projects = new ProjectProjectionService(files, paths, protector);
        var desktopState = new DesktopStateAdapter(files, protector, paths);
        var operationLock = new WindowsOperationLock();
        var operationHistory = new OperationHistoryStore(files, paths);
        var service = new SwitcherService(paths, files, operationLock, executor, repository, classifier,
            profileManagement, config, runtime, desktopState, catalogs, projects, history);
        return new ApplicationHost(paths, service, profileManagement, registryStore, catalogs, projects, runtime, config,
            operationLock, operationHistory, history, files);
    }
}
