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

    Срок хранения в v2 - это УДАЛЕНИЕ, и второго места, куда строка могла бы переехать,
    больше нет. Поэтому здесь же проверяется, что состаренный эпизод исчезает из журнала
    насовсем и что сторож говорит об этом словом; лишний по потолку уходит тем же путём.

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
    [int]    $TaskCodeunitId = 110232,
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
# Настройка и состояние - одни на базу, и приставки компании в их SQL-имени нет.
$setup   = '[LockWatch Setup]'
$state   = '[LockWatch Watchdog]'
$context = "[$Company`$LockWatch Context Table]"
# Та же таблица, но именем, каким её пишет в журнал разбор: без компании и без скобок.
# Спор в опыте идёт за неё, и спрашивать эпизод надо по ЭТОМУ имени.
$contextName = 'LockWatch Context Table'
$tasks   = '[dbo].[Scheduled Task]'
$service = "MicrosoftDynamicsNavServer`$$Instance"

# Срок ЗАПРОСА у sqlcmd. Без него запрос, вставший за чужим замком, висит сколько угодно:
# -l ограничивает только вход, а не самый запрос. Опыт здесь держит замки нарочно, и
# спрашивать очередную судьбу эпизода, стоя в ней же, - верный способ не кончить прогон
# никогда. Две минуты: дольше всех тут ждёт не запрос, а опыт, и он ждёт своим счётом.
function QueryTimeoutSeconds { 120 }

function Invoke-Sql([string]$query) {
    # -w 500 обязателен: по умолчанию sqlcmd рвёт строку на 80 знаках, и длинное значение
    # приходит ДВУМЯ строками. Проверка, читающая первую, получает обрезок и судит по нему.
    # -b обязателен не меньше: без него sqlcmd возвращает НОЛЬ и на ошибке SQL, проверка
    # кода возврата проходит вхолостую, а запрос не выполнен вовсе.
    $answer = & sqlcmd -S $Server -d $Database -E -b -l 30 -t (QueryTimeoutSeconds) -w 500 -W -s '|' -h -1 -Q "SET NOCOUNT ON; $query" 2>&1
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
# Номер эпизода, который ушёл по сроку. Своего в журнале прогон уносит за собой сам: иначе
# стенд копил бы по опытному эпизоду за прогон, и однажды они стали бы объяснением чужого
# замера.
$movedNo = ''
$movedSaid = ''
# Подготовленные вызовы ждут знака файлом и без него висели бы вечно: их снимает уборка.
$armProc = $null
$stopProc = $null
function Start-Sqlcmd([string]$name, [string]$sql) {
    # Срок ЗАПРОСА здесь нарочно не ставится: эти соединения держат замок, а держателю
    # положено ждать - в его скрипте стоит WAITFOR, и замок и есть то, ради чего он поднят.
    # Оборвав его по сроку, прогон кончил бы опыт посреди окна и стал бы винить инструмент.
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
# пишет каждым проходом - удаление старых строк идёт всегда, - а завод и остановка к нему
# не обращаются вовсе и потому проходят целиком, пока проход стоит.
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

# Отказ обязан называть то, что ИЗМЕРИЛ. "Окно не открылось" читается как "замок не встал",
# то есть посылает смотреть на sqlcmd даже тогда, когда замок стоял, а не шли проходы.
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
# только зовёт StartWatch, и не отработай вызов - отказал бы сам Invoke-Method.
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

# Сколько ждать удаления строки. Удаление идёт тем же проходом, что и съём очереди, а
# проход случается раз в период опроса - три секунды по умолчанию. Тридцати секунд хватает
# на десяток проходов подряд: если за десять проходов не ушло, дело не в невезении.
function MoveWaitSeconds { 30 }

# Сколько времени отметке прохода позволено разойтись с часами SQL. Её ставит сам проход
# моментом от SQL, и разойтись они могут только на длительность самого прохода. Минута -
# это шестьдесят его цен при объявленном потолке в тысячу миллисекунд, то есть запас,
# который не спрячет ошибки в часовой пояс: тот дал бы три часа, а не секунду.
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
    # Тот же вызов, но отказ здесь - не беда прогона, а ОТВЕТ: сцена спрашивает, переживает
    # ли завод правку настройки мимо NAV, и отказ обязан стать числом в проверке.
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
    return [pscustomobject]@{ Ok = ($LASTEXITCODE -eq 0); Log = (("$line" -replace '\s+', ' ')).Trim() }
}

# Тот же вызов, но с ОТВЕТОМ: слово инструмента приходит через MESSAGE, а командлет отдаёт
# его предупреждением в свой вывод.
function Ask-Method([string]$method) {
    $file = Join-Path $outDir "invoke-$method.ps1"
    Write-Ps51 $file @"
`$ErrorActionPreference = 'Stop'
$navImport
Invoke-NAVCodeunit -ServerInstance $Instance -CompanyName '$Company' -CodeunitId $TaskCodeunitId -MethodName $method -ErrorAction Stop
"@
    $log = & $ps51 -NoProfile -ExecutionPolicy Bypass -File $file 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { Fail "$method не отработал:`n$log" }
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
function GrowWaitSeconds {
    # Вдвое с лишним больше порога в две секунды, считая в секундах: ожидание растёт не
    # само по себе, а ОТМЕТКАМИ прохода - раз в период опроса, - и на занятой машине
    # заход может опоздать. Минута перекрывает десяток таких опозданий.
    60
}
function GrowProbeMs {
    # Столько "ждал" обязан набрать пойманный эпизод, чтобы его длительность была видна.
    # Две секунды - заводской порог записи; ниже него эпизода не было бы вовсе.
    2000
}
function CeilingProbeRows {
    # Потолок журнала на время опыта - одна строка. Нужен он затем, чтобы проверить
    # удаление по потолку, а не только по сроку. Единица, а не ноль: ноль означает
    # "потолка нет". Ставится он до перезапуска - настройку служба держит в кэше.
    1
}
function ShortEpisodeMs {
    # Столько "ждал" подставной короткий эпизод. Единица, а не ноль: ноль читается как
    # "длительность неизвестна", а спор идёт за строку, которая ЖДАЛА, но мало.
    1
}
# Запас поверх порога: часы у отметки прохода - SQL, а спрашивает время NAV, и на стенде они
# расходятся на секунды. Пять секунд перекрывают эту разницу, не пряча самой границы.
function SilenceSlackSeconds { 5 }

# Уборка за собой судится по факту, и её беды копятся здесь: в отчёт они обязаны попасть и
# тогда, когда сцена оборвалась отказом, - больше о них сказать некому.
$cleanupWarn = @()
$cleanupFail = @()

try {
    Write-Host 'Подготовка стенда'
    if ((Get-Service $service).Status -ne 'Running') { Start-Service $service }
    # Запоминается ВСЁ, что прогон правит, и возвращается найденным: у установки свои
    # значения этих полей, и заводские числа здесь стирали бы её настройку под видом уборки.
    $ceilingWas = Scalar "SELECT CONVERT(varchar(11),[Journal Rows Ceiling]) FROM $setup;"
    $minWaitWas = Scalar "SELECT CONVERT(varchar(11),[Journal Min Wait (ms)]) FROM $setup;"
    $deadlocksWas = Scalar "SELECT CONVERT(varchar(2),[Deadlocks Enabled]) FROM $setup;"
    $documentsWas = Scalar "SELECT CONVERT(varchar(11),[Documents per Pass]) FROM $setup;"
    if (-not ($ceilingWas -and $minWaitWas -and $deadlocksWas -and $documentsWas)) {
        $cleanupWarn += 'настройка прочиталась не вся - вернуть её поля в уборке нечем'
    }
    # Сбор взаимоблокировок выключается: он берёт графы из КОЛЬЦЕВОГО БУФЕРА сервера, а
    # туда они попадают от кого угодно и когда угодно. Строка в журнале была бы законной,
    # но проверка "эпизод заведён ровно один" считает строки.
    #
    # Порог записи ставится в ноль: опыт держит блокировку считанные секунды, и на заводском
    # пороге эпизод мог бы не открыться вовсе. Потолок - в одну строку, чтобы проверить
    # удаление по потолку. Разбор документа выключается: проход с ним читает ВСЮ включённую
    # таблицу контекста, а опыт держит её строку замком.
    Invoke-Sql @"
UPDATE $setup SET [SQL Server] = N'$Server', [Deadlocks Enabled] = 0,
       [Journal Min Wait (ms)] = 0, [Documents per Pass] = 0,
       [Journal Rows Ceiling] = $(CeilingProbeRows);
"@ | Out-Null

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
    # Строки контекста для опыта лежат с отрицательными номерами и выключены: настоящая
    # таблица контекста начинает с номера 110232, так что отрицательные ей не принадлежат.
    Invoke-Sql @"
DELETE FROM $episode;
DELETE FROM $context WHERE [Table No_] BETWEEN -6000 AND -1;
INSERT INTO $context ([Table No_],[Table Name],[Document Field No_],[Document Field Name],[Document Caption],[Enabled])
VALUES (-1,N'LW Fixture',0,N'',N'',0);
"@ | Out-Null

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
    # туда местное - и человек увидит БУДУЩЕЕ ровно на разницу поясов.
    $clock = Scalar @"
SELECT CONVERT(varchar(11),ABS(DATEDIFF(second,SYSUTCDATETIME(),[Last Pass At]))) + '|' +
       CONVERT(varchar(11),DATEDIFF(minute,SYSUTCDATETIME(),SYSDATETIME()))
FROM $state;
"@
    $c = @(($clock -split '\|') | ForEach-Object { $_.Trim() })
    while ($c.Count -lt 2) { $c += '0' }
    Check 'время записано по UTC' (([int]$c[0]) -le (ClockSlackSeconds)) `
        "отметка прохода расходится с UTC на $($c[0]) с, пояс сервера $($c[1]) мин"

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
    # галку прямо в SQL. Служба такой правки не видит, а первая же запись из NAV в ту же
    # строку падает словами про страницу, которой нет (FINDINGS, раздел 69). Завод сторожа
    # читает строку заново (SELECTLATESTVERSION) и обязан пережить эту правку.
    #
    # Кэш прогревается НАРОЧНО: сцена спрашивает слово сторожа перед правкой. Выключатель
    # гасится в SQL, а завод обязан поставить его обратно - обе половины и проверяются:
    # отказ завода и незаписанное значение красят проверку.
    Ask-Method 'SayHealth' | Out-Null
    Invoke-Sql "UPDATE $setup SET [Enabled] = 0;" | Out-Null
    $armAgain = Try-Method 'StartWatch'
    $enabledNow = Scalar "SELECT CONVERT(varchar(2),[Enabled]) FROM $setup;"
    Check 'настройка, правленная мимо NAV, не ломает завод сторожа' `
        ($armAgain.Ok -and ($enabledNow -eq '1')) `
        "завод $(if ($armAgain.Ok) { 'отработал' } else { "ОТКАЗАЛ: $($armAgain.Log)" }), выключатель после завода $enabledNow при ожидаемом 1"

    # Завод ПОВЕРХ идущего прохода. Строка исполняющейся задачи в таблице есть, но снятие
    # её не останавливает: она доходит до конца и на прежнем коде перевзводила себя уже
    # после завода - цепочек становилось ДВЕ, обе живые, обе перевзводятся.
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
    # Ждём именно этого: появилась вторая - ответ есть сразу, не появилась за двадцать
    # секунд - тоже ответ. Строка задачи живёт и пока задача ИСПОЛНЯЕТСЯ, поэтому число
    # снимается в тишине: когда очередной проход уже отчитался.
    Wait-For { (TaskCount) -gt 1 } 20 | Out-Null
    $quietPass = LastPass
    Wait-For { (LastPass) -ne $quietPass } 30 | Out-Null
    Check 'завод поверх идущего прохода не создаёт второй цепочки' ((TaskCount) -eq 1) `
        "задач в планировщике $(TaskCount) при ожидаемой 1, сторож пишет: $(Scalar "SELECT [Watchdog Message] FROM $state;")"

    Write-Host 'Устраиваю блокировку и НИЧЕГО не нажимаю'
    $hold = "SET LOCK_TIMEOUT -1`nBEGIN TRAN`nUPDATE $context SET [Table Name] = N'HELD' WHERE [Table No_] = -1`nWAITFOR DELAY '00:05:00'`nROLLBACK`n"
    $want = "SET LOCK_TIMEOUT -1`nBEGIN TRAN`nUPDATE $context SET [Table Name] = N'WANT' WHERE [Table No_] = -1`nROLLBACK`n"
    $blocker = Start-Sqlcmd 'watch-hold.sql' $hold
    Start-Sleep -Seconds 2
    $waiter = Start-Sqlcmd 'watch-want.sql' $want

    # Спрашивается эпизод НА СВОЕЙ таблице, а не "хоть какой-нибудь открытый". Счёт
    # открытых строк выполняется всякой чужой блокировкой: на тихом стенде её нет, а на
    # боевой базе - на той самой, ради которой инструмент и ставят, - она есть всегда.
    $caught = Wait-For { ([int](Scalar "SELECT COUNT(*) FROM $episode WHERE [Open] = 1 AND [NAV Table Name] = N'$contextName';")) -gt 0 } 60
    # Номер СВОЕГО эпизода: по нему дальше спрашивается его судьба, а не судьба соседа.
    $caughtNo = Scalar "SELECT TOP 1 CONVERT(varchar(11),[Entry No_]) FROM $episode WHERE [NAV Table Name] = N'$contextName' ORDER BY [Entry No_] DESC;"
    if ('' -eq $caughtNo) { $caughtNo = '-1' }
    $seen = Scalar "SELECT TOP 1 [NAV Table Name] + '|' + CONVERT(varchar(11),[NAV Key No_]) + '|' + CONVERT(varchar(11),[Blocker SPID]) FROM $episode ORDER BY [Entry No_] DESC;"
    Check 'сторож поймал настоящую блокировку сам' $caught `
        "эпизод $caughtNo на [$contextName]; последняя строка журнала: $seen"

    # Блокировка держится, пока ожидание не ПЕРЕВАЛИТ заводской порог записи: иначе
    # длительность эпизода отдана воле случая, и проверка удаления мерила бы не срок, а то,
    # в какой миг прохода пришла очередь. Держателя хватает: он взят на пять минут.
    $grew = Wait-For { ([int](Scalar "SELECT ISNULL([Max Wait (ms)],0) FROM $episode WHERE [Entry No_] = $caughtNo;")) -ge (GrowProbeMs) } (GrowWaitSeconds)
    if (-not $grew) {
        $grewMs = Scalar "SELECT CONVERT(varchar(11),[Max Wait (ms)]) FROM $episode WHERE [Entry No_] = $caughtNo;"
        Fail "эпизод $caughtNo за $(GrowWaitSeconds) с дорос лишь до $grewMs мс при ожидаемых $(GrowProbeMs) - опыт не удался"
    }

    Write-Host 'Отпускаю блокировку и жду, пока эпизод закроется САМ'
    Stop-Sqlcmd $blocker
    Stop-Sqlcmd $waiter
    $blocker = $null
    # Закрыться обязан ТОТ ЖЕ эпизод. "Есть закрытая строка" выполняется любой чужой,
    # закрывшейся когда угодно и кем угодно, а наш при этом остался бы открытым навсегда.
    $closed = Wait-For { ([int](Scalar "SELECT COUNT(*) FROM $episode WHERE [Entry No_] = $caughtNo AND [Open] = 0;")) -gt 0 } 60
    Check 'эпизод закрылся сам, без нажатия' $closed `
        "эпизод $caughtNo $(if ($closed) { 'закрыт' } else { 'ОТКРЫТ' }); закрытых всего $(Scalar "SELECT COUNT(*) FROM $episode WHERE [Open] = 0;"), открытых $(Scalar "SELECT COUNT(*) FROM $episode WHERE [Open] = 1;")"
    if (-not $closed) {
        Fail ("эпизод $caughtNo закрытым не стал, и срок хранения мерить не на чем - это отказ " +
              "инструмента, не опыта: закрытых эпизодов на базе $(Scalar "SELECT COUNT(*) FROM $episode WHERE [Open] = 0;"), но спор идёт за свой")
    }

    # Копия пойманного эпизода кладётся ДО старения: она останется свежей и станет второй
    # строкой для проверки потолка. Копия, а не выдуманная строка: у эпизода четыре десятка
    # полей, и подставная строка проверяла бы не удаление, а умение прогона заполнять таблицу.
    function New-EpisodeCopy([int]$fromNo, [int]$startShiftSeconds) {
        Scalar @"
DECLARE @cols nvarchar(max) = N'', @sel nvarchar(max) = N'', @s nvarchar(max);
SELECT @cols = @cols + CASE WHEN @cols = N'' THEN N'' ELSE N',' END + QUOTENAME(c.name),
       @sel = @sel + CASE WHEN @sel = N'' THEN N'' ELSE N',' END +
         CASE c.name WHEN N'Entry No_' THEN N'@new'
                     WHEN N'Max Wait (ms)' THEN N'$(ShortEpisodeMs)'
                     WHEN N'Open' THEN N'0'
                     WHEN N'Started At' THEN N'DATEADD(second,@shift,GETUTCDATE())'
                     ELSE QUOTENAME(c.name) END
FROM sys.columns c JOIN sys.types ty ON ty.user_type_id = c.user_type_id
WHERE c.object_id = OBJECT_ID(N'$episode') AND c.is_computed = 0 AND ty.name <> N'timestamp';
DECLARE @new int = (SELECT ISNULL(MAX([Entry No_]),0) + 1 FROM $episode);
SET @s = N'INSERT INTO $episode (' + @cols + N') SELECT ' + @sel + N' FROM $episode WHERE [Entry No_] = $fromNo;';
EXEC sp_executesql @s, N'@new int,@shift int', @new = @new, @shift = $startShiftSeconds;
SELECT CONVERT(varchar(11),@new);
"@
    }
    $copyNo = [int](New-EpisodeCopy ([int]$caughtNo) 0)
    if ($copyNo -le 0) { Fail 'копия пойманного эпизода не легла - опыт не удался' }

    # Срок хранения в v2 - УДАЛЕНИЕ, и второго места, куда строка могла бы переехать, нет.
    # Ждать настоящих суток нельзя, а подставлять свой срок - значит мерить не то, что
    # пойдёт в бою: эпизод СТАРИТСЯ на день больше боевого срока из настройки.
    Write-Host 'Старю закрытый эпизод и снова НИЧЕГО не нажимаю'
    $retention = [int](Scalar "SELECT [Retention (Days)] FROM $setup;")
    if ($retention -le 0) {
        Fail "срок хранения в настройке $retention дней - старить нечем, а подставлять свой срок значило бы мерить не то, что пойдёт в бою"
    }
    $movedNo = Scalar "SELECT TOP 1 CONVERT(varchar(11),[Entry No_]) FROM $episode WHERE [Entry No_] = $caughtNo AND [Open] = 0;"
    if ('' -eq $movedNo) { Fail "эпизод $caughtNo закрытым не стал, и удаление мерить не на чем - опыт не удался" }
    # Строка сторожа обнуляется ПЕРЕД старением: её пишет каждый проход, и "удалено" от
    # прошлого удаления осталось бы в ней от прежнего прогона.
    Invoke-Sql "UPDATE $state SET [Watchdog Message] = N'';" | Out-Null
    Invoke-Sql "UPDATE $episode SET [Started At] = DATEADD(day,-$($retention + 1),[Started At]) WHERE [Entry No_] = $movedNo;" | Out-Null
    # Слово снимается В ТОТ ЖЕ МИГ, что и уход строки: строку эту переписывает КАЖДЫЙ
    # проход, и следующий затрёт "удалено" обычным отчётом.
    $agedGone = Wait-For {
        if (([int](Scalar "SELECT COUNT(*) FROM $episode WHERE [Entry No_] = $movedNo;")) -ne 0) { return $false }
        $script:movedSaid = Scalar "SELECT [Watchdog Message] FROM $state;"
        return $true
    } (MoveWaitSeconds)
    if (-not $agedGone) { $movedSaid = Scalar "SELECT [Watchdog Message] FROM $state;" }
    # Истории в v2 нет вовсе: удаление обязано быть окончательным, и таблицы, куда строка
    # могла бы переехать, в базе не должно быть ни одной.
    $historyTables = [int](Scalar "SELECT COUNT(*) FROM sys.tables WHERE [name] LIKE '%LockWatch Episode History%';")
    Check 'эпизод старше срока удалён из журнала насовсем, и сторож об этом говорит' `
        ($agedGone -and ($historyTables -eq 0) -and ($movedSaid -match 'Deleted by retention or ceiling|Удалено по сроку или потолку')) `
        ("эпизод $movedNo (ждал $(ShortEpisodeMs) мс, срок $retention дн.) из журнала $(if ($agedGone) { 'ушёл' } else { 'НЕ ушёл' }), " +
         "таблиц истории $historyTables; сторож пишет: $movedSaid")

    # Удаление по ПОТОЛКУ - вторая половина того же обещания, и меряется она иначе: строка
    # не старая, а лишняя. Копия пойманного уже лежит в журнале свежей; вторая копия делает
    # их две, и потолок в одну строку обязан унести СТАРУЮ.
    Write-Host 'Кладу вторую свежую строку и жду, пока лишнюю выбросит ПОТОЛОК'
    $ceilNo = [int](New-EpisodeCopy $copyNo 1)
    if ($ceilNo -le 0) { Fail 'вторая свежая строка не легла - опыт не удался' }
    Invoke-Sql "UPDATE $state SET [Watchdog Message] = N'';" | Out-Null
    # Ждём УХОДА строки, а не времени: проход ходит раз в период опроса.
    $ceilGone = Wait-For { ([int](Scalar "SELECT COUNT(*) FROM $episode WHERE [Entry No_] = $copyNo;")) -eq 0 } (MoveWaitSeconds)
    $ceilSaid = Scalar "SELECT [Watchdog Message] FROM $state;"
    $ceilLeft = [int](Scalar "SELECT COUNT(*) FROM $episode WHERE [Entry No_] = $ceilNo;")
    Check 'лишняя по потолку строка удалена, свежая оставлена, и сторож об этом говорит' `
        ($ceilGone -and ($ceilLeft -eq 1) -and ($ceilSaid -match 'Deleted by retention or ceiling|Удалено по сроку или потолку')) `
        ("строка $copyNo из журнала $(if ($ceilGone) { 'ушла' } else { 'НЕ ушла' }), свежая $ceilNo осталась ($ceilLeft); сторож пишет: $ceilSaid")

    Write-Host 'Останавливаю сторожа'
    Invoke-Method 'StopWatch'
    $enabled = Scalar "SELECT CONVERT(varchar(2),[Enabled]) FROM $setup;"
    Check 'остановка снимает и выключатель, и задачу' (($enabled -eq '0') -and ((TaskCount) -eq 0)) `
        "включён $enabled, задач в планировщике $(TaskCount)"

    # Одного выключателя мало: уже поставленная задача проснулась бы и после "стоп".
    # Поэтому проверяем не намерение, а результат - что проходов больше НЕТ.
    #
    # Проход, начавшийся ДО остановки, дописывает свою отметку уже после неё, и окно,
    # поставленное сразу за "стоп", засчитало бы ЕГО как проход после остановки. Поэтому
    # окно начинается с ТИШИНЫ: пока отметка двигается, идущий проход ещё не кончился.
    $quietFrom = LastPass
    $settled = Wait-For {
        $now = LastPass
        if ($now -eq $quietFrom) { Start-Sleep -Seconds 5; return (LastPass) -eq $quietFrom }
        $script:quietFrom = $now
        return $false
    } 30
    if (-not $settled) {
        Fail 'отметка последнего прохода не устоялась за 30 с - проходы не прекратились, и мерить окно нечем'
    }
    $frozen = LastPass
    $moved = Wait-For { (LastPass) -ne $frozen } 15
    Check 'после остановки проходов больше нет' (-not $moved) `
        "за 15 секунд отметка последнего прохода $(if ($moved) { 'СДВИНУЛАСЬ' } else { 'не сдвинулась' })"

    # Остановка гасит выключатель и снимает задачи, но идущую снять нечем: строка её на
    # месте и после снятия. Значит не перевзвестись она должна САМА, и ради этого
    # выключатель перечитывается ВТОРОЙ раз - перед перевзводом, а не только в начале задачи.
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
    # опыта: ноль значит, что цепочка оборвалась, два - что она раздвоилась.
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
    # Меряем ПОЯВЛЕНИЕ НОВОЙ задачи, а не итоговый ноль: воскресшая цепочка ставит ровно
    # одну задачу, та просыпается, видит выключатель в НАЧАЛЕ задачи и умирает сама. Ноль
    # наступает и на сломанном коде - секунды на три позже, - а чужой номер в очереди факт.
    $newTask = Wait-For {
        '' -ne (Scalar "SELECT TOP 1 CONVERT(varchar(40),[ID]) FROM $tasks WHERE [Run Codeunit] = $TaskCodeunitId AND [Company] = N'$Company' AND [ID] <> '$heldId';")
    } 20
    Check 'остановка во время прохода не воскрешает цепочку' (-not $newTask) `
        "новых задач после остановки $(if ($newTask) { 'ПОЯВИЛАСЬ' } else { 'не появилось' }), в очереди сейчас $(TaskCount), сторож пишет: $(Scalar "SELECT [Watchdog Message] FROM $state;")"

    # Обещание, записанное рядом с CODEUNIT.RUN: своя ошибка внутри прохода откатывает его
    # транзакцию, но НЕ роняет задачу - иначе цепочка оборвалась бы на первой же
    # неожиданности, и наблюдение кончилось бы молча, посреди ночи.
    #
    # Замок устраивает. Держим журнал ДОЛЬШЕ предела ожидания блокировки у NAV, и проход
    # срывается сам, по-настоящему. Дальше спрашивается не намерение, а результат - сказал
    # ли сторож про падение и ПОШЛИ ЛИ проходы снова, когда замок отпустили.
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
    # экземпляра завод отрабатывает молча, галка стоит, задача стоит - а проходов нет.
    # Сказать об этом некому: строку сторожа пишет проход, а прохода нет, - и наблюдение
    # выглядит живым, пока никто не смотрит на дату.
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
    # Журнал чистится ПО СВОЕМУ ПРИЗНАКУ, а не целиком: свой эпизод здесь тот, что про нашу
    # таблицу контекста, - ровно так же его называет и сам прогон, спрашивая его судьбу.
    # Чужие строки журнала - это чьи-то настоящие блокировки, и сметать их заодно со своим
    # значило бы унести не своё.
    $cleanup = "DELETE FROM $context WHERE [Table No_] BETWEEN -6000 AND -1;"
    $cleanup += " DELETE FROM $episode WHERE [NAV Table Name] = N'$contextName';"
    # Задачи снимаются С КОМПАНИЕЙ. Тот же кодюнит в другой компании той же базы - это чужая
    # цепочка, и DELETE без компании унёс бы её заодно со своей.
    $cleanup += " DELETE FROM $tasks WHERE [Run Codeunit] = $TaskCodeunitId AND [Company] = N'$Company';"
    # Выключатель гасится НАРОЧНО: прогон кончается остановленным сторожем. Остальные поля
    # возвращаются НАЙДЕННЫМИ: прогон трогал их только на время опыта.
    $cleanup += " UPDATE $setup SET [Enabled] = 0;"
    if ($deadlocksWas) { $cleanup += " UPDATE $setup SET [Deadlocks Enabled] = $deadlocksWas;" }
    if ($minWaitWas)   { $cleanup += " UPDATE $setup SET [Journal Min Wait (ms)] = $minWaitWas;" }
    if ($documentsWas) { $cleanup += " UPDATE $setup SET [Documents per Pass] = $documentsWas;" }
    if ($ceilingWas)   { $cleanup += " UPDATE $setup SET [Journal Rows Ceiling] = $ceilingWas;" }
    # Своя строка из журнала уносится по НОМЕРУ, а не очисткой таблицы: чужие строки - это
    # чужие настоящие блокировки.
    if ($movedNo) { $cleanup += " DELETE FROM $episode WHERE [Entry No_] = $movedNo;" }
    if ($copyNo -gt 0) { $cleanup += " DELETE FROM $episode WHERE [Entry No_] = $copyNo;" }
    if ($ceilNo -gt 0) { $cleanup += " DELETE FROM $episode WHERE [Entry No_] = $ceilNo;" }
    # Уборка судится по ФАКТУ, а не по намерению. Ключ -b здесь обязателен: без него sqlcmd
    # вернёт НОЛЬ и на ошибке, и провалившаяся уборка выглядела бы сделанной.
    $cleanupSaid = & sqlcmd -S $Server -d $Database -E -b -l 30 -t (QueryTimeoutSeconds) -h -1 -W -Q $cleanup 2>&1
    if ($LASTEXITCODE -ne 0) {
        $cleanupFail += "уборка отказала: sqlcmd вернул $LASTEXITCODE, $(($cleanupSaid -join ' ').Trim())"
    }
    $leftRows = [int](Scalar "SELECT COUNT(*) FROM $context WHERE [Table No_] BETWEEN -6000 AND -1;")
    $leftJournal = [int](Scalar "SELECT COUNT(*) FROM $episode WHERE [NAV Table Name] = N'$contextName';")
    if ($leftRows -gt 0)    { $cleanupFail += "строк контекста опыта осталось $leftRows" }
    if ($leftJournal -gt 0) { $cleanupFail += "своих эпизодов в журнале осталось $leftJournal" }
    if ((TaskCount) -gt 0)  { $cleanupFail += "задач сторожа осталось $(TaskCount) (компания $Company)" }
    # Настройка спрашивается тем же счётом: возвращённая "почти" - это не возвращённая.
    # Сверяется она, только если была ПРОЧИТАНА: пустая находка - это не ноль, а нечитанная
    # строка, и сравнивать с ней нечего.
    if ($ceilingWas -and $minWaitWas -and $deadlocksWas -and $documentsWas) {
        $backWas = "$ceilingWas|$minWaitWas|$deadlocksWas|$documentsWas"
        $backNow = Scalar @"
SELECT ISNULL(CONVERT(varchar(11),[Journal Rows Ceiling]),'') + '|' +
       ISNULL(CONVERT(varchar(11),[Journal Min Wait (ms)]),'') + '|' +
       ISNULL(CONVERT(varchar(2),[Deadlocks Enabled]),'') + '|' +
       ISNULL(CONVERT(varchar(11),[Documents per Pass]),'')
FROM $setup;
"@
        if ($backNow -ne $backWas) {
            $cleanupWarn += "настройка возвращена не той, что была найдена: [$backNow] вместо [$backWas]"
        }
    }
    if ($cleanupWarn -or $cleanupFail) {
        Write-Host ''
        Write-Host 'ВНИМАНИЕ: уборка за собой прошла не так, как задумано:' -ForegroundColor Yellow
        ($cleanupWarn + $cleanupFail) | ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow }
    }
    if ($StopInstance) { Stop-Service $service -Force }
}

Write-Host ''
Write-Host "пройдено $passed из $total"
Write-Host ''
$report | ForEach-Object { Write-Host $_ }
if ($passed -lt $total) { Fail 'фоновая задача проверку не прошла' }
# Уборка - часть прогона, а не вежливость в конце: оставленная задача идёт сама и сыграет в
# следующем замере, оставленная строка контекста сыграет чужой строкой.
if ($cleanupFail) { Fail ("уборка за собой не обошлась:`n  " + ($cleanupFail -join "`n  ")) }
Write-Host 'Готово: сторож заводится, идёт сам, ловит блокировку и умирает по кнопке' -ForegroundColor Green
