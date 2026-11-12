using System.Text.Json;
using System.Text;
using System.Diagnostics;
using Switcher.Core.Paths;
using Switcher.Core.Profiles;
using Switcher.Core.Switching;
using Switcher.Infrastructure;

namespace Switcher.Cli;

internal static class Program
{
    public static async Task<int> Main(string[] args)
    {
        using var cancellation = new CancellationTokenSource();
        ConsoleCancelEventHandler cancelHandler = (_, eventArgs) =>
        {
            eventArgs.Cancel = true;
            cancellation.Cancel();
        };
        Console.CancelKeyPress += cancelHandler;
        try
        {
            var options = CliOptions.Parse(args);
            if (options.Help || options.Command is null) { PrintHelp(); return 0; }
            if (options.Command is "menu" or "setup" or "init") return LaunchDesktop(options.CodexHome, options.DataDirectory, options.CodexExecutable);
            var paths = SwitcherPaths.FromEnvironment(options.CodexHome, options.DataDirectory, options.CodexExecutable);
            return await ExecuteAsync(ApplicationHost.Create(paths, options.CodexExecutable), options, cancellation.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException) { return 130; }
        catch (Exception ex) { Console.Error.WriteLine(Sanitize(ex.Message)); return 1; }
        finally { Console.CancelKeyPress -= cancelHandler; }
    }

    private static async Task<int> ExecuteAsync(ApplicationHost host, CliOptions options, CancellationToken cancellationToken)
    {
        switch (options.Command!.ToLowerInvariant())
        {
            case "status": case "diagnose": WriteStatus(host, options.Json); return 0;
            case "profiles": case "profile-list": WriteProfiles(host, options.Json); return 0;
            case "switch": case "toggle": case "official": case "api": case "config-official": case "config-api": case "profile-use-official": case "profile-use-api":
                return await SwitchAsync(host, options, cancellationToken).ConfigureAwait(false);
            case "history-scan": return await HistoryAsync(host, options, false, cancellationToken).ConfigureAwait(false);
            case "history-prepare": case "history-repair": return await HistoryAsync(host, options, true, cancellationToken).ConfigureAwait(false);
            case "project-scan": case "project-repair": return await ProjectAsync(host, options, cancellationToken).ConfigureAwait(false);
            case "desktop-scan": case "desktop-repair": return await DesktopCompatibilityAsync(host, options, cancellationToken).ConfigureAwait(false);
            case "profile-add-api": return AddApi(host, options);
            case "profile-add-official": return await AddOfficialAsync(host, options, cancellationToken).ConfigureAwait(false);
            case "profile-rename":
                host.Profiles.Rename(ParseKind(options.Kind), Required(options.Profile, "--profile"), Required(options.Name, "--name"));
                Console.WriteLine("档案名称已更新。"); return 0;
            case "profile-update": return await UpdateApiAsync(host, options, cancellationToken).ConfigureAwait(false);
            case "profile-reauth": return await ReauthorizeAsync(host, options, cancellationToken).ConfigureAwait(false);
            case "profile-remove":
                var removeKind = ParseKind(options.Kind);
                host.Profiles.Remove(removeKind, Required(options.Profile, "--profile"), host.Service.GetLiveMode() == "未设置" ? null : FindLiveId(host, removeKind));
                Console.WriteLine("档案已删除。旧档案不会被自动重新导入。"); return 0;
            default: throw new ArgumentException($"未知命令：{options.Command}。使用 --help 查看命令。 ");
        }
    }

    private static async Task<int> SwitchAsync(ApplicationHost host, CliOptions options, CancellationToken cancellationToken)
    {
        var kind = options.Command!.Equals("toggle", StringComparison.OrdinalIgnoreCase)
            ? (host.Service.GetLiveMode() == "official" ? ProfileKind.Api : ProfileKind.Official)
            : options.Command.Contains("official", StringComparison.OrdinalIgnoreCase) ? ProfileKind.Official
            : options.Command.Contains("api", StringComparison.OrdinalIgnoreCase) ? ProfileKind.Api : ParseKind(options.Kind);
        var progress = new Progress<SwitchProgress>(item => Console.Error.WriteLine(item.Percent is { } p ? $"[{p,3}%] {item.Stage}：{item.Message}" : $"{item.Stage}：{item.Message}"));
        var quick = options.Quick || options.Command is "config-official" or "config-api";
        var result = await host.Service.SwitchAsync(kind, options.Profile, quick, options.FullHistory, progress, cancellationToken).ConfigureAwait(false);
        Console.WriteLine(options.Json ? JsonSerializer.Serialize(result, new JsonSerializerOptions { WriteIndented = true }) : $"已切换到{result.TargetKind.ToLegacyValue()}档案“{result.TargetProfileName}”。请完全退出并重新启动 Codex Desktop。{string.Join(" ", result.Notices)}");
        return 0;
    }

    private static async Task<int> HistoryAsync(ApplicationHost host, CliOptions options, bool full, CancellationToken cancellationToken)
    {
        var progress = new Progress<SwitchProgress>(item => Console.Error.WriteLine(item.Message));
        var result = await host.Service.PrepareHistoryAsync(full || options.FullHistory, progress, cancellationToken).ConfigureAwait(false);
        Console.WriteLine(options.Json ? JsonSerializer.Serialize(result, new JsonSerializerOptions { WriteIndented = true }) : result.Message);
        return result.Prepared ? 0 : 1;
    }

    private static async Task<int> ProjectAsync(ApplicationHost host, CliOptions options, CancellationToken cancellationToken)
    {
        var repair = string.Equals(options.Command, "project-repair", StringComparison.OrdinalIgnoreCase);
        var result = await host.Service.PrepareProjectProjectionAsync(repair, options.InferFromWorkingDirectory,
            new Progress<SwitchProgress>(item => Console.Error.WriteLine(item.Message)), cancellationToken).ConfigureAwait(false);
        Console.WriteLine(options.Json ? JsonSerializer.Serialize(result, new JsonSerializerOptions { WriteIndented = true }) : result.Message);
        return 0;
    }

    private static async Task<int> DesktopCompatibilityAsync(ApplicationHost host, CliOptions options, CancellationToken cancellationToken)
    {
        var result = await host.Service.PrepareDesktopStateAsync(options.Command == "desktop-repair", cancellationToken).ConfigureAwait(false);
        Console.WriteLine(options.Json ? JsonSerializer.Serialize(result, new JsonSerializerOptions { WriteIndented = true }) : result.Message);
        return 0;
    }

    private static int AddApi(ApplicationHost host, CliOptions options)
    {
        var profile = host.Profiles.AddApi(new AddApiProfile(Required(options.Name, "--name"), Required(options.BaseUrl, "--base-url"), ReadApiKey(), options.Catalog,
            ModelCatalogMode: options.CatalogMode ?? "manual", ModelCatalogSourceOfficialId: options.SourceOfficial));
        Console.WriteLine($"已添加 API 档案：{profile.Name}（{profile.Id}）。"); return 0;
    }

    private static async Task<int> AddOfficialAsync(ApplicationHost host, CliOptions options, CancellationToken cancellationToken)
    {
        if (string.IsNullOrWhiteSpace(options.AuthFile))
        {
            Console.Error.WriteLine("即将打开 Codex 官方登录；登录使用临时隔离目录，完成后会恢复当前模式。 ");
            var profile = await host.Service.AddOfficialInteractivelyAsync(options.Name, cancellationToken: cancellationToken).ConfigureAwait(false);
            Console.WriteLine($"已登记官方档案：{profile.Name}（{profile.Id}）。");
            return 0;
        }
        var auth = File.ReadAllText(options.AuthFile, new System.Text.UTF8Encoding(false, true));
        var imported = host.Profiles.ImportOfficial(options.Name ?? "", auth);
        Console.WriteLine($"已导入官方档案：{imported.Name}（{imported.Id}）。"); return 0;
    }

    private static async Task<int> UpdateApiAsync(ApplicationHost host, CliOptions options, CancellationToken cancellationToken)
    {
        var kind = ParseKind(options.Kind);
        if (kind == ProfileKind.Official) return await ReauthorizeAsync(host, options, cancellationToken).ConfigureAwait(false);
        var current = (ApiProfile)host.Registry.Load().Find(kind, Required(options.Profile, "--profile"));
        if (!string.IsNullOrWhiteSpace(options.BaseUrl) || !string.IsNullOrWhiteSpace(options.CatalogMode) || options.Catalog is not null || options.SourceOfficial is not null)
            host.Profiles.UpdateApiSettings(current.Id, current.ToSettings(), options.BaseUrl, options.CatalogMode, options.Catalog, options.SourceOfficial);
        else host.Profiles.EditApiProfile(current.Id, current.ToSettings(), current.BaseUrl, current.ModelCatalogMode, current.ModelCatalogJson, current.ModelCatalogSourceOfficialId, ReadApiKey());
        Console.WriteLine("API 档案已更新。"); return 0;
    }

    private static async Task<int> ReauthorizeAsync(ApplicationHost host, CliOptions options, CancellationToken cancellationToken)
    {
        var profile = Required(options.Profile, "--profile");
        var kind = ParseKind(options.Kind);
        var path = options.AuthFile;
        if (kind == ProfileKind.Official && string.IsNullOrWhiteSpace(path))
        {
            var refreshed = await host.Service.ReauthorizeOfficialAsync(profile, cancellationToken).ConfigureAwait(false);
            Console.WriteLine($"官方档案“{refreshed.Name}”已重新授权。 ");
            return 0;
        }
        var auth = File.ReadAllText(Required(path, "--auth-file"), new System.Text.UTF8Encoding(false, true));
        if (kind == ProfileKind.Official) host.Profiles.ReauthorizeOfficial(profile, auth);
        else
        {
            var current = (ApiProfile)host.Registry.Load().Find(kind, profile);
            var classifier = new Switcher.Infrastructure.Profiles.CodexAuthClassifier();
            var key = classifier.GetApiKey(auth);
            host.Profiles.EditApiProfile(current.Id, current.ToSettings(), current.BaseUrl, current.ModelCatalogMode, current.ModelCatalogJson, current.ModelCatalogSourceOfficialId, key);
        }
        Console.WriteLine("已使用当前 Codex 凭据更新档案；不会启动 OAuth 登录。 "); return 0;
    }

    private static void WriteStatus(ApplicationHost host, bool json)
    {
        var registry = host.Registry.Load();
        var payload = new { codex_home = host.Paths.CodexHome, data_directory = host.Paths.DataDirectory, live_mode = host.Service.GetLiveMode(), api_profiles = registry.ApiProfiles.Count, official_profiles = registry.OfficialProfiles.Count, active_api_profile_id = registry.ActiveApiProfileId, active_official_profile_id = registry.ActiveOfficialProfileId };
        Console.WriteLine(json ? JsonSerializer.Serialize(payload, new JsonSerializerOptions { WriteIndented = true }) : $"CODEX_HOME：{payload.codex_home}\n数据目录：{payload.data_directory}\n当前模式：{payload.live_mode}\nAPI 档案：{payload.api_profiles}\n官方档案：{payload.official_profiles}");
    }

    private static void WriteProfiles(ApplicationHost host, bool json)
    {
        var profiles = host.Service.ListProfiles().Select(profile => new { profile.Id, profile.Name, kind = profile is ApiProfile ? "api" : "official", catalog_path = host.Catalogs.GetStatus(profile, profile is ApiProfile ? ProfileKind.Api : ProfileKind.Official).Path }).ToArray();
        Console.WriteLine(json ? JsonSerializer.Serialize(profiles, new JsonSerializerOptions { WriteIndented = true }) : string.Join(Environment.NewLine, profiles.Select(item => $"{item.kind}\t{item.Id}\t{item.Name}\t{item.catalog_path}")));
    }

    private static string? FindLiveId(ApplicationHost host, ProfileKind kind)
    {
        var registry = host.Registry.Load(); return kind == ProfileKind.Api ? registry.ActiveApiProfileId : registry.ActiveOfficialProfileId;
    }

    private static int LaunchDesktop(string? codexHome, string? dataDirectory, string? codexExecutable)
    {
        var app = Path.Combine(AppContext.BaseDirectory, "CodexProfileSwitcher.exe");
        if (!File.Exists(app)) throw new FileNotFoundException("图形界面文件不存在。请运行固定入口或重新安装应用。", app);
        var start = new ProcessStartInfo(app) { UseShellExecute = true, WorkingDirectory = AppContext.BaseDirectory };
        AddArgument(start, "--codex-home", codexHome);
        AddArgument(start, "--data-dir", dataDirectory);
        AddArgument(start, "--codex-exe", codexExecutable);
        Process.Start(start);
        return 0;
    }

    private static void AddArgument(ProcessStartInfo start, string name, string? value)
    {
        if (!string.IsNullOrWhiteSpace(value)) { start.ArgumentList.Add(name); start.ArgumentList.Add(value); }
    }

    private static ProfileKind ParseKind(string? kind) => string.Equals(kind, "official", StringComparison.OrdinalIgnoreCase) ? ProfileKind.Official : ProfileKind.Api;
    private static string Required(string? value, string option) => string.IsNullOrWhiteSpace(value) ? throw new ArgumentException($"缺少 {option}。") : value;
    private static string Sanitize(string message) => message.Replace(Environment.NewLine, " ").Replace("\r", " ").Replace("\n", " ");

    private static string ReadApiKey()
    {
        if (Console.IsInputRedirected) return Required(Console.ReadLine(), "stdin API Key");
        Console.Error.Write("API Key（输入不会回显）：");
        var key = new StringBuilder();
        while (true)
        {
            var input = Console.ReadKey(intercept: true);
            if (input.Key == ConsoleKey.Enter) break;
            if (input.Key == ConsoleKey.Backspace) { if (key.Length > 0) key.Length--; continue; }
            if (!char.IsControl(input.KeyChar)) key.Append(input.KeyChar);
        }
        Console.Error.WriteLine();
        return Required(key.ToString(), "API Key");
    }

    private static void PrintHelp() => Console.WriteLine($"""
Codex Profile Switcher {typeof(Program).Assembly.GetName().Version?.ToString(3) ?? "unknown"}
用法：Switcher.Cli <命令> [选项]
命令：menu、setup、status、profiles、switch、toggle、official、api、config-official、config-api、profile-add-api、profile-add-official、profile-rename、profile-update、profile-reauth、profile-remove、history-scan、history-prepare、project-scan、project-repair、desktop-scan、desktop-repair、diagnose
选项：--codex-home PATH --data-dir PATH --codex-exe PATH --profile ID/名称 --kind api|official --quick --full-history --infer-from-cwd --json
API：--name NAME --base-url HTTPS_URL --catalog PATH --catalog-mode manual|official --source-official ID。添加 API 时从终端隐藏输入或 stdin 读取 Key。
官方添加/重新授权可使用隔离临时 CODEX_HOME 运行 codex login；也可使用 --auth-file PATH 导入已有完整认证。切换验证只调用 codex login status，不连接中转 API。
""");
}

internal sealed class CliOptions
{
    public string? Command { get; private set; }
    public string? CodexHome { get; private set; }
    public string? DataDirectory { get; private set; }
    public string? CodexExecutable { get; private set; }
    public string? Profile { get; private set; }
    public string? Kind { get; private set; }
    public string? Name { get; private set; }
    public string? BaseUrl { get; private set; }
    public string? Catalog { get; private set; }
    public string? CatalogMode { get; private set; }
    public string? SourceOfficial { get; private set; }
    public string? AuthFile { get; private set; }
    public bool Quick { get; private set; }
    public bool FullHistory { get; private set; }
    public bool InferFromWorkingDirectory { get; private set; }
    public bool Json { get; private set; }
    public bool Help { get; private set; }

    public static CliOptions Parse(string[] args)
    {
        var result = new CliOptions();
        for (var i = 0; i < args.Length; i++)
        {
            var arg = args[i];
            if (arg is "-h" or "--help") { result.Help = true; continue; }
            if (!arg.StartsWith("-", StringComparison.Ordinal)) { result.Command ??= arg; continue; }
            var name = arg.TrimStart('-').ToLowerInvariant();
            switch (name)
            {
                case "quick": result.Quick = true; break;
                case "full-history": case "fullhistoryscan": result.FullHistory = true; break;
                case "infer-from-cwd": result.InferFromWorkingDirectory = true; break;
                case "json": result.Json = true; break;
                case "libraryonly": case "unsafeallowrunningcodex": case "noshow": break;
                default:
                    if (i + 1 >= args.Length) throw new ArgumentException($"参数 {arg} 缺少值。 ");
                    var value = args[++i];
                    switch (name.Replace("-", "", StringComparison.Ordinal))
                    {
                        case "codexhome": result.CodexHome = value; break;
                        case "datadir": case "datadirectory": result.DataDirectory = value; break;
                        case "codexexe": case "codexexecutable": result.CodexExecutable = value; break;
                        case "monitordatadir": case "relaymodelcatalogpath": break;
                        case "profile": result.Profile = value; break;
                        case "kind": result.Kind = value; break;
                        case "name": result.Name = value; break;
                        case "baseurl": result.BaseUrl = value; break;
                        case "catalog": result.Catalog = value; break;
                        case "catalogmode": result.CatalogMode = value; break;
                        case "sourceofficial": result.SourceOfficial = value; break;
                        case "authfile": result.AuthFile = value; break;
                        default: throw new ArgumentException($"未知参数：{arg}。 ");
                    }
                    break;
            }
        }
        return result;
    }
}
