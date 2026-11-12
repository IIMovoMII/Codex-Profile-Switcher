#requires -Version 5.1
[CmdletBinding()]
param()
$script:ProjectRoot = Split-Path -Parent $PSScriptRoot

$ErrorActionPreference='Stop'
$testDirectory=Join-Path ([IO.Path]::GetTempPath()) ('codex-native-sqlite-test-'+[Guid]::NewGuid().ToString('N'))
$testSource=$script:ProjectRoot
$sqlite=Join-Path $testSource 'tools\sqlite3.ps1'
function Assert-Sqlite([bool]$Value,[string]$Message){if(-not $Value){throw $Message}}
try{
    [void][IO.Directory]::CreateDirectory($testDirectory)
    $database=Join-Path $testDirectory "含空格和引号' 数据.sqlite"
    $databaseUri=([Uri]$database).AbsoluteUri
    $text="项目`n包含\反斜杠和`"双引号"
    $literal="'"+$text.Replace("'","''")+"'"
    $json=@(& $sqlite -json $databaseUri ("CREATE TABLE data(id INTEGER, text TEXT, optional TEXT, weight REAL); INSERT INTO data VALUES(1,"+$literal+",NULL,1.25); SELECT * FROM data;")) -join "`n"
    Assert-Sqlite ($LASTEXITCODE -eq 0) 'The Windows bridge could not create a database.'
    $rows=@($json | ConvertFrom-Json)
    Assert-Sqlite ($rows.Count -eq 1 -and $rows[0].text -ceq $text -and $null -eq $rows[0].optional -and $rows[0].weight -eq 1.25) 'Unicode, escapes, NULL or numeric JSON results changed.'
    $lines=@('SELECT id FROM data; SELECT json_extract(''{"ok":2}'',''$.ok'');' | & $sqlite -readonly -batch -bail -noheader -cmd '.timeout 5000' $databaseUri)
    Assert-Sqlite ($LASTEXITCODE -eq 0 -and $lines.Count -eq 2 -and $lines[0] -eq '1' -and $lines[1] -eq '2') 'Pipeline SQL, JSON functions or multiple statements failed.'
    $before=(Get-FileHash -LiteralPath $database).Hash
    $failure=@(& $sqlite -readonly $databaseUri 'DELETE FROM data;' 2>&1)
    Assert-Sqlite ($LASTEXITCODE -ne 0 -and (Get-FileHash -LiteralPath $database).Hash -ceq $before) 'Read-only SQL was allowed to write.'
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class SqliteWalTest {
 [DllImport("winsqlite3.dll",CallingConvention=CallingConvention.Cdecl)]static extern int sqlite3_open_v2(byte[] path,out IntPtr db,int flags,IntPtr vfs);
 [DllImport("winsqlite3.dll",CallingConvention=CallingConvention.Cdecl)]static extern int sqlite3_exec(IntPtr db,byte[] sql,IntPtr callback,IntPtr args,out IntPtr error);
 [DllImport("winsqlite3.dll",CallingConvention=CallingConvention.Cdecl)]static extern int sqlite3_close(IntPtr db);
 public static IntPtr Open(string path){IntPtr db,error;if(sqlite3_open_v2(Encoding.UTF8.GetBytes(path+"\0"),out db,6,IntPtr.Zero)!=0)throw new Exception("Open failed");if(sqlite3_exec(db,Encoding.UTF8.GetBytes("PRAGMA journal_mode=WAL;INSERT INTO data VALUES(2,'WAL项目',NULL,2.5);\0"),IntPtr.Zero,IntPtr.Zero,out error)!=0)throw new Exception("WAL insert failed");return db;}
 public static void Close(IntPtr db){sqlite3_close(db);}
}
'@
    $held=[SqliteWalTest]::Open($database)
    try{
        Assert-Sqlite ([IO.File]::Exists($database+'-wal')) 'The WAL backup fixture was not active.'
        $backup=Join-Path $testDirectory "备份' 数据.sqlite"
        $backupCommand=".backup '"+$backup.Replace("'","''")+"'"
        $result=@($backupCommand | & $sqlite -readonly -batch -bail $databaseUri)
        Assert-Sqlite ($LASTEXITCODE -eq 0) 'The native backup failed.'
        $count=@(& $sqlite -readonly $backup 'SELECT COUNT(*) FROM data;')
        Assert-Sqlite ($LASTEXITCODE -eq 0 -and $count[0] -eq '2') 'A committed WAL row was missing from the backup.'
    }finally{[SqliteWalTest]::Close($held)}
    # Force production helpers to use the bridge with no external sqlite.exe.
    $savedPath=$env:PATH
    try{
        $env:PATH=$env:SystemRoot+'\System32;'+$env:SystemRoot
        $fixture=& (Join-Path $PSScriptRoot 'test-gui-fixture.ps1') -Root (Join-Path $testDirectory 'fixture')
        . (Join-Path $testSource 'codex-profile-switcher.ps1') -LibraryOnly -CodexHome $fixture.CodexHome -DataDir $fixture.DataDir -CodexExecutable $fixture.FakeCodex -UnsafeAllowRunningCodex
        Initialize-WindowsSqlite
        Assert-Sqlite ((Get-Command sqlite3).Source -ieq $sqlite) 'The fallback fixture found a system sqlite3.'
        $stateDatabase=Join-Path $CodexHome 'state_5.sqlite'
        $null=& $sqlite $stateDatabase @'
CREATE TABLE projects(id TEXT PRIMARY KEY,name TEXT,position INTEGER,updated_at_ms INTEGER);
CREATE TABLE project_roots(project_id TEXT,position INTEGER,path TEXT);
CREATE TABLE threads(id TEXT PRIMARY KEY,model_provider TEXT,cwd TEXT,project_id TEXT,archived INTEGER,agent_role TEXT);
INSERT INTO projects VALUES('one','个人项目',0,1);
INSERT INTO project_roots VALUES('one',0,'D:\Example');
INSERT INTO threads VALUES('native-thread','relay','D:\Example',NULL,0,NULL);
'@
        $sessions=Join-Path $CodexHome 'sessions';[void][IO.Directory]::CreateDirectory($sessions)
        Write-AtomicText (Join-Path $sessions 'native.jsonl') '{"type":"session_meta","payload":{"id":"native-thread","cwd":"D:\\Example","model_provider":"relay"}}'
        $historyResult=& (Join-Path $testSource 'codex-history-compat.ps1') -Command repair -CodexHome $CodexHome -BackupRoot (Join-Path $testDirectory 'history') -PortableInputIds
        Assert-Sqlite ($null -ne $historyResult -and @(& $sqlite -readonly $stateDatabase 'SELECT model_provider FROM threads;')[0] -ceq 'openai') 'The history repair did not update the database with the bridge.'
        $globalPath=Join-Path $CodexHome '.codex-global-state.json'
        $global=Read-DesktopJson (Read-TextFile $globalPath)
        $global['thread-project-assignments']=@{'native-thread'=@{projectKind='local';projectId='one'}}
        Write-AtomicText $globalPath (ConvertTo-Json -InputObject $global -Depth 10)
        $projection=& (Join-Path $testSource 'codex-project-projection.ps1') -Command repair -CodexHome $CodexHome -BackupRoot (Join-Path $testDirectory 'projection') -SkipProcessGate
        Assert-Sqlite (@(& $sqlite -readonly $stateDatabase 'SELECT project_id FROM threads;')[0] -ceq 'one') 'The project repair did not update the database with the bridge.'
    }finally{$env:PATH=$savedPath}
    Write-Output 'Windows SQLite tests passed: JSON/Unicode, URI paths, stdin/multiple statements, read-only rejection, WAL backup, history/project repairs without external sqlite3.'
}finally{
    $resolved=[IO.Path]::GetFullPath($testDirectory)
    $parent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if(-not $resolved.StartsWith($parent,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notlike 'codex-native-sqlite-test-*'){throw 'Unsafe test cleanup path.'}
    if([IO.Directory]::Exists($resolved)){Remove-Item -LiteralPath $resolved -Recurse -Force}
}
