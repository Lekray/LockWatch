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
# Та же таблица, но именем, каким её пишет в журнал разбор: без компании и без скобок.
# Спор в опыте идёт за неё, и спрашивать эпизод надо по ЭТОМУ имени.
$markName = 'LockWatch Context Mark'
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

# Кто держит замок на журнале. Спрашивается ради ОТКАЗА: за "окно не открылось" стоят две
# разные беды - замок не встал (это опыт) и проходов нет вовсе (это инструмент или стенд), -
# а по самому "не встал" они неотличимы.
$holderSql = @"
SELECT TOP 1 ISNULL(s.program_name,'?') + ' (' + CONVERT(varchar(11),l.request_session_id) + ', ' + l.request_mode + ')'
FROM sys.dm_tran_locks l JOIN sys.dm_exec_sessions s ON s.session_id = l.request_session_id
WHERE l.request_status = 'GRANT' AND l.resource_type = 'OBJECT'
  AND l.resource_associated_entity_id = OBJECT_ID(N'$episode')
  AND l.request_mode LIKE 'X%';
"@

# Сколько смотреть на отметку прохода, прежде чем сказать "проходов нет". Период опроса по
# умолчанию три секунды, сам проход обязан уложиться в объявленный потолок - секунду.
# Десять секунд - это два полных круга с запасом, и тратятся они только на отказе.
function PassProbeSeconds { 10 }

# Отказ обязан называть то, что ИЗМЕРИЛ. Прежнее слово было "окно не открылось, опыт не
# удался" - и читалось оно как "замок не встал", то есть посылало смотреть на sqlcmd даже
# тогда, когда замок стоял, а не шли проходы. Различает их только замер обеих сторон.
function Fail-NoWindow([string]$scene) {
    $holder = Scalar $holderSql
    $was = LastPass
    Start-Sleep -Seconds (PassProbeSeconds)
    $now = LastPass
    Fail ("$scene - проход на журнале не встал за 60 с. Замок на журнале: " +
          $(if ($holder) { "держит $holder" } else { 'НИКТО не держит' }) + '; проходы: ' +
          $(if ($now -ne $was) { "идут, отметка [$was] -> [$now]" } else { "НЕ ИДУТ, отметка [$was] стоит $(PassProbeSeconds) с" }) +
          "; задач в очереди $(TaskCount), сторож пишет: $(Scalar "SELECT [Watchdog Message] FROM $state;")")
}

# То же различение для "прохода не случилось". Опыт к этому непричастен ВСЕГДА: он тут
# только зовёт StartWatch, и не отработай вызов - отказал бы сам Invoke-Method. Отвечает за
# молчание либо инструмент (цепочка не перевзвелась), либо стенд (планировщик экземпляра не
# исполняет задачи), и назвать надо замер, а не виноватого.
function Fail-NoPass([string]$scene) {
    Fail ("$scene - прохода не случилось за 60 с, и опыт тут ни при чём: он только завёл сторожа. " +
          "Выключатель $(Scalar "SELECT CONVERT(varchar(2),[Enabled]) FROM $setup;"), " +
          "задач в очереди $(TaskCount), отметка последнего прохода [$(LastPass)], " +
          "сторож пишет: $(Scalar "SELECT [Watchdog Message] FROM $state;")")
}

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

function Try-Method([string]$method) {
    # Тот же вызов, но отказ здесь - не беда прогона, а ОТВЕТ: сцена спрашивает, падает ли
    # завод после чужой правки, и падение обязано стать числом в проверке, а не концом
    # прогона.
    $file = Join-Path $outDir "try-$method.ps1"
    Write-Ps51 $file @"
`$ErrorActionPreference = 'Stop'
$navImport
Invoke-NAVCodeunit -ServerInstance $Instance -CompanyName '$Company' -CodeunitId $TaskCodeunitId -MethodName $method -ErrorAction Stop
"@
    $log = & $ps51 -NoProfile -ExecutionPolicy Bypass -File $file 2>&1 | Out-String
    $line = ($log -split "`r?`n" | Where-Object { $_ -match 'Invoke-NAVCodeunit|Sorry|ERROR|Ошибка' } | Select-Object -First 1)
    # Кавычки вокруг $line обязательны: строки ошибки на успешном вызове нет вовсе, а
    # $null -replace отдаёт ПУСТОЙ МАССИВ, а не пустую строку, и .Trim() на нём падает.
    # Ловится это только на зелёном пути - там, где отказа и не ждали.
    return [pscustomobject]@{ Ok = ($LASTEXITCODE -eq 0); Log = (("$line" -replace '\s+', ' ')).Trim() }
}

function ProbeThresholdMs {
    # Число заведомо не заводское: порог по умолчанию 5000, и совпадение с ним скрыло бы
    # подмену - проверка прошла бы и на затёртой правке.
    7777
}

# Тот же вызов, но с ОТВЕТОМ: слово инструмента приходит через MESSAGE, а командлет отдаёт
# его предупреждением в свой вывод. Отдельная функция нужна затем, что обычный вызов ответа
# не возвращает - иначе каждый StartWatch печатал бы приветствие модуля прямо в отчёт.
function Ask-Method([string]$method) {
    $file = Join-Path $outDir "invoke-$method.ps1"
    Write-Ps51 $file @"
`$ErrorActionPreference = 'Stop'
$navImport
Invoke-NAVCodeunit -ServerInstance $Instance -CompanyName '$Company' -CodeunitId $TaskCodeunitId -MethodName $method -ErrorAction Stop
"@
    $log = & $ps51 -NoProfile -ExecutionPolicy Bypass -File $file 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { Fail "$method не отработал:`n$log" }
    # Приветствие модуля управления режется по его же концу, а не по длине: длина завтра
    # другая, а строка отчёта от него втрое длиннее самого ответа.
    $log = ($log -replace '\s+', ' ').Trim()
    $log = ($log -replace '^.*Microsoft\.Dynamics\.Nav\.Apps\.Management\s*', '') -replace '^WARNING: ', ''
    return $log.Trim()
}

# Сколько молчания инструмент считает бедой - то же правило, что и у него самого: двадцать
# периодов опроса, но не меньше минуты. Повторено здесь НАРОЧНО: прогон, спрашивающий порог
# у проверяемого, проверял бы согласие инструмента с самим собой, а не с обещанием.
function SilenceWaitSeconds {
    $ms = ([int](Scalar "SELECT [Poll Period (ms)] FROM $setup;")) * 20
    if ($ms -lt 60000) { $ms = 60000 }
    return [int][math]::Ceiling($ms / 1000)
}
# Запас поверх порога: часы у отметки прохода - SQL, а спрашивает время NAV, и на стенде они
# расходятся на секунды. Пять секунд перекрывают эту разницу, не пряча самой границы.
function SilenceSlackSeconds { 5 }

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
    # в кэше: UPDATE мимо NAV до сессии не доходит. Здесь раньше стояло предположение, будто
    # первое же обращение запишет кэшированную строку обратно; замер 13.09.2026 говорит
    # другое - запись из NAV в правленную мимо строку не проходит ВОВСЕ и отказывает словами
    # про страницу (FINDINGS, раздел 69). Вывод от этого не меняется: отметка не обнуляется,
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

    # Время в журнале - UTC, и это не придирка к формату. Часы серверной сессии NAV идут по
    # UTC, в колонку момент ложится как есть, а в пояс читателя его переводит клиент; отдай
    # туда местное - и человек увидит БУДУЩЕЕ ровно на разницу поясов. Ловилось на стенде +3
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

    # Настройка, правленная МИМО NAV. На запертой установке это первый же порыв: поменять
    # порог прямо в SQL. Служба такой правки не видит - строка лежит в её кэше, - и это
    # полбеды; беда в том, что первая же запись из NAV в ту же строку падает совсем, а
    # говорит при этом про страницу, которой нет (FINDINGS, раздел 69). Завод сторожа - как
    # раз такая запись.
    #
    # Кэш прогревается НАРОЧНО: сцена спрашивает слово сторожа перед правкой. Без этого она
    # зависела бы от того, читал ли кто-то настройку в этой жизни службы.
    Ask-Method 'SayHealth' | Out-Null
    $thresholdWas = Scalar "SELECT [Alert Threshold (ms)] FROM $setup;"
    Invoke-Sql "UPDATE $setup SET [Alert Threshold (ms)] = $(ProbeThresholdMs);" | Out-Null
    $armAgain = Try-Method 'StartWatch'
    $thresholdNow = Scalar "SELECT [Alert Threshold (ms)] FROM $setup;"
    Invoke-Sql "UPDATE $setup SET [Alert Threshold (ms)] = $thresholdWas;" | Out-Null
    # Половины две, и порознь они пусты: завод, читающий кэш, падает - и первая краснеет; а
    # завод, прочитавший кэш и всё же записавший, вернул бы прежний порог - краснеет вторая.
    Check 'настройка, правленная мимо NAV, не ломает завод сторожа' `
        ($armAgain.Ok -and ($thresholdNow -eq "$(ProbeThresholdMs)")) `
        "завод $(if ($armAgain.Ok) { 'отработал' } else { "ОТКАЗАЛ: $($armAgain.Log)" }), порог после завода $thresholdNow при ожидаемом $(ProbeThresholdMs)"

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
    if (-not (Wait-PassStuck 60)) { Fail-NoWindow 'завод поверх идущего прохода' }
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

    # Спрашивается эпизод НА СВОЕЙ таблице, а не "хоть какой-нибудь открытый". Счёт
    # открытых строк выполняется всякой чужой блокировкой: на тихом стенде её нет, а на
    # боевой базе - на той самой, ради которой инструмент и ставят, - она есть всегда.
    # Условие выполнялось бы состоянием, которого опыт не создавал, и поймай сторож что
    # угодно вместо нашего замка - сказать об этом было бы некому. Имя таблицы прогон и
    # так печатал рядом: спросить его стоило ровно ничего.
    $caught = Wait-For { ([int](Scalar "SELECT COUNT(*) FROM $episode WHERE [Open] = 1 AND [NAV Table Name] = N'$markName';")) -gt 0 } 60
    # Номер СВОЕГО эпизода: по нему дальше спрашивается его судьба, а не судьба соседа.
    $caughtNo = Scalar "SELECT TOP 1 CONVERT(varchar(11),[Entry No_]) FROM $episode WHERE [NAV Table Name] = N'$markName' ORDER BY [Entry No_] DESC;"
    if ('' -eq $caughtNo) { $caughtNo = '-1' }
    $seen = Scalar "SELECT TOP 1 [NAV Table Name] + '|' + CONVERT(varchar(11),[NAV Key No_]) + '|' + CONVERT(varchar(11),[Head SPID]) FROM $episode ORDER BY [Entry No_] DESC;"
    Check 'сторож поймал настоящую блокировку сам' $caught `
        "эпизод $caughtNo на [$markName]; последняя строка журнала: $seen"

    Write-Host 'Отпускаю блокировку и жду, пока эпизод закроется САМ'
    Stop-Sqlcmd $blocker
    Stop-Sqlcmd $waiter
    $blocker = $null
    # Закрыться обязан ТОТ ЖЕ эпизод. "Есть закрытая строка" выполняется любой чужой,
    # закрывшейся когда угодно и кем угодно, а наш при этом остался бы открытым навсегда -
    # ровно та беда, ради которой закрытие и проверяют.
    $closed = Wait-For { ([int](Scalar "SELECT COUNT(*) FROM $episode WHERE [Entry No_] = $caughtNo AND [Open] = 0;")) -gt 0 } 60
    Check 'эпизод закрылся сам, без нажатия' $closed `
        "эпизод $caughtNo $(if ($closed) { 'закрыт' } else { 'ОТКРЫТ' }); закрытых всего $(Scalar "SELECT COUNT(*) FROM $episode WHERE [Open] = 0;"), открытых $(Scalar "SELECT COUNT(*) FROM $episode WHERE [Open] = 1;")"

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
    # Старится и едет СВОЙ эпизод, тот самый, что поймал сторож. Самая свежая закрытая
    # строка - это не то же самое: на базе, где наблюдение уже шло, ею оказалась бы чужая,
    # и переезд проверялся бы на ней.
    $movedNo = Scalar "SELECT TOP 1 CONVERT(varchar(11),[Entry No_]) FROM $episode WHERE [Open] = 0 AND [Entry No_] = $caughtNo;"
    # Бед тут две, и они разные. Срок не задан - это стенд, и подставлять свой ради опыта
    # нельзя: переезд меряется БОЕВЫМ сроком. Свой эпизод не закрылся - это инструмент, и
    # проверка выше уже красная. А "закрытых эпизодов нет" было просто неправдой: чужих
    # закрытых на базе сколько угодно, спор же идёт за СВОЙ.
    if ($retention -le 0) {
        Fail "срок переезда в настройке $retention дней - старить нечем, а подставлять свой срок значило бы мерить не то, что пойдёт в бою"
    }
    if ('' -eq $movedNo) {
        Fail ("эпизод $caughtNo закрытым не стал, и переезд мерить не на чем - это отказ " +
              "инструмента, не опыта: закрытых эпизодов на базе $(Scalar "SELECT COUNT(*) FROM $episode WHERE [Open] = 0;"), но спор идёт за свой")
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
    if (-not (Wait-For { (LastPass) -ne $beforeStop } 60)) { Fail-NoPass 'завод перед опытом с остановкой' }
    $cover = Start-Sqlcmd 'watch-journal-hold-stop.sql' $journalHold
    if (-not (Wait-PassStuck 60)) { Fail-NoWindow 'остановка во время прохода' }
    # Номер ИДУЩЕЙ задачи запоминается, пока она стоит на замке: по нему потом отличается
    # своя строка от чужой. Строка идущей задачи в очереди одна и та же - это и меряем.
    $heldId = Scalar "SELECT TOP 1 CONVERT(varchar(40),[ID]) FROM $tasks WHERE [Run Codeunit] = $TaskCodeunitId AND [Company] = N'$Company';"
    # Задач тут обязана быть ровно одна, и обе стороны от единицы - беда ИНСТРУМЕНТА, а не
    # опыта: ноль значит, что цепочка оборвалась, два - что она раздвоилась, и второе ровно
    # то, о чём проверка выше. Опыт держит замок на журнале, а задачи ставит сторож.
    $tasksHeld = TaskCount
    if (($tasksHeld -ne 1) -or ('' -eq $heldId)) {
        Fail ("во время прохода задач в очереди $tasksHeld при ожидаемой одной" +
              $(if ($tasksHeld -eq 0) { ' - цепочка оборвалась' }
                elseif ($tasksHeld -gt 1) { ' - цепочка раздвоилась' }
                else { ', а номер идущей задачи не прочитался' }) +
              "; опыт тут ни при чём - он только держит замок. Сторож пишет: $(Scalar "SELECT [Watchdog Message] FROM $state;")")
    }
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
    if (-not (Wait-For { (LastPass) -ne $beforeFall } 60)) { Fail-NoPass 'завод перед опытом с падением' }
    $cover = Start-Sqlcmd 'watch-journal-hold-fall.sql' $journalHold
    if (-not (Wait-PassStuck 60)) { Fail-NoWindow 'падение прохода на замке' }
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

    # Цепочка умеет стоять в очереди и не исполняться НИ РАЗУ: при выключенном планировщике
    # экземпляра завод отрабатывает молча, галка стоит, задача стоит - а проходов нет
    # (замер 12.09.2026, FINDINGS, раздел 63). Сказать об этом некому: строку сторожа пишет
    # проход, а прохода нет, - и наблюдение выглядит живым, пока никто не смотрит на дату.
    #
    # Настоящий ключ экземпляра тут не трогается: это перезапуск службы посреди прогона.
    # Устраивается то же СОСТОЯНИЕ - задача снимается из очереди, а выключатель остаётся
    # стоять. В нём вся соль: выключенного сторожа ругать не за что.
    #
    # Строку задачи снимаем в цикле: идущая задача перевзводит себя ПОСЛЕ снятия, и одного
    # DELETE мало - он уберёт строку, а следующий проход поставит новую.
    Write-Host 'Роняю цепочку и спрашиваю здоровье'
    $dead = $false
    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $deadline) {
        Invoke-Sql "DELETE FROM $tasks WHERE [Run Codeunit] = $TaskCodeunitId AND [Company] = N'$Company';" | Out-Null
        Start-Sleep -Milliseconds 300
        if ((TaskCount) -eq 0) {
            $quiet = LastPass
            Start-Sleep -Seconds 5
            if (((TaskCount) -eq 0) -and ((LastPass) -eq $quiet)) { $dead = $true; break }
        }
    }
    if (-not $dead) {
        Fail "цепочку уронить не вышло: задач в очереди $(TaskCount), отметка прохода двигается - опыт не состоялся"
    }
    # Спрашивается СРАЗУ, пока молчание короткое: слово, говорящееся всегда, тут обязано
    # промолчать. Без этой половины проверку прошёл бы сторож, кричащий после каждой
    # остановки, - а такой хуже молчащего.
    $earlyAge = [int](Scalar "SELECT DATEDIFF(second,[Last Pass At],SYSUTCDATETIME()) FROM $state;")
    $earlySaid = Ask-Method 'SayHealth'
    # Отметку прохода НЕ подставляем: писать её мимо NAV значило бы спорить с кэшем сервера,
    # а порог тут всего минута - его дешевле выждать по-настоящему. Заодно проверяется и сам
    # порог: слово обязано появиться не раньше, чем цепочка вправду замолчала.
    #
    # Ждём тут не события, а ЧАСОВ - другого способа перейти порог нет, - но смотрим на
    # возраст отметки у СЕРВЕРА, а не на свой будильник: время инструмент берёт там же.
    $wait = (SilenceWaitSeconds) + (SilenceSlackSeconds)
    Write-Host "  жду порог молчания: $wait с"
    $aged = Wait-For {
        ([int](Scalar "SELECT DATEDIFF(second,[Last Pass At],SYSUTCDATETIME()) FROM $state;")) -gt $wait
    } ($wait + 30)
    if (-not $aged) { Fail 'отметка прохода не состарилась - часы сервера стоят, мерить нечем' }
    $silentSaid = Ask-Method 'SayHealth'
    $spoke = $silentSaid -match 'chain of passes|Цепочка проходов'
    # Цепочка возвращается, и спрашивается ТО ЖЕ САМОЕ: живую оболгать нельзя.
    Invoke-Method 'StartWatch'
    $beforeAlive = LastPass
    if (-not (Wait-For { (LastPass) -ne $beforeAlive } 60)) { Fail-NoPass 'завод после опыта с молчанием' }
    $aliveSaid = Ask-Method 'SayHealth'
    Check 'замолчавшая цепочка названа словами, а идущая - не оболгана' `
        ($spoke -and ($earlySaid -notmatch 'chain of passes|Цепочка проходов') -and
         ($aliveSaid -notmatch 'chain of passes|Цепочка проходов')) `
        "через $earlyAge с молчания: $earlySaid; за порогом в $(SilenceWaitSeconds) с: $silentSaid; при живой цепочке: $aliveSaid"
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
