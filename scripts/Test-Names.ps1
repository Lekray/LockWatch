#requires -Version 7
<#
.SYNOPSIS
    Дорога к ИМЕНИ целиком: подписчик кладёт отметку, журнал по ней называет человека.

.DESCRIPTION
    Имена были проверены по частям и ни разу целиком. Обкатка прохода кладёт отметку
    контекста САМА, запросом в таблицу, и проверяет тем самым только чтение; прогон
    переходника проверяет, что подписка встала и отметка появляется, но журнала при этом
    не касается. Между двумя половинами оставался стык, на котором как раз и ломается
    ответ на вопрос «кто»: отметку, положенную настоящим подписчиком внутри чужой
    транзакции, надо ещё найти по выданной блокировке и разложить в правильные колонки.

    Здесь эта цепочка проходится вся и на НАСТОЯЩЕЙ таблице установки:

      переходник под таблицу из настройки  ->  сессия NAV правит свою строку
      ->  подписчик кладёт отметку в ТОЙ ЖЕ транзакции  ->  вторая сессия NAV встаёт в
      очередь за спорной строкой  ->  проход находит обе отметки по блокировкам
      ->  в журнале появляются «Пользователь», «Откуда имя» и «Кто ждал».

    Обе сессии идут под ОДНОЙ учётной записью, и поэтому имена в них совпадают: различить
    подмену виновника жертвой по самому имени прогон не может. Здесь раньше было написано,
    что различает он её ДОКУМЕНТОМ, и это оказалось неверным: документ приходит ПЕРВОЙ
    дорогой, по хэшу спорной строки, и верен независимо от того, чью отметку прочли второй.
    Сломано нарочно 11.09.2026 - отметку виновника искали по сеансу ЖЕРТВЫ, - и прогон
    остался зелёным ЦЕЛИКОМ, 11 из 11.

    Различает подмену ИСТОЧНИК документа. Обе дороги его называют, и сходятся они лишь
    тогда, когда отметку клал тот, кто ДЕРЖИТ: у ждущего в отметке свой документ, и
    разошедшиеся дороги инструмент помечает отдельным значением. Значение это прогон читал
    и раньше, а спрашивать стал только теперь; с той же поломкой выходит 11 из 12.

    Две отметки лежат рядом, и перепутать их дороже, чем не найти ни одной.

    Прогон ставит подписчика на ЧУЖУЮ таблицу и потому убирает его за собой обязательно -
    и объект, и подложенные строки. Служба перезапускается дважды: подписку платформа
    замечает при старте и забывает тоже при нём.

.EXAMPLE
    $env:LW_DOC_TABLE_NO = 37; $env:LW_DOC_FIELD_NO = 3
    pwsh scripts/Test-Names.ps1
#>
[CmdletBinding()]
param(
    [string] $Server   = 'localhost',
    [string] $Database = $env:LW_DATABASE,
    [string] $Instance = $env:LW_INSTANCE,
    [string] $Company  = $env:LW_COMPANY,
    [int]    $TableNo  = $(if ($env:LW_DOC_TABLE_NO) { [int]$env:LW_DOC_TABLE_NO } else { 0 }),
    [int]    $FieldNo  = $(if ($env:LW_DOC_FIELD_NO) { [int]$env:LW_DOC_FIELD_NO } else { 0 }),
    [int]    $AdapterObjectNo = 110250,
    [int]    $PassCodeunitId  = 110235,
    [int]    $TaskCodeunitId  = 110236,
    [int]    $HoldCodeunitId  = 110243,
    [int]    $MgmtPort = 7145,
    [int]    $TimeoutMinutes = 3
)

$ErrorActionPreference = 'Stop'
$root   = Split-Path -Parent $PSScriptRoot
$outDir = Join-Path $root 'out'
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir | Out-Null }

function Fail([string]$message) { Write-Host "ОТКАЗ: $message" -ForegroundColor Red; exit 1 }
if (-not $Database) { Fail 'не задано имя базы: переменная LW_DATABASE или параметр -Database' }
if (-not $Instance) { Fail 'не задан экземпляр службы: переменная LW_INSTANCE' }
if (-not $Company)  { Fail 'не задана компания: переменная LW_COMPANY' }
if ($TableNo -le 0) { Fail 'не задана таблица документа: переменная LW_DOC_TABLE_NO или -TableNo' }
if ($FieldNo -le 0) { Fail 'не задано поле документа: переменная LW_DOC_FIELD_NO или -FieldNo' }

$finsql = 'C:\Program Files (x86)\Microsoft Dynamics NAV\110\RoleTailored Client\finsql.exe'
if (-not (Test-Path $finsql)) { Fail "нет finsql.exe: $finsql" }

$context  = "[$Company`$LockWatch Context Table]"
# Отметку читать ТОЛЬКО грязным чтением. Она лежит в незавершённой транзакции того, кто её
# положил, и обычный SELECT встаёт на ней самой: опрос ждал полторы минуты, держатель за это
# время отпускал блокировку, а прогон объявлял, что эпизода не было. Инструмент этой беды не
# знает - он ищет отметку не выборкой, а по ВЫДАННОЙ блокировке.
$mark     = "[$Company`$LockWatch Context Mark]"
$markRead = "[$Company`$LockWatch Context Mark] WITH (READUNCOMMITTED)"
$episode  = "[$Company`$LockWatch Episode]"
$setup    = "[$Company`$LockWatch Setup]"
$state    = "[$Company`$LockWatch Watchdog]"
$service  = "MicrosoftDynamicsNavServer`$$Instance"

# Номера строк-мишеней заданы не здесь: их знает Codeunit 110243, и повторены они тут
# затем, что прогон обязан подложить ровно те строки, за которыми держатель пойдёт.
# Разойдись они - держатель откажет словами «строки нет», и это лучший из исходов.
$holdDoc = 'LOCKWATCH-LIVE'
$waitDoc = 'LOCKWATCH-LIVE-2'

$passed = 0; $total = 0; $report = @()
function Check([string]$what, [bool]$ok, [string]$detail) {
    $script:total++
    if ($ok) { $script:passed++; $verdict = 'пройдено' } else { $verdict = 'ПРОВАЛ  ' }
    $script:report += "$verdict $what"
    $script:report += "         $detail"
}

function Invoke-Sql([string]$query) {
    $answer = & sqlcmd -S $Server -d $Database -E -b -l 30 -w 500 -W -s '|' -h -1 -Q "SET NOCOUNT ON; $query" 2>&1
    if ($LASTEXITCODE -ne 0) { Fail "SQL не выполнился: $($answer -join ' ')" }
    return ,@($answer | Where-Object { $_ -and ($_ -notmatch '^\(') })
}
function Scalar([string]$query) { $rows = Invoke-Sql $query; if ($rows.Count -eq 0) { return '' }; return "$($rows[0])".Trim() }

function Invoke-Finsql([string]$argLine, [string]$logName) {
    $log = Join-Path $outDir $logName
    if (Test-Path $log) { Remove-Item $log -Force }
    $navArgs = "ServerName=$Server,Database=$Database,NTAuthentication=1,LogFile=`"$log`""
    $process = Start-Process -FilePath $finsql -PassThru -NoNewWindow -ArgumentList "$argLine,$navArgs"
    if (-not $process.WaitForExit($TimeoutMinutes * 60000)) { $process.Kill(); Fail "finsql завис дольше $TimeoutMinutes мин" }
    if (Test-Path $log) {
        $text = ([System.Text.Encoding]::GetEncoding(866).GetString([IO.File]::ReadAllBytes($log))).Trim()
        if ($text) { Fail "finsql ($logName):`n$text" }
    }
}
function Import-Object([string]$sourceFile, [string]$tag) {
    # Импорт в C/SIDE идёт в cp866: cp1251 и UTF-8 ломают кириллицу молча.
    $text = [IO.File]::ReadAllText($sourceFile, [Text.UTF8Encoding]::new($false))
    $text = ($text -replace "`r`n", "`n") -replace "`n", "`r`n"
    $cp866 = [System.Text.Encoding]::GetEncoding(866)
    if ($cp866.GetString($cp866.GetBytes($text)) -ne $text) { Fail "cp866 теряет символы в $sourceFile" }
    $pack = Join-Path $outDir "$tag.cp866.txt"
    [IO.File]::WriteAllBytes($pack, $cp866.GetBytes($text))
    Invoke-Finsql "Command=ImportObjects,File=`"$pack`",ImportAction=overwrite,SynchronizeSchemaChanges=Force,NavServerName=$Server,NavServerInstance=$Instance,NavServerManagementPort=$MgmtPort" "import-$tag.log"
}
function Compile-Codeunit([int]$id, [string]$tag) {
    Invoke-Finsql "Command=CompileObjects,Filter=`"Type=Codeunit;ID=$id`",SynchronizeSchemaChanges=Force,NavServerName=$Server,NavServerInstance=$Instance,NavServerManagementPort=$MgmtPort" "compile-$tag.log"
}
function Delete-Codeunit([int]$id, [string]$tag) {
    Invoke-Finsql "Command=DeleteObjects,Filter=`"Type=Codeunit;ID=$id`"" "delete-$tag.log"
}

$ps51 = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$navImport = "Import-Module 'C:\Program Files\Microsoft Dynamics NAV\110\Service\NavAdminTool.ps1' -DisableNameChecking -WarningAction SilentlyContinue | Out-Null"
function Write-Ps51([string]$path, [string]$body) {
    [IO.File]::WriteAllText($path, (($body -replace "`r`n", "`n") -replace "`n", "`r`n"), (New-Object System.Text.UTF8Encoding($true)))
}
$probeFile = Join-Path $outDir 'wait-nav-names.ps1'
Write-Ps51 $probeFile @"
$navImport
`$deadline = (Get-Date).AddMinutes(6)
while ((Get-Date) -lt `$deadline) {
    try { Get-NAVServerSession -ServerInstance $Instance -ErrorAction Stop | Out-Null; exit 0 } catch { Start-Sleep -Seconds 5 }
}
exit 1
"@
function Restart-Nav([string]$why) {
    Write-Host "  перезапускаю службу $Instance ($why)"
    Restart-Service $service -Force
    & $ps51 -NoProfile -ExecutionPolicy Bypass -File $probeFile | Out-Null
    if ($LASTEXITCODE -ne 0) { Fail "экземпляр $Instance не ответил по порту управления" }
}
function Invoke-Codeunit([int]$id, [string]$method, [string]$why) {
    $runFile = Join-Path $outDir "names-invoke-$id-$method.ps1"
    Write-Ps51 $runFile @"
`$ErrorActionPreference = 'Stop'
$navImport
Invoke-NAVCodeunit -ServerInstance $Instance -CompanyName '$Company' -CodeunitId $id -MethodName $method -ErrorAction Stop
"@
    $log = & $ps51 -NoProfile -ExecutionPolicy Bypass -File $runFile 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { Fail "$why не отработал:`n$log" }
    return $log
}

# Держатель и ждущий уходят В ФОНЕ и своего кода возврата не приносят. Держатель спит
# полторы минуты нарочно, а ждущий обязан УПАСТЬ по пределу ожидания NAV в 10 000 мс -
# это его честный конец, а не беда, и считать такой отказ отказом прогона нельзя.
function Start-NavCall([int]$id, [string]$method, [string]$tag) {
    $runFile = Join-Path $outDir "names-bg-$tag.ps1"
    $logFile = Join-Path $outDir "names-bg-$tag.log"
    if (Test-Path $logFile) { Remove-Item $logFile -Force }
    Write-Ps51 $runFile @"
`$ErrorActionPreference = 'Continue'
$navImport
`$out = Invoke-NAVCodeunit -ServerInstance $Instance -CompanyName '$Company' -CodeunitId $id -MethodName $method -WarningAction Continue 3>&1 4>&1 2>&1 | Out-String
Set-Content -Path '$logFile' -Value `$out -Encoding UTF8
"@
    return Start-Process -FilePath $ps51 -PassThru -WindowStyle Hidden `
        -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $runFile)
}

# Значения собираются ПО ТИПАМ: умолчаний NAV в SQL не создаёт и объявляет столбцы NOT NULL.
$zeroByType = @'
CASE WHEN t.name IN (N'nvarchar',N'varchar',N'char',N'nchar',N'text',N'ntext',N'xml') THEN N'SPACE(0)'
     WHEN t.name IN (N'datetime',N'datetime2',N'smalldatetime',N'date',N'time',N'datetimeoffset') THEN N'CONVERT(datetime,0)'
     WHEN t.name = N'uniqueidentifier' THEN N'CONVERT(uniqueidentifier,0x00000000000000000000000000000000)'
     WHEN t.name IN (N'binary',N'varbinary',N'image') THEN N'0x'
     ELSE N'0' END
'@
function Get-SqlPattern([string]$name) {
    $pattern = ''
    foreach ($ch in $name.ToCharArray()) {
        if ([char]::IsLetterOrDigit($ch) -or ($ch -eq ' ')) { $pattern += $ch } else { $pattern += '_' }
    }
    return $pattern
}
function New-TargetRow([string]$sqlTableName, [string]$docColumn, [string]$docNo) {
    $sql = @'
DECLARE @t sysname = N'{T}', @col sysname = N'{C}', @doc nvarchar(20) = N'{D}';
DECLARE @cols nvarchar(max) = N'', @vals nvarchar(max) = N'', @sql nvarchar(max);
SELECT @cols = @cols + CASE WHEN @cols = N'' THEN N'' ELSE N',' END + QUOTENAME(c.name),
       @vals = @vals + CASE WHEN @vals = N'' THEN N'' ELSE N',' END +
         CASE WHEN c.name = @col THEN N'@doc' ELSE {Z} END
FROM sys.columns c JOIN sys.types t ON t.user_type_id = c.user_type_id
WHERE c.object_id = OBJECT_ID(QUOTENAME(@t)) AND c.is_computed = 0 AND c.is_identity = 0
  AND t.name <> N'timestamp';
SET @sql = N'INSERT INTO ' + QUOTENAME(@t) + N' (' + @cols + N') VALUES (' + @vals + N');';
EXEC sp_executesql @sql, N'@doc nvarchar(20)', @doc = @doc;
'@
    $sql = $sql.Replace('{T}', $sqlTableName).Replace('{C}', $docColumn).Replace('{D}', $docNo).Replace('{Z}', $zeroByType)
    Invoke-Sql $sql | Out-Null
}

Write-Host "Дорога к имени целиком: таблица $TableNo, поле $FieldNo, переходник $AdapterObjectNo"

$sqlTableName = ''; $docColumn = ''; $adapterUp = $false; $holdProc = $null; $waitProc = $null
$hadContext = [int](Scalar "SELECT COUNT(*) FROM $context WHERE [Table No_] = $TableNo;")

try {
    # ---------- 1. настройка и таблица контекста ----------
    Invoke-Sql @"
UPDATE $setup SET [SQL Server] = N'$Server', [Enabled] = 0, [Deadlocks Enabled] = 0, [Coverage Enabled] = 0;
DELETE FROM [dbo].[Scheduled Task] WHERE [Run Codeunit] = $TaskCodeunitId;
DELETE FROM $mark;
IF NOT EXISTS (SELECT 1 FROM $context WHERE [Table No_] = $TableNo)
INSERT INTO $context ([Table No_],[Table Name],[Document Field No_],[Document Field Name],[Document Caption],[Enabled])
VALUES ($TableNo,N'',$FieldNo,N'',N'',1);
UPDATE $context SET [Enabled] = 1, [Document Field No_] = $FieldNo WHERE [Table No_] = $TableNo;
UPDATE $state SET [Watchdog Message] = N'';
"@ | Out-Null
    Restart-Nav 'настройка правится мимо NAV, и в кэше службы лежит прежняя'
    Invoke-Codeunit $TaskCodeunitId 'RefreshContextNames' 'перечитывание имён' | Out-Null

    $names = Scalar "SELECT [Table Name] + '|' + [Document Field Name] FROM $context WHERE [Table No_] = $TableNo;"
    $nm = ($names -split '\|') | ForEach-Object { $_.Trim() }
    if (($nm.Count -lt 2) -or ($nm[0] -eq '')) { Fail "NAV не назвал таблицу $TableNo - подкладывать строки некуда" }
    $navTable = $nm[0]; $navField = $nm[1]

    $tablePattern = "$Company`$" + (Get-SqlPattern $navTable)
    $tables = Invoke-Sql "SELECT name FROM sys.tables WHERE name LIKE N'$tablePattern';"
    if ($tables.Count -ne 1) { Fail "имя таблицы [$navTable] подошло к $($tables.Count) таблицам SQL" }
    $sqlTableName = "$($tables[0])".Trim()
    $columnPattern = Get-SqlPattern $navField
    $columns = Invoke-Sql "SELECT c.name FROM sys.columns c WHERE c.object_id = OBJECT_ID(N'[$sqlTableName]') AND c.name LIKE N'$columnPattern';"
    if ($columns.Count -ne 1) { Fail "имя поля [$navField] подошло к $($columns.Count) столбцам" }
    $docColumn = "$($columns[0])".Trim()

    # ---------- 2. строки-мишени ----------
    Invoke-Sql "DELETE FROM [$sqlTableName] WHERE [$docColumn] LIKE N'LOCKWATCH-LIVE%';" | Out-Null
    New-TargetRow $sqlTableName $docColumn $holdDoc
    New-TargetRow $sqlTableName $docColumn $waitDoc
    $rows = [int](Scalar "SELECT COUNT(*) FROM [$sqlTableName] WHERE [$docColumn] LIKE N'LOCKWATCH-LIVE%';")
    Check 'мишени подложены в НАСТОЯЩУЮ таблицу установки, названную настройкой' `
        (($rows -eq 2) -and ($sqlTableName -ne '')) `
        "таблица [$navTable] -> [$sqlTableName], поле [$navField] -> [$docColumn], строк $rows"

    # ---------- 3. переходник ----------
    $generated = Join-Path $outDir "c${AdapterObjectNo}_LockWatch_Adapter_$TableNo.txt"
    if (Test-Path $generated) { Remove-Item $generated -Force }
    & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'New-ContextAdapter.ps1') `
        -TableNo $TableNo -ObjectNo $AdapterObjectNo -Server $Server -Database $Database -Company $Company | Out-Null
    if ($LASTEXITCODE -ne 0) { Fail 'сборщик переходника отказал' }
    Check 'переходник собран под ту таблицу, что названа в настройке' `
        ((Test-Path $generated) -and (([IO.File]::ReadAllText($generated)) -match "\[EventSubscriber\(Table,$TableNo,")) `
        "файл $(Split-Path -Leaf $generated), подписка на таблицу $TableNo"

    Import-Object $generated 'names-adapter'
    Compile-Codeunit $AdapterObjectNo 'names-adapter'
    $adapterUp = $true
    Restart-Nav 'подписку платформа замечает при старте'

    # Сторож заводится ДО опыта, и ловит эпизод он, а не прогон. Ждущая сессия NAV живёт
    # ровно предел ожидания - 10 000 мс, - а один вызов через Windows PowerShell 5.1
    # стартует дольше: к первому ручному проходу ждать уже некому, и журнал честно пуст.
    # Сторож ходит изнутри NAV раз в три секунды и в это окно попадает дважды.
    Invoke-Sql "UPDATE $setup SET [Enabled] = 1;" | Out-Null
    Invoke-Codeunit $TaskCodeunitId 'StartWatch' 'завод сторожа' | Out-Null

    $selfTest = Invoke-Codeunit $AdapterObjectNo 'SelfTest' 'обкатка переходника'
    Check 'платформа знает подписку выложенного переходника' `
        ($selfTest -match 'passed 3 of 3|пройдено 3 из 3') `
        (($selfTest -split "`n" | Where-Object { $_ -match 'passed|пройдено|ERROR|Ошибка' } | Select-Object -First 1) -replace '\s+', ' ')

    # ---------- 4. держатель и ждущий - обе сессии NAV ----------
    Invoke-Sql "DELETE FROM $episode WHERE [NAV Table Name] = N'$navTable'; DELETE FROM $mark;" | Out-Null

    Write-Host '  держатель пошёл: сессия NAV правит свою строку и не отпускает'
    $holdProc = Start-NavCall $HoldCodeunitId 'Hold' 'hold'
    $deadline = (Get-Date).AddSeconds(45)
    while ((Get-Date) -lt $deadline) {
        if ([int](Scalar "SELECT COUNT(*) FROM $markRead WHERE [Document No_] = N'$holdDoc';") -gt 0) { break }
        Start-Sleep -Milliseconds 400
    }
    $holdMark = Scalar "SELECT TOP 1 CONVERT(varchar(11),[Session Id]) + '|' + [User Id] + '|' + CONVERT(varchar(11),[Table No_]) FROM $markRead WHERE [Document No_] = N'$holdDoc';"
    $hm = ($holdMark -split '\|') | ForEach-Object { $_.Trim() }
    Check 'отметку виновника положил ПОДПИСЧИК, в его же транзакции' `
        (($hm.Count -eq 3) -and ($hm[0] -ne '') -and ($hm[1] -ne '') -and ($hm[2] -eq "$TableNo")) `
        "сеанс $($hm[0]), учётная запись [$($hm[1])], таблица $($hm[2]) при ожидаемой $TableNo"
    $holdUser = if ($hm.Count -eq 3) { $hm[1] } else { '' }

    Write-Host '  ждущий пошёл: своя строка, своя отметка, потом очередь за спорной'
    $waitProc = Start-NavCall $HoldCodeunitId 'Wait' 'wait'
    # Отметка ждущего живёт ровно его транзакцию, а транзакция кончится отказом по пределу
    # ожидания. Снимать её надо НА ЛЕТУ: через пятнадцать секунд её нет вовсе, и проверка
    # "у ждущего своя отметка" читалась бы как "переходник её не положил".
    $waitMark = ''
    $deadline = (Get-Date).AddSeconds(45)
    while ((Get-Date) -lt $deadline) {
        $waitMark = Scalar "SELECT TOP 1 CONVERT(varchar(11),[Session Id]) + '|' + [User Id] FROM $markRead WHERE [Document No_] = N'$waitDoc';"
        if ($waitMark -ne '') { break }
        Start-Sleep -Milliseconds 300
    }
    $wm = ($waitMark -split '\|') | ForEach-Object { $_.Trim() }
    Check 'у ждущего своя отметка, и в ней ЕГО документ, а не спорный' `
        (($wm.Count -eq 2) -and ($wm[0] -ne '') -and ($wm[1] -ne '') -and ($wm[0] -ne $hm[0])) `
        "сеанс $($wm[0]) при сеансе держателя $($hm[0]), учётная запись [$($wm[1])]"
    $waitUser = if ($wm.Count -eq 2) { $wm[1] } else { '' }

    # ---------- 5. эпизод ловит сторож ----------
    # Ждём не проход, а РЕЗУЛЬТАТ: обе учётные записи в строке журнала. Имя ждущего может
    # доспроситься следующим проходом после открытия эпизода (раздел 32), поэтому ожидание
    # тянется дольше одного окна ожидания.
    $deadline = (Get-Date).AddSeconds(60)
    while ((Get-Date) -lt $deadline) {
        $navUser = Scalar "SELECT TOP 1 [User Name] + '|' + [Victim User Name] FROM $episode WHERE [NAV Table Name] = N'$navTable' ORDER BY [Entry No_] DESC;"
        $u = ($navUser -split '\|') | ForEach-Object { $_.Trim() }
        if (($u.Count -eq 2) -and ($u[0] -ne '') -and ($u[1] -ne '')) { break }
        Start-Sleep -Milliseconds 500
    }

    $row = Scalar @"
SELECT TOP 1 [NAV Table Name] + '|' + [Document No_] + '|' +
  CONVERT(varchar(11),[Document Source]) + '|' + [User Name] + '|' +
  CONVERT(varchar(11),[User Source]) + '|' + [Victim User Name] + '|' +
  [Blocker Login] + '|' + [Victim Login] + '|' + [No Document Reason]
FROM $episode WHERE [NAV Table Name] = N'$navTable' ORDER BY [Entry No_] DESC;
"@
    $f = @(($row -split '\|') | ForEach-Object { $_.Trim() })
    while ($f.Count -lt 9) { $f += '' }

    Check 'эпизод заведён на той самой таблице' ($f[0] -eq $navTable) `
        "таблица в журнале [$($f[0])] при ожидаемой [$navTable]"

    # Две отметки лежат рядом, и перепутать их дороже, чем не найти ни одной: у ждущего в
    # отметке СВОЙ документ - тот, которым он занимался, - а спор идёт за чужой.
    Check 'в журнале спорный документ, а не тот, которым занималась жертва' `
        (($f[1] -eq $holdDoc) -and ($f[1] -ne $waitDoc)) `
        "документ [$($f[1])] при ожидаемом [$holdDoc], причина пустоты [$($f[8])]"

    # ЧЬЮ отметку прочитал инструмент - вопрос, на который ни одна проверка выше не
    # отвечает, и это выяснилось поломкой. Отметок в этот миг две, у держателя и у
    # ждущего; обе сессии идут под ОДНОЙ учётной записью (другой на стенде взять негде),
    # поэтому по имени они неразличимы. Документ тоже не различает: он приходит ПЕРВОЙ
    # дорогой, по хэшу спорной строки, и верен независимо от того, чью отметку прочли
    # второй. Прочитанная отметка ЖДУЩЕГО оставляла прогон зелёным целиком - 11 из 11.
    #
    # Различает их источник документа. Обе дороги называют документ, и сходятся они только
    # тогда, когда отметку клал ТОТ, КТО ДЕРЖИТ: у ждущего в отметке свой документ, и
    # разошедшиеся дороги инструмент помечает отдельным значением. Значение это прогон
    # читал и раньше - и не спрашивал.
    Check 'обе дороги к документу сошлись - значит прочитана отметка ДЕРЖАТЕЛЯ' `
        ($f[2] -eq '1') `
        "«Откуда документ» $($f[2]) при ожидаемом 1 (по хэшу спорной строки; 3 значит дороги разошлись, то есть отметка чужая)"

    Check 'ПОЛЬЗОВАТЕЛЬ назван, и это учётная запись из отметки виновника' `
        (($f[3] -ne '') -and ($f[3] -eq $holdUser)) `
        "«Пользователь» [$($f[3])] при учётной записи держателя [$holdUser]"

    Check 'откуда имя - по отметке контекста, а не от платформы' ($f[4] -eq '1') `
        "«Откуда имя» $($f[4]) при ожидаемом 1"

    Check 'КТО ЖДАЛ назван, и это учётная запись из отметки ждущего' `
        (($f[5] -ne '') -and ($f[5] -eq $waitUser)) `
        "«Кто ждал» [$($f[5])] при учётной записи ждущего [$waitUser]"

    # Два ответа на "кто" лежат рядом и об одном и том же сеансе говорят РАЗНОЕ: учётная
    # запись - человек, логин - служба, под которой ходит весь NAV. Совпади они - значит
    # одно затекло в другое, и колонка «Пользователь» перестала называть человека.
    Check 'логин SQL стоит рядом с учётной записью и не подменяет её' `
        (($f[6] -ne '') -and ($f[7] -ne '') -and ($f[6] -ne $f[3]) -and ($f[7] -ne $f[5])) `
        "логины [$($f[6])] и [$($f[7])], учётные записи [$($f[3])] и [$($f[5])]"
}
finally {
    Write-Host ''
    Write-Host 'Убираю за собой'
    if ($holdProc -and -not $holdProc.HasExited) { $holdProc.WaitForExit(120000) | Out-Null }
    if ($waitProc -and -not $waitProc.HasExited) { $waitProc.WaitForExit(60000) | Out-Null }
    if ($adapterUp) {
        # Объект убирается ДО перезапуска, а подписку платформа забывает при старте. Оставить
        # подписку на удалённый кодюнит значило бы уронить чужую таблицу на каждой записи.
        Delete-Codeunit $AdapterObjectNo 'names-adapter'
        Restart-Nav 'подписчика на чужой таблице не оставляем'
    }
    if ($sqlTableName -and $docColumn) {
        Invoke-Sql "DELETE FROM [$sqlTableName] WHERE [$docColumn] LIKE N'LOCKWATCH-LIVE%';" | Out-Null
    }
    $cleanup = "DELETE FROM $mark; UPDATE $setup SET [Enabled] = 0, [Deadlocks Enabled] = 1, [Coverage Enabled] = 1;" +
               " DELETE FROM [dbo].[Scheduled Task] WHERE [Run Codeunit] = $TaskCodeunitId;"
    if ($hadContext -eq 0) { $cleanup += " DELETE FROM $context WHERE [Table No_] = $TableNo;" }
    Invoke-Sql $cleanup | Out-Null
    Write-Host '  переходник снят, строки убраны, отметки очищены'
}

Write-Host ''
Write-Host "пройдено $passed из $total"
$report | ForEach-Object { Write-Host $_ }
if ($passed -ne $total) { Fail 'дорога к имени не пройдена' }
Write-Host 'Готово: имя доезжает от подписчика до журнала' -ForegroundColor Green
