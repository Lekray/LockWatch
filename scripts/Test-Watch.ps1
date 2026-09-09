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
$state   = "[$Company`$LockWatch Watchdog]"
$mark    = "[$Company`$LockWatch Context Mark]"
$tasks   = '[dbo].[Scheduled Task]'
$service = "MicrosoftDynamicsNavServer`$$Instance"

function Invoke-Sql([string]$query) {
    # -w 500 обязателен: по умолчанию sqlcmd рвёт строку на 80 знаках, и длинное значение
    # приходит ДВУМЯ строками. Проверка, читающая первую, получает обрезок и судит по нему.
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
function TaskCount { [int](Scalar "SELECT COUNT(*) FROM $tasks WHERE [Run Codeunit] = $TaskCodeunitId AND [Company] = N'$Company';") }
function LastPass  { Scalar "SELECT ISNULL(CONVERT(varchar(30),[Last Pass At],121),'') FROM $state;" }
# Версия строки - то, по чему NAV судит "запись изменилась". Пока фон писал состояние в
# строку настройки, версия той строки двигалась каждый проход, и человек не мог поставить
# в ней ни одной галки: страница устаревала быстрее, чем он до неё дотягивался.
#
# Столбец версии переводится в binary(8) ПЕРЕД показом, и это не украшение: CONVERT прямо
# из timestamp отдаёт ПУСТО - без ошибки, с нулевым кодом возврата и пустой строкой. Ловится
# это только тем, что проверка тихо перестаёт что-либо проверять: два пустых значения равны
# друг другу, и половина проверки проходит на чём угодно.
function Stamp([string]$table) {
    Scalar "SELECT ISNULL((SELECT TOP 1 CONVERT(varchar(50),CONVERT(binary(8),[timestamp]),1) FROM $table),'');"
}
function SetupStamp { Stamp $setup }
function StateStamp { Stamp $state }

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
$cover = $null
# Подготовленный завод ждёт знака файлом и без него висел бы вечно: его снимает уборка.
$armProc = $null
function Start-Sqlcmd([string]$name, [string]$sql) {
    $file = Join-Path $outDir $name
    [IO.File]::WriteAllText($file, (($sql -replace "`r`n", "`n") -replace "`n", "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
    Start-Process -FilePath 'sqlcmd' -PassThru -WindowStyle Hidden -ArgumentList @(
        '-S', $Server, '-d', $Database, '-E', '-b', '-l', '30', '-i', $file
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
    # Сбор взаимоблокировок на время опыта выключается. Он берёт графы из КОЛЬЦЕВОГО
    # БУФЕРА сервера, а туда они попадают от кого угодно и когда угодно - хоть от прошлого
    # прогона, хоть от чужой работы на той же базе. Строка в журнале получилась бы законной,
    # но проверка "эпизод заведён ровно один" считает строки, и опыт судил бы инструмент по
    # чужим кругам. Две дороги - два прогона, и каждый отвечает только за свою.
    Invoke-Sql "UPDATE $setup SET [SQL Server] = N'$Server', [Deadlocks Enabled] = 0;" | Out-Null

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
    $watchdog = Scalar "SELECT [Watchdog Message] FROM $state;"
    Check 'проход случился сам, без единого нажатия' ($wentThrough -and ($watchdog -match 'Pass went through|Проход прошёл')) `
        "сторож пишет: $watchdog"
    if (-not $wentThrough) { Fail 'фоновая задача так и не проснулась - дальше проверять нечего' }

    $firstPass = LastPass
    $setupStamp = SetupStamp
    $stateStamp = StateStamp
    $secondPass = Wait-For { (LastPass) -ne $firstPass } 60
    Check 'цепочка перевзвелась и не раздвоилась' ($secondPass -and ((TaskCount) -eq 1)) `
        "второй проход $(if ($secondPass) { 'был' } else { 'НЕ БЫЛ' }), задач в планировщике $(TaskCount)"

    # Проверка, ради которой состояние и вынесено в свою таблицу. Проверяются ОБЕ стороны:
    # строка настройки за целый проход не шелохнулась, а строка состояния - сдвинулась.
    # Без второй половины проверка проходила бы и на мёртвом стороже.
    $setupHeld = (SetupStamp) -eq $setupStamp
    $stateMoved = (StateStamp) -ne $stateStamp
    Check 'проход пишет своё состояние и не трогает строку настройки' ($setupHeld -and $stateMoved) `
        "версия настройки $(if ($setupHeld) { 'не менялась' } else { 'СДВИНУЛАСЬ' }), версия состояния $(if ($stateMoved) { 'сдвинулась' } else { 'НЕ МЕНЯЛАСЬ' })"

    # Завод ПОВЕРХ идущего прохода. Задачу, которая уже исполняется, снять нечем, и на
    # прежнем коде она перевзводила себя уже после завода: цепочек становилось ДВЕ, обе
    # живые, обе перевзводятся. На прежнем коде задач тут выходит 2.
    #
    # Окно ловится не сном, а ЗАМКОМ. Держим ЖУРНАЛ: его проход читает каждым проходом -
    # переезд старых строк идёт всегда, - а завод к нему не обращается вовсе и потому
    # проходит целиком, пока проход стоит. Накопительный слой на эту роль не годится: на
    # тихом стенде счётчики не двигаются, проход в него не заходит и замка не видит
    # (проверено - двенадцать проходов подряд мимо запертой таблицы охвата).
    #
    # Времени у опыта меньше десяти секунд: столько проход держится на замке, а потом
    # срывается по пределу ожидания NAV, подхватывается задачей и перевзводится. Поэтому
    # завод готовится ЗАРАНЕЕ - отдельный процесс поднимает модуль NAV и ждёт знака файлом.
    # Запуск с модулем стоит несколько секунд, и без прогрева опыт не успевал бы.
    Write-Host 'Завожу сторожа ПОВЕРХ идущего прохода'
    $armReady   = Join-Path $outDir 'watch-arm.ready'
    $armTrigger = Join-Path $outDir 'watch-arm.trigger'
    $armDone    = Join-Path $outDir 'watch-arm.done'
    foreach ($f in @($armReady, $armTrigger, $armDone)) { if (Test-Path $f) { Remove-Item $f -Force } }
    $armFile = Join-Path $outDir 'watch-arm.ps1'
    Write-Ps51 $armFile @"
$navImport
Set-Content -Path '$armReady' -Value 'ready'
while (-not (Test-Path '$armTrigger')) { Start-Sleep -Milliseconds 50 }
try {
    Invoke-NAVCodeunit -ServerInstance $Instance -CompanyName '$Company' -CodeunitId $TaskCodeunitId -MethodName StartWatch -ErrorAction Stop
    Set-Content -Path '$armDone' -Value 'ok'
} catch { Set-Content -Path '$armDone' -Value `$_.Exception.Message }
"@
    $armProc = Start-Process -FilePath $ps51 -PassThru -WindowStyle Hidden `
        -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $armFile)
    if (-not (Wait-For { Test-Path $armReady } 90)) { Fail 'подготовленный завод не поднял модуль NAV - опыт не удался' }

    $hold = "SET LOCK_TIMEOUT -1`nBEGIN TRAN`nDELETE FROM $episode WITH (TABLOCKX)`nWAITFOR DELAY '00:01:00'`nROLLBACK`n"
    $cover = Start-Sqlcmd 'watch-journal-hold.sql' $hold
    # Ждём ФАКТА - что проход и вправду встал на журнале. Номер объекта спрашивается у
    # каталога: обратный перевод (OBJECT_NAME от resource_associated_entity_id) роняет
    # запрос переполнением на первой же чужой блокировке рода KEY.
    $stuckSql = @"
SELECT TOP 1 CONVERT(varchar(11),l.request_session_id)
FROM sys.dm_tran_locks l JOIN sys.dm_exec_sessions s ON s.session_id = l.request_session_id
WHERE l.request_status = 'WAIT'
  AND l.resource_associated_entity_id IN (
        SELECT OBJECT_ID(N'$episode')
        UNION ALL SELECT p.hobt_id FROM sys.partitions p WHERE p.object_id = OBJECT_ID(N'$episode'))
  AND s.program_name LIKE 'Microsoft Dynamics NAV%';
"@
    if (-not (Wait-For { '' -ne (Scalar $stuckSql) } 60)) { Fail 'проход на журнале не встал - окно не открылось, опыт не удался' }
    Set-Content -Path $armTrigger -Value 'go'
    $armed = Wait-For { Test-Path $armDone } 20
    $armSaid = if ($armed) { (Get-Content $armDone -Raw).Trim() } else { 'не ответил' }
    Stop-Sqlcmd $cover
    if ($armSaid -ne 'ok') { Fail "подготовленный завод не отработал: $armSaid" }
    # Задержанный проход доходит до конца и на прежнем коде тут же ставит СВОЮ задачу.
    # Сломано нарочно 09.09.2026 - сверка поколения снята: 8 из 9, и красная эта проверка,
    # "задач в планировщике 2 при ожидаемой 1".
    # Ждём именно этого: появилась вторая - ответ есть сразу, не появилась за двадцать
    # секунд - тоже ответ. Строка задачи живёт и пока задача ИСПОЛНЯЕТСЯ, поэтому число
    # снимается в тишине: когда очередной проход уже отчитался.
    Wait-For { (TaskCount) -gt 1 } 20 | Out-Null
    $quietPass = LastPass
    Wait-For { (LastPass) -ne $quietPass } 30 | Out-Null
    Check 'завод поверх идущего прохода не создаёт второй цепочки' ((TaskCount) -eq 1) `
        "задач в планировщике $(TaskCount) при ожидаемой 1, сторож пишет: $(Scalar "SELECT [Watchdog Message] FROM $state;")"

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
    Stop-Sqlcmd $cover
    Stop-Sqlcmd $armProc
    & sqlcmd -S $Server -d $Database -E -l 30 -h -1 -Q "DELETE FROM $mark WHERE [Server Instance Id] = -1; DELETE FROM $episode; DELETE FROM $tasks WHERE [Run Codeunit] = $TaskCodeunitId; UPDATE $setup SET [Enabled] = 0, [Deadlocks Enabled] = 1;" 2>&1 | Out-Null
    if ($StopInstance) { Stop-Service $service -Force }
}

Write-Host ''
Write-Host "пройдено $passed из $total"
Write-Host ''
$report | ForEach-Object { Write-Host $_ }
if ($passed -lt $total) { Fail 'фоновая задача проверку не прошла' }
Write-Host 'Готово: сторож заводится, идёт сам, ловит блокировку и умирает по кнопке' -ForegroundColor Green
