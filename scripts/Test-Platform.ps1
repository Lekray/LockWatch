#requires -Version 7
<#
.SYNOPSIS
    Дорога к имени ЧЕЛОВЕКА от самой платформы: спрашивает ли её проход, и не выдумывает ли
    он имя, когда платформа молчит.

.DESCRIPTION
    Уровень 2 стоит дорого - правка CustomSettings.config, перезапуск экземпляра, оба права
    SQL и постоянная серверная сессия XE, - и потому включается решением заказчика. Но
    страшнее цены другое: **молчание этой дороги невидимо**. Не выдали право или не взвели
    ключ - платформа не пишет ничего, а журнал выглядит точно так же, как на здоровой
    системе без единой блокировки.

    В v2 у дороги нет ни своей страницы, ни кнопки, ни отчёта о состоянии: имя спрашивает
    сам проход, и спрашивает только тогда, когда это разрешено настройкой. Поэтому и
    проверяется здесь ровно две вещи - что выключатель соблюдается и что из молчания
    платформы не рождается имя. Слова сторожа "Имена от платформы: N из M" и есть отчёт о
    том, что вопрос задан.

    Держателем блокировки здесь может быть только СЕССИЯ NAV: штатная таблица показывает
    лишь те транзакции, что платформа завела в свою карту, а соединение sqlcmd в неё не
    попадает никогда. Держит Codeunit 110235, ждёт всё тот же sqlcmd.

    Прогон возвращает ключ мониторинга в то состояние, в котором его нашёл, - и настройку
    тоже: имена от платформы, сбор кругов и разбор документа он правит на время опыта, а
    возвращает теми, какими их застал.

.EXAMPLE
    pwsh scripts/Test-Platform.ps1
#>
[CmdletBinding()]
param(
    [string] $Server   = 'localhost',
    [string] $Database = $env:LW_DATABASE,
    [string] $Instance = $env:LW_INSTANCE,
    [string] $Company  = $env:LW_COMPANY,
    [int]    $PassCodeunitId = 110230,
    [int]    $HoldCodeunitId = 110235,
    [switch] $KeepJournal,
    [switch] $StopInstance
)

$ErrorActionPreference = 'Stop'
$root   = Split-Path -Parent $PSScriptRoot
$outDir = Join-Path $root 'out'
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir | Out-Null }

function Fail([string]$message) { Write-Host "ОТКАЗ: $message" -ForegroundColor Red; exit 1 }
function Warn-Cleanup([string]$message) { Write-Host "ВНИМАНИЕ: $message" -ForegroundColor Red }
function Refuse([string]$message, [bool]$soft) {
    # Мягкий отказ - предупреждение вместо завершения процесса. Он нужен УБОРКЕ: Fail делает
    # exit, а exit прекращает процесс сразу и до конца блока finally - catch его не ловит
    # вовсе, и предупреждение о невозврате ключа было бы мёртвым кодом.
    if ($soft) { Warn-Cleanup $message; return $false }
    Fail $message
}
function Invoke-CleanupSql([string]$query, [string]$why) {
    # -b обязателен: без него sqlcmd отдаёт НОЛЬ и на ошибке SQL, и уборка, не выполнившаяся
    # вовсе, выглядела бы сделанной. Отказ уборки прогон не роняет - о нём говорят словами.
    $answer = & sqlcmd -S $Server -d $Database -E -b -l 30 -h -1 -Q $query 2>&1
    if ($LASTEXITCODE -ne 0) { Warn-Cleanup "$why не убралось: $(($answer -join ' ') -replace '\s+', ' ')" }
}
if (-not $Database) { Fail 'не задано имя базы: переменная LW_DATABASE или параметр -Database' }
if (-not $Instance) { Fail 'не задан экземпляр службы: переменная LW_INSTANCE' }
if (-not $Company)  { Fail 'не задана компания: переменная LW_COMPANY' }

$episode = "[$Company`$LockWatch Episode]"
# Настройка - одна на базу, и приставки компании в её SQL-имени нет.
$setup   = '[LockWatch Setup]'
# Таблица контекста: строка-носитель держателя лежит в ней, а в журнале она называется без
# приставки компании - так её разбирает SplitSqlObjectName.
$context = "[$Company`$LockWatch Context Table]"
$contextName = 'LockWatch Context Table'
# Номер строки-носителя. Тот же, что у Codeunit 110235 Hold Bench (потолок целого NAV):
# настоящей таблицы с таким номером нет, а отрицательный номер таблица контекста не примет.
$benchTableNo = 2147483647
$watchdog = '[LockWatch Watchdog]'
$service = "MicrosoftDynamicsNavServer`$$Instance"

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
# Ответ держателя и его ОШИБКА - разные потоки, и второй до сих пор уходил в никуда. Держатель
# тут - наш же объект C/AL, и упасть он может по-своему; отказ, не показавший этих слов,
# посылает смотреть на стенд там, где упал объект.
$holdOut = Join-Path $outDir 'hold-answer.txt'
$holdErr = Join-Path $outDir 'hold-error.txt'
# Читать файл, открытый на запись чужим процессом, обычным способом нельзя: Get-Content
# отказывает по занятости. Отсюда общий доступ и пустая строка вместо отказа - читаем мы это
# только ради слов в отказе, и падать на самом чтении бессмысленно.
function Read-Shared([string]$path) {
    if (-not (Test-Path $path)) { return '' }
    try {
        $fs = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        try { return (New-Object IO.StreamReader($fs)).ReadToEnd() } finally { $fs.Dispose() }
    } catch { return '' }
}
function Start-Codeunit([int]$id, [string]$method) {
    # Слова прошлого прогона гасятся ДО запуска: отказ читает эти файлы и принял бы чужой
    # ответ за сегодняшний - то самое состояние, которого опыт не создавал.
    foreach ($f in @($holdOut, $holdErr)) { if (Test-Path $f) { Remove-Item $f -Force } }
    $runFile = Join-Path $outDir "invoke-plat-bg-$id-$method.ps1"
    Write-Ps51 $runFile @"
`$ErrorActionPreference = 'Stop'
$navImport
Invoke-NAVCodeunit -ServerInstance $Instance -CompanyName '$Company' -CodeunitId $id -MethodName $method -ErrorAction Stop
"@
    return Start-Process -FilePath $ps51 -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput $holdOut -RedirectStandardError $holdErr `
        -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$runFile`""
}
function Set-Monitoring([string]$value, [string]$why, [switch]$Soft) {
    $cfgFile = Join-Path $outDir 'set-monitoring.ps1'
    Write-Ps51 $cfgFile @"
`$ErrorActionPreference = 'Stop'
$navImport
Set-NAVServerConfiguration -ServerInstance $Instance -KeyName EnableDeadlockMonitoring -KeyValue $value -ErrorAction Stop
"@
    & $ps51 -NoProfile -ExecutionPolicy Bypass -File $cfgFile | Out-Null
    if ($LASTEXITCODE -ne 0) { return (Refuse "ключ мониторинга не переключился ($why)" $Soft) }
    Write-Host "  ключ EnableDeadlockMonitoring = $value, перезапускаю службу ($why)"
    Restart-Service $service -Force
    & $ps51 -NoProfile -ExecutionPolicy Bypass -File $probeFile | Out-Null
    if ($LASTEXITCODE -ne 0) { return (Refuse "экземпляр $Instance не ответил по порту управления" $Soft) }
    return $true
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
    # BOM обязателен, как и во всех .sql репозитория: файл читает sqlcmd, и без BOM он
    # разбирает его как OEM. Кириллицы в этих запросах нет, но правило одно на весь
    # репозиторий - иначе оно держится памятью того, кто писал файл.
    [IO.File]::WriteAllText($file, (($body -replace "`r`n", "`n") -replace "`n", "`r`n"), (New-Object System.Text.UTF8Encoding($true)))
    # Путь БЕЗ кавычек: список аргументов Start-Process экранирует его сам, а добавленные
    # руками кавычки уезжают в sqlcmd частью имени файла, и он молча не находит его.
    return Start-Process -FilePath 'sqlcmd' -PassThru -WindowStyle Hidden `
        -ArgumentList @('-S', $Server, '-d', $Database, '-E', '-b', '-l', '30', '-i', $file)
}
function Stop-Sqlcmd($process) {
    if ($process -and -not $process.HasExited) { $process.Kill(); $process.WaitForExit(10000) | Out-Null }
}
# Ждать НАСТУПЛЕНИЯ события, а не спать наугад: сон вслепую делает прогон то зелёным, то
# красным в зависимости от того, чем занята машина.
function Wait-For([scriptblock]$condition, [int]$seconds) {
    $deadline = (Get-Date).AddSeconds($seconds)
    while ((Get-Date) -lt $deadline) {
        if (& $condition) { return $true }
        Start-Sleep -Milliseconds 500
    }
    return $false
}
# Сколько ждать, пока блокировка встанет и её увидит очередь. Держатель держит минуту, и
# опоздать сюда можно только на пуске модуля NAV и на холодной службе - девяноста секунд
# хватает на оба, а больше ждать нечего: держатель к этому времени уже отпустил бы замок.
function HoldWaitSeconds { 90 }

# Проверка на дорогу к имени. Одна и та же в обеих сценах, и это нарочно: обещается не
# "имя есть", а ЧЕСТНОСТЬ - источник имени и само имя обязаны сходиться. Имя без источника
# платформы (2) значило бы, что оно взялось из ниоткуда; источник 2 при пустом имени - что
# проход отчитался о названном, ничего не назвав.
function NameIsHonest([string]$source, [string]$name) {
    if ($source -eq '2') { return ($name -ne '') }
    return ($name -eq '')
}

$wasMonitoring = ''
$setupWas = ''
$holder = $null
$waiter = $null
try {
    Write-Host 'Подготовка стенда'
    if ((Get-Service $service).Status -ne 'Running') { Start-Service $service }
    $wasMonitoring = Get-Monitoring
    Write-Host "  ключ мониторинга найден в состоянии $wasMonitoring"
    # Настройка возвращается НАЙДЕННОЙ, а не заводской: имена от платформы, сбор кругов и
    # разбор документа принадлежат установке, и прогон правит их только на время опыта.
    # Заводские значения тут - догадка о чужой настройке.
    $setupWas = Scalar "SELECT CONVERT(varchar(2),[Platform Names Enabled]) + '|' + CONVERT(varchar(2),[Deadlocks Enabled]) + '|' + CONVERT(varchar(11),[Documents per Pass]) FROM $setup;"
    Invoke-Sql "UPDATE $setup SET [SQL Server] = N'$Server', [Platform Names Enabled] = 0, [Deadlocks Enabled] = 0, [Documents per Pass] = 0;" | Out-Null
    if (-not $KeepJournal) { Invoke-Sql "DELETE FROM $episode;" | Out-Null }

    # Перезапуск нужен и затем, чтобы правка настройки дошла до службы: при работающей
    # службе строка лежит в кэше, и запрос до сессии не доходит вовсе.
    Write-Host "  перезапускаю службу $Instance и жду ответа порта управления"
    Restart-Service $service -Force
    & $ps51 -NoProfile -ExecutionPolicy Bypass -File $probeFile | Out-Null
    if ($LASTEXITCODE -ne 0) { Fail "экземпляр $Instance не ответил по порту управления" }

    # ---------- сцена первая: имена ВЫКЛЮЧЕНЫ, дорогу проход не зовёт ----------
    # Держатель и ждущий ставятся заново на каждую сцену: строка-носитель живёт внутри
    # транзакции держателя, и пережить перезапуск службы она не может.
    function Invoke-HoldScene([string]$why) {
        Write-Host "  ${why}: блокировку держит сессия NAV, ждёт sqlcmd"
        $script:holder = Start-Codeunit $HoldCodeunitId 'Hold'
        $held = $false
        $deadline = (Get-Date).AddSeconds((HoldWaitSeconds))
        while ((Get-Date) -lt $deadline) {
            # Чтение ГРЯЗНОЕ, и это не небрежность. Обычное чтение встало бы в очередь за той
            # самой блокировкой, которую мы ждём: опрос заблокировался бы на всё время
            # удержания и вернул бы ответ уже ПОСЛЕ его конца. Ловилось ровно так: sqlcmd
            # умирал сразу с нулевым кодом.
            $doc = Scalar "SELECT [Table Name] FROM $context WITH (READUNCOMMITTED) WHERE [Table No_] = $benchTableNo;"
            if ($doc -eq 'LOCKWATCH-BENCH') { $held = $true; break }
            Start-Sleep -Milliseconds 500
        }
        if (-not $held) {
            # Блокировку держит НАШ объект C/AL, и его молчание отличается от "не успел"
            # только по самому процессу и по тому, что он сказал.
            $holdSaid = ((((Read-Shared $holdOut) + ' ' + (Read-Shared $holdErr))) -replace '\s+', ' ').Trim()
            if ($holdSaid.Length -gt 200) { $holdSaid = $holdSaid.Substring(0, 200) + '...' }
            Fail ('сессия NAV блокировку так и не взяла за ' + (HoldWaitSeconds) + ' с: держатель ' +
                  $(if ($script:holder.HasExited) { "вышел с кодом $($script:holder.ExitCode)" } else { 'ещё идёт' }) +
                  $(if ($holdSaid) { ", сказал: $holdSaid" } else { ', не сказал ничего' }))
        }
        $script:waiter = Start-Sqlcmd 'platform-want.sql' "SET LOCK_TIMEOUT -1`nBEGIN TRAN`nUPDATE $context SET [Table Name] = N'WANT' WHERE [Table No_] = $benchTableNo`nROLLBACK`n"
        # Ждущий, умерший на старте, выглядит точно как ждущий, который не успел встать в
        # очередь. Разница видна только по самому процессу, и спросить о ней надо до того,
        # как прогон объявит "инструмент не увидел блокировку".
        Start-Sleep -Seconds 2
        if ($script:waiter.HasExited) { Fail "ждущий sqlcmd умер сразу, код выхода $($script:waiter.ExitCode) - опыт не удался" }
        $waitRow = ''
        $deadline = (Get-Date).AddSeconds(40)
        while ((Get-Date) -lt $deadline) {
            $waitRow = Scalar @"
SELECT TOP 1 CONVERT(varchar(11),wt.session_id)
FROM sys.dm_os_waiting_tasks wt
JOIN sys.dm_exec_sessions s ON s.session_id = wt.session_id
WHERE wt.wait_type LIKE 'LCK[_]%' AND s.host_process_id = $($script:waiter.Id);
"@
            if ($waitRow) { break }
            Start-Sleep -Milliseconds 500
        }
        if (-not $waitRow) {
            Fail ('ожидание в очереди сервера так и не появилось за 40 с: ждущий ' +
                  $(if ($script:waiter.HasExited) { "вышел с кодом $($script:waiter.ExitCode)" } else { 'ещё идёт' }) +
                  ', держатель ' +
                  $(if ($script:holder.HasExited) { "вышел с кодом $($script:holder.ExitCode)" } else { 'ещё идёт' }) +
                  ", отметка держателя [$(Scalar "SELECT [Table Name] FROM $context WITH (READUNCOMMITTED) WHERE [Table No_] = $benchTableNo;")]")
        }
        return $waitRow
    }
    # Держатель держит минуту; после замера его надо ДОЖДАТЬСЯ, а не убивать. Убитый клиент
    # оставляет на сервере сессию, которая держит ту же строку, и второй держатель сцены
    # упёрся бы в неё вставкой - опыт объявил бы "строку не удалось положить", и причина
    # была бы не в инструменте.
    function Wait-HolderGone {
        if ($script:holder -and -not $script:holder.HasExited) { $script:holder.WaitForExit(90000) | Out-Null }
        Stop-Sqlcmd $script:waiter
        $script:waiter = $null
        # Строка-носитель уходит в транзакции держателя; её отсутствие - знак, что транзакция
        # кончилась, а не что мы просто перестали смотреть.
        Wait-For { '' -eq (Scalar "SELECT [Table Name] FROM $context WITH (READUNCOMMITTED) WHERE [Table No_] = $benchTableNo;") } 30 | Out-Null
    }

    Write-Host ''
    Write-Host 'Сцена первая: имена от платформы выключены, дорогу проход не зовёт'
    Invoke-HoldScene 'сцена без имён' | Out-Null
    Invoke-Codeunit $PassCodeunitId 'RunPass' 'проход по живой очереди без имён' | Out-Null
    $saidOff = Scalar "SELECT [Watchdog Message] FROM $watchdog;"
    $rowOff = Scalar @"
SELECT TOP 1 [NAV Table Name] + '|' + [Blocker Program] + '|' + CONVERT(varchar(11),[Victim Is NAV]) + '|' +
             [User Name] + '|' + CONVERT(varchar(11),[User Source])
FROM $episode WHERE [NAV Table Name] = N'$contextName' ORDER BY [Entry No_] DESC;
"@
    $o = @(($rowOff -split '\|') | ForEach-Object { $_.Trim() })
    while ($o.Count -lt 5) { $o += '' }
    # Спрашивается не "в журнале есть строка", а ЧЬЯ она. Здесь весь опыт держится на том,
    # что блокировку держит СЕССИЯ NAV: имя человека платформа обещает только ей, и спор
    # двух чужих соединений отвечал бы на другой вопрос. Жертва спрашивается признаком
    # сессии NAV, а не программой: программу жертвы из журнала убрали. Ждёт здесь sqlcmd,
    # то есть признак обязан быть «Нет» (2): «Да» значило бы, что опыт поставил в очередь
    # не того.
    Check 'эпизод по блокировке сессии NAV заведён' `
        (($o[0] -eq $contextName) -and ($o[1] -match '(?i)dynamics nav') -and ($o[2] -eq '2')) `
        "таблица [$($o[0])] при ожидаемой [$contextName], держал [$($o[1])], жертва - сессия NAV $($o[2]) при ожидаемом 2 (нет, ждёт sqlcmd)"
    Check 'при выключенных именах проход к платформе не ходит и имя не выдумывает' `
        (($saidOff -notmatch 'Имена от платформы|Names from the platform') -and
         (NameIsHonest $o[4] $o[3])) `
        "сторож пишет: $saidOff; имя [$($o[3])], откуда $($o[4])"

    Write-Host '  жду, пока держатель отпустит строку'
    Wait-HolderGone

    # ---------- сцена вторая: имена ВКЛЮЧЕНЫ, дорога обязана быть спрошена ----------
    # Ключ мониторинга здесь взводится: именно он наполняет штатную таблицу, и с ним
    # "платформа молчит" - это уже настоящее молчание, а не выключенный сбор.
    Write-Host ''
    Write-Host 'Сцена вторая: имена взведены, ключ мониторинга включён'
    Invoke-Sql "UPDATE $setup SET [Platform Names Enabled] = 1;" | Out-Null
    Set-Monitoring 'true' 'имена взводятся' | Out-Null
    Invoke-HoldScene 'сцена с именами' | Out-Null
    Invoke-Codeunit $PassCodeunitId 'RunPass' 'проход по живой очереди с именами' | Out-Null
    $saidOn = Scalar "SELECT [Watchdog Message] FROM $watchdog;"
    $rowOn = Scalar @"
SELECT TOP 1 [User Name] + '|' + CONVERT(varchar(11),[User Source])
FROM $episode WHERE [NAV Table Name] = N'$contextName' ORDER BY [Entry No_] DESC;
"@
    $n = ($rowOn -split '\|') | ForEach-Object { $_.Trim() }
    if ($n.Count -lt 2) { $n += @('', '') }
    # Слово "Имена от платформы: N из M" - и есть доказательство, что вопрос задан. Число M
    # обязано быть не меньше единицы: наш эпизод стоит открытым и без имени виновника, и
    # промахнуться мимо него проход мог только не спросив вовсе.
    $counts = 0
    if ($saidOn -match 'Имена от платформы: (\d+) из (\d+)') { $counts = [int]$Matches[2] }
    elseif ($saidOn -match 'Names from the platform: (\d+) of (\d+)') { $counts = [int]$Matches[2] }
    Check 'при включённых именах проход спросил платформу и назвал только то, что она дала' `
        (($counts -ge 1) -and (NameIsHonest $n[1] $n[0])) `

        "сторож пишет: $saidOn; имя [$($n[0])], откуда $($n[1])"
}
finally {
    Write-Host 'Убираю за собой'
    Stop-Sqlcmd $waiter
    if ($holder -and -not $holder.HasExited) { $holder.WaitForExit(90000) | Out-Null }
    # Ответ держателя читается ПОСЛЕ его конца: он и есть решающий опыт про карту
    # транзакций - видит ли сессия хотя бы собственную блокировку.
    if (Test-Path $holdOut) {
        $answer = [IO.File]::ReadAllText($holdOut)
        if ($answer -match 'LOCKHOLD user (\S+) session (\d+) ms (\d+) ownrows (\d+) laterows (\d+)') {
            Write-Host "  держатель видел строк платформы: сразу $($Matches[4]), при ждущем $($Matches[5]); его учётка $($Matches[1])"
        }
        Remove-Item $holdOut -Force
    }
    # Настройка возвращается в найденное состояние, а не в заводское: три её поля правит
    # этот прогон, и все три принадлежат установке.
    if ($setupWas -match '^\d\|\d\|\d+$') {
        $was = $setupWas -split '\|'
        $setupBack = "UPDATE $setup SET [Platform Names Enabled] = $($was[0]), [Deadlocks Enabled] = $($was[1]), [Documents per Pass] = $($was[2]);"
    } else {
        $setupBack = "UPDATE $setup SET [Platform Names Enabled] = 0, [Deadlocks Enabled] = 1, [Documents per Pass] = 0;"
        Warn-Cleanup 'прежние значения настройки прочитать не удалось - вернул 0, 1 и 0'
    }
    Invoke-CleanupSql ("$setupBack" + $(if (-not $KeepJournal) { " DELETE FROM $episode;" })) 'уборка за прогоном'
    # Ключ возвращается в то состояние, в котором его нашли: включённый мониторинг живёт
    # серверной сессией XE, которая переживает снятие инструмента, и оставлять его
    # взведённым по итогам прогона нельзя. Зовётся МЯГКО: Fail делает exit, а exit
    # прекращает процесс сразу и до конца finally - catch его не ловит, и предупреждение
    # о невозврате ключа с жёстким вызовом было бы мёртвым кодом.
    if ($wasMonitoring) {
        try { Set-Monitoring $wasMonitoring 'ключ возвращается как был' -Soft | Out-Null }
        catch { Warn-Cleanup "ключ мониторинга вернуть не удалось: $($_.Exception.Message)" }
    }
    if ($StopInstance) { Stop-Service $service -Force }
}

Write-Host ''
Write-Host "пройдено $passed из $total"
Write-Host ''
$report | ForEach-Object { Write-Host $_ }
if ($passed -lt $total) { Fail 'дорога от платформы проверку не прошла' }
Write-Host 'Готово: проход спрашивает платформу, а имя из молчания не выдумывает' -ForegroundColor Green
