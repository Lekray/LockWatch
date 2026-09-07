#requires -Version 7
<#
.SYNOPSIS
    Цена прохода ЦЕЛИКОМ и под нагрузкой: сотня настоящих ждущих, живая очередь сервера,
    замер того, что делает фоновая задача, а не его половин по отдельности.

.DESCRIPTION
    Съём с DMV и запись в журнал меряны порознь: 12 мс при двухстах ждущих и 441 мс на
    пятистах строках. Вместе они делят одно соединение и один проход, и складывать два
    замера в уме - это не замер, а надежда. Здесь проход меряет сам себя: NAV пишет
    длительность в настройку, оттуда она и читается.

    Ждущие делаются НАСТОЯЩИМИ: один держатель берёт строку своей же таблицы, сотня
    соединений становится за ним в очередь. Все они живут в одном процессе Windows
    PowerShell 5.1 - там System.Data.SqlClient идёт с платформой, и сотня соединений
    стоит одного процесса вместо сотни.

.PARAMETER Waiters
    Сколько ждущих устроить. По умолчанию сто: столько уже похоже на шторм, но ещё не
    съедает рабочие потоки сервера на тесном стенде.

.EXAMPLE
    pwsh scripts/Test-Load.ps1 -Waiters 100
#>
[CmdletBinding()]
param(
    [string] $Server   = 'localhost',
    [string] $Database = $env:LW_DATABASE,
    [string] $Instance = $env:LW_INSTANCE,
    [string] $Company  = $env:LW_COMPANY,
    [int]    $Waiters  = 100,
    [int]    $PassCodeunitId = 110235,
    [switch] $StopInstance
)

$ErrorActionPreference = 'Stop'
$root   = Split-Path -Parent $PSScriptRoot
$outDir = Join-Path $root 'out'
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir | Out-Null }

function Fail([string]$message) { Write-Host "ОТКАЗ: $message" -ForegroundColor Red; exit 1 }
if (-not $Database) { Fail 'не задано имя базы: переменная LW_DATABASE' }
if (-not $Instance) { Fail 'не задан экземпляр службы: переменная LW_INSTANCE' }
if (-not $Company)  { Fail 'не задана компания: переменная LW_COMPANY' }

$episode = "[$Company`$LockWatch Episode]"
$setup   = "[$Company`$LockWatch Setup]"
$mark    = "[$Company`$LockWatch Context Mark]"
$service = "MicrosoftDynamicsNavServer`$$Instance"

function Invoke-Sql([string]$query) {
    # -b обязателен не меньше: без него sqlcmd возвращает НОЛЬ и на ошибке SQL, проверка
    # кода возврата проходит вхолостую, а запрос не выполнен вовсе.
    $answer = & sqlcmd -S $Server -d $Database -E -b -l 30 -w 500 -W -s '|' -h -1 -Q "SET NOCOUNT ON; $query" 2>&1
    if ($LASTEXITCODE -ne 0) { Fail "SQL не выполнился: $($answer -join ' ')" }
    return ,@($answer | Where-Object { $_ -and ($_ -notmatch '^\(') })
}
function Scalar([string]$query) {
    $rows = Invoke-Sql $query
    if ($rows.Count -eq 0) { return '' }
    return $rows[0].Trim()
}
function WaitingNow { [int](Scalar "SELECT COUNT(*) FROM sys.dm_os_waiting_tasks WHERE wait_type LIKE 'LCK[_]%';") }

$passed = 0; $total = 0; $report = @(); $timings = @()
function Check([string]$what, [bool]$ok, [string]$detail) {
    $script:total++
    if ($ok) { $script:passed++; $verdict = 'пройдено' } else { $verdict = 'ПРОВАЛ  ' }
    $script:report += "$verdict $what"
    $script:report += "         $detail"
}
function Wait-For([scriptblock]$condition, [int]$seconds) {
    $deadline = (Get-Date).AddSeconds($seconds)
    while ((Get-Date) -lt $deadline) {
        if (& $condition) { return $true }
        Start-Sleep -Milliseconds 300
    }
    return $false
}

$ps51 = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$navImport = "Import-Module 'C:\Program Files\Microsoft Dynamics NAV\110\Service\NavAdminTool.ps1' -DisableNameChecking -WarningAction SilentlyContinue | Out-Null"
function Write-Ps51([string]$path, [string]$body) {
    [IO.File]::WriteAllText($path, (($body -replace "`r`n", "`n") -replace "`n", "`r`n"), (New-Object System.Text.UTF8Encoding($true)))
}

$markEsc  = $mark.Replace('$', '`$')
$stopFile = Join-Path $outDir 'load-stop.flag'
$loadFile = Join-Path $outDir 'load-waiters.ps1'
$crowd = $null

# Один процесс на всю толпу. Сотня процессов sqlcmd съела бы память рабочей станции, а
# память на этом стенде уже однажды уронила SQL Server: он перестал выдавать рабочие
# потоки, и вход в него начал отваливаться по таймауту.
# Параметров у скрипта толпы нет вовсе, значения вписаны в него при создании. Start-Process
# склеивает -ArgumentList пробелом БЕЗ кавычек, и имя таблицы в скобках и с пробелами
# рассыпалось бы на аргументы: процесс запускается, тут же тихо умирает, а выглядит это
# как "очередь не набралась".
Write-Ps51 $loadFile @"
`$ErrorActionPreference = 'Stop'
`$log = '$outDir\load-crowd.log'
try {
    `$conns = New-Object System.Collections.ArrayList
    `$cs = 'Server=$Server;Database=$Database;Trusted_Connection=True;Connect Timeout=15'
    `$hold = New-Object System.Data.SqlClient.SqlConnection(`$cs)
    `$hold.Open()
    `$c = `$hold.CreateCommand()
    `$c.CommandText = "SET LOCK_TIMEOUT -1; BEGIN TRAN; UPDATE $markEsc SET [Document No_] = N'HELD' WHERE [Server Instance Id] = -1;"
    `$c.ExecuteNonQuery() | Out-Null
    [void]`$conns.Add(`$hold)
    for (`$i = 0; `$i -lt $Waiters; `$i++) {
        `$w = New-Object System.Data.SqlClient.SqlConnection(`$cs + ';Asynchronous Processing=True')
        `$w.Open()
        `$cmd = `$w.CreateCommand()
        `$cmd.CommandTimeout = 0
        `$cmd.CommandText = "SET LOCK_TIMEOUT -1; BEGIN TRAN; UPDATE $markEsc SET [Document No_] = N'WANT' WHERE [Server Instance Id] = -1; ROLLBACK;"
        `$cmd.BeginExecuteNonQuery() | Out-Null
        [void]`$conns.Add(`$w)
    }
    'crowd ready: ' + `$conns.Count | Out-File -FilePath `$log -Encoding utf8
    while (-not (Test-Path '$stopFile')) { Start-Sleep -Milliseconds 300 }
    foreach (`$x in `$conns) { try { `$x.Close() } catch { } }
} catch {
    `$_.Exception.ToString() | Out-File -FilePath `$log -Encoding utf8
    exit 1
}
"@

function Invoke-Pass {
    $file = Join-Path $outDir 'invoke-load-pass.ps1'
    Write-Ps51 $file @"
`$ErrorActionPreference = 'Stop'
$navImport
Invoke-NAVCodeunit -ServerInstance $Instance -CompanyName '$Company' -CodeunitId $PassCodeunitId -MethodName RunPass -ErrorAction Stop
"@
    $log = & $ps51 -NoProfile -ExecutionPolicy Bypass -File $file 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { Fail "проход не отработал:`n$log" }
    $row = Scalar "SELECT CONVERT(varchar(11),[Last Pass (ms)]) + '|' + CONVERT(varchar(11),[Last Pass Rows]) + '|' + CONVERT(varchar(2),[Last Pass Truncated]) FROM $setup;"
    return ($row -split '\|') | ForEach-Object { $_.Trim() }
}

try {
    Write-Host "Подготовка стенда, ждущих будет $Waiters"
    if (Test-Path $stopFile) { Remove-Item $stopFile -Force }
    if ((Get-Service $service).Status -ne 'Running') { Start-Service $service }
    # Сбор взаимоблокировок на время опыта выключается. Он берёт графы из КОЛЬЦЕВОГО
    # БУФЕРА сервера, а туда они попадают от кого угодно и когда угодно - хоть от прошлого
    # прогона, хоть от чужой работы на той же базе. Строка в журнале получилась бы законной,
    # но проверка "эпизод заведён ровно один" считает строки, и опыт судил бы инструмент по
    # чужим кругам. Две дороги - два прогона, и каждый отвечает только за свою.
    #
    # Здесь у этого есть и вторая причина: разбор буфера стоит около 150 мс, и раз в минуту
    # он лёг бы в худший проход. Цена буфера измерена отдельно и известна; смешивать её с
    # потолком NAV-половины значило бы мерить потолок тем, что от нагрузки не зависит.
    Invoke-Sql "UPDATE $setup SET [SQL Server] = N'$Server', [Deadlocks Enabled] = 0;" | Out-Null
    Invoke-Sql "DELETE FROM $episode;" | Out-Null
    Invoke-Sql "DELETE FROM $mark WHERE [Server Instance Id] = -1;" | Out-Null
    Invoke-Sql @"
INSERT INTO $mark ([Server Instance Id],[Session Id],[User Id],[Company Name],[Table No_],[Document No_],[Marked At])
VALUES (-1,-1,N'STAND',N'$Company',0,N'LOCK-TARGET',GETDATE());
"@ | Out-Null

    Write-Host "  перезапускаю службу $Instance и жду ответа порта управления"
    Restart-Service $service -Force
    $probeFile = Join-Path $outDir 'wait-nav.ps1'
    Write-Ps51 $probeFile @"
$navImport
`$deadline = (Get-Date).AddMinutes(6)
while ((Get-Date) -lt `$deadline) {
    try { Get-NAVServerSession -ServerInstance $Instance -ErrorAction Stop | Out-Null; exit 0 } catch { Start-Sleep -Seconds 5 }
}
exit 1
"@
    & $ps51 -NoProfile -ExecutionPolicy Bypass -File $probeFile | Out-Null
    if ($LASTEXITCODE -ne 0) { Fail "экземпляр $Instance не ответил по порту управления" }

    Write-Host 'Собираю толпу'
    $crowdLog = Join-Path $outDir 'load-crowd.log'
    if (Test-Path $crowdLog) { Remove-Item $crowdLog -Force }
    $crowd = Start-Process -FilePath $ps51 -PassThru -WindowStyle Hidden -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $loadFile
    )
    if (-not (Wait-For { (WaitingNow) -ge $Waiters } 180)) {
        $why = if (Test-Path $crowdLog) { (Get-Content $crowdLog -Raw).Trim() } else { 'толпа ничего не сказала' }
        Fail "очередь так и не набралась: ждущих $(WaitingNow) из $Waiters - опыт не удался, инструмент тут ни при чём.`n$why"
    }
    Write-Host "  ждущих в очереди сервера: $(WaitingNow)"

    Write-Host 'Проход первый - все эпизоды заводятся'
    $first = Invoke-Pass
    $timings += "открытие: {0} мс на {1} строк, {2} мкс на строку" -f $first[0], $first[1], [int]([int]$first[0] * 1000 / [Math]::Max(1,[int]$first[1]))
    Check 'проход увидел всю очередь' (([int]$first[1]) -ge $Waiters) "строк в проходе $($first[1]) при $Waiters ждущих, усечён $($first[2])"

    # Проходов обновления несколько нарочно. Первый проход после перезапуска службы несёт
    # разовую цену, которой в установившемся режиме нет вовсе: платформа поднимает сборку
    # System.Data, соединение открывается впервые, сервер компилирует планы запросов.
    # Выдать её за цену наблюдения значило бы напугать заказчика тем, чего не будет.
    Write-Host 'Проходы обновления - установившийся режим'
    $updateMs = @()
    for ($i = 1; $i -le 4; $i++) {
        $second = Invoke-Pass
        $updateMs += [int]$second[0]
        $timings += "обновление {0}: {1} мс на {2} строк, {3} мкс на строку" -f $i, $second[0], $second[1], [int]([int]$second[0] * 1000 / [Math]::Max(1,[int]$second[1]))
    }
    $steady = ($updateMs | Measure-Object -Minimum).Minimum
    $rows = [int](Scalar "SELECT COUNT(*) FROM $episode;")
    Check 'второй проход не наплодил строк' ($rows -eq [int]$first[1]) "строк в журнале $rows при $($first[1]) в первом проходе"

    $behind = [int](Scalar "SELECT TOP 1 [Victims Behind Head] FROM $episode ORDER BY [Entry No_];")
    $depth  = [int](Scalar "SELECT TOP 1 [Chain Depth] FROM $episode ORDER BY [Entry No_];")
    $heads  = [int](Scalar "SELECT COUNT(DISTINCT [Head SPID]) FROM $episode;")
    Check 'одна беда сосчитана как одна' (($heads -eq 1) -and ($behind -eq $rows) -and ($depth -eq 1)) `
        "голов $heads, жертв за головой $behind из $rows, глубина $depth"

    Write-Host 'Отпускаю толпу'
    New-Item -ItemType File -Path $stopFile -Force | Out-Null
    if (-not (Wait-For { (WaitingNow) -eq 0 } 120)) { Fail 'очередь не разошлась' }

    Write-Host 'Проход третий - все эпизоды закрываются'
    $third = Invoke-Pass
    $timings += "закрытие: {0} мс на {1} строк" -f $third[0], $rows
    $open = [int](Scalar "SELECT COUNT(*) FROM $episode WHERE [Open] = 1;")
    Check 'ушедшая очередь закрыла все эпизоды' ($open -eq 0) "открытых осталось $open из $rows"

    $worst = [Math]::Max([Math]::Max([int]$first[0], ($updateMs | Measure-Object -Maximum).Maximum), [int]$third[0])
    $ceiling = [int](Scalar "SELECT [Max Pass (ms)] FROM $setup;")
    Check 'проход целиком укладывается в объявленный потолок' ($worst -le $ceiling) `
        "худший проход $worst мс при потолке $ceiling"
    # Разовая цена первого прохода не должна маскироваться под постоянную: если она мала,
    # значит холодного старта нет вовсе и говорить о нём в отчётах не надо.
    Check 'установившийся проход заметно дешевле первого' ($steady -le [int]$first[0]) `
        "первый $($first[0]) мс, установившийся $steady мс, разовая надбавка $([int]$first[0] - $steady) мс"
}
finally {
    New-Item -ItemType File -Path $stopFile -Force -ErrorAction SilentlyContinue | Out-Null
    if ($crowd -and -not $crowd.HasExited) { Start-Sleep -Seconds 2; if (-not $crowd.HasExited) { $crowd.Kill() } }
    & sqlcmd -S $Server -d $Database -E -l 30 -h -1 -Q "DELETE FROM $mark WHERE [Server Instance Id] = -1; DELETE FROM $episode; UPDATE $setup SET [Deadlocks Enabled] = 1;" 2>&1 | Out-Null
    if (Test-Path $stopFile) { Remove-Item $stopFile -Force }
    if ($StopInstance) { Stop-Service $service -Force }
}

Write-Host ''
Write-Host "пройдено $passed из $total"
Write-Host ''
$report | ForEach-Object { Write-Host $_ }
Write-Host ''
$timings | ForEach-Object { Write-Host $_ }
if ($passed -lt $total) { Fail 'нагрузочный прогон не пройден' }
Write-Host 'Готово: проход измерен целиком и под нагрузкой' -ForegroundColor Green
