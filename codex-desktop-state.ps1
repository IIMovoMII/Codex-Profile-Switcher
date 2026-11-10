#requires -Version 5.1
# Dot-sourced by the switcher. Never writes state while Desktop is running.
# Desktop 26.1103 scopes renderer state to ChatGPT identities. Its constructor
# selects the anonymous owner and clears local projects on every API launch.
# We archive each identity separately, restore the requested identity, share
# only local project metadata/completed onboarding, then remove the obsolete
# renderer envelope before launch. Native in-app account switching can create
# a fresh envelope as usual. No application files or OAuth claims are changed.

function ConvertTo-DesktopMap {
    param([AllowNull()]$Value)
    if ($null -eq $Value) { return $null }
    # ConvertFrom-Json wraps JSON strings in a PSObject that still satisfies
    # `-is [pscustomobject]`. Handling strings (and other value types) first
    # prevents a scalar from being walked as an object, which serialized every
    # string as {"Length":N} and corrupted the Desktop global state.
    if ($Value -is [string]) { return [string]$Value }
    if ($Value -is [System.ValueType]) { return $Value }
    if ($Value -is [System.Collections.IDictionary]) {
        $result = @{}
        foreach ($key in $Value.Keys) { $result[[string]$key] = ConvertTo-DesktopMap $Value[$key] }
        return ,$result
    }
    if ($Value -is [System.Collections.IList]) {
        $items = New-Object Collections.Generic.List[object]
        foreach ($item in $Value) { $items.Add((ConvertTo-DesktopMap $item)) }
        return ,$items.ToArray()
    }
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        $result = @{}
        foreach ($property in $Value.PSObject.Properties) { $result[$property.Name] = ConvertTo-DesktopMap $property.Value }
        return ,$result
    }
    return $Value
}

function Copy-DesktopValue {
    param([AllowNull()]$Value)
    if ($null -eq $Value) { return $null }
    # Clone recursively without a JSON/pipeline round trip. In particular,
    # ConvertFrom-Json turns [] into no output; wrapping that creates [null].
    return ,(ConvertTo-DesktopMap $Value)
}

function Read-DesktopJson {
    param([Parameter(Mandatory = $true)][string]$Text)
    # PowerShell 7.5+ otherwise changes ISO date strings into DateTime values.
    if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) {
        return ConvertTo-DesktopMap (ConvertFrom-Json -InputObject $Text -DateKind String)
    }
    return ConvertTo-DesktopMap (ConvertFrom-Json -InputObject $Text)
}

function Assert-DesktopJsonShape {
    param([AllowNull()]$Value, [string]$Location = 'Desktop state')
    if ($Value -is [System.Collections.IDictionary]) {
        if ($Value.Count -eq 1 -and $Value.Contains('Length') -and $Value['Length'] -is [System.ValueType]) {
            throw ('Corrupt Desktop scalar at ' + $Location + '; refusing to write. Run the separate manual repair after exiting Codex.')
        }
        foreach ($key in $Value.Keys) { Assert-DesktopJsonShape $Value[$key] ($Location + '.' + $key) }
    }
    elseif ($Value -is [System.Collections.IList]) {
        foreach ($item in $Value) { Assert-DesktopJsonShape $item ($Location + '[]') }
    }
}

function Assert-DesktopGlobals {
    param([Parameter(Mandatory = $true)][System.Collections.IDictionary]$Globals)
    Assert-DesktopJsonShape $Globals
    foreach ($key in @('active-workspace-roots', 'electron-saved-workspace-roots', 'project-order', 'projectless-thread-ids', 'pinned-thread-ids')) {
        if (-not $Globals.Contains($key) -or $null -eq $Globals[$key]) { continue }
        if ($Globals[$key] -isnot [System.Collections.IList]) { throw ('Invalid Desktop string array: ' + $key) }
        foreach ($item in $Globals[$key]) { if ($item -isnot [string]) { throw ('Invalid Desktop path/id in ' + $key) } }
    }
    if ($Globals.Contains('local-projects')) {
        if ($Globals['local-projects'] -isnot [System.Collections.IDictionary]) { throw 'Invalid Desktop local-projects object.' }
        foreach ($project in $Globals['local-projects'].Values) {
            if ($project -isnot [System.Collections.IDictionary] -or $project['name'] -isnot [string] -or
                $project['rootPaths'] -isnot [System.Collections.IList]) { throw 'Invalid Desktop project name/roots.' }
            foreach ($path in $project['rootPaths']) { if ($path -isnot [string]) { throw 'Invalid Desktop project root path.' } }
        }
    }
}

function Assert-DesktopProfile {
    param([AllowNull()]$Profile)
    if ($Profile -isnot [System.Collections.IDictionary] -or
        $Profile['atoms'] -isnot [System.Collections.IDictionary] -or
        $Profile['globals'] -isnot [System.Collections.IDictionary]) { throw 'Invalid Desktop renderer profile.' }
    Assert-DesktopGlobals $Profile['globals']
    # Atoms are private per account; validate but never coerce damaged values.
    Assert-DesktopJsonShape $Profile['atoms']
}

function ConvertTo-DesktopCanonicalValue {
    param([AllowNull()]$Value)
    if ($Value -is [System.Collections.IDictionary]) {
        $result = [ordered]@{}
        [string[]]$keys = @($Value.Keys)
        [Array]::Sort($keys, [StringComparer]::Ordinal)
        foreach ($key in $keys) { $result[$key] = ConvertTo-DesktopCanonicalValue $Value[$key] }
        return ,$result
    }
    if ($Value -is [System.Collections.IList]) {
        $items = New-Object Collections.Generic.List[object]
        foreach ($item in $Value) { $items.Add((ConvertTo-DesktopCanonicalValue $item)) }
        return ,$items.ToArray()
    }
    return $Value
}

function ConvertTo-DesktopCanonicalJson {
    param([AllowNull()]$Value)
    return ConvertTo-Json -InputObject (ConvertTo-DesktopCanonicalValue $Value) -Depth 100 -Compress
}

function Get-DesktopAuthOwner {
    param([AllowNull()][string]$AuthText)
    if ([string]::IsNullOrWhiteSpace($AuthText)) { return $null }
    $auth = Read-DesktopJson $AuthText
    if ($auth['auth_mode'] -ne 'chatgpt' -or $null -eq $auth['tokens']) { return $null }
    foreach ($tokenName in @('id_token', 'access_token')) {
        try {
            $parts = ([string]$auth['tokens'][$tokenName]).Split('.')
            if ($parts.Length -ne 3) { continue }
            $payload = $parts[1].Replace('-', '+').Replace('_', '/')
            $payload = $payload.PadRight([int]([Math]::Ceiling($payload.Length / 4.0) * 4), '=')
            $claims = Read-DesktopJson ($script:Utf8NoBom.GetString([Convert]::FromBase64String($payload)))
            $namespace = $claims['https://api.openai.com/auth']
            if ($null -eq $namespace) { continue }
            $userId = [string]$namespace['chatgpt_user_id']
            $accountId = [string]$auth['tokens']['account_id']
            if ([string]::IsNullOrWhiteSpace($accountId)) { $accountId = [string]$namespace['chatgpt_account_id'] }
            if ([string]::IsNullOrWhiteSpace($userId) -or [string]::IsNullOrWhiteSpace($accountId)) { continue }
            # The app hashes JSON.stringify([userId, accountId]); these IDs are ASCII.
            $identityJson = ConvertTo-Json -InputObject @($userId, $accountId) -Compress
            return Get-Sha256Hex ($script:Utf8NoBom.GetBytes($identityJson))
        }
        catch { continue } # Synthetic/old tokens need no identity migration.
    }
    return $null
}

function Get-DesktopGlobals {
    param([Parameter(Mandatory = $true)][System.Collections.IDictionary]$Root)
    $result = @{}
    foreach ($key in $script:DesktopScopedGlobals) {
        if ($Root.Contains($key)) { $result[$key] = Copy-DesktopValue $Root[$key] }
    }
    return ,$result
}

function Select-LocalDesktopGlobals {
    param([Parameter(Mandatory = $true)][System.Collections.IDictionary]$Globals)
    $result = Copy-DesktopValue $Globals
    $localHost = 'local:' + $CodexHome
    $projects = $Globals['local-projects']
    if ($projects -isnot [System.Collections.IDictionary]) { $projects = @{} }
    $hosts = $Globals['thread-project-membership-host-ids']
    if ($hosts -isnot [System.Collections.IDictionary]) { $hosts = @{} }
    $assignments = $Globals['thread-project-assignments']
    if ($assignments -isnot [System.Collections.IDictionary]) { $assignments = @{} }
    foreach ($key in @('app-server-project-id-by-legacy-project-id-by-host', 'app-server-projects-migration-by-host')) {
        if (-not $Globals.Contains($key)) { continue }
        $result[$key] = @{}
        if ($Globals[$key].Contains($localHost)) { $result[$key][$localHost] = Copy-DesktopValue $Globals[$key][$localHost] }
    }
    foreach ($key in @('thread-project-assignments', 'thread-project-membership-host-ids', 'thread-writable-roots', 'thread-workspace-root-hints', 'thread-projectless-output-directories', 'sidebar-project-thread-orders')) {
        if ($Globals[$key] -isnot [System.Collections.IDictionary]) { continue }
        $result[$key] = @{}
        foreach ($id in $Globals[$key].Keys) {
            if ($hosts.Contains($id) -and $hosts[$id] -ne $localHost) { continue }
            if ($assignments.Contains($id) -and ($assignments[$id]['projectKind'] -ne 'local' -or
                -not $projects.Contains([string]$assignments[$id]['projectId']))) { continue }
            $result[$key][$id] = Copy-DesktopValue $Globals[$key][$id]
        }
    }
    if ($Globals.Contains('project-order')) { $result['project-order'] = @($Globals['project-order'] | Where-Object { $projects.Contains([string]$_) }) }
    if ($Globals.Contains('projectless-thread-ids')) {
        $result['projectless-thread-ids'] = @($Globals['projectless-thread-ids'] | Where-Object { -not $hosts.Contains([string]$_) -or $hosts[[string]$_] -eq $localHost })
    }
    return ,$result
}

$script:DesktopScopedGlobals = @(
    'active-workspace-roots', 'electron-saved-workspace-roots', 'local-projects',
    'app-server-project-id-by-legacy-project-id-by-host', 'app-server-projects-migration-by-host',
    'selected-project', 'project-appearances', 'pinned-thread-ids',
    'app-server-migrated-pinned-thread-ids-by-host', 'sidebar-project-thread-orders',
    'thread-project-assignments', 'thread-project-membership-host-ids', 'thread-writable-roots',
    'thread-workspace-root-hints', 'thread-projectless-output-directories',
    'projectless-thread-ids', 'project-order', 'remote-project-connection-backfill-completed',
    'queued-follow-ups'
)
# Device atoms preserved by the inspected Desktop build, plus completed role
# preferences copied below only when there is actual completion evidence.
$script:DesktopDeviceAtoms = @(
    'last_completed_onboarding', 'electron:onboarding-projectless-completed',
    'electron:bedrock-govcloud-guidance-acknowledged', 'ctrl-tab-shortcut-notice-shown',
    'number-shortcut-notice-shown', 'thread-sort-key'
)
$script:DesktopWelcomeAtom = 'electron:onboarding-welcome-v2-role-state'
$script:DesktopEnvelopeKey = 'electron-account-renderer-state-v1'
$script:DesktopAtomsKey = 'electron-persisted-atom-state'

function New-DesktopStatePlan {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('official', 'api')][string]$TargetMode,
        [AllowNull()][string]$SourceAuthText,
        [AllowNull()][string]$TargetAuthText,
        [AllowNull()][string]$OfficialAuthText
    )
    $globalPath = Join-Path $CodexHome '.codex-global-state.json'
    $archivePath = Join-Path $DataDir 'desktop-renderer-state.dpapi'
    $empty = [pscustomobject]@{ Files = @(); ProjectCount = 0; CompletedWelcome = $false; EnvelopeRemoved = $false }
    if (-not [IO.File]::Exists($globalPath)) { return $empty }
    try { $root = Read-DesktopJson (Read-TextFile $globalPath) }
    catch { throw 'Cannot parse Desktop global state; no state files were changed.' }
    if ($root -isnot [System.Collections.IDictionary]) { throw 'Invalid Desktop global state: expected object.' }
    Assert-DesktopGlobals (Get-DesktopGlobals $root)
    Assert-DesktopJsonShape $root[$script:DesktopAtomsKey]
    $originalRoot = Copy-DesktopValue $root
    $archive = @{ version = 1; codex_home = $CodexHome; profiles = @{}; api = @{ atoms = @{}; globals = @{} } }
    if ([IO.File]::Exists($archivePath)) {
        $archiveBytes = [IO.File]::ReadAllBytes($archivePath)
        $archivePlain = $null
        try {
            $archivePlain = Unprotect-BytesForCurrentUser $archiveBytes
            $archive = Read-DesktopJson ($script:Utf8NoBom.GetString($archivePlain))
        }
        catch { throw 'Cannot read the encrypted Desktop renderer archive; no state files were changed.' }
        finally {
            [Array]::Clear($archiveBytes, 0, $archiveBytes.Length)
            if ($null -ne $archivePlain) { [Array]::Clear($archivePlain, 0, $archivePlain.Length) }
        }
        if ($archive['version'] -ne 1 -or $archive['codex_home'] -ne $CodexHome -or
            $archive['profiles'] -isnot [System.Collections.IDictionary] -or
            $archive['api'] -isnot [System.Collections.IDictionary]) { throw 'Invalid Desktop renderer archive.' }
    }
    $previousArchive = Copy-DesktopValue $archive
    Assert-DesktopProfile $archive['api']
    foreach ($profile in $archive['profiles'].Values) { Assert-DesktopProfile $profile }
    $sourceOwner = Get-DesktopAuthOwner $SourceAuthText
    $targetOwner = Get-DesktopAuthOwner $TargetAuthText
    $officialOwner = Get-DesktopAuthOwner $OfficialAuthText
    $atoms = if ($root[$script:DesktopAtomsKey] -is [System.Collections.IDictionary]) { $root[$script:DesktopAtomsKey] } else { @{} }
    $globals = Get-DesktopGlobals $root
    $envelope = $root[$script:DesktopEnvelopeKey]
    if ($null -ne $envelope) {
        if ($envelope -isnot [System.Collections.IDictionary] -or
            $envelope['inactive'] -isnot [System.Collections.IDictionary] -or
            -not $envelope.Contains('owner')) { throw 'Unknown Desktop account-state schema; no files were changed.' }
        foreach ($owner in $envelope['inactive'].Keys) {
            if ($owner -notmatch '^[a-f0-9]{64}$') { throw 'Invalid Desktop renderer owner.' }
            $profile = $envelope['inactive'][$owner]
            Assert-DesktopProfile $profile
            if ($profile['atoms'] -isnot [System.Collections.IDictionary] -or
                $profile['globals'] -isnot [System.Collections.IDictionary]) { throw 'Invalid inactive Desktop profile.' }
            foreach ($key in $profile['globals'].Keys) {
                if ($key -notin $script:DesktopScopedGlobals) { throw ('Unknown Desktop account-state field; no files were changed: ' + $key) }
            }
            $archive['profiles'][$owner] = Copy-DesktopValue $profile
        }
        $activeOwner = [string]$envelope['owner']
        if (-not [string]::IsNullOrWhiteSpace($activeOwner)) {
            if ($activeOwner -notmatch '^[a-f0-9]{64}$') { throw 'Invalid active Desktop renderer owner.' }
            $archive['profiles'][$activeOwner] = @{ atoms = Copy-DesktopValue $atoms; globals = Copy-DesktopValue $globals }
        }
        else { $archive['api'] = @{ atoms = Copy-DesktopValue $atoms; globals = Copy-DesktopValue $globals } }
    }
    elseif ($null -ne $sourceOwner) {
        $archive['profiles'][$sourceOwner] = @{ atoms = Copy-DesktopValue $atoms; globals = Copy-DesktopValue $globals }
    }
    elseif ((Get-AuthInfoFromText $SourceAuthText).Kind -eq 'api') {
        $archive['api'] = @{ atoms = Copy-DesktopValue $atoms; globals = Copy-DesktopValue $globals }
    }

    $targetProfile = @{ atoms = @{}; globals = @{} }
    if ($TargetMode -eq 'api') { $targetProfile = $archive['api'] }
    elseif ($null -ne $targetOwner -and $archive['profiles'].Contains($targetOwner)) { $targetProfile = $archive['profiles'][$targetOwner] }
    elseif ($null -eq $envelope -and $sourceOwner -eq $targetOwner) { $targetProfile = @{ atoms = $atoms; globals = $globals } }

    # Prefer the latest active local list, including an explicitly empty list.
    # A reset anonymous view has no list at all: recover only the configured
    # official profile, never another account chosen by enumeration order.
    $localGlobals = $globals
    if (-not $localGlobals.Contains('local-projects')) {
        foreach ($owner in @($sourceOwner, $targetOwner, $officialOwner)) {
            if ($null -ne $owner -and $archive['profiles'].Contains($owner) -and
                $archive['profiles'][$owner]['globals'].Contains('local-projects')) {
                $localGlobals = $archive['profiles'][$owner]['globals']; break
            }
        }
        if (-not $localGlobals.Contains('local-projects') -and $archive['api']['globals'].Contains('local-projects')) {
            $localGlobals = $archive['api']['globals']
        }
    }
    $localGlobals = Select-LocalDesktopGlobals $localGlobals
    $oldLocalGlobals = Select-LocalDesktopGlobals $targetProfile['globals']
    if ($null -eq $envelope -and $null -eq $sourceOwner -and $TargetMode -eq 'official' -and
        $null -eq $targetOwner -and $null -eq $officialOwner) {
        # First login with no resolvable account: retain the existing device
        # state. There is no account whose private atoms can be restored.
        $targetProfile = @{ atoms = Copy-DesktopValue $atoms; globals = Copy-DesktopValue $globals }
    }
    $targetAtoms = Copy-DesktopValue $targetProfile['atoms']
    if ($targetAtoms -isnot [System.Collections.IDictionary]) { $targetAtoms = @{} }
    foreach ($key in $script:DesktopDeviceAtoms) {
        if ($atoms.Contains($key)) { $targetAtoms[$key] = Copy-DesktopValue $atoms[$key] }
    }
    $completed = $false
    $welcomeSources = @($atoms, $targetAtoms)
    foreach ($owner in @($sourceOwner, $targetOwner, $officialOwner)) {
        if ($null -ne $owner -and $archive['profiles'].Contains($owner)) { $welcomeSources += ,$archive['profiles'][$owner]['atoms'] }
    }
    # A fresh official renderer can omit the role atom while the API snapshot
    # still proves this device already completed onboarding. Use it only as a
    # fallback, after the current and requested account's actual choices.
    if ($archive['api']['atoms'] -is [System.Collections.IDictionary]) { $welcomeSources += ,$archive['api']['atoms'] }
    foreach ($source in $welcomeSources) {
        $welcome = $source[$script:DesktopWelcomeAtom]
        if ($null -ne $welcome -and $welcome['completedConversationalOnboarding'] -eq $true) {
            $targetAtoms[$script:DesktopWelcomeAtom] = Copy-DesktopValue $welcome
            $targetAtoms['electron:onboarding-welcome-pending'] = $false
            # Retain the user's existing choices, including suggestions=false.
            $completed = $true; break
        }
    }

    foreach ($key in $script:DesktopScopedGlobals) {
        if ($targetProfile['globals'].Contains($key)) { $root[$key] = Copy-DesktopValue $targetProfile['globals'][$key] }
        else { $root.Remove($key) }
    }
    # This allowlist intentionally omits remote/cloud selections and queues.
    foreach ($key in @(
        'active-workspace-roots', 'electron-saved-workspace-roots', 'local-projects',
        'app-server-project-id-by-legacy-project-id-by-host', 'app-server-projects-migration-by-host',
        'project-appearances', 'sidebar-project-thread-orders', 'thread-project-assignments',
        'thread-project-membership-host-ids', 'thread-writable-roots', 'thread-workspace-root-hints',
        'thread-projectless-output-directories', 'projectless-thread-ids', 'project-order'
    )) {
        if ($localGlobals.Contains($key)) {
            if ($localGlobals[$key] -is [System.Collections.IDictionary] -and $key -ne 'local-projects' -and
                $root[$key] -is [System.Collections.IDictionary]) {
                if ($oldLocalGlobals[$key] -is [System.Collections.IDictionary]) {
                    foreach ($id in $oldLocalGlobals[$key].Keys) { [void]$root[$key].Remove($id) }
                }
                foreach ($id in $localGlobals[$key].Keys) { $root[$key][$id] = Copy-DesktopValue $localGlobals[$key][$id] }
            }
            elseif ($key -eq 'projectless-thread-ids' -and $null -ne $root[$key]) {
                $foreignIds = @($root[$key] | Where-Object { $_ -notin @($oldLocalGlobals[$key]) })
                $root[$key] = @($foreignIds + @($localGlobals[$key]) | Select-Object -Unique)
            }
            else { $root[$key] = Copy-DesktopValue $localGlobals[$key] }
        }
    }
    $root[$script:DesktopAtomsKey] = $targetAtoms
    [void]$root.Remove($script:DesktopEnvelopeKey)
    Assert-DesktopGlobals (Get-DesktopGlobals $root)
    Assert-DesktopJsonShape $root[$script:DesktopAtomsKey]

    $files = New-Object Collections.Generic.List[object]
    $originalJson = ConvertTo-DesktopCanonicalJson $originalRoot
    $targetJson = ConvertTo-DesktopCanonicalJson $root
    if ($originalJson -cne $targetJson) {
        $targetBytes = $script:Utf8NoBom.GetBytes($targetJson)
        $files.Add([pscustomobject]@{ Path = $globalPath; TargetBytes = $targetBytes })
        $files.Add([pscustomobject]@{ Path = ($globalPath + '.bak'); TargetBytes = $targetBytes })
    }
    $archiveJson = ConvertTo-DesktopCanonicalJson $archive
    if ((ConvertTo-DesktopCanonicalJson $previousArchive) -cne $archiveJson) {
        $plain = $script:Utf8NoBom.GetBytes($archiveJson)
        try { $protected = Protect-BytesForCurrentUser $plain }
        finally { [Array]::Clear($plain, 0, $plain.Length) }
        $files.Add([pscustomobject]@{ Path = $archivePath; TargetBytes = $protected })
    }
    $projectCount = if ($root['local-projects'] -is [System.Collections.IDictionary]) { $root['local-projects'].Count } else { 0 }
    return [pscustomobject]@{ Files = $files.ToArray(); ProjectCount = $projectCount; CompletedWelcome = $completed; EnvelopeRemoved = $null -ne $envelope }
}

function Backup-DesktopStatePlan {
    param([Parameter(Mandatory = $true)]$Plan)
    if ($Plan.Files.Count -eq 0) { return }
    $backupRoot = Join-Path $DataDir 'desktop-state-backups'
    $backupDir = Join-Path $backupRoot ([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ') + '-' + [Guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($backupDir) | Out-Null
    $entries = @()
    foreach ($file in $Plan.Files) {
        if ([IO.File]::Exists($file.Path)) {
            $destination = Join-Path $backupDir ([IO.Path]::GetFileName($file.Path))
            [IO.File]::Copy($file.Path, $destination, $false)
            $entries += [ordered]@{ source = $file.Path; backup = $destination; sha256 = Get-Sha256Hex ([IO.File]::ReadAllBytes($destination)) }
        }
    }
    Write-AtomicText -Path (Join-Path $backupDir 'manifest.json') -Text (ConvertTo-Json -InputObject ([ordered]@{ version = 1; files = $entries }) -Depth 8)
}
