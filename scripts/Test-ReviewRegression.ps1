#requires -Version 7
<#
.SYNOPSIS
    Regression checks for counter sampling without queue access and foreign deadlocks.
.DESCRIPTION
    Runs only on a local development stand. Restores the SQL reader from a saved FOB,
    setup, watchdog and counter rows. Uses a database user without a login and disposable
    SQL tables. The normal source files and delivery packages are never changed.
#>
[CmdletBinding()]
param(
    [string] $Server = 'localhost',
    [string] $Database = $env:LW_DATABASE,
    [string] $Instance = $env:LW_INSTANCE,
    [string] $Company = $env:LW_COMPANY,
    [int] $MgmtPort = 7145,
    [ValidateSet('all','coverage','deadlock')][string] $Only = 'all'
)
$ErrorActionPreference = 'Stop'
if ($Server -ne 'localhost') { throw 'This regression is restricted to localhost.' }
if (-not $Database -or -not $Instance -or -not $Company) { throw 'Database, Instance and Company are required.' }
$root = Split-Path $PSScriptRoot -Parent
$tag = 'LWReview' + [guid]::NewGuid().ToString('N').Substring(0,10)
$work = Join-Path $root ('out/' + $tag)
New-Item -ItemType Directory -Path $work | Out-Null
$finsql = 'C:\Program Files (x86)\Microsoft Dynamics NAV\110\RoleTailored Client\finsql.exe'
$service = 'MicrosoftDynamicsNavServer$' + $Instance
$connectionString = "Server=$Server;Database=$Database;Integrated Security=SSPI;Application Name=$tag;Connect Timeout=15"
$episodeTable = '[' + $Company.Replace(']',']]') + '$LockWatch Episode]'
$coverageTable = '[' + $Company.Replace(']',']]') + '$LockWatch Coverage]'
$counterTable = '[' + $tag + ']'
$foreignTable = '##' + $tag
$seedNo = -2147481000
$checks = 0
$passed = 0
$failure = $null
$cleanupErrors = [Collections.Generic.List[string]]::new()
$readerChanged = $false
$userCreated = $false
$tableCreated = $false
$seedCreated = $false
$setupBefore = $null
$stateBefore = $null
$coverageBefore = $null
$originalObject = $null
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
function Finsql([string]$command,[string]$name) {
    $log=Join-Path $work ($name+'.log')
    $line=$command+",ServerName=$Server,Database=$Database,NTAuthentication=1,NavServerName=localhost,NavServerInstance=$Instance,NavServerManagementPort=$MgmtPort,LogFile=`"$log`""
    $p=Start-Process $finsql -ArgumentList $line -PassThru -WindowStyle Hidden
    if (-not $p.WaitForExit(180000)) { $p.Kill(); throw "finsql timed out: $name" }
    if ((Test-Path $log) -and (Get-Item $log).Length -gt 0) {
        throw ("finsql $name reported: " + [IO.File]::ReadAllText($log,[Text.Encoding]::GetEncoding(1251)))
    }
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
function Restore-Reader {
    if (-not $script:readerChanged) { return }
    Finsql ('Command=ImportObjects,File="'+(Join-Path $work 'reader-before.fob')+'",ImportAction=Overwrite,SynchronizeSchemaChanges=Force') 'restore-reader'
    $actual=Query 'SELECT [Date],[Time],Compiled FROM dbo.[Object] WHERE [Type]=5 AND ID=110234'
    if ($actual.Rows.Count -ne 1 -or -not $actual.Rows[0].Compiled -or $actual.Rows[0].Date -ne $originalObject.Rows[0].Date -or $actual.Rows[0].Time -ne $originalObject.Rows[0].Time) {
        throw 'The original reader was not restored by stamp and Compiled.'
    }
    Restart-Stand
    $script:readerChanged=$false
}
function Make-Wait {
    $holder=Open-Sql; $waiter=Open-Sql
    try {
        $hold=$holder.CreateCommand(); $hold.CommandTimeout=15
        $hold.CommandText="BEGIN TRAN; UPDATE $counterTable WITH (ROWLOCK) SET Value=Value+1 WHERE Id=1;"
        [void]$hold.ExecuteNonQuery()
        $wait=$waiter.CreateCommand(); $wait.CommandTimeout=15
        $wait.CommandText="UPDATE $counterTable WITH (ROWLOCK) SET Value=Value+1 WHERE Id=1;"
        $pending=$wait.ExecuteNonQueryAsync()
        Start-Sleep -Milliseconds 1600
        $hold.CommandText='COMMIT'; [void]$hold.ExecuteNonQuery()
        [void]$pending.GetAwaiter().GetResult()
    } finally { $waiter.Dispose(); $holder.Dispose() }
}
try {
    $setupBefore=Query 'SELECT * FROM [LockWatch Setup]'
    $stateBefore=Query 'SELECT * FROM [LockWatch Watchdog]'
    $coverageBefore=Query "SELECT * FROM $coverageTable"
    if ($setupBefore.Rows.Count -ne 1 -or $stateBefore.Rows.Count -ne 1) { throw 'Initialize LockWatch before the regression.' }
    if ($setupBefore.Rows[0].Enabled -ne 0 -or [int](Scalar 'SELECT COUNT(*) FROM [Scheduled Task] WHERE [Run Codeunit]=110236') -ne 0) {
        throw 'Stop the watch before running this isolated regression.'
    }
    $prepared=$true
    Execute "UPDATE [LockWatch Setup] SET [Coverage Enabled]=1,[Deadlocks Enabled]=0,[SQL Server]=$(Q $Server);"
    Restart-Stand
    if ($Only -in @('all','coverage')) {
        $userCreated=$true
        Execute "CREATE USER [$tag] WITHOUT LOGIN; GRANT VIEW DATABASE STATE TO [$tag]; GRANT VIEW DEFINITION TO [$tag];"
        $tableCreated=$true
        Execute "CREATE TABLE $counterTable (Id int NOT NULL PRIMARY KEY,Value int NOT NULL); INSERT $counterTable VALUES(1,0);"
        $objectId=[int](Scalar "SELECT OBJECT_ID($(Q $tag));")
        $originalObject=Query 'SELECT [Date],[Time],Compiled FROM dbo.[Object] WHERE [Type]=5 AND ID=110234'
        if ($originalObject.Rows.Count -ne 1 -or -not $originalObject.Rows[0].Compiled) { throw 'Deploy a compiled SQL reader first.' }
        Finsql ('Command=ExportObjects,File="'+(Join-Path $work 'reader-before.fob')+'",Filter="Type=Codeunit;ID=110234"') 'export-reader'
        if (-not (Test-Path (Join-Path $work 'reader-before.fob'))) { throw 'Reader rollback FOB missing.' }
        $source=[IO.File]::ReadAllText((Join-Path $root 'objects/c110234_LockWatch_Sql.txt'),[Text.Encoding]::UTF8)
        $prefix="'EXECUTE AS USER = ''$tag'';' + "
        foreach($name in @('QueueSql','CountersSql')) {
            $pattern='(?m)(SqlCmd\.CommandText := )('+[regex]::Escape($name)+'\([^\r\n]*\);)'
            if ([regex]::Matches($source,$pattern).Count -ne 1) { throw "Unexpected $name injection anchor count." }
            $source=[regex]::Replace($source,$pattern,{param($m) $m.Groups[1].Value+$prefix+$m.Groups[2].Value})
        }
        $stamp=[DateTime]::Now.ToString('HH:mm:ss')
        $source=[regex]::Replace($source,'(?m)^    Date=.*?;\r?$',('    Date='+[DateTime]::Now.ToString('dd.MM.yy')+';'))
        $source=[regex]::Replace($source,'(?m)^    Time=.*?;\r?$',"    Time=$stamp;")
        $source=$source.Replace("`r`n","`n").Replace("`n","`r`n")
        $encoding=[Text.Encoding]::GetEncoding(866,[Text.EncoderExceptionFallback]::new(),[Text.DecoderExceptionFallback]::new())
        $injected=Join-Path $work 'reader-injected.cp866.txt'
        [IO.File]::WriteAllBytes($injected,$encoding.GetBytes($source))
        $readerChanged=$true
        Finsql ('Command=ImportObjects,File="'+$injected+'",ImportAction=Overwrite,SynchronizeSchemaChanges=Force') 'inject-reader'
        Finsql 'Command=CompileObjects,Filter="Type=Codeunit;ID=110234"' 'compile-reader'
        $actual=Query 'SELECT CONVERT(varchar(8),[Time],108) AS Stamp,Compiled FROM dbo.[Object] WHERE [Type]=5 AND ID=110234'
        if (-not $actual.Rows[0].Compiled -or $actual.Rows[0].Stamp -ne $stamp) { throw 'Injected reader is not current and compiled.' }
        Restart-Stand
        Nav 110238 'StartOver'
        Check 'zero-wait index is absent from sparse baseline' ([int](Scalar "SELECT COUNT(*) FROM $coverageTable WHERE [SQL Object Id]=$objectId") -eq 0) "object $objectId"
        if ([int](Scalar "SELECT COUNT(*) FROM $episodeTable WHERE [Entry No_]=$seedNo") -ne 0) { throw 'Regression episode key already exists.' }
        $cols=Query "SELECT c.name,t.name AS typ FROM sys.columns c JOIN sys.types t ON c.user_type_id=t.user_type_id WHERE c.object_id=OBJECT_ID($(Q $episodeTable)) AND t.name NOT IN ('timestamp','rowversion') ORDER BY c.column_id"
        $names=@(); $values=@()
        foreach($col in $cols.Rows) {
            $names+='['+$col.name.Replace(']',']]')+']'
            $values+=switch ($col.typ) {
                {$_ -in 'varchar','nvarchar','char','nchar','text','ntext'} {"N''"}
                {$_ -in 'datetime','datetime2','smalldatetime','date'} {"CONVERT(datetime,'17530101',112)"}
                {$_ -in 'varbinary','binary','image'} {'0x'}
                'uniqueidentifier' {"'00000000-0000-0000-0000-000000000000'"}
                default {'0'}
            }
        }
        $keyIndex=[array]::IndexOf($names,'[Entry No_]')
        if ($keyIndex -lt 0) { throw 'Episode primary key was not found.' }
        $values[$keyIndex]=[string]$seedNo
        Execute "INSERT $episodeTable ($($names -join ',')) VALUES ($($values -join ',')); UPDATE $episodeTable SET [Open]=1,[Started At]=GETUTCDATE(),[Last Seen At]=GETUTCDATE() WHERE [Entry No_]=$seedNo;"
        $seedCreated=$true
        $before=Query "SELECT [Open],[Started At],[Last Seen At] FROM $episodeTable WHERE [Entry No_]=$seedNo"
        Make-Wait
        $dmv=Query "SELECT SUM(row_lock_wait_count+page_lock_wait_count) AS Waits,SUM(row_lock_wait_in_ms+page_lock_wait_in_ms) AS Ms FROM sys.dm_db_index_operational_stats(DB_ID(),$objectId,NULL,NULL)"
        Check 'real wait fixture' ([long]$dmv.Rows[0].Waits -gt 0 -and [long]$dmv.Rows[0].Ms -gt 0) "waits $($dmv.Rows[0].Waits), ms $($dmv.Rows[0].Ms)"
        Nav 110235 'RunPass'
        $gain=Query "SELECT Waits,[Wait (ms)] AS Ms FROM $coverageTable WHERE [SQL Object Id]=$objectId"
        Check 'first wait counted despite denied queue' ($gain.Rows.Count -eq 1 -and [long]$gain.Rows[0].Waits -eq [long]$dmv.Rows[0].Waits -and [long]$gain.Rows[0].Ms -eq [long]$dmv.Rows[0].Ms) "counter rows $($gain.Rows.Count)"
        $after=Query "SELECT [Open],[Started At],[Last Seen At] FROM $episodeTable WHERE [Entry No_]=$seedNo"
        Check 'queue failure preserves open episode' ($after.Rows.Count -eq 1 -and $after.Rows[0].Open -eq 1 -and $after.Rows[0]['Started At'] -eq $before.Rows[0]['Started At'] -and $after.Rows[0]['Last Seen At'] -eq $before.Rows[0]['Last Seen At']) 'open state and timestamps'
        $message=[string](Scalar 'SELECT [Watchdog Message] FROM [LockWatch Watchdog]')
        Check 'queue failure remains visible' ($message -match 'queue.*not.*read|очередь.*не.*проч|отказ|15562|permission|доверенн') $message
        Execute "DELETE $episodeTable WHERE [Entry No_]=$seedNo"; $seedCreated=$false
        Restore-Reader
    }
    if ($Only -in @('all','deadlock')) {
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
        Execute "UPDATE [LockWatch Setup] SET [Deadlocks Enabled]=1; UPDATE [LockWatch Watchdog] SET [Deadlocks Read At]=CONVERT(datetime,'17530101',112),[Deadlocks Read Until]=DATEADD(minute,-2,GETUTCDATE());"
        Restart-Stand
        Nav 110235 'RunPass'
        $foreign=[int](Scalar "SELECT COUNT(*) FROM $episodeTable WHERE [Deadlock Id]<>'' AND [Database Id]<>DB_ID() AND [SQL Object Name] LIKE '%$tag%'")
        Check 'foreign graph excluded from journal' ($foreign -eq 0) "foreign rows $foreign"
    }
} catch { $failure=$_; Write-Host ('ERROR '+$_.Exception.Message) }
finally {
    if ($prepared) {
    if ($foreignOwner) { $foreignOwner.Dispose() }
    try { Restore-Reader } catch { $cleanupErrors.Add($_.Exception.Message) }
    if ($seedCreated) { try { Execute "DELETE $episodeTable WHERE [Entry No_]=$seedNo" } catch {$cleanupErrors.Add($_.Exception.Message)} }
    try { Execute "DELETE $episodeTable WHERE [Deadlock Id]<>'' AND [SQL Object Name] LIKE '%$tag%'" } catch {$cleanupErrors.Add($_.Exception.Message)}
    if ($tableCreated) { try { Execute "IF OBJECT_ID($(Q $tag)) IS NOT NULL DROP TABLE $counterTable" } catch {$cleanupErrors.Add($_.Exception.Message)} }
    if ($userCreated) { try { Execute "IF USER_ID($(Q $tag)) IS NOT NULL DROP USER [$tag]" } catch {$cleanupErrors.Add($_.Exception.Message)} }
    if ($null -ne $coverageBefore) { try { Restore-Rows $coverageTable $coverageBefore } catch {$cleanupErrors.Add($_.Exception.Message)} }
    if ($null -ne $setupBefore) { try { Restore-Rows '[LockWatch Setup]' $setupBefore } catch {$cleanupErrors.Add($_.Exception.Message)} }
    if ($null -ne $stateBefore) { try { Restore-Rows '[LockWatch Watchdog]' $stateBefore } catch {$cleanupErrors.Add($_.Exception.Message)} }
    try { Restart-Stand } catch {$cleanupErrors.Add($_.Exception.Message)}
    foreach($problem in $cleanupErrors) { Write-Host ('CLEANUP FAILED '+$problem) }
    }
}
Write-Host "passed $passed of $checks"
Write-Host "Artifacts: $work"
if ($failure -or $cleanupErrors.Count -gt 0 -or $passed -ne $checks -or $checks -eq 0) { exit 1 }
