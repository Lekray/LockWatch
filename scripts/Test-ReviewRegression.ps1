#requires -Version 7
<#
.SYNOPSIS
    Regression check: a deadlock of another database on the same server stays out of the journal.
.DESCRIPTION
    Runs only on a local development stand. Makes a real deadlock on a disposable global
    temporary table (tempdb), proves the graph reached system_health, runs one pass and
    proves the pass read the ring and wrote no row of the foreign graph. Setup and watchdog
    rows are snapshotted and restored; the normal source files and delivery packages are
    never changed.
#>
[CmdletBinding()]
param(
    [string] $Server = 'localhost',
    [string] $Database = $env:LW_DATABASE,
    [string] $Instance = $env:LW_INSTANCE,
    [string] $Company = $env:LW_COMPANY,
    # Recycle system_health before the fixture. A stand whose ring receiver has hit its
    # output ceiling stops showing new events at all (droppedCount stays zero), and the
    # fixture would be blamed for a server state (FINDINGS, section 62).
    [switch] $CycleRing
)
$ErrorActionPreference = 'Stop'
if ($Server -ne 'localhost') { throw 'This regression is restricted to localhost.' }
if (-not $Database -or -not $Instance -or -not $Company) { throw 'Database, Instance and Company are required.' }
$root = Split-Path $PSScriptRoot -Parent
$tag = 'LWReview' + [guid]::NewGuid().ToString('N').Substring(0,10)
$work = Join-Path $root ('out/' + $tag)
New-Item -ItemType Directory -Path $work | Out-Null
$service = 'MicrosoftDynamicsNavServer$' + $Instance
$connectionString = "Server=$Server;Database=$Database;Integrated Security=SSPI;Application Name=$tag;Connect Timeout=15"
$episodeTable = '[' + $Company.Replace(']',']]') + '$LockWatch Episode]'
$foreignTable = '##' + $tag
$checks = 0
$passed = 0
$failure = $null
$cleanupErrors = [Collections.Generic.List[string]]::new()
$setupBefore = $null
$stateBefore = $null
$foreignOwner = $null
$prepared = $false

function Open-Sql {
    $c = [Data.SqlClient.SqlConnection]::new($connectionString)
    $c.Open()
    return $c
}
function Query([string]$sql) {
    $c = Open-Sql
    try {
        $cmd = $c.CreateCommand(); $cmd.CommandText = $sql; $cmd.CommandTimeout = 45
        $adapter = [Data.SqlClient.SqlDataAdapter]::new($cmd)
        $dt = [Data.DataTable]::new()
        [void]$adapter.Fill($dt)
        return ,$dt
    } finally { $c.Dispose() }
}
function Execute([string]$sql) {
    $c = Open-Sql
    try { $cmd=$c.CreateCommand(); $cmd.CommandText=$sql; $cmd.CommandTimeout=45; [void]$cmd.ExecuteNonQuery() }
    finally { $c.Dispose() }
}
function Scalar([string]$sql) {
    $dt = Query $sql
    if ($dt.Rows.Count -eq 0) { return $null }
    return $dt.Rows[0][0]
}
function Check([string]$name,[bool]$ok,[string]$detail) {
    $script:checks++
    if ($ok) { $script:passed++; Write-Host "PASS $name -- $detail" }
    else { Write-Host "FAIL $name -- $detail" }
}
function Q([string]$value) { return "'" + $value.Replace("'","''") + "'" }
function Nav([int]$id,[string]$method) {
    $scriptPath=Join-Path $work ('nav-' + $id + '-' + $method + '.ps1')
    $body = "`$ErrorActionPreference='Stop'`r`n" +
        "Import-Module 'C:\Program Files\Microsoft Dynamics NAV\110\Service\NavAdminTool.ps1' -DisableNameChecking -WarningAction SilentlyContinue | Out-Null`r`n" +
        "Invoke-NAVCodeunit -ServerInstance $(Q $Instance) -CompanyName $(Q $Company) -CodeunitId $id -MethodName $(Q $method) -ErrorAction Stop`r`n"
    [IO.File]::WriteAllText($scriptPath,$body,[Text.UTF8Encoding]::new($true))
    $stdout=$scriptPath+'.out'; $stderr=$scriptPath+'.err'
    $p=Start-Process powershell.exe -ArgumentList ('-NoProfile -File "'+$scriptPath+'"') -PassThru -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    if (-not $p.WaitForExit(180000)) { $p.Kill(); throw "NAV invocation timed out: $id/$method" }
    if ($p.ExitCode -ne 0) { throw ("NAV invocation failed: $id/$method " + [IO.File]::ReadAllText($stderr)) }
}
function Restart-Stand {
    Restart-Service -Name $service
    $deadline=[DateTime]::UtcNow.AddMinutes(3)
    $scriptPath=Join-Path $work 'ready.ps1'
    $body="`$ErrorActionPreference='Stop'`r`nImport-Module 'C:\Program Files\Microsoft Dynamics NAV\110\Service\NavAdminTool.ps1' -DisableNameChecking -WarningAction SilentlyContinue | Out-Null`r`nGet-NAVServerSession -ServerInstance $(Q $Instance) | Out-Null"
    [IO.File]::WriteAllText($scriptPath,$body,[Text.UTF8Encoding]::new($true))
    do {
        & powershell.exe -NoProfile -File $scriptPath *> (Join-Path $work 'ready.log')
        if ($LASTEXITCODE -eq 0) { return }
        Start-Sleep -Seconds 3
    } while ([DateTime]::UtcNow -lt $deadline)
    throw 'NAV management endpoint did not become ready.'
}
function Restore-Rows([string]$table,[Data.DataTable]$snapshot) {
    $copy=$snapshot.Copy()
    if ($copy.Columns.Contains('timestamp')) { $copy.Columns.Remove('timestamp') }
    $c=Open-Sql
    try {
        $tx=$c.BeginTransaction()
        try {
            $cmd=$c.CreateCommand(); $cmd.Transaction=$tx; $cmd.CommandTimeout=45
            $cmd.CommandText="DELETE FROM $table"; [void]$cmd.ExecuteNonQuery()
            $bulk=[Data.SqlClient.SqlBulkCopy]::new($c,[Data.SqlClient.SqlBulkCopyOptions]::Default,$tx)
            $bulk.DestinationTableName=$table; $bulk.BulkCopyTimeout=45
            foreach($column in $copy.Columns) { [void]$bulk.ColumnMappings.Add($column.ColumnName,$column.ColumnName) }
            $bulk.WriteToServer($copy); $bulk.Dispose(); $tx.Commit()
        } catch { $tx.Rollback(); throw }
    } finally { $c.Dispose() }
}
try {
    $setupBefore=Query 'SELECT * FROM [LockWatch Setup]'
    $stateBefore=Query 'SELECT * FROM [LockWatch Watchdog]'
    if ($setupBefore.Rows.Count -ne 1 -or $stateBefore.Rows.Count -ne 1) { throw 'Initialize LockWatch before the regression.' }
    if ($setupBefore.Rows[0].Enabled -ne 0 -or [int](Scalar "SELECT COUNT(*) FROM [dbo].[Scheduled Task] WHERE [Run Codeunit]=110232 AND [Company]=N'$Company'") -ne 0) {
        throw 'Stop the watch before running this isolated regression.'
    }
    $prepared=$true
    if ($CycleRing) {
        Execute "IF EXISTS (SELECT 1 FROM sys.dm_xe_sessions WHERE name = N'system_health') ALTER EVENT SESSION [system_health] ON SERVER STATE = STOP;"
        Execute "IF NOT EXISTS (SELECT 1 FROM sys.dm_xe_sessions WHERE name = N'system_health') ALTER EVENT SESSION [system_health] ON SERVER STATE = START;"
        Write-Host 'system_health ring buffer recycled'
    }
    $foreignOwner=Open-Sql
    $cmd=$foreignOwner.CreateCommand(); $cmd.CommandTimeout=15
    $cmd.CommandText="CREATE TABLE $foreignTable (Id int NOT NULL PRIMARY KEY,Value int NOT NULL); INSERT $foreignTable VALUES (1,0),(2,0);"
    [void]$cmd.ExecuteNonQuery()
    $left=Open-Sql; $right=Open-Sql
    try {
        $a=$left.CreateCommand(); $a.CommandTimeout=25; $a.CommandText="BEGIN TRAN; UPDATE $foreignTable WITH (ROWLOCK) SET Value=1 WHERE Id=1;"; [void]$a.ExecuteNonQuery()
        $b=$right.CreateCommand(); $b.CommandTimeout=25; $b.CommandText="BEGIN TRAN; UPDATE $foreignTable WITH (ROWLOCK) SET Value=1 WHERE Id=2;"; [void]$b.ExecuteNonQuery()
        $a.CommandText="UPDATE $foreignTable WITH (ROWLOCK) SET Value=2 WHERE Id=2; COMMIT;"; $ta=$a.ExecuteNonQueryAsync()
        $b.CommandText="UPDATE $foreignTable WITH (ROWLOCK) SET Value=2 WHERE Id=1; COMMIT;"; $tb=$b.ExecuteNonQueryAsync()
        $deadlocks=0
        foreach($pending in @($ta,$tb)) {
            try { [void]$pending.GetAwaiter().GetResult() }
            catch { if ($_.Exception.ToString() -match '1205|deadlock|взаимоблок') {$deadlocks++} else {throw} }
        }
        Check 'foreign deadlock fixture' ($deadlocks -eq 1) "victims $deadlocks"
    } finally { $left.Dispose(); $right.Dispose() }
    $eventSql=@"
SET QUOTED_IDENTIFIER ON;
SELECT COUNT(*) FROM
(SELECT CONVERT(xml,t.target_data) AS x FROM sys.dm_xe_session_targets t JOIN sys.dm_xe_sessions s ON s.address=t.event_session_address WHERE s.name='system_health' AND t.target_name='ring_buffer') q
CROSS APPLY q.x.nodes('/RingBufferTarget/event[@name="xml_deadlock_report"]') e(n)
WHERE CONVERT(nvarchar(max),e.n.query('.')) LIKE '%$tag%';
"@
    $deadline=[DateTime]::UtcNow.AddSeconds(20)
    do { $seen=[int](Scalar $eventSql); if ($seen -gt 0) {break}; Start-Sleep -Seconds 1 } while ([DateTime]::UtcNow -lt $deadline)
    Check 'foreign graph is in system_health' ($seen -gt 0) "graphs $seen"
    if ($seen -eq 0) { throw 'Foreign event absent: database filtering cannot be judged.' }
    # Счётчик сервера обнуляется нарочно: после прохода он обязан вырасти, и это
    # единственное доказательство, что проход кольцо ДЕЙСТВИТЕЛЬНО прочитал, а не
    # что чужая строка просто не попала в журнал по другой причине.
    $armSql = "UPDATE [LockWatch Setup] SET [SQL Server]=$(Q $Server),[Deadlocks Enabled]=1;" +
        " UPDATE [LockWatch Watchdog] SET [Deadlocks Read At]=CONVERT(datetime,'17530101',112)," +
        "[Deadlocks Read Until]=DATEADD(minute,-2,GETUTCDATE()),[Deadlocks Counted]=0;"
    Execute $armSql
    Restart-Stand
    Nav 110230 'RunPass'
    $counted=[long](Scalar 'SELECT [Deadlocks Counted] FROM [LockWatch Watchdog]')
    Check 'buffer read by the pass' ($counted -gt 0) "server counter $counted"
    $foreign=[int](Scalar "SELECT COUNT(*) FROM $episodeTable WHERE [Deadlock Id]<>'' AND [Database Id]<>DB_ID() AND [SQL Object Name] LIKE '%$tag%'")
    Check 'foreign graph excluded from journal' ($foreign -eq 0) "foreign rows $foreign"
} catch { $failure=$_; Write-Host ('ERROR '+$_.Exception.Message) }
finally {
    if ($prepared) {
    if ($foreignOwner) { $foreignOwner.Dispose() }
    try { Execute "DELETE $episodeTable WHERE [Deadlock Id]<>'' AND [SQL Object Name] LIKE '%$tag%'" } catch {$cleanupErrors.Add($_.Exception.Message)}
    if ($null -ne $setupBefore) { try { Restore-Rows '[LockWatch Setup]' $setupBefore } catch {$cleanupErrors.Add($_.Exception.Message)} }
    if ($null -ne $stateBefore) { try { Restore-Rows '[LockWatch Watchdog]' $stateBefore } catch {$cleanupErrors.Add($_.Exception.Message)} }
    try { Restart-Stand } catch {$cleanupErrors.Add($_.Exception.Message)}
    foreach($problem in $cleanupErrors) { Write-Host ('CLEANUP FAILED '+$problem) }
    }
}
Write-Host "passed $passed of $checks"
Write-Host "Artifacts: $work"
if ($failure -or $cleanupErrors.Count -gt 0 -or $passed -ne $checks -or $checks -eq 0) { exit 1 }
