#requires -Version 7
<#
.SYNOPSIS
    Проверка прохода на НАСТОЯЩЕЙ блокировке: два соединения дерутся за одну строку,
    проход снимает очередь, и журнал сверяется с тем, что происходит на самом деле.

.DESCRIPTION
    Всё, что можно было проверить без базы, проверено обкаткой разбора; всё, что можно
    было проверить без ожидания, - мерным прогоном журнала. Осталось то, что не проверить
    ни тем, ни другим: доходит ли до C/AL описание ресурса, разбирается ли оно в имя
    таблицы и номер ключа, разматывается ли цепочка до головы и закрывается ли эпизод,
    когда жертва ушла из очереди.

    Блокировка устраивается на СВОЕЙ таблице (отметка контекста), а не на чужой: чужая
    строка на стенде - это чужие данные, а своя пуста и никому не мешает. На таблице
    настройки её устраивать нельзя вовсе - настройку читает сам проход, и опыт
    заблокировал бы наблюдателя.

    Жертва и виновник - обычные соединения sqlcmd, а не сеансы NAV, и это нарочно: у чужой
    сессии предел ожидания NAV не действует, поэтому проход обязан ответить "исход не
    определён", а не приписать ей чужой предел. Опознаются они по номеру процесса, а не по
    номеру сеанса: номер процесса известен заранее, номер сеанса пришлось бы угадывать.

.PARAMETER KeepJournal
    Не чистить журнал эпизодов ни перед опытом, ни после. По умолчанию журнал очищается
    и до, и после: проверки считают строки, и чужая строка сделала бы их бессмысленными,
    а оставленная своя помешала бы следующему прогону.

.EXAMPLE
    pwsh scripts/Test-Pass.ps1
#>
[CmdletBinding()]
param(
    [string] $Server   = 'localhost',
    [string] $Database = $env:LW_DATABASE,
    [string] $Instance = $env:LW_INSTANCE,
    [string] $Company  = $env:LW_COMPANY,
    [int]    $PassCodeunitId = 110235,
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

function Invoke-Sql([string]$query) {
    $answer = & sqlcmd -S $Server -d $Database -E -l 30 -W -s '|' -h -1 -Q "SET NOCOUNT ON; $query" 2>&1
    if ($LASTEXITCODE -ne 0) { Fail "SQL не выполнился: $($answer -join ' ')" }
    return ,@($answer | Where-Object { $_ -and ($_ -notmatch '^\(') })
}
function Scalar([string]$query) {
    $rows = Invoke-Sql $query
    if ($rows.Count -eq 0) { return '' }
    return $rows[0].Trim()
}

$passed = 0; $total = 0; $report = @()
function Check([string]$what, [bool]$ok, [string]$detail) {
    $script:total++
    if ($ok) { $script:passed++; $verdict = 'пройдено' } else { $verdict = 'ПРОВАЛ  ' }
    $script:report += "$verdict $what"
    $script:report += "         $detail"
}

$blocker = $null; $waiter = $null
# Запрос уезжает ФАЙЛОМ, а не параметром -Q. Start-Process склеивает элементы -ArgumentList
# пробелом и кавычек вокруг них не ставит: запрос с пробелами рассыпается на аргументы,
# sqlcmd молча выходит с ошибкой, а выглядит это как "блокировка не случилась".
function Start-Sqlcmd([string]$name, [string]$sql) {
    $file = Join-Path $outDir $name
    [IO.File]::WriteAllText($file, (($sql -replace "`r`n", "`n") -replace "`n", "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
    Start-Process -FilePath 'sqlcmd' -PassThru -WindowStyle Hidden -ArgumentList @(
        '-S', $Server, '-d', $Database, '-E', '-l', '30', '-i', $file
    )
}
function Stop-Sqlcmd($process) {
    # Снятие процесса рвёт соединение, а разорванное соединение сервер откатывает сам:
    # отдельного ROLLBACK не нужно, и это единственный способ отпустить блокировку, если
    # опыт упал посреди.
    if ($process -and -not $process.HasExited) { $process.Kill(); $process.WaitForExit(10000) | Out-Null }
}

# Модуль NAV живёт только в Windows PowerShell 5.1, поэтому и ожидание готовности, и сам
# вызов идут через него. Готовность спрашивается ДО опыта: служба поднимается минутами,
# а блокировка столько не держится.
$probeFile = Join-Path $outDir 'wait-nav.ps1'
$runFile   = Join-Path $outDir 'invoke-pass.ps1'
function Write-Ps51([string]$path, [string]$body) {
    [IO.File]::WriteAllText($path, (($body -replace "`r`n", "`n") -replace "`n", "`r`n"), (New-Object System.Text.UTF8Encoding($true)))
}
$navImport = "Import-Module 'C:\Program Files\Microsoft Dynamics NAV\110\Service\NavAdminTool.ps1' -DisableNameChecking -WarningAction SilentlyContinue | Out-Null"
Write-Ps51 $probeFile @"
$navImport
`$deadline = (Get-Date).AddMinutes(6)
while ((Get-Date) -lt `$deadline) {
    try { Get-NAVServerSession -ServerInstance $Instance -ErrorAction Stop | Out-Null; exit 0 } catch { Start-Sleep -Seconds 5 }
}
exit 1
"@
Write-Ps51 $runFile @"
`$ErrorActionPreference = 'Stop'
$navImport
Invoke-NAVCodeunit -ServerInstance $Instance -CompanyName '$Company' -CodeunitId $PassCodeunitId -MethodName RunPass -ErrorAction Stop
"@
$ps51 = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
function Invoke-Pass([string]$why) {
    $log = & $ps51 -NoProfile -ExecutionPolicy Bypass -File $runFile 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { Fail "$why не отработал:`n$log" }
}

try {
    Write-Host 'Подготовка стенда'
    if ((Get-Service $service).Status -ne 'Running') { Start-Service $service }
    # Правка настройки мимо NAV в кэш службы не доходит, поэтому имя сервера ставится ДО
    # перезапуска. Перезапуск нужен и сам по себе: без него служба исполнила бы прежнюю
    # версию только что выложенных объектов, и опыт проверил бы не то.
    Invoke-Sql "UPDATE $setup SET [SQL Server] = N'$Server', [Watchdog Message] = N'';" | Out-Null
    if (-not $KeepJournal) { Invoke-Sql "DELETE FROM $episode;" | Out-Null }
    Invoke-Sql @"
DELETE FROM $mark WHERE [Server Instance Id] = -1;
INSERT INTO $mark ([Server Instance Id],[Session Id],[User Id],[Company Name],[Table No_],[Document No_],[Marked At])
VALUES (-1,-1,N'STAND',N'$Company',0,N'LOCK-TARGET',GETDATE());
"@ | Out-Null

    Write-Host "  перезапускаю службу $Instance и жду ответа порта управления"
    Restart-Service $service -Force
    & $ps51 -NoProfile -ExecutionPolicy Bypass -File $probeFile | Out-Null
    if ($LASTEXITCODE -ne 0) { Fail "экземпляр $Instance не ответил по порту управления" }

    Write-Host 'Устраиваю блокировку'
    $hold = "SET LOCK_TIMEOUT -1`nBEGIN TRAN`nUPDATE $mark SET [Document No_] = N'HELD' WHERE [Server Instance Id] = -1`nWAITFOR DELAY '00:05:00'`nROLLBACK`n"
    $want = "SET LOCK_TIMEOUT -1`nBEGIN TRAN`nUPDATE $mark SET [Document No_] = N'WANT' WHERE [Server Instance Id] = -1`nROLLBACK`n"
    $blocker = Start-Sqlcmd 'lock-hold.sql' $hold
    Start-Sleep -Seconds 2
    $waiter = Start-Sqlcmd 'lock-want.sql' $want

    # Ждём, пока ожидание ПОЯВИТСЯ в очереди сервера. Иначе провал проверки означал бы
    # "опыт не удался", а выглядел бы как "инструмент не увидел блокировку" - самая
    # дорогая подмена, какая бывает в прогоне.
    $waitRow = ''
    $deadline = (Get-Date).AddSeconds(40)
    while ((Get-Date) -lt $deadline) {
        $waitRow = Scalar @"
SELECT TOP 1 CONVERT(varchar(11),wt.session_id) + '|' + CONVERT(varchar(11),wt.blocking_session_id)
FROM sys.dm_os_waiting_tasks wt
JOIN sys.dm_exec_sessions s ON s.session_id = wt.session_id
WHERE wt.wait_type LIKE 'LCK[_]%' AND s.host_process_id = $($waiter.Id);
"@
        if ($waitRow) { break }
        Start-Sleep -Milliseconds 500
    }
    if (-not $waitRow) { Fail 'ожидание в очереди сервера так и не появилось - опыт не удался, инструмент тут ни при чём' }
    $waiterSpid  = [int]($waitRow -split '\|')[0]
    $blockerSpid = [int]($waitRow -split '\|')[1]
    Write-Host "  жертва $waiterSpid ждёт виновника $blockerSpid"
    Start-Sleep -Seconds 2

    Write-Host 'Проход по живой очереди'
    Invoke-Pass 'проход'

    $watchdog = Scalar "SELECT [Watchdog Message] FROM $setup;"
    Check 'проход отчитался, а не промолчал' (($watchdog -ne '') -and ($watchdog -notmatch 'не удалось')) "сторож пишет: $watchdog"

    $rows = [int](Scalar "SELECT COUNT(*) FROM $episode;")
    Check 'эпизод заведён ровно один' ($rows -eq 1) "строк в журнале $rows"

    $row = Scalar @"
SELECT TOP 1
  CONVERT(varchar(11),[Victim SPID]) + '|' + CONVERT(varchar(11),[Head SPID]) + '|' +
  CONVERT(varchar(11),[Blocker SPID]) + '|' + CONVERT(varchar(11),[Chain Depth]) + '|' +
  CONVERT(varchar(11),[Victims Behind Head]) + '|' + [Resource Kind] + '|' +
  CONVERT(varchar(30),[Hobt Id]) + '|' + CONVERT(varchar(11),[NAV Key No_]) + '|' +
  [NAV Table Name] + '|' + CONVERT(varchar(11),[Resource Unresolved]) + '|' +
  CONVERT(varchar(11),[Victim Is NAV]) + '|' + CONVERT(varchar(11),[Open]) + '|' +
  CONVERT(varchar(11),[Max Wait (ms)]) + '|' + [Wait Type]
FROM $episode ORDER BY [Entry No_] DESC;
"@
    if (-not $row) { Fail 'в журнале пусто - дальше проверять нечего' }
    $f = ($row -split '\|') | ForEach-Object { $_.Trim() }

    Check 'жертва и виновник те самые' ((([int]$f[0]) -eq $waiterSpid) -and (([int]$f[2]) -eq $blockerSpid)) `
        "жертва $($f[0]) при ожидаемой $waiterSpid, виновник $($f[2]) при ожидаемом $blockerSpid"
    Check 'ресурс разобран, а не показан сырым' (($f[5] -eq 'KEYLOCK') -and ($f[6] -ne '0') -and ($f[9] -eq '0')) `
        "род [$($f[5])], hobt $($f[6]), не опознан $($f[9]), чего ждёт [$($f[13])]"
    Check 'имя таблицы и номер ключа сняты с SQL' (($f[8] -eq 'LockWatch Context Mark') -and ($f[7] -eq '0')) `
        "таблица [$($f[8])], ключ NAV $($f[7])"
    Check 'цепочка размотана до головы' ((([int]$f[1]) -eq $blockerSpid) -and ($f[3] -eq '1') -and ($f[4] -eq '1')) `
        "голова $($f[1]), глубина $($f[3]), жертв за головой $($f[4])"
    Check 'чужая сессия названа чужой' ($f[10] -eq '2') "признак сессии NAV $($f[10]) при ожидаемом 2 (нет)"
    Check 'эпизод открыт и длительность растёт' (($f[11] -eq '1') -and (([int]$f[12]) -gt 0)) `
        "открыт $($f[11]), длительность $($f[12]) мс"

    Write-Host 'Отпускаю блокировку и делаю второй проход'
    Stop-Sqlcmd $blocker
    Stop-Sqlcmd $waiter
    $deadline = (Get-Date).AddSeconds(20)
    while ((Get-Date) -lt $deadline) {
        $still = Scalar "SELECT TOP 1 CONVERT(varchar(11),session_id) FROM sys.dm_os_waiting_tasks WHERE wait_type LIKE 'LCK[_]%' AND session_id = $waiterSpid;"
        if (-not $still) { break }
        Start-Sleep -Milliseconds 500
    }
    Invoke-Pass 'второй проход'

    $closed = Scalar @"
SELECT TOP 1 CONVERT(varchar(11),[Open]) + '|' + CONVERT(varchar(11),[Outcome]) + '|' +
  CONVERT(varchar(11),CASE WHEN [Ended At] > [Started At] THEN 1 ELSE 0 END)
FROM $episode ORDER BY [Entry No_] DESC;
"@
    $c = ($closed -split '\|') | ForEach-Object { $_.Trim() }
    Check 'ушедшая из очереди жертва закрывает эпизод' (($c[0] -eq '0') -and ($c[2] -eq '1')) `
        "открыт $($c[0]), конец позже начала $($c[2])"
    # Предел 10 000 мс - предел NAV, а не сервера. Приписать его соединению sqlcmd значило
    # бы выдумать факт, которого нет, и выдумать правдоподобно.
    Check 'чужой сессии исход не приписан' ($c[1] -eq '0') "исход $($c[1]) при ожидаемом 0 (не определён)"
}
finally {
    Stop-Sqlcmd $blocker
    Stop-Sqlcmd $waiter
    # Убираем за собой И строку-мишень, И эпизоды. Оставленный эпизод - не мусор, а помеха:
    # мерный прогон журнала отказывается работать по непустому журналу, и следующий прогон
    # упал бы с виду беспричинно. Оставить его можно нарочно, ключом -KeepJournal.
    $cleanup = "DELETE FROM $mark WHERE [Server Instance Id] = -1;"
    if (-not $KeepJournal) { $cleanup += " DELETE FROM $episode;" }
    & sqlcmd -S $Server -d $Database -E -l 30 -h -1 -Q $cleanup 2>&1 | Out-Null
    if ($StopInstance) { Stop-Service $service -Force }
}

Write-Host ''
Write-Host "пройдено $passed из $total"
Write-Host ''
$report | ForEach-Object { Write-Host $_ }
if ($passed -lt $total) { Fail 'проверка на живой блокировке не пройдена' }
Write-Host 'Готово: проход проверен на настоящей блокировке' -ForegroundColor Green
