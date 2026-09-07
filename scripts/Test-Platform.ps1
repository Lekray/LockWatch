#requires -Version 7
<#
.SYNOPSIS
    Дорога к имени ЧЕЛОВЕКА от самой платформы: жива ли она, и говорит ли инструмент правду,
    когда она мертва.

.DESCRIPTION
    Уровень 2 стоит дорого - правка CustomSettings.config, перезапуск экземпляра, оба права
    SQL и постоянная серверная сессия XE, - и потому включается решением заказчика. Но
    страшнее цены другое: **отказ этой дороги невидим**. Не выдали право или не взвели ключ -
    платформа пишет одну строку трассировки, а штатная таблица ведёт себя в точности как при
    отсутствии блокировок. Экран будет пуст и на здоровой системе, и на сломанной.

    Поэтому прогон меряет обе стороны. Сперва ключ СНИМАЕТСЯ, и инструмент обязан сказать
    словами, что дорога мертва, - а не показать пустую колонку. Потом ключ взводится, и на
    настоящей блокировке имя обязано появиться.

    Держателем блокировки здесь может быть только СЕССИЯ NAV: штатная таблица показывает
    лишь те транзакции, что платформа завела в свою карту, а соединение sqlcmd в неё не
    попадает никогда. Держит Codeunit 110242, ждёт всё тот же sqlcmd.

    Прогон возвращает ключ в то состояние, в котором его нашёл.

.EXAMPLE
    pwsh scripts/Test-Platform.ps1
#>
[CmdletBinding()]
param(
    [string] $Server   = 'localhost',
    [string] $Database = $env:LW_DATABASE,
    [string] $Instance = $env:LW_INSTANCE,
    [string] $Company  = $env:LW_COMPANY,
    [int]    $PassCodeunitId = 110235,
    [int]    $PlatformCodeunitId = 110241,
    [int]    $HoldCodeunitId = 110242,
    [switch] $KeepJournal,
    [switch] $StopInstance
)

$ErrorActionPreference = 'Stop'
$root   = Split-Path -Parent $PSScriptRoot
$outDir = Join-Path $root 'out'
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir | Out-Null }

function Fail([string]$message) { Write-Host "ОТКАЗ: $message" -ForegroundColor Red; exit 1 }
if (-not $Database) { Fail 'не задано имя базы: переменная LW_DATABASE или параметр -Database' }
if (-not $Instance) { Fail 'не задан экземпляр службы: переменная LW_INSTANCE' }
if (-not $Company)  { Fail 'не задана компания: переменная LW_COMPANY' }

$episode = "[$Company`$LockWatch Episode]"
$setup   = "[$Company`$LockWatch Setup]"
$mark    = "[$Company`$LockWatch Context Mark]"
$service = "MicrosoftDynamicsNavServer`$$Instance"
$expectedUser = "$env:USERDOMAIN\$env:USERNAME"

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

$ps51 = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$navImport = "Import-Module 'C:\Program Files\Microsoft Dynamics NAV\110\Service\NavAdminTool.ps1' -DisableNameChecking -WarningAction SilentlyContinue | Out-Null"
function Write-Ps51([string]$path, [string]$body) {
    [IO.File]::WriteAllText($path, (($body -replace "`r`n", "`n") -replace "`n", "`r`n"), (New-Object System.Text.UTF8Encoding($true)))
}
$probeFile = Join-Path $outDir 'wait-nav-platform.ps1'
Write-Ps51 $probeFile @"
$navImport
`$deadline = (Get-Date).AddMinutes(6)
while ((Get-Date) -lt `$deadline) {
    try { Get-NAVServerSession -ServerInstance $Instance -ErrorAction Stop | Out-Null; exit 0 } catch { Start-Sleep -Seconds 5 }
}
exit 1
"@
function Invoke-Codeunit([int]$id, [string]$method, [string]$why) {
    $runFile = Join-Path $outDir "invoke-plat-$id-$method.ps1"
    Write-Ps51 $runFile @"
`$ErrorActionPreference = 'Stop'
$navImport
Invoke-NAVCodeunit -ServerInstance $Instance -CompanyName '$Company' -CodeunitId $id -MethodName $method -ErrorAction Stop
"@
    $log = & $ps51 -NoProfile -ExecutionPolicy Bypass -File $runFile 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { Fail "$why не отработал:`n$log" }
    return $log
}
function Start-Codeunit([int]$id, [string]$method) {
    $runFile = Join-Path $outDir "invoke-plat-bg-$id-$method.ps1"
    Write-Ps51 $runFile @"
`$ErrorActionPreference = 'Stop'
$navImport
Invoke-NAVCodeunit -ServerInstance $Instance -CompanyName '$Company' -CodeunitId $id -MethodName $method -ErrorAction Stop
"@
    return Start-Process -FilePath $ps51 -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput (Join-Path $outDir 'hold-answer.txt') `
        -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$runFile`""
}
function Set-Monitoring([string]$value, [string]$why) {
    $cfgFile = Join-Path $outDir 'set-monitoring.ps1'
    Write-Ps51 $cfgFile @"
`$ErrorActionPreference = 'Stop'
$navImport
Set-NAVServerConfiguration -ServerInstance $Instance -KeyName EnableDeadlockMonitoring -KeyValue $value -ErrorAction Stop
"@
    & $ps51 -NoProfile -ExecutionPolicy Bypass -File $cfgFile | Out-Null
    if ($LASTEXITCODE -ne 0) { Fail "ключ мониторинга не переключился ($why)" }
    Write-Host "  ключ EnableDeadlockMonitoring = $value, перезапускаю службу ($why)"
    Restart-Service $service -Force
    & $ps51 -NoProfile -ExecutionPolicy Bypass -File $probeFile | Out-Null
    if ($LASTEXITCODE -ne 0) { Fail "экземпляр $Instance не ответил по порту управления" }
}
function Get-Monitoring() {
    $cfgFile = Join-Path $outDir 'get-monitoring.ps1'
    Write-Ps51 $cfgFile @"
$navImport
(Get-NAVServerConfiguration -ServerInstance $Instance | Where-Object { `$_.Key -eq 'EnableDeadlockMonitoring' }).Value
"@
    $value = (& $ps51 -NoProfile -ExecutionPolicy Bypass -File $cfgFile 2>&1 | Where-Object { $_ -match '^(true|false)$' } | Select-Object -First 1)
    if (-not $value) { Fail 'текущее значение ключа мониторинга прочитать не удалось' }
    return "$value".Trim()
}
function Start-Sqlcmd([string]$name, [string]$body) {
    $file = Join-Path $outDir $name
    [IO.File]::WriteAllText($file, (($body -replace "`r`n", "`n") -replace "`n", "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
    # Путь БЕЗ кавычек: список аргументов Start-Process экранирует его сам, а добавленные
    # руками кавычки уезжают в sqlcmd частью имени файла, и он молча не находит его.
    return Start-Process -FilePath 'sqlcmd' -PassThru -WindowStyle Hidden `
        -ArgumentList @('-S', $Server, '-d', $Database, '-E', '-b', '-l', '30', '-i', $file)
}
function Stop-Sqlcmd($process) {
    if ($process -and -not $process.HasExited) { $process.Kill(); $process.WaitForExit(10000) | Out-Null }
}

$wasMonitoring = ''
$holder = $null
$waiter = $null
try {
    Write-Host 'Подготовка стенда'
    if ((Get-Service $service).Status -ne 'Running') { Start-Service $service }
    $wasMonitoring = Get-Monitoring
    Write-Host "  ключ мониторинга найден в состоянии $wasMonitoring"
    Invoke-Sql "UPDATE $setup SET [SQL Server] = N'$Server', [Platform Names Enabled] = 1, [Alert Channel] = 0, [Deadlocks Enabled] = 0;" | Out-Null
    if (-not $KeepJournal) { Invoke-Sql "DELETE FROM $episode;" | Out-Null }
    Invoke-Sql "DELETE FROM $mark WHERE [Server Instance Id] = -1;" | Out-Null

    # ---------- дорога СНЯТА: инструмент обязан сказать это словами ----------
    Write-Host 'Ключ снят - дорога должна быть названа мёртвой'
    Set-Monitoring 'false' 'дорога снимается'
    Invoke-Codeunit $PlatformCodeunitId 'CheckRoad' 'проверка дороги при снятом ключе' | Out-Null
    $deadStatus = Scalar "SELECT [Platform Road Status] FROM $setup;"
    Check 'при снятом ключе дорога названа мёртвой, а не показана пустой колонкой' `
        (($deadStatus -match 'мертва|dead') -and ($deadStatus.Length -gt 20)) `
        "сторож пишет: $deadStatus"

    # ---------- дорога ВЗВЕДЕНА ----------
    Write-Host 'Ключ взведён - дорога должна ожить'
    Set-Monitoring 'true' 'дорога взводится'
    Invoke-Codeunit $PlatformCodeunitId 'CheckRoad' 'проверка дороги при взведённом ключе' | Out-Null
    $aliveStatus = Scalar "SELECT [Platform Road Status] FROM $setup;"
    Check 'при взведённом ключе сессия мониторинга поднята платформой' `
        ($aliveStatus -match 'жива|alive') `
        "сторож пишет: $aliveStatus"

    # ---------- настоящая блокировка, держит СЕССИЯ NAV ----------
    Write-Host 'Блокировку держит сессия NAV, ждёт sqlcmd'
    Invoke-Sql @"
INSERT INTO $mark ([Server Instance Id],[Session Id],[User Id],[Company Name],[Table No_],[Document No_],[Marked At])
VALUES (-1,-1,N'STAND',N'$Company',0,N'PLATFORM-TARGET',GETDATE());
"@ | Out-Null
    $holder = Start-Codeunit $HoldCodeunitId 'Hold'

    # Ждём, пока держатель ВОЗЬМЁТ блокировку. Без этого гонка: ждущий встал бы первым и
    # держателем оказался бы он сам, а сессия NAV осталась бы ни при чём.
    $held = $false
    $deadline = (Get-Date).AddSeconds(90)
    while ((Get-Date) -lt $deadline) {
        # Чтение ГРЯЗНОЕ, и это не небрежность. Обычное чтение встало бы в очередь за той
        # самой блокировкой, которую мы ждём: опрос заблокировался бы на всё время
        # удержания, вернул бы ответ уже ПОСЛЕ его конца, и ждущему не за чем было бы
        # вставать. Ловилось ровно так: sqlcmd умирал сразу с нулевым кодом.
        $doc = Scalar "SELECT [Document No_] FROM $mark WITH (READUNCOMMITTED) WHERE [Server Instance Id] = -1;"
        if ($doc -eq 'HELD-BY-NAV') { $held = $true; break }
        Start-Sleep -Milliseconds 500
    }
    if (-not $held) { Fail 'сессия NAV блокировку так и не взяла - опыт не удался, инструмент тут ни при чём' }

    $waiter = Start-Sqlcmd 'platform-want.sql' "SET LOCK_TIMEOUT -1`nBEGIN TRAN`nUPDATE $mark SET [Document No_] = N'WANT' WHERE [Server Instance Id] = -1`nROLLBACK`n"
    # Ждущий, умерший на старте, выглядит точно как ждущий, который не успел встать в
    # очередь. Разница видна только по самому процессу, и спросить о ней надо до того, как
    # прогон объявит "инструмент не увидел блокировку".
    Start-Sleep -Seconds 2
    if ($waiter.HasExited) { Fail "ждущий sqlcmd умер сразу, код выхода $($waiter.ExitCode) - опыт не удался" }
    $waitRow = ''
    $deadline = (Get-Date).AddSeconds(40)
    while ((Get-Date) -lt $deadline) {
        $waitRow = Scalar @"
SELECT TOP 1 CONVERT(varchar(11),wt.session_id)
FROM sys.dm_os_waiting_tasks wt
JOIN sys.dm_exec_sessions s ON s.session_id = wt.session_id
WHERE wt.wait_type LIKE 'LCK[_]%' AND s.host_process_id = $($waiter.Id);
"@
        if ($waitRow) { break }
        Start-Sleep -Milliseconds 500
    }
    if (-not $waitRow) { Fail 'ожидание в очереди сервера так и не появилось - опыт не удался' }

    # Что платформа видит в этот миг - печатается ВСЕГДА, а не только при отказе: когда имя
    # не назовётся, разбираться придётся именно по этому списку.
    $locksLog = Invoke-Codeunit $PlatformCodeunitId 'ShowLocks' 'список блокировок платформы'
    if ($locksLog -match 'PLATFORMLOCKS rows (\d+) head (.*)') {
        Write-Host "  платформа видит строк: $($Matches[1])"
        Write-Host "  первые: $($Matches[2] -replace '\s+', ' ')"
    }

    Invoke-Codeunit $PassCodeunitId 'RunPass' 'проход по живой очереди' | Out-Null
    $rows = [int](Scalar "SELECT COUNT(*) FROM $episode;")
    Check 'эпизод по блокировке сессии NAV заведён' ($rows -ge 1) "строк в журнале $rows"

    # ---------- главная проверка: правду о мёртвой карте ----------
    # Здесь и выясняется цена всей затеи. Ключ взведён, права на месте, сессия мониторинга
    # работает - а таблица пуста ПРИ НЕПУСТОЙ ОЧЕРЕДИ. Инструмент обязан сказать это
    # словами, а не показать пустую колонку: пустая колонка читается как "спорили без
    # людей", и это ровно противоположный вывод.
    Invoke-Codeunit $PlatformCodeunitId 'CheckRoad' 'проверка дороги при живой блокировке' | Out-Null
    $liveStatus = Scalar "SELECT [Platform Road Status] FROM $setup;"
    Check 'при живой блокировке и пустой штатной таблице сказано, что карта мертва' `
        ($liveStatus -match 'карта мертва|the map is dead') `
        "сторож пишет: $liveStatus"

    $nameLog = Invoke-Codeunit $PlatformCodeunitId 'NameOpen' 'называние пользователя платформой'
    $named = 0; $tried = 0; $note = ''
    if ($nameLog -match 'PLATFORMNAME named (\d+) of (\d+) note (.*)') {
        $named = [int]$Matches[1]; $tried = [int]$Matches[2]; $note = $Matches[3].Trim()
    }
    $row = Scalar @"
SELECT TOP 1 [User Name] + '|' + CONVERT(varchar(11),[User Source]) + '|' + [Blocker AL Scope]
FROM $episode ORDER BY [Entry No_] DESC;
"@
    $f = ($row -split '\|') | ForEach-Object { $_.Trim() }
    # Имя, которого платформа не дала, выдумывать нельзя. Источник обязан остаться прежним -
    # тем, что назвала наша собственная отметка контекста, - а не стать платформенным.
    Check 'имя, которого платформа не дала, не выдумано' `
        (($tried -ge 1) -and ($named -eq 0) -and ($f.Count -ge 2) -and ($f[1] -ne '2') -and ($note.Length -gt 20)) `
        "названо $named из $tried, откуда имя $($f[1]) (не 2), объяснение: $note"
}
finally {
    Write-Host 'Убираю за собой'
    Stop-Sqlcmd $waiter
    if ($holder -and -not $holder.HasExited) { $holder.WaitForExit(90000) | Out-Null }
    # Ответ держателя читается ПОСЛЕ его конца: он и есть решающий опыт про карту
    # транзакций - видит ли сессия хотя бы собственную блокировку.
    $holdOut = Join-Path $outDir 'hold-answer.txt'
    if (Test-Path $holdOut) {
        $answer = [IO.File]::ReadAllText($holdOut)
        if ($answer -match 'LOCKHOLD user (\S+) session (\d+) ms (\d+) ownrows (\d+) laterows (\d+)') {
            Write-Host "  держатель видел строк платформы: сразу $($Matches[4]), при ждущем $($Matches[5]); его учётка $($Matches[1])"
        }
        Remove-Item $holdOut -Force
    }
    & sqlcmd -S $Server -d $Database -E -b -l 30 -h -1 -Q `
        "DELETE FROM $mark WHERE [Server Instance Id] = -1; UPDATE $setup SET [Platform Names Enabled] = 0, [Alert Channel] = 1, [Deadlocks Enabled] = 1;$(if (-not $KeepJournal) { " DELETE FROM $episode;" })" 2>&1 | Out-Null
    # Ключ возвращается в то состояние, в котором его нашли: включённый мониторинг живёт
    # серверной сессией XE, которая переживает снятие инструмента, и оставлять его
    # взведённым по итогам прогона нельзя.
    if ($wasMonitoring) {
        try { Set-Monitoring $wasMonitoring 'ключ возвращается как был' } catch { Write-Host 'ВНИМАНИЕ: ключ мониторинга вернуть не удалось' -ForegroundColor Red }
    }
    if ($StopInstance) { Stop-Service $service -Force }
}

Write-Host ''
Write-Host "пройдено $passed из $total"
Write-Host ''
$report | ForEach-Object { Write-Host $_ }
if ($passed -lt $total) { Fail 'дорога от платформы проверку не прошла' }
Write-Host 'Готово: дорога от платформы измерена, и её молчание названо словами' -ForegroundColor Green
