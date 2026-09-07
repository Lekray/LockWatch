#requires -Version 7
<#
.SYNOPSIS
    Проверка фоновой задачи: заводится ли сторож, идут ли проходы САМИ, не двоится ли
    цепочка, ловит ли она настоящую блокировку без единого нажатия и умирает ли по кнопке.

.DESCRIPTION
    Собравшаяся задача, которая ни разу не проснулась, - это текст, а не наблюдение.
    Поэтому здесь ничего не вызывается вручную, кроме "завести" и "остановить": эпизод
    обязан появиться в журнале сам, и закрыться тоже сам.

    Проверяется и то, о чём легко забыть: что цепочка не двоится. Два наблюдателя,
    идущие вперемежку, закрывают эпизоды друг другу, и разобрать такой журнал потом
    нельзя - а на экране всё это время всё выглядит здоровым.

.EXAMPLE
    pwsh scripts/Test-Watch.ps1
#>
[CmdletBinding()]
param(
    [string] $Server   = 'localhost',
    [string] $Database = $env:LW_DATABASE,
    [string] $Instance = $env:LW_INSTANCE,
    [string] $Company  = $env:LW_COMPANY,
    [int]    $TaskCodeunitId = 110236,
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
$tasks   = '[dbo].[Scheduled Task]'
$service = "MicrosoftDynamicsNavServer`$$Instance"

function Invoke-Sql([string]$query) {
    # -w 500 обязателен: по умолчанию sqlcmd рвёт строку на 80 знаках, и длинное значение
    # приходит ДВУМЯ строками. Проверка, читающая первую, получает обрезок и судит по нему.
    $answer = & sqlcmd -S $Server -d $Database -E -l 30 -w 500 -W -s '|' -h -1 -Q "SET NOCOUNT ON; $query" 2>&1
    if ($LASTEXITCODE -ne 0) { Fail "SQL не выполнился: $($answer -join ' ')" }
    return ,@($answer | Where-Object { $_ -and ($_ -notmatch '^\(') })
}
function Scalar([string]$query) {
    $rows = Invoke-Sql $query
    if ($rows.Count -eq 0) { return '' }
    return $rows[0].Trim()
}
function TaskCount { [int](Scalar "SELECT COUNT(*) FROM $tasks WHERE [Run Codeunit] = $TaskCodeunitId AND [Company] = N'$Company';") }
function LastPass  { Scalar "SELECT ISNULL(CONVERT(varchar(30),[Last Pass At],121),'') FROM $setup;" }

$passed = 0; $total = 0; $report = @()
function Check([string]$what, [bool]$ok, [string]$detail) {
    $script:total++
    if ($ok) { $script:passed++; $verdict = 'пройдено' } else { $verdict = 'ПРОВАЛ  ' }
    $script:report += "$verdict $what"
    $script:report += "         $detail"
}

# Ждать НАСТУПЛЕНИЯ события, а не спать наугад: сон вслепую делает прогон то зелёным,
# то красным в зависимости от того, чем занята машина.
function Wait-For([scriptblock]$condition, [int]$seconds) {
    $deadline = (Get-Date).AddSeconds($seconds)
    while ((Get-Date) -lt $deadline) {
        if (& $condition) { return $true }
        Start-Sleep -Milliseconds 500
    }
    return $false
}

$blocker = $null
function Start-Sqlcmd([string]$name, [string]$sql) {
    $file = Join-Path $outDir $name
    [IO.File]::WriteAllText($file, (($sql -replace "`r`n", "`n") -replace "`n", "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
    Start-Process -FilePath 'sqlcmd' -PassThru -WindowStyle Hidden -ArgumentList @(
        '-S', $Server, '-d', $Database, '-E', '-l', '30', '-i', $file
    )
}
function Stop-Sqlcmd($process) {
    if ($process -and -not $process.HasExited) { $process.Kill(); $process.WaitForExit(10000) | Out-Null }
}

$ps51 = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$navImport = "Import-Module 'C:\Program Files\Microsoft Dynamics NAV\110\Service\NavAdminTool.ps1' -DisableNameChecking -WarningAction SilentlyContinue | Out-Null"
function Write-Ps51([string]$path, [string]$body) {
    [IO.File]::WriteAllText($path, (($body -replace "`r`n", "`n") -replace "`n", "`r`n"), (New-Object System.Text.UTF8Encoding($true)))
}
$probeFile = Join-Path $outDir 'wait-nav.ps1'
Write-Ps51 $probeFile @"
$navImport
`$deadline = (Get-Date).AddMinutes(6)
while ((Get-Date) -lt `$deadline) {
    try { Get-NAVServerSession -ServerInstance $Instance -ErrorAction Stop | Out-Null; exit 0 } catch { Start-Sleep -Seconds 5 }
}
exit 1
"@
function Invoke-Method([string]$method) {
    $file = Join-Path $outDir "invoke-$method.ps1"
    Write-Ps51 $file @"
`$ErrorActionPreference = 'Stop'
$navImport
Invoke-NAVCodeunit -ServerInstance $Instance -CompanyName '$Company' -CodeunitId $TaskCodeunitId -MethodName $method -ErrorAction Stop
"@
    $log = & $ps51 -NoProfile -ExecutionPolicy Bypass -File $file 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { Fail "$method не отработал:`n$log" }
}

try {
    Write-Host 'Подготовка стенда'
    if ((Get-Service $service).Status -ne 'Running') { Start-Service $service }
    Invoke-Sql "UPDATE $setup SET [SQL Server] = N'$Server';" | Out-Null

    Write-Host "  перезапускаю службу $Instance и жду ответа порта управления"
    Restart-Service $service -Force
    & $ps51 -NoProfile -ExecutionPolicy Bypass -File $probeFile | Out-Null
    if ($LASTEXITCODE -ne 0) { Fail "экземпляр $Instance не ответил по порту управления" }

    # Гасим то, что могло остаться от прошлого прогона, И ДОЖИДАЕМСЯ тишины. Удалить строку
    # задачи запросом мало: задача, которая уже исполняется, строки в таблице не имеет, и
    # её проход всё равно случится - уже после того, как мы обнулили отметки. Прогон тогда
    # краснеет не по делу, а причину искать негде.
    Write-Host '  гашу остатки прошлого прогона и жду тишины'
    Invoke-Method 'StopWatch'
    if (-not (Wait-For { (TaskCount) -eq 0 } 30)) { Fail 'задачи прошлого прогона не снялись' }
    $quiet = LastPass
    if (-not (Wait-For { $now = LastPass; if ($now -eq $quiet) { Start-Sleep -Seconds 5; (LastPass) -eq $quiet } else { $script:quiet = $now; $false } } 60)) {
        Fail 'проходы прошлого прогона не прекратились'
    }
    # Настройку через SQL НЕ обнуляем. Строка настройки одна на базу, и служба держит её
    # в кэше: UPDATE мимо NAV до сессии не доходит, а первое же обращение к настройке
    # запишет кэшированную строку обратно - вместе со старой отметкой последнего прохода.
    # Прогон тогда видит "проход был" ещё до первого прохода. Поэтому отметка не обнуляется,
    # а ЗАПОМИНАЕТСЯ, и проверка ждёт её ИЗМЕНЕНИЯ.
    Invoke-Sql "DELETE FROM $episode;" | Out-Null
    Invoke-Sql "DELETE FROM $mark WHERE [Server Instance Id] = -1;" | Out-Null

    Write-Host 'Завожу сторожа'
    $beforeStart = LastPass
    Invoke-Method 'StartWatch'
    $enabled = Scalar "SELECT CONVERT(varchar(2),[Enabled]) FROM $setup;"
    Check 'завод ставит ровно одну задачу' (($enabled -eq '1') -and ((TaskCount) -eq 1)) `
        "включён $enabled, задач в планировщике $(TaskCount)"

    Write-Host 'Жду, пока проход случится САМ'
    $wentThrough = Wait-For { (LastPass) -ne $beforeStart } 60
    $watchdog = Scalar "SELECT [Watchdog Message] FROM $setup;"
    Check 'проход случился сам, без единого нажатия' ($wentThrough -and ($watchdog -match 'Pass went through|Проход прошёл')) `
        "сторож пишет: $watchdog"
    if (-not $wentThrough) { Fail 'фоновая задача так и не проснулась - дальше проверять нечего' }

    $firstPass = LastPass
    $secondPass = Wait-For { (LastPass) -ne $firstPass } 60
    Check 'цепочка перевзвелась и не раздвоилась' ($secondPass -and ((TaskCount) -eq 1)) `
        "второй проход $(if ($secondPass) { 'был' } else { 'НЕ БЫЛ' }), задач в планировщике $(TaskCount)"

    Write-Host 'Устраиваю блокировку и НИЧЕГО не нажимаю'
    Invoke-Sql @"
INSERT INTO $mark ([Server Instance Id],[Session Id],[User Id],[Company Name],[Table No_],[Document No_],[Marked At])
VALUES (-1,-1,N'STAND',N'$Company',0,N'LOCK-TARGET',GETDATE());
"@ | Out-Null
    $hold = "SET LOCK_TIMEOUT -1`nBEGIN TRAN`nUPDATE $mark SET [Document No_] = N'HELD' WHERE [Server Instance Id] = -1`nWAITFOR DELAY '00:05:00'`nROLLBACK`n"
    $want = "SET LOCK_TIMEOUT -1`nBEGIN TRAN`nUPDATE $mark SET [Document No_] = N'WANT' WHERE [Server Instance Id] = -1`nROLLBACK`n"
    $blocker = Start-Sqlcmd 'watch-hold.sql' $hold
    Start-Sleep -Seconds 2
    $waiter = Start-Sqlcmd 'watch-want.sql' $want

    $caught = Wait-For { ([int](Scalar "SELECT COUNT(*) FROM $episode WHERE [Open] = 1;")) -gt 0 } 60
    $seen = Scalar "SELECT TOP 1 [NAV Table Name] + '|' + CONVERT(varchar(11),[NAV Key No_]) + '|' + CONVERT(varchar(11),[Head SPID]) FROM $episode ORDER BY [Entry No_] DESC;"
    Check 'сторож поймал настоящую блокировку сам' $caught "в журнале: $seen"

    Write-Host 'Отпускаю блокировку и жду, пока эпизод закроется САМ'
    Stop-Sqlcmd $blocker
    Stop-Sqlcmd $waiter
    $blocker = $null
    $closed = Wait-For { ([int](Scalar "SELECT COUNT(*) FROM $episode WHERE [Open] = 0;")) -gt 0 } 60
    Check 'эпизод закрылся сам, без нажатия' $closed `
        "закрытых $(Scalar "SELECT COUNT(*) FROM $episode WHERE [Open] = 0;"), открытых $(Scalar "SELECT COUNT(*) FROM $episode WHERE [Open] = 1;")"

    Write-Host 'Останавливаю сторожа'
    Invoke-Method 'StopWatch'
    $enabled = Scalar "SELECT CONVERT(varchar(2),[Enabled]) FROM $setup;"
    Check 'остановка снимает и выключатель, и задачу' (($enabled -eq '0') -and ((TaskCount) -eq 0)) `
        "включён $enabled, задач в планировщике $(TaskCount)"

    # Одного выключателя мало: уже поставленная задача проснулась бы и после "стоп".
    # Поэтому проверяем не намерение, а результат - что проходов больше НЕТ.
    $frozen = LastPass
    $moved = Wait-For { (LastPass) -ne $frozen } 15
    Check 'после остановки проходов больше нет' (-not $moved) `
        "за 15 секунд отметка последнего прохода $(if ($moved) { 'СДВИНУЛАСЬ' } else { 'не сдвинулась' })"
}
finally {
    Stop-Sqlcmd $blocker
    & sqlcmd -S $Server -d $Database -E -l 30 -h -1 -Q "DELETE FROM $mark WHERE [Server Instance Id] = -1; DELETE FROM $episode; DELETE FROM $tasks WHERE [Run Codeunit] = $TaskCodeunitId; UPDATE $setup SET [Enabled] = 0;" 2>&1 | Out-Null
    if ($StopInstance) { Stop-Service $service -Force }
}

Write-Host ''
Write-Host "пройдено $passed из $total"
Write-Host ''
$report | ForEach-Object { Write-Host $_ }
if ($passed -lt $total) { Fail 'фоновая задача проверку не прошла' }
Write-Host 'Готово: сторож заводится, идёт сам, ловит блокировку и умирает по кнопке' -ForegroundColor Green
