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

    Оба трудных случая - завод и остановка ПОВЕРХ идущего прохода - устраиваются нарочно:
    проход держат замком на журнале, и окно, в которое сном не попасть, открывается на
    сколько угодно. Тем же замком проходу устраивается и настоящая ошибка: держать дольше
    предела ожидания NAV - значит уронить его так, как он упадёт в шторм.

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
$history = "[$Company`$LockWatch Episode History]"
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
# Номер эпизода, уехавшего в историю. Историю не чистит ничто - ни проход, ни задача, ни
# срок, - поэтому свою строку прогон уносит за собой сам: иначе стенд копил бы по опытному
# эпизоду за прогон, и однажды они стали бы объяснением чужого замера.
$movedNo = ''
$movedSaid = ''
# Подготовленные вызовы ждут знака файлом и без него висели бы вечно: их снимает уборка.
$armProc = $null
$stopProc = $null
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
# Подготовленный вызов. Поднять модуль NAV стоит несколько секунд, а окно, в которое надо
# попасть, живёт меньше десяти: столько проход держится на замке, а потом срывается по
# пределу ожидания NAV. Поэтому процесс поднимается ЗАРАНЕЕ и ждёт знака файлом.
function Start-Prepared([string]$tag, [string]$method) {
    $ready   = Join-Path $outDir "watch-$tag.ready"
    $trigger = Join-Path $outDir "watch-$tag.trigger"
    $done    = Join-Path $outDir "watch-$tag.done"
    foreach ($f in @($ready, $trigger, $done)) { if (Test-Path $f) { Remove-Item $f -Force } }
    $file = Join-Path $outDir "watch-$tag.ps1"
    Write-Ps51 $file @"
$navImport
Set-Content -Path '$ready' -Value 'ready'
while (-not (Test-Path '$trigger')) { Start-Sleep -Milliseconds 50 }
try {
    Invoke-NAVCodeunit -ServerInstance $Instance -CompanyName '$Company' -CodeunitId $TaskCodeunitId -MethodName $method -ErrorAction Stop
    Set-Content -Path '$done' -Value 'ok'
} catch { Set-Content -Path '$done' -Value `$_.Exception.Message }
"@
    $proc = Start-Process -FilePath $ps51 -PassThru -WindowStyle Hidden `
        -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $file)
    if (-not (Wait-For { Test-Path $ready } 90)) { Fail "подготовленный вызов $method не поднял модуль NAV" }
    [PSCustomObject]@{ Process = $proc; Trigger = $trigger; Done = $done; Method = $method }
}
# Ответа ждём именно от подготовленного процесса: его молчание значит, что опыт не
# состоялся вовсе, и судить дальше по числу задач было бы гаданием, а не замером.
function Invoke-Prepared($prepared, [int]$seconds) {
    Set-Content -Path $prepared.Trigger -Value 'go'
    if (-not (Wait-For { Test-Path $prepared.Done } $seconds)) { return 'не ответил' }
    return (Get-Content $prepared.Done -Raw).Trim()
}

# Замок, которым открывается окно длиной в проход. Держим ЖУРНАЛ: его проход читает и
# пишет каждым проходом - переезд старых строк идёт всегда, - а завод и остановка к нему
# не обращаются вовсе и потому проходят целиком, пока проход стоит. Накопительный слой на
# эту роль не годится: на тихом стенде счётчики не двигаются, проход в него не заходит и
# замка не видит (проверено - двенадцать проходов подряд мимо запертой таблицы охвата).
$journalHold = "SET LOCK_TIMEOUT -1`nBEGIN TRAN`nDELETE FROM $episode WITH (TABLOCKX)`nWAITFOR DELAY '00:01:00'`nROLLBACK`n"
# Ждём ФАКТА - что проход и вправду встал на журнале. Номер объекта спрашивается у
# каталога: обратный перевод (OBJECT_NAME от resource_associated_entity_id) роняет запрос
# переполнением на первой же чужой блокировке рода KEY.
$stuckSql = @"
SELECT TOP 1 CONVERT(varchar(11),l.request_session_id)
FROM sys.dm_tran_locks l JOIN sys.dm_exec_sessions s ON s.session_id = l.request_session_id
WHERE l.request_status = 'WAIT'
  AND l.resource_associated_entity_id IN (
        SELECT OBJECT_ID(N'$episode')
        UNION ALL SELECT p.hobt_id FROM sys.partitions p WHERE p.object_id = OBJECT_ID(N'$episode'))
  AND s.program_name LIKE 'Microsoft Dynamics NAV%';
"@
function Wait-PassStuck([int]$seconds) { Wait-For { '' -ne (Scalar $stuckSql) } $seconds }

# Сколько ждать, пока задержанный проход СОРВЁТСЯ. Предел ожидания блокировки у NAV -
# 10 000 мс: столько проход держится на замке, прежде чем упасть. К этому прибавляется
# период опроса - задача должна была ещё и проснуться. Тридцать секунд - это трижды с
# запасом, и ждём мы тут наступления события, а не спим на всякий случай.
function FallWaitSeconds { 30 }

# Сколько ждать ПЕРЕЕЗДА в историю. Переезд идёт тем же проходом, что и съём очереди, а
# проход случается раз в период опроса - три секунды по умолчанию. Тридцати секунд хватает
# на десяток проходов подряд: если за десять проходов не уехало, дело не в невезении.
function MoveWaitSeconds { 30 }

# Пустая дата NAV в SQL. Ни NULL, ни ноль: столбец NOT NULL, а нулю отвечает 1900 год.
$blankDate = "CONVERT(datetime,'17530101')"
# Сколько времени двум отметкам позволено разойтись. Обе ставит ОДИН проход - одна с часов
# SQL, другая с часов NAV, - и разойтись они могут только на длительность самого прохода.
# Минута - это шестьдесят его цен при объявленном потолке в тысячу миллисекунд, то есть
# запас, который не спрячет ошибки в часовой пояс: тот дал бы три часа, а не секунду.
function ClockSlackSeconds { 60 }

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

    # Гасим то, что могло остаться от прошлого прогона, И ДОЖИДАЕМСЯ тишины. Снять задачу
    # мало: строка исполняющейся задачи в таблице ЕСТЬ, но снятие её не останавливает - она
    # доходит до конца, и её проход всё равно случится, уже после того, как мы обнулили
    # отметки. Прогон тогда краснеет не по делу, а причину искать негде.
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
    # Отметка охвата обнуляется, чтобы её поставил ПЕРВЫЙ проход этого прогона: сравнивать
    # её с отметкой того же прохода можно только пока обе свежие. Ставит её C/AL, а отметку
    # прохода - часы SQL, и в этом вся соль сравнения.
    Invoke-Sql "UPDATE $state SET [Coverage Since] = $blankDate;" | Out-Null

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

    # Время в журнале - UTC, и это не придирка к формату. NAV хранит DateTime в SQL по UTC
    # и при чтении переводит его в местное САМ; отдай ему местное - и человек увидит в
    # журнале БУДУЩЕЕ ровно на разницу поясов. Ловилось это на стенде с поясом +3
    # (10.09.2026): отметка прохода лежала местным временем, а отметка охвата, которую
    # ставит CURRENTDATETIME, - по UTC, и две половины сторожа расходились на три часа
    # внутри одной строки.
    #
    # Спрашивается поэтому не формат, а согласие: обе отметки поставил ОДИН проход, и
    # сойтись они обязаны. Сверка с UTC-часами сервера стоит рядом - без неё проверка
    # прошла бы и на двух одинаково сдвинутых часах.
    $clock = Scalar @"
SELECT CONVERT(varchar(11),ABS(DATEDIFF(second,SYSUTCDATETIME(),[Last Pass At]))) + '|' +
       CONVERT(varchar(11),ABS(DATEDIFF(second,[Last Pass At],[Coverage Since]))) + '|' +
       CONVERT(varchar(11),DATEDIFF(minute,SYSUTCDATETIME(),SYSDATETIME()))
FROM $state;
"@
    $c = @(($clock -split '\|') | ForEach-Object { $_.Trim() })
    while ($c.Count -lt 3) { $c += '0' }
    Check 'время записано по UTC, и обе половины сторожа сходятся' `
        ((([int]$c[0]) -le (ClockSlackSeconds)) -and (([int]$c[1]) -le (ClockSlackSeconds))) `
        "отметка прохода расходится с UTC на $($c[0]) с, с отметкой от NAV - на $($c[1]) с, пояс сервера $($c[2]) мин"

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

    # Завод ПОВЕРХ идущего прохода. Строка исполняющейся задачи в таблице есть, но снятие
    # её не останавливает: она доходит до конца и на прежнем коде перевзводила себя уже
    # после завода - цепочек становилось ДВЕ, обе живые, обе перевзводятся. На прежнем
    # коде задач тут выходит 2.
    #
    # Обе руки готовятся заранее, и остановка - тоже: она понадобится в самом конце, а
    # ждать знака ей ничего не стоит.
    Write-Host 'Завожу сторожа ПОВЕРХ идущего прохода'
    $armProc = Start-Prepared 'arm' 'StartWatch'
    $stopProc = Start-Prepared 'stop' 'StopWatch'

    $cover = Start-Sqlcmd 'watch-journal-hold.sql' $journalHold
    if (-not (Wait-PassStuck 60)) { Fail 'проход на журнале не встал - окно не открылось, опыт не удался' }
    $armSaid = Invoke-Prepared $armProc 20
    Stop-Sqlcmd $cover
    $cover = $null
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
VALUES (-1,-1,N'STAND',N'$Company',0,N'LOCK-TARGET',GETUTCDATE());
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

    # Переезд в историю виден только на ЖИВОМ стороже. Мерный прогон журнала зовёт
    # MoveOldEntries сам и потому проверяет арифметику срока, а не то, что переезд вообще
    # СЛУЧАЕТСЯ: вынь этот вызов из прохода - и мерный прогон останется зелёным, а горячая
    # таблица будет расти молча, пока в неё не упрётся сервер.
    #
    # Ждать настоящих суток нельзя, а трогать настройку незачем: срок берётся из неё какой
    # есть, и эпизод СТАРИТСЯ на день больше срока. Так проверяется тот самый переезд, что
    # пойдёт в бою, - с боевым сроком, а не с подставленным ради опыта.
    #
    # Сломано нарочно 10.09.2026 - вызов MoveOldEntries вынут из прохода целиком: 11 из 12,
    # и красная ровно эта проверка, "эпизод из журнала НЕ ушёл, в истории его 0". Мерный
    # прогон журнала на том же коде остался зелёным ВЕСЬ, 19 из 19: он зовёт переезд сам.
    Write-Host 'Старю закрытый эпизод и снова НИЧЕГО не нажимаю'
    $retention = [int](Scalar "SELECT [Retention (Days)] FROM $setup;")
    $movedNo = Scalar "SELECT TOP 1 CONVERT(varchar(11),[Entry No_]) FROM $episode WHERE [Open] = 0 ORDER BY [Entry No_] DESC;"
    if (($retention -le 0) -or ('' -eq $movedNo)) {
        Fail "стареть нечего: срок $retention дней, закрытых эпизодов нет - опыт не удался"
    }
    # Строка сторожа обнуляется ПЕРЕД старением: её пишет каждый проход, и "уехало" от
    # прошлого переезда осталось бы в ней от прежнего прогона. Проверка читала бы чужой
    # ответ и проходила бы даже там, где не уехало ничто.
    Invoke-Sql "UPDATE $state SET [Watchdog Message] = N'';" | Out-Null
    $historyBefore = [int](Scalar "SELECT COUNT(*) FROM $history WHERE [Entry No_] = $movedNo;")
    Invoke-Sql "UPDATE $episode SET [Started At] = DATEADD(day,-$($retention + 1),[Started At]) WHERE [Entry No_] = $movedNo;" | Out-Null

    # Слово сторожа снимается В ТОТ ЖЕ МИГ, что и уход строки, а не после ожидания: строку
    # эту переписывает КАЖДЫЙ проход, и следующий - через три секунды - затрёт "уехало"
    # обычным отчётом. Проверка, читающая её спустя время, зависела бы от того, чем занята
    # машина: то зелёная, то красная, и обе краски незаслуженные.
    $leftJournal = Wait-For {
        if (([int](Scalar "SELECT COUNT(*) FROM $episode WHERE [Entry No_] = $movedNo;")) -ne 0) { return $false }
        $script:movedSaid = Scalar "SELECT [Watchdog Message] FROM $state;"
        return $true
    } (MoveWaitSeconds)
    if (-not $leftJournal) { $movedSaid = Scalar "SELECT [Watchdog Message] FROM $state;" }
    $inHistory = [int](Scalar "SELECT COUNT(*) FROM $history WHERE [Entry No_] = $movedNo;")
    # Спрашивается не "стало ли в журнале меньше", а судьба ИМЕННО ЭТОЙ строки: ушла из
    # журнала и пришла в историю под своим номером. Счёт строк прошёл бы и на удалении - а
    # удаление и переезд отличаются ровно тем, ради чего инструмент ставят.
    # Слово сторожа стоит рядом с фактом нарочно: переезд, случившийся молча, человек
    # объяснить не сможет - ненайденный вчерашний эпизод без объяснения стоит часа поисков.
    Check 'журнал переезжает в историю сам, и сторож об этом говорит' `
        ($leftJournal -and ($inHistory -eq 1) -and ($historyBefore -eq 0) -and
         ($movedSaid -match 'Moved to history|Уехало в историю')) `
        "эпизод $movedNo из журнала $(if ($leftJournal) { 'ушёл' } else { 'НЕ ушёл' }), в истории его $inHistory при ожидаемой 1 (было $historyBefore); сторож пишет: $movedSaid"

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

    # Зеркало опыта с заводом, и ловится тем же замком. Остановка гасит выключатель и
    # снимает задачи, но идущую снять нечем: строка её на месте и после снятия (замер
    # 09.09.2026 - задача та же самая, проход дошёл до конца). Значит не перевзвестись
    # она должна САМА, и ради этого выключатель перечитывается ВТОРОЙ раз - перед
    # перевзводом, а не только в начале задачи.
    #
    # Опасение, что для остановки замок пришлось бы держать вдвое дольше, замер снял:
    # остановка укладывается в 466 мс при окне меньше десяти секунд - ставить ей нечего.
    Write-Host 'Завожу заново и останавливаю уже ВО ВРЕМЯ прохода'
    Invoke-Method 'StartWatch'
    $beforeStop = LastPass
    if (-not (Wait-For { (LastPass) -ne $beforeStop } 60)) { Fail 'сторож не пошёл заново - опыт не удался' }
    $cover = Start-Sqlcmd 'watch-journal-hold-stop.sql' $journalHold
    if (-not (Wait-PassStuck 60)) { Fail 'проход на журнале не встал - окно не открылось, опыт не удался' }
    # Номер ИДУЩЕЙ задачи запоминается, пока она стоит на замке: по нему потом отличается
    # своя строка от чужой. Строка идущей задачи в очереди одна и та же - это и меряем.
    $heldId = Scalar "SELECT TOP 1 CONVERT(varchar(40),[ID]) FROM $tasks WHERE [Run Codeunit] = $TaskCodeunitId AND [Company] = N'$Company';"
    if (((TaskCount) -ne 1) -or ('' -eq $heldId)) { Fail "во время прохода в очереди не одна задача, а $(TaskCount) - опыт не удался" }
    $stopSaid = Invoke-Prepared $stopProc 20
    Stop-Sqlcmd $cover
    $cover = $null
    if ($stopSaid -ne 'ok') { Fail "подготовленная остановка не отработала: $stopSaid" }
    # Меряем ПОЯВЛЕНИЕ НОВОЙ задачи, а не итоговый ноль, и разница тут не в придирке.
    # Снятая сверка воскрешает сторожа не навсегда, а на одно колено: воскресшая цепочка
    # ставит ровно одну задачу, та просыпается, видит выключатель в НАЧАЛЕ задачи и умирает
    # сама. Ноль наступает и на сломанном коде - секунды на три позже, - поэтому первая
    # мера, ждавшая нуля, проходила вхолостую: на коде БЕЗ сверки она давала зелёные 10 из
    # 10. А вот чужой номер в очереди - это факт: своя строка была ровно одна, и её номер
    # записан выше.
    #
    # Сломано нарочно 09.09.2026 - сверка выключателя перед перевзводом снята: 9 из 10, и
    # красная эта проверка, "новых задач после остановки ПОЯВИЛАСЬ, в очереди сейчас 1".
    #
    # Времени тут с запасом: воскресшая задача лежит в очереди период опроса, три секунды,
    # и строка её не пропадает даже на время исполнения.
    $newTask = Wait-For {
        '' -ne (Scalar "SELECT TOP 1 CONVERT(varchar(40),[ID]) FROM $tasks WHERE [Run Codeunit] = $TaskCodeunitId AND [Company] = N'$Company' AND [ID] <> '$heldId';")
    } 20
    Check 'остановка во время прохода не воскрешает цепочку' (-not $newTask) `
        "новых задач после остановки $(if ($newTask) { 'ПОЯВИЛАСЬ' } else { 'не появилось' }), в очереди сейчас $(TaskCount), сторож пишет: $(Scalar "SELECT [Watchdog Message] FROM $state;")"

    # Обещание, записанное рядом с CODEUNIT.RUN: своя ошибка внутри прохода откатывает его
    # транзакцию, но НЕ роняет задачу - иначе цепочка оборвалась бы на первой же
    # неожиданности, и наблюдение кончилось бы молча, посреди ночи. Обещание это стояло с
    # первого дня и прогоном закрыто не было: устроить проходу настоящую ошибку было нечем.
    #
    # Замок устраивает. Держим журнал ДОЛЬШЕ предела ожидания блокировки у NAV, и проход
    # срывается сам, по-настоящему: не поддельной ошибкой из подмены, а той самой, которая
    # случится в шторм. Дальше спрашивается не намерение, а результат - сказал ли сторож
    # про падение и ПОШЛИ ЛИ проходы снова, когда замок отпустили.
    #
    # Сломано нарочно 10.09.2026 - ответ CODEUNIT.RUN не используется, и ошибка перестаёт
    # перехватываться: 10 из 11, и красная эта проверка, "сорвался МОЛЧА, проходы после
    # замка НЕ ПОШЛИ, задач 0". Записанное рядом с перехватом сбылось дословно.
    Write-Host 'Завожу заново и держу журнал дольше предела ожидания NAV'
    Invoke-Method 'StartWatch'
    $beforeFall = LastPass
    if (-not (Wait-For { (LastPass) -ne $beforeFall } 60)) { Fail 'сторож не пошёл заново - опыт не удался' }
    $cover = Start-Sqlcmd 'watch-journal-hold-fall.sql' $journalHold
    if (-not (Wait-PassStuck 60)) { Fail 'проход на журнале не встал - окно не открылось, опыт не удался' }
    # Слово ловится ДО отпускания замка: следующий удачный проход перепишет строку сторожа
    # своим "проход прошёл", и спрашивать будет уже не о чем.
    $fell = Wait-For {
        (Scalar "SELECT [Watchdog Message] FROM $state;") -match 'Проход упал|The pass fell over'
    } (FallWaitSeconds)
    $fellSaid = Scalar "SELECT [Watchdog Message] FROM $state;"
    Stop-Sqlcmd $cover
    $cover = $null
    $afterFall = LastPass
    $resumed = Wait-For { (LastPass) -ne $afterFall } 60
    Check 'упавший проход подхвачен задачей, и цепочка не оборвалась' `
        ($fell -and $resumed -and ((TaskCount) -eq 1)) `
        "сорвался $(if ($fell) { 'и сказал об этом' } else { 'МОЛЧА' }), проходы после замка $(if ($resumed) { 'пошли' } else { 'НЕ ПОШЛИ' }), задач $(TaskCount); сторож писал: $fellSaid"
}
finally {
    Stop-Sqlcmd $blocker
    Stop-Sqlcmd $cover
    if ($armProc) { Stop-Sqlcmd $armProc.Process }
    if ($stopProc) { Stop-Sqlcmd $stopProc.Process }
    $cleanup = "DELETE FROM $mark WHERE [Server Instance Id] = -1; DELETE FROM $episode;"
    $cleanup += " DELETE FROM $tasks WHERE [Run Codeunit] = $TaskCodeunitId;"
    $cleanup += " UPDATE $setup SET [Enabled] = 0, [Deadlocks Enabled] = 1;"
    # Своя строка из истории уносится по НОМЕРУ, а не очисткой таблицы: история стенда -
    # это чужие настоящие эпизоды, и смести их заодно со своим было бы дороже, чем
    # оставить свой.
    if ($movedNo) { $cleanup += " DELETE FROM $history WHERE [Entry No_] = $movedNo;" }
    & sqlcmd -S $Server -d $Database -E -l 30 -h -1 -Q $cleanup 2>&1 | Out-Null
    if ($StopInstance) { Stop-Service $service -Force }
}

Write-Host ''
Write-Host "пройдено $passed из $total"
Write-Host ''
$report | ForEach-Object { Write-Host $_ }
if ($passed -lt $total) { Fail 'фоновая задача проверку не прошла' }
Write-Host 'Готово: сторож заводится, идёт сам, ловит блокировку и умирает по кнопке' -ForegroundColor Green
