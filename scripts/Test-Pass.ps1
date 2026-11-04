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

    Блокировка устраивается на СВОЕЙ таблице (таблица контекста), а не на чужой: чужая
    строка на стенде - это чужие данные, а своя пуста и никому не мешает. На таблице
    настройки её устраивать нельзя вовсе - настройку читает сам проход, и опыт
    заблокировал бы наблюдателя. Строки контекста для опыта лежат с ОТРИЦАТЕЛЬНЫМИ
    номерами и выключены: настоящая таблица контекста начинает с номера 110232, а
    выключенную строку не читает и разбор документа.

    Разбор документа на время опыта выключен (Documents per Pass = 0), и это не
    послабление: проход с включённым разбором читает ВСЮ включённую таблицу контекста,
    а опыт держит её строку замком - проход встал бы на своём же опыте. Документ
    проверяется отдельно, в Test-Document.ps1, на настоящей таблице установки.

    Сцен четыре. Первая - спор за СТРОКУ, с именем таблицы, ключом и ОБОИМИ людьми:
    держателя сервер называет логином, узлом и программой, а имя пользователя NAV у
    чужого соединения пустое, и выдумывать его инструмент не вправе. Вторая - спор за
    ОБЪЕКТ, имя которого разбор не понимает: каталог SQL отвечает не только про таблицы
    NAV, и такое имя обязано доехать до журнала сырым, а не потеряться молча. Третья -
    очередь в ДВА КОЛЕНА: виновником обязан оказаться ГОЛОВА цепочки, а не сосед,
    который сам стоит в очереди. Четвёртая - спор за таблицу ЦЕЛИКОМ: замок на объекте
    обязан быть записан родом OBJECTLOCK и с именем таблицы.

    Жертва и виновник - обычные соединения sqlcmd, а не сеансы NAV, и это нарочно: у
    чужой сессии предел ожидания NAV не действует, поэтому проход обязан ответить
    "исход не определён", а не приписать ей чужой предел. Опознаются они по номеру
    процесса, а не по номеру сеанса: номер процесса известен заранее, номер сеанса
    пришлось бы угадывать.

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
    [int]    $PassCodeunitId = 110230,
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
$context = "[$Company`$LockWatch Context Table]"
$contextName = "$Company`$LockWatch Context Table"
# Настройка и состояние - одни на базу, и приставки компании в их SQL-имени нет.
$setup   = '[LockWatch Setup]'
$state   = '[LockWatch Watchdog]'
# Сколько ждём, пока жертва получит блокировку после снятия виновника. Разорванное
# соединение сервер откатывает не мгновенно - разрыв он замечает на следующей сетевой
# операции, - и на наблюдавшихся заходах это секунды. Минута взята с запасом вдесятеро;
# превышение её означает, что виновник не отпустил вовсе, то есть опыт не удался.
function GrantWaitSeconds { 60 }
# Пустая дата NAV в SQL. Ни NULL, ни ноль: столбец NOT NULL, а нулю отвечает 1900 год.
$blankDate = "CONVERT(datetime,'17530101')"
$service = "MicrosoftDynamicsNavServer`$$Instance"
# Мишени второй сцены. Имя, которого разбор не понимает, нужно НАСТОЯЩЕЕ, и брать его у
# платформы нельзя: своих таблиц $ndo$ у неё на базу около дюжины, но их читает сама служба,
# и запертая на десяток секунд таблица планировщика уронила бы сеанс, а не проверила
# инструмент. Поэтому имена свои, заведомо ничьи, и ломают они то же правило вторым
# способом: после $VSIFT$ стоит не число. Обе пусты и уходят в уборке.
#
# Слова LockWatch в имени нет НАРОЧНО: снятие считает след по нему («таблиц SQL не
# осталось»), и мишень, пережившая упавший прогон, покрасила бы чужую проверку.
# Имя РАЗОВОЕ, своё у каждого захода: повторное имя вытаскивает из кэша планов номер
# ПРЕЖНЕГО объекта, и ждущий встаёт в очередь за призраком удалённой таблицы.
$probeTag   = "$PID-$((Get-Date).ToString('HHmmss'))"
$probeAName = "LW Probe`$VSIFT`$A$probeTag"
$probeBName = "LW Probe`$VSIFT`$B$probeTag"
$probeA = "[$probeAName]"
$probeB = "[$probeBName]"
# Имена рабочих станций. Их sqlcmd называет ключом -H, и без них проверка "сервер назвал
# узел виновника" проходит и на перепутанных местах колонках.
$holderHost = 'LW-HOLDER'
$victimHost = 'LW-VICTIM'
$middleHost = 'LW-MIDDLE'
# Логины сторон спора. Их три, и они разные НАРОЧНО. Весь вопрос "кто кого" в том, что
# людей несколько; опыт, где обе стороны ходят под одним именем, пропустит подмену
# виновника жертвой молча - имя совпадёт при любой ошибке, и красить будет нечему.
#
# Подключиться логином SQL нельзя: смешанный режим на стенде выключен. Поэтому
# соединение остаётся своим, а в чужой логин сессия входит через EXECUTE AS - он
# подменяет ровно ту колонку, которую читает инструмент: sys.dm_exec_sessions.login_name.
$holderLogin = 'LW Probe Holder'
$victimLogin = 'LW Probe Waiter'
$middleLogin = 'LW Probe Middle'

# Срок ЗАПРОСА у sqlcmd. Без него запрос, вставший за чужим замком, висит сколько угодно:
# -l ограничивает только вход, а не самый запрос.
function QueryTimeoutSeconds { 120 }

function Invoke-Sql([string]$query) {
    # -w 500 обязателен: по умолчанию sqlcmd рвёт строку на 80 знаках, и длинное значение
    # приходит ДВУМЯ строками. -b обязателен не меньше: без него sqlcmd возвращает НОЛЬ и
    # на ошибке SQL, проверка кода возврата проходит вхолостую, а запрос не выполнен.
    $answer = & sqlcmd -S $Server -d $Database -E -b -l 30 -t (QueryTimeoutSeconds) -w 500 -W -s '|' -h -1 -Q "SET NOCOUNT ON; $query" 2>&1
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
$probeHoldA = $null; $probeHoldB = $null; $probeWaiter = $null
$headProc = $null; $midProc = $null; $tailProc = $null
$bulkProc = $null; $bulkWaiter = $null
# Запрос уезжает ФАЙЛОМ, а не параметром -Q. Start-Process склеивает элементы -ArgumentList
# пробелом и кавычек вокруг них не ставит: запрос с пробелами рассыпается на аргументы,
# sqlcmd молча выходит с ошибкой, а выглядит это как "блокировка не случилась".
function Start-Sqlcmd([string]$name, [string]$sql, [string]$workstation = '') {
    # Срок ЗАПРОСА здесь нарочно не ставится: эти соединения держат блокировку, а держателю
    # положено ждать - оборвав его по сроку, прогон кончил бы опыт посреди сцены.
    $file = Join-Path $outDir $name
    [IO.File]::WriteAllText($file, (($sql -replace "`r`n", "`n") -replace "`n", "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
    $sqlArgs = @('-S', $Server, '-d', $Database, '-E', '-b', '-l', '30', '-i', $file)
    if ($workstation) { $sqlArgs += @('-H', $workstation) }
    Start-Process -FilePath 'sqlcmd' -PassThru -WindowStyle Hidden -ArgumentList $sqlArgs
}
# Логин заводится прогоном и им же убирается: оставленный на стенде опытный логин - это
# чужая учётная запись в списке безопасности сервера, которую никто не заказывал.
function New-ProbeLogin([string]$login) {
    # Пароль случайный и никуда не записывается. Войти этим логином всё равно нельзя -
    # смешанный режим выключен, - но синтаксис CREATE LOGIN пароля требует.
    $password = [Guid]::NewGuid().ToString('N') + 'Aa1!'
    Invoke-Sql @"
IF SUSER_ID(N'$login') IS NULL CREATE LOGIN [$login] WITH PASSWORD = '$password', CHECK_POLICY = OFF;
IF DATABASE_PRINCIPAL_ID(N'$login') IS NULL CREATE USER [$login] FOR LOGIN [$login];
GRANT SELECT, UPDATE ON $context TO [$login];
"@ | Out-Null
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
# Сколько строк класть в таблицу контекста, чтобы сервер перевёл замки на неё целиком.
# Предел эскалации у SQL Server - пять тысяч замков на ОДИН оператор; шесть тысяч проходят
# его с запасом и остаются дешёвыми.
function BulkRows { 6000 }
function BulkBase {
    # Сдвиг пачки от нуля: строки сцены четвёртой начинаются с -(BulkBase + 1), а не с -1,
    # чтобы номер строки-носителя других сцен не попал в их число.
    1000
}
function BulkLowest {
    # Нижняя строка пачки. Она же - нижняя граница уборки: брошенный прогон оставляет
    # хвост до неё, и следующий за ним наткнулся бы на повторяющийся ключ.
    -((BulkBase) + (BulkRows))
}
function PassWaitSeconds {
    # Столько ждём конца прохода, отпущенного из-под чужого замка. Проход на стенде идёт
    # доли секунды, но поднимает свою сессию NAV; три минуты перекрывают это с запасом.
    180
}

function Invoke-Pass([string]$why) {
    $log = & $ps51 -NoProfile -ExecutionPolicy Bypass -File $runFile 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { Fail "$why не отработал:`n$log" }
}

# Уборка за собой судится по факту, и её беды копятся здесь: в отчёт они обязаны попасть и
# тогда, когда сцена оборвалась отказом, - больше о них сказать некому.
$cleanupWarn = @()
$cleanupFail = @()

try {
    Write-Host 'Подготовка стенда'
    if ((Get-Service $service).Status -ne 'Running') { Start-Service $service }
    # Настройка, которую прогон трогает, запоминается ЗДЕСЬ - такой, какой он её нашёл.
    # Возвращать её заводской значило бы выдавать свою правку за уборку: у установки свои
    # значения этих полей, и сторож после прогона пошёл бы с чужими.
    $wasDeadlocks  = Scalar "SELECT CONVERT(varchar(2),[Deadlocks Enabled]) FROM $setup;"
    $wasStatements = Scalar "SELECT CONVERT(varchar(2),[Collect Statement Values]) FROM $setup;"
    $wasMinWait    = Scalar "SELECT CONVERT(varchar(11),[Journal Min Wait (ms)]) FROM $setup;"
    $wasDocuments  = Scalar "SELECT CONVERT(varchar(11),[Documents per Pass]) FROM $setup;"
    $wasPlatform   = Scalar "SELECT CONVERT(varchar(2),[Platform Names Enabled]) FROM $setup;"
    # Пустая находка - это не ноль, а НЕЧИТАННАЯ строка. Поля ниже прогон всё равно правит,
    # и возвращать их в уборке будет нечем: молчание тут означало бы полную уборку, которой
    # не было. Поэтому о неполном чтении говорится вслух, а беда копится к отчёту.
    $setupRead = [bool]($wasDeadlocks -and $wasStatements -and $wasMinWait -and $wasDocuments -and $wasPlatform)
    if (-not $setupRead) {
        $cleanupWarn += 'настройка прочиталась не вся - возвращать её поля в уборке нечем'
    }
    # Правка настройки мимо NAV в кэш службы не доходит, поэтому имя сервера ставится ДО
    # перезапуска. Перезапуск нужен и сам по себе: без него служба исполнила бы прежнюю
    # версию только что выложенных объектов, и опыт проверил бы не то.
    #
    # Сбор взаимоблокировок на время опыта выключается: он берёт графы из КОЛЬЦЕВОГО БУФЕРА
    # сервера, а туда они попадают от кого угодно и когда угодно. Строка в журнале была бы
    # законной, но проверка "эпизод заведён ровно один" считает строки.
    #
    # Разбор документа выключается по доводу из заголовка: проход с ним читает всю таблицу
    # контекста, а опыт держит её строку замком. Имена от платформы выключаются нарочно:
    # проверка "имя не выдумано" должна стоять на дороге, где имени взять неоткуда.
    Invoke-Sql ("UPDATE $setup SET [SQL Server] = N'$Server', [Deadlocks Enabled] = 0, " +
                "[Collect Statement Values] = 1, [Journal Min Wait (ms)] = 0, " +
                "[Documents per Pass] = 0, [Platform Names Enabled] = 0; " +
                "UPDATE $state SET [Watchdog Message] = N'';") | Out-Null
    if (-not $KeepJournal) { Invoke-Sql "DELETE FROM $episode;" | Out-Null }
    # Строки опыта лежат с отрицательными номерами и выключены. Настоящая таблица контекста
    # начинает с номера 110232, так что отрицательные номера ей не принадлежат.
    Invoke-Sql @"
DELETE FROM $context WHERE [Table No_] BETWEEN $(BulkLowest) AND -1;
INSERT INTO $context ([Table No_],[Table Name],[Document Field No_],[Document Field Name],[Document Caption],[Enabled])
VALUES (-1,N'LW Fixture',0,N'',N'',0),
       (-2,N'LW Fixture',0,N'',N'',0);
"@ | Out-Null

    Write-Host "  перезапускаю службу $Instance и жду ответа порта управления"
    Restart-Service $service -Force
    & $ps51 -NoProfile -ExecutionPolicy Bypass -File $probeFile | Out-Null
    if ($LASTEXITCODE -ne 0) { Fail "экземпляр $Instance не ответил по порту управления" }

    Write-Host 'Сцена первая: спор за строку - стороны под РАЗНЫМИ логинами'
    New-ProbeLogin $holderLogin
    New-ProbeLogin $victimLogin
    # EXECUTE AS стоит ПЕРВЫМ и до открытия транзакции: сессия должна встать в очередь уже
    # под своим логином, иначе сервер назовёт в очереди прежнюю учётную запись.
    $hold = "EXECUTE AS LOGIN = N'$holderLogin'`nSET LOCK_TIMEOUT -1`nBEGIN TRAN`nUPDATE $context SET [Table Name] = N'HELD' WHERE [Table No_] = -1`nWAITFOR DELAY '00:05:00'`nROLLBACK`n"
    # Жертва правит СВОЮ строку и только после этого встаёт в очередь за чужой. Порядок
    # обязателен: это два разных ресурса, и спутать их в журнале нечем.
    $want = "EXECUTE AS LOGIN = N'$victimLogin'`nSET LOCK_TIMEOUT -1`nBEGIN TRAN`nUPDATE $context SET [Table Name] = N'VICTIM' WHERE [Table No_] = -2`nUPDATE $context SET [Table Name] = N'WANT' WHERE [Table No_] = -1`nROLLBACK`n"
    $blocker = Start-Sqlcmd 'lock-hold.sql' $hold $holderHost
    Start-Sleep -Seconds 2
    $waiter = Start-Sqlcmd 'lock-want.sql' $want $victimHost

    # Ждём, пока ожидание ПОЯВИТСЯ в очереди сервера. Иначе провал проверки означал бы
    # "опыт не удался", а выглядел бы как "инструмент не увидел блокировку".
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

    $watchdog = Scalar "SELECT [Watchdog Message] FROM $state;"
    Check 'проход отчитался, а не промолчал' (($watchdog -ne '') -and ($watchdog -notmatch 'не удалось')) "сторож пишет: $watchdog"

    $rows = [int](Scalar "SELECT COUNT(*) FROM $episode;")
    Check 'эпизод заведён ровно один' ($rows -eq 1) "строк в журнале $rows"

    $row = Scalar @"
SELECT TOP 1
  CONVERT(varchar(11),[Victim SPID]) + '|' + CONVERT(varchar(11),[Blocker SPID]) + '|' +
  [Resource Kind] + '|' + CONVERT(varchar(30),[Hobt Id]) + '|' +
  CONVERT(varchar(11),[NAV Key No_]) + '|' + [NAV Table Name] + '|' +
  CONVERT(varchar(11),[Victim Is NAV]) + '|' + CONVERT(varchar(11),[Open]) + '|' +
  CONVERT(varchar(11),[Max Wait (ms)]) + '|' + [User Name] + '|' +
  CONVERT(varchar(11),[User Source]) + '|' + [Victim User Name] + '|' +
  [Blocker Login] + '|' + [Blocker Host] + '|' + [Blocker Program] + '|' +
  CONVERT(varchar(11),[Document Source]) + '|' + [No Document Reason]
FROM $episode ORDER BY [Entry No_] DESC;
"@
    if (-not $row) { Fail 'в журнале пусто - дальше проверять нечего' }
    $f = ($row -split '\|') | ForEach-Object { $_.Trim() }
    if ($f.Count -lt 17) { Fail "строка журнала пришла неполной: $($f.Count) колонок" }

    Check 'жертва и виновник те самые' ((([int]$f[0]) -eq $waiterSpid) -and (([int]$f[1]) -eq $blockerSpid)) `
        "жертва $($f[0]) при ожидаемой $waiterSpid, виновник $($f[1]) при ожидаемом $blockerSpid"
    # Признака "не опознано" в журнале больше нет; разобранность ресурса видна по тому,
    # что род назван ключевым, а hobt у него известен: сырой ресурс не даёт ни того, ни другого.
    Check 'ресурс разобран: род ключевой, hobt известен' (($f[2] -eq 'KEYLOCK') -and ($f[3] -ne '0')) `
        "род [$($f[2])], hobt $($f[3])"
    Check 'имя таблицы и номер ключа сняты с SQL' (($f[5] -eq 'LockWatch Context Table') -and ($f[4] -eq '0')) `
        "таблица [$($f[5])], ключ NAV $($f[4])"
    Check 'чужая сессия названа чужой' ($f[6] -eq '2') "признак сессии NAV $($f[6]) при ожидаемом 2 (нет)"

    # Текст запроса. Проверка СОСТЯЗАТЕЛЬНАЯ: виновник пишет HELD, жертва - WANT, и
    # перепутанные местами колонки провалят обе проверки разом. Проверка "текст непустой"
    # прошла бы и на тексте не того сеанса, а чужой запрос выглядит так же убедительно.
    $st = Scalar @"
SELECT TOP 1
  CONVERT(varchar(11),ISNULL(DATALENGTH([Blocker Statement Text]),0)) + '|' +
  CONVERT(varchar(11),ISNULL(DATALENGTH([Victim Statement]),0)) + '|' +
  CONVERT(varchar(11),CASE WHEN CAST(CAST([Blocker Statement Text] AS varbinary(max)) AS varchar(max)) LIKE '%HELD%' THEN 1 ELSE 0 END) + '|' +
  CONVERT(varchar(11),CASE WHEN CAST(CAST([Blocker Statement Text] AS varbinary(max)) AS varchar(max)) LIKE '%WANT%' THEN 1 ELSE 0 END) + '|' +
  CONVERT(varchar(11),CASE WHEN CAST(CAST([Victim Statement] AS varbinary(max)) AS varchar(max)) LIKE '%UPDATE%' THEN 1 ELSE 0 END) + '|' +
  CONVERT(varchar(11),CASE WHEN CAST(CAST([Victim Statement] AS varbinary(max)) AS varchar(max)) LIKE '%WAITFOR%' THEN 1 ELSE 0 END) + '|' +
  LEFT([Blocker Statement],40)
FROM $episode ORDER BY [Entry No_] DESC;
"@
    $q = ($st -split '\|') | ForEach-Object { $_.Trim() }
    if ($q.Count -lt 7) { Fail "строка о запросах пришла неполной: $($q.Count) колонок" }

    Check 'запрос виновника лёг в журнал, и это ЕГО запрос' `
        (($q[2] -eq '1') -and ($q[3] -eq '0') -and ([int]$q[0] -gt 0)) `
        "байтов $($q[0]), HELD внутри $($q[2]), WANT внутри $($q[3])"
    # У жертвы значения искать бессмысленно: её запрос берётся из КЭША ПЛАНОВ и приходит
    # параметризованным. Поэтому состязательность другая: обязан быть UPDATE и не быть
    # WAITFOR, который есть только в батче виновника.
    Check 'запрос жертвы лёг в журнал, и это ЕЁ запрос' `
        (($q[4] -eq '1') -and ($q[5] -eq '0') -and ([int]$q[1] -gt 0)) `
        "байтов $($q[1]), UPDATE внутри $($q[4]), WAITFOR внутри $($q[5])"
    Check 'начало запроса видно в списке, одной строкой' `
        (($q[6] -ne '') -and ($q[6] -notmatch "[`r`n]")) `
        "в колонке [$($q[6])]"
    # Имя названо по тому, что спрашивается: "не нулевая", а не "растёт". Проход здесь ОДИН,
    # и роста по одному наблюдению не видно - видно только, что длительность вообще снята.
    Check 'эпизод открыт, и длительность у него не нулевая' (($f[7] -eq '1') -and (([int]$f[8]) -gt 0)) `
        "открыт $($f[7]), длительность $($f[8]) мс"

    # Имя пользователя NAV у чужого соединения взять неоткуда: отметок контекста больше нет,
    # а платформа называет только свои сессии. Пустое имя с источником "нет" - это честный
    # ответ; выдуманное имя здесь было бы обвинением живого человека.
    Check 'имя виновника не выдумано там, где его никто не называл' `
        (($f[9] -eq '') -and ($f[10] -eq '0')) `
        "имя [$($f[9])], откуда $($f[10]) при ожидаемом 0 (нет)"
    Check 'имя ждущего не выдумано' ($f[11] -eq '') "кто ждал [$($f[11])] при ожидаемом пустом"

    # Второй ответ на "кто", и он о ДРУГОМ. Учётную запись NAV даёт платформа, а у чужого
    # соединения её нет; сервер же знает о держателе логин, узел и программу с самого
    # начала. Логин и узел сверяются ПО ИМЕНИ, а не на непустоту: непустота проходит и на
    # перепутанных колонках - логин-то есть у обоих.
    Check 'сервер назвал держателя: логин, узел, программа' `
        (($f[12] -eq $holderLogin) -and ($f[13] -eq $holderHost) -and ($f[14] -match '(?i)sqlcmd')) `
        "логин [$($f[12])] при ожидаемом [$holderLogin], узел [$($f[13])] при ожидаемом [$holderHost], программа [$($f[14])]"

    Write-Host 'Отпускаю блокировку и делаю второй проход'
    # Снимается ТОЛЬКО виновник, а жертва доводит свою транзакцию сама: ждать надо ВЫХОДА
    # жертвы, а не исчезновения её из очереди сервера - из очереди убирает и смерть, и
    # различить их по очереди нечем. Выход с кодом 0 и есть улика выдачи блокировки.
    Stop-Sqlcmd $blocker
    $waiterLeft = $waiter.WaitForExit((GrantWaitSeconds) * 1000)
    $waiterCode = if ($waiterLeft) { $waiter.ExitCode } else { -1 }
    Stop-Sqlcmd $waiter
    if (-not $waiterLeft) {
        Fail "жертва блокировки не дождалась за $(GrantWaitSeconds) с - опыт не удался, инструмент тут ни при чём"
    }
    if ($waiterCode -ne 0) {
        Fail "жертва вышла с кодом $waiterCode, а не по выдаче блокировки - опыт не удался, инструмент тут ни при чём"
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

    Write-Host 'Сцена вторая: спор за объект, имени которого разбор не понимает'
    # Сметаются ВСЕ мишени, а не две названные: прогон, умерший посреди опыта, оставляет
    # таблицу под своим именем, и следующий заход спорил бы за чужой объект.
    $sweep = Invoke-Sql "SELECT 'DROP TABLE [' + name + '];' FROM sys.tables WHERE name LIKE 'LW Probe%';"
    if ($sweep.Count -gt 0) { Invoke-Sql ($sweep -join ' ') | Out-Null }
    Invoke-Sql @"
CREATE TABLE $probeA ([Filler] int NOT NULL);
CREATE TABLE $probeB ([Filler] int NOT NULL);
"@ | Out-Null

    # Ждущий берёт объекты ПО ОЧЕРЕДИ и в ОДНОЙ транзакции. Жертва у эпизодов одна,
    # транзакция одна, род ресурса один и hobt у обоих ноль: ожидание объекта целиком его
    # не несёт вовсе. Различить их в журнале можно только именем.
    function New-ProbeHold([string]$name) {
        "SET LOCK_TIMEOUT -1`nBEGIN TRAN`nSELECT COUNT(*) FROM $name WITH (TABLOCKX)`nWAITFOR DELAY '00:05:00'`nROLLBACK`n"
    }
    # Захват держателя ждём ФАКТОМ, а не сном. Опоздавший держатель меняет опыт целиком:
    # ждущий берёт первый объект сам и встаёт за вторым, ожидания на первом не возникает.
    # Имя переводится в номер ЗАПРОСОМ К КАТАЛОГУ на каждом заходе, а не наоборот: обратный
    # перевод OBJECT_NAME(resource_associated_entity_id) падает переполнением на hobt.
    function Wait-ObjectHeld([string]$name) {
        $stop = (Get-Date).AddSeconds(30)
        while ((Get-Date) -lt $stop) {
            $held = Scalar @"
SELECT TOP 1 CONVERT(varchar(11),request_session_id) FROM sys.dm_tran_locks
WHERE resource_type = 'OBJECT' AND request_mode = 'X' AND request_status = 'GRANT'
  AND resource_associated_entity_id = OBJECT_ID(N'[$name]');
"@
            if ($held) { return $true }
            Start-Sleep -Milliseconds 300
        }
        return $false
    }
    # Ждём, пока ожидание появится в очереди СЕРВЕРА, и только потом идём проходом. Умерший
    # ждущий - сразу отказ: он уже ничего не дождётся, и досиживать до конца срока незачем.
    function Wait-ObjectQueue([string]$name) {
        $stop = (Get-Date).AddSeconds(60)
        while ((Get-Date) -lt $stop) {
            if ($probeWaiter.HasExited) { return $false }
            $seen = Scalar @"
SELECT TOP 1 CONVERT(varchar(11),l.request_session_id)
FROM sys.dm_tran_locks l
JOIN sys.dm_exec_sessions s ON s.session_id = l.request_session_id
WHERE l.resource_type = 'OBJECT' AND l.request_status = 'WAIT'
  AND s.host_process_id = $($probeWaiter.Id)
  AND l.resource_associated_entity_id = OBJECT_ID(N'[$name]');
"@
            if ($seen) { return $true }
            Start-Sleep -Milliseconds 400
        }
        return $false
    }
    # Отказ обязан говорить, ЧТО он видел: очередь сервера в этот миг - единственное, по
    # чему потом отличают "опыт не удался" от "инструмент не увидел".
    function Get-ProbeQueue() {
        $alive = 'жив'
        if ($probeWaiter.HasExited) { $alive = 'мёртв' }
        $lines = Invoke-Sql @"
SELECT CONVERT(varchar(11),wt.session_id) + ' (процесс ' +
       CONVERT(varchar(11),ISNULL(s.host_process_id,0)) + ') ждёт ' + wt.wait_type +
       ' [' + ISNULL(wt.resource_description,'') + ']'
FROM sys.dm_os_waiting_tasks wt
LEFT JOIN sys.dm_exec_sessions s ON s.session_id = wt.session_id
WHERE wt.wait_type LIKE 'LCK[_]%';
"@
        $queue = 'очередь сервера пуста'
        if ($lines.Count -gt 0) { $queue = ($lines | ForEach-Object { $_.Trim() }) -join '; ' }
        $cat = (Invoke-Sql "SELECT name + ' = ' + CONVERT(varchar(11),object_id) FROM sys.tables WHERE name LIKE 'LW Probe%';") -join '; '
        return "ждущий - процесс $($probeWaiter.Id), $alive. Каталог: $cat. Очередь: $queue"
    }

    $probeBoth = "SET LOCK_TIMEOUT -1`nBEGIN TRAN`nSELECT COUNT(*) FROM $probeA WITH (TABLOCKX)`nSELECT COUNT(*) FROM $probeB WITH (TABLOCKX)`nROLLBACK`n"
    $probeHoldA = Start-Sqlcmd 'probe-hold-a.sql' (New-ProbeHold $probeA)
    $probeHoldB = Start-Sqlcmd 'probe-hold-b.sql' (New-ProbeHold $probeB)
    if (-not (Wait-ObjectHeld $probeAName)) { Fail "первый объект держателем не взят - опыт не удался" }
    if (-not (Wait-ObjectHeld $probeBName)) { Fail "второй объект держателем не взят - опыт не удался" }
    $probeWaiter = Start-Sqlcmd 'probe-both.sql' $probeBoth

    if (-not (Wait-ObjectQueue $probeAName)) { Fail "ожидание на первом объекте в очередь не встало - опыт не удался. $(Get-ProbeQueue)" }
    Invoke-Pass 'проход по неопознанному объекту'

    $un = Scalar @"
SELECT TOP 1 [SQL Object Name] + '|' + [NAV Table Name] + '|' +
  CONVERT(varchar(11),[NAV Key No_]) + '|' + [Resource Kind]
FROM $episode WHERE [Resource Kind] = 'OBJECTLOCK' ORDER BY [Entry No_];
"@
    $u = @(($un -split '\|') | ForEach-Object { $_.Trim() })
    while ($u.Count -lt 4) { $u += '' }
    Check 'имя, которого разбор не понял, показано сырым' `
        (($u[0] -eq $probeAName) -and ($u[1] -eq '') -and ($u[2] -eq '-1')) `
        "сырое имя [$($u[0])], таблица NAV [$($u[1])], ключ $($u[2])"

    Write-Host '  отпускаю первый объект: ждущий берёт его и встаёт за вторым'
    Stop-Sqlcmd $probeHoldA
    if (-not (Wait-ObjectQueue $probeBName)) { Fail "ожидание на втором объекте в очередь не встало - опыт не удался. $(Get-ProbeQueue)" }
    Invoke-Pass 'второй проход по неопознанному объекту'

    $pair = Scalar @"
SELECT CONVERT(varchar(11),COUNT(*)) + '|' + CONVERT(varchar(11),COUNT(DISTINCT [SQL Object Name]))
FROM $episode WHERE [Resource Kind] = 'OBJECTLOCK';
"@
    $pr = @(($pair -split '\|') | ForEach-Object { $_.Trim() })
    while ($pr.Count -lt 2) { $pr += '' }
    # Имя тут не украшение, а РАЗДЕЛИТЕЛЬ: по остальным полям эпизоды неразличимы.
    Check 'эпизоды на разных объектах различимы: у каждого своё имя' `
        (($pr[0] -eq '2') -and ($pr[1] -eq '2')) `
        "эпизодов $($pr[0]), разных имён $($pr[1]) при ожидаемых 2 и 2"

    # Мишени второй сцены отпускаются здесь, а не в уборке: третья сцена меряет ЦЕПОЧКУ,
    # и чужие ожидания в очереди ей ни к чему.
    Stop-Sqlcmd $probeHoldB
    Stop-Sqlcmd $probeWaiter

    Write-Host 'Сцена третья: очередь в два колена - у кого спрашивать имя виновника'
    # Самое тонкое место всей дороги: в очереди A -> B -> C непосредственный виновник у C -
    # это B, но B сам стоит за A. Назвать соседа виновником - ошибка того же рода, что
    # обвинить пострадавшего, только правдоподобнее: имя настоящее, живого человека.
    #
    # Спорной строкой у каждого служит его же строка контекста - тем же приёмом, что и в
    # первой сцене. Так каждая сессия держит ровно одну выданную блокировку.
    Invoke-Sql @"
DELETE FROM $context WHERE [Table No_] BETWEEN -29 AND -20;
INSERT INTO $context ([Table No_],[Table Name],[Document Field No_],[Document Field Name],[Document Caption],[Enabled])
VALUES (-21,N'CHAIN-HEAD',0,N'',N'',0),
       (-22,N'CHAIN-MID',0,N'',N'',0),
       (-23,N'CHAIN-TAIL',0,N'',N'',0);
"@ | Out-Null

    # Номер сеанса спрашивается по номеру ПРОЦЕССА: процесс известен заранее, сеанс
    # пришлось бы угадывать. Умерший процесс - сразу ноль, а не досиживание срока.
    function Get-Spid($process) {
        $stop = (Get-Date).AddSeconds(60)
        while ((Get-Date) -lt $stop) {
            if ($process.HasExited) { return 0 }
            $id = Scalar "SELECT TOP 1 CONVERT(varchar(11),session_id) FROM sys.dm_exec_sessions WHERE host_process_id = $($process.Id);"
            if ($id) { return [int]$id }
            Start-Sleep -Milliseconds 300
        }
        return 0
    }
    # Захват ждём ФАКТОМ - выданной блокировкой рода KEY на таблице контекста. Опоздавшее
    # колено меняет опыт целиком: цепочка выходит короче, и красная проверка означала бы
    # "опыт не удался", а читалась бы как "инструмент спросил не у того".
    function Wait-ContextHeld([int]$spid) {
        $stop = (Get-Date).AddSeconds(60)
        while ((Get-Date) -lt $stop) {
            $held = Scalar @"
SELECT TOP 1 CONVERT(varchar(11),l.request_session_id)
FROM sys.dm_tran_locks l
JOIN sys.partitions p ON p.hobt_id = l.resource_associated_entity_id
WHERE l.resource_type = 'KEY' AND l.request_status = 'GRANT'
  AND l.request_session_id = $spid AND OBJECT_NAME(p.object_id) = N'$contextName';
"@
            if ($held) { return $true }
            Start-Sleep -Milliseconds 300
        }
        return $false
    }
    function Wait-BlockedBy([int]$spid, [int]$by) {
        $stop = (Get-Date).AddSeconds(60)
        while ((Get-Date) -lt $stop) {
            $seen = Scalar @"
SELECT TOP 1 CONVERT(varchar(11),wt.session_id) FROM sys.dm_os_waiting_tasks wt
WHERE wt.session_id = $spid AND wt.blocking_session_id = $by AND wt.wait_type LIKE 'LCK[_]%';
"@
            if ($seen) { return $true }
            Start-Sleep -Milliseconds 400
        }
        return $false
    }

    # Логин ставится КАЖДОМУ колену своё и ДО транзакции: проверка спрашивает логин
    # ГОЛОВЫ у виновника, и общее имя у всей очереди сделало бы её слепой - подмена
    # головы соседом прошла бы с тем же логином. Сцена первая на этом же и стоит.
    $chainA = "EXECUTE AS LOGIN = N'$holderLogin'`nSET LOCK_TIMEOUT -1`nBEGIN TRAN`nUPDATE $context SET [Table Name] = N'CHAIN-HEAD' WHERE [Table No_] = -21`nWAITFOR DELAY '00:05:00'`nROLLBACK`n"
    $chainB = "EXECUTE AS LOGIN = N'$middleLogin'`nSET LOCK_TIMEOUT -1`nBEGIN TRAN`nUPDATE $context SET [Table Name] = N'CHAIN-MID' WHERE [Table No_] = -22`nUPDATE $context SET [Table Name] = N'WANT-HEAD' WHERE [Table No_] = -21`nROLLBACK`n"
    $chainC = "EXECUTE AS LOGIN = N'$victimLogin'`nSET LOCK_TIMEOUT -1`nBEGIN TRAN`nUPDATE $context SET [Table Name] = N'CHAIN-TAIL' WHERE [Table No_] = -23`nUPDATE $context SET [Table Name] = N'WANT-MID' WHERE [Table No_] = -22`nROLLBACK`n"

    New-ProbeLogin $middleLogin

    $headProc = Start-Sqlcmd 'chain-head.sql' $chainA $holderHost
    $spidHead = Get-Spid $headProc
    if ($spidHead -eq 0) { Fail 'голова цепочки не подключилась - опыт не удался' }
    if (-not (Wait-ContextHeld $spidHead)) { Fail 'голова цепочки свою строку не взяла - опыт не удался' }

    $midProc = Start-Sqlcmd 'chain-mid.sql' $chainB $middleHost
    $spidMid = Get-Spid $midProc
    if ($spidMid -eq 0) { Fail 'среднее колено не подключилось - опыт не удался' }
    if (-not (Wait-ContextHeld $spidMid)) { Fail 'среднее колено свою строку не взяло - опыт не удался' }
    if (-not (Wait-BlockedBy $spidMid $spidHead)) { Fail 'среднее колено за голову не встало - опыт не удался' }

    $tailProc = Start-Sqlcmd 'chain-tail.sql' $chainC $victimHost
    $spidTail = Get-Spid $tailProc
    if ($spidTail -eq 0) { Fail 'хвост цепочки не подключился - опыт не удался' }
    if (-not (Wait-BlockedBy $spidTail $spidMid)) { Fail 'хвост цепочки за среднее колено не встал - опыт не удался' }
    Write-Host "  цепочка собрана: $spidTail ждёт $spidMid, $spidMid ждёт $spidHead"

    # Проходов до трёх: первый заход после открытия эпизода вполне может застать очередь в
    # промежуточном виде. Больше трёх ждать незачем - молчание после трёх и есть ответ.
    $tailRow = ''
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        Invoke-Pass "проход по цепочке, заход $attempt"
        $tailRow = Scalar @"
SELECT TOP 1 CONVERT(varchar(11),[Blocker SPID]) + '|' + [Blocker Login] + '|' + [Blocker Host] + '|' + [Victim User Name]
FROM $episode WHERE [Victim SPID] = $spidTail AND [Open] = 1 ORDER BY [Entry No_] DESC;
"@
        $tail = @(($tailRow -split '\|') | ForEach-Object { $_.Trim() })
        if (($tail.Count -ge 1) -and ($tail[0] -eq "$spidHead")) { break }
    }
    while ($tail.Count -lt 4) { $tail += '' }

    $midRow = Scalar @"
SELECT TOP 1 CONVERT(varchar(11),[Victim SPID]) + '|' + CONVERT(varchar(11),[Blocker SPID]) + '|' + [Blocker Login]
FROM $episode WHERE [Victim SPID] = $spidMid AND [Open] = 1 ORDER BY [Entry No_] DESC;
"@
    $mid = @(($midRow -split '\|') | ForEach-Object { $_.Trim() })
    while ($mid.Count -lt 3) { $mid += '' }

    # Сломано нарочно 09.09.2026 на прежней дороге - виновник спрошен у непосредственного
    # блокирующего вместо головы: имя пострадавшего в колонке виновника, и выглядит это
    # правдой. Поля головы в v2 подменяют блокирующего в самой строке, и проверка спрашивает
    # то же самое: голова - это A, а не сосед B.
    Check 'в очереди из двух колен виновник взят у ГОЛОВЫ, а не у соседа' `
        (($tail[0] -eq "$spidHead") -and ($tail[1] -eq $holderLogin) -and ($tail[2] -eq $holderHost)) `
        "виновник spid $($tail[0]) при ожидаемом $spidHead (сосед - $spidMid), логин [$($tail[1])], узел [$($tail[2])]"

    # Тот же сеанс в соседнем эпизоде стоит ДРУГОЙ стороной, и колонки обязаны это
    # различать: здесь он пострадавший, а виновник у него - та же голова.
    Check 'сосед по цепочке в своём эпизоде назван пострадавшим, а не виновником' `
        (($mid[0] -eq "$spidMid") -and ($mid[1] -eq "$spidHead") -and ($mid[2] -eq $holderLogin)) `
        "ждал spid $($mid[0]) при ожидаемом $spidMid, виновник spid $($mid[1]) при ожидаемом $spidHead, логин [$($mid[2])]"

    Write-Host 'Сцена четвёртая: спор за таблицу целиком - больше пяти тысяч строк одним оператором'
    foreach ($p in @($blocker, $waiter, $probeHoldA, $probeHoldB, $probeWaiter, $headProc, $midProc, $tailProc)) {
        Stop-Sqlcmd $p
    }
    # Ждём, пока с таблицы сойдут ЧУЖИЕ замки. Эскалация при них не случается вовсе:
    # сервер откладывает её и берёт строки по одной.
    $busy = 'x'
    $deadline = (Get-Date).AddSeconds(30)
    while (((Get-Date) -lt $deadline) -and $busy) {
        $busy = Scalar @"
SELECT TOP 1 CONVERT(varchar(11),l.request_session_id)
FROM sys.dm_tran_locks l
WHERE l.request_mode LIKE 'X%'
  AND l.resource_associated_entity_id IN (
        SELECT p.hobt_id FROM sys.partitions p WHERE p.object_id = OBJECT_ID(N'[$contextName]'));
"@
        if ($busy) { Start-Sleep -Milliseconds 500 }
    }
    Invoke-Sql @"
DELETE FROM $context WHERE [Table No_] BETWEEN $(BulkLowest) AND -1;
INSERT INTO $context ([Table No_],[Table Name],[Document Field No_],[Document Field Name],[Document Caption],[Enabled])
SELECT TOP $(BulkRows) -($(BulkBase) + ROW_NUMBER() OVER (ORDER BY (SELECT NULL))), N'LW Fixture', 0, N'', N'', 0
FROM sys.all_columns;
"@ | Out-Null
    # Замок на объект берётся ХИНТОМ, а не расчётом на эскалацию, и на это есть замер.
    # Эскалация на стенде не сработала и на шести тысячах строк: 04.11.2026 держатель
    # прошёл оператор и держал строки все две минуты, а замка на объекте сервер так и не
    # завёл - опыт краснел там, где его устроил сам выбор средства. Проверяет же он не
    # политику сервера, а разбор: в dm_tran_locks явный замок на объект неотличим от
    # эскалированного, и ждущий встаёт в очередь так же.
    #
    # Пачка остаётся в шесть тысяч строк: спор идёт за таблицу, к которой один оператор
    # прикоснулся целиком, и тяжесть оператора - часть сцены.
    $bulkHold = "SET LOCK_TIMEOUT -1`nBEGIN TRAN`nUPDATE $context WITH (TABLOCKX) SET [Table Name] = N'BULK-HELD' WHERE [Table No_] BETWEEN -7000 AND -1001`nWAITFOR DELAY '00:02:00'`nROLLBACK`n"
    $bulkProc = Start-Sqlcmd 'lock-bulk-hold.sql' $bulkHold
    # Ждём ФАКТА, а не спим: замок на объекте виден в dm_tran_locks, и он же отличает
    # "сервер перевёл замки на таблицу" от "оператор ещё идёт по строкам".
    $tableLock = ''
    $deadline = (Get-Date).AddSeconds(60)
    while ((Get-Date) -lt $deadline) {
        $tableLock = Scalar @"
SELECT TOP 1 CONVERT(varchar(11),l.request_session_id)
FROM sys.dm_tran_locks l
WHERE l.resource_type = 'OBJECT' AND l.resource_associated_entity_id = OBJECT_ID(N'[$contextName]')
  AND l.request_status = 'GRANT' AND l.request_mode LIKE 'X%';
"@
        if ($tableLock) { break }
        Start-Sleep -Milliseconds 500
    }
    if (-not $tableLock) {
        # Снимок держателя - не проверка, а диагностика: без него отказ "замка нет" не
        # отличить от "оператор ещё идёт по строкам" и от "сервер не стал эскалировать".
        # Три ответа разом: сколько строк в пачке, какие замки держит сеанс и чего он ждёт.
        # NOLOCK обязателен: держатель ещё может сидеть на строках, и обычный счёт
        # встал бы в его очередь, отложив сам отказ на минуты.
        $bulkCount = Scalar "SELECT CONVERT(varchar(11),COUNT(*)) FROM $context WITH (NOLOCK) WHERE [Table No_] BETWEEN -7000 AND -1001;"
        $holderSid = Scalar "SELECT CONVERT(varchar(11),session_id) FROM sys.dm_exec_sessions WHERE host_process_id = $($bulkProc.Id);"
        $holderLocks = 'сеанса нет'
        $holderWait = 'ничего'
        if ($holderSid) {
            $holderLocks = @(Invoke-Sql @"
SELECT l.resource_type + ':' + l.request_mode + ':' + l.request_status + ' x' + CONVERT(varchar(11),COUNT(*))
FROM sys.dm_tran_locks l WHERE l.request_session_id = $holderSid
GROUP BY l.resource_type, l.request_mode, l.request_status;
"@) -join '; '
            if (-not $holderLocks) { $holderLocks = 'замков нет' }
            $holderWait = Scalar "SELECT wait_type + ' за ' + CONVERT(varchar(11),blocking_session_id) FROM sys.dm_os_waiting_tasks WHERE session_id = $holderSid;"
            if (-not $holderWait) { $holderWait = 'ничего' }
        }
        $escalation = Scalar "SELECT lock_escalation_desc FROM sys.tables WHERE object_id = OBJECT_ID(N'[$contextName]');"
        Fail ("замок на таблицу целиком так и не встал за 60 с - опыт не состоялся: строк в пачке " +
              "$bulkCount из $(BulkRows), держатель $(if ($bulkProc.HasExited) { "вышел с кодом $($bulkProc.ExitCode)" } else { 'ещё идёт' }), " +
              "эскалация $escalation, замки держателя [$holderLocks], ждёт [$holderWait]")
    }
    $bulkWant = "SET LOCK_TIMEOUT -1`nBEGIN TRAN`nUPDATE $context SET [Table Name] = N'BULK-WANT' WHERE [Table No_] = -1001`nROLLBACK`n"
    $bulkWaiter = Start-Sqlcmd 'lock-bulk-want.sql' $bulkWant
    $bulkWait = ''
    $deadline = (Get-Date).AddSeconds(40)
    while ((Get-Date) -lt $deadline) {
        $bulkWait = Scalar @"
SELECT TOP 1 CONVERT(varchar(11),wt.session_id)
FROM sys.dm_os_waiting_tasks wt
JOIN sys.dm_exec_sessions s ON s.session_id = wt.session_id
WHERE wt.wait_type LIKE 'LCK[_]%' AND s.host_process_id = $($bulkWaiter.Id);
"@
        if ($bulkWait) { break }
        Start-Sleep -Milliseconds 500
    }
    if (-not $bulkWait) {
        Fail ("ждущий за таблицей в очередь не встал - опыт не состоялся: замок держит сеанс " +
              "$tableLock, ждущий $(if ($bulkWaiter.HasExited) { "вышел с кодом $($bulkWaiter.ExitCode)" } else { 'ещё идёт' })")
    }
    Start-Sleep -Seconds 2
    Invoke-Pass 'проход по спору за таблицу'
    $bulkRow = Scalar @"
SELECT TOP 1 [Resource Kind] + '|' + [NAV Table Name] + '|' + CONVERT(varchar(11),[NAV Key No_])
FROM $episode WHERE [Victim SPID] = $bulkWait ORDER BY [Entry No_] DESC;
"@
    $b = @(($bulkRow -split '\|') | ForEach-Object { $_.Trim() })
    while ($b.Count -lt 3) { $b += '' }
    Stop-Sqlcmd $bulkWaiter
    Stop-Sqlcmd $bulkProc
    # Спор за таблицу обязан быть записан родом OBJECTLOCK и с именем таблицы: сырой род
    # OBJECT без имени читается как "не разобрано" и не отвечает на вопрос "за что".
    Check 'спор за таблицу целиком записан родом OBJECTLOCK и с именем таблицы' `
        (($b[0] -eq 'OBJECTLOCK') -and ($b[1] -eq 'LockWatch Context Table')) `
        "род [$($b[0])] при ожидаемом OBJECTLOCK, таблица [$($b[1])], ключ $($b[2])"
}
finally {
    Stop-Sqlcmd $blocker
    Stop-Sqlcmd $waiter
    Stop-Sqlcmd $probeHoldA
    Stop-Sqlcmd $probeHoldB
    Stop-Sqlcmd $probeWaiter
    Stop-Sqlcmd $headProc
    Stop-Sqlcmd $midProc
    Stop-Sqlcmd $tailProc
    Stop-Sqlcmd $bulkProc
    Stop-Sqlcmd $bulkWaiter
    # Убираем за собой И строки-мишени, И эпизоды. Оставленный эпизод - не мусор, а помеха:
    # мерный прогон журнала отказывается работать по непустому журналу, и следующий прогон
    # упал бы с виду беспричинно. Оставить его можно нарочно, ключом -KeepJournal.
    $cleanup = "DELETE FROM $context WHERE [Table No_] BETWEEN $(BulkLowest) AND -1;"
    # Признаки возвращаются ТЕМИ, какими их нашли: у установки свои значения этих полей, и
    # заводские числа здесь стирали бы её настройку под видом уборки за собой.
    if ($wasDeadlocks)  { $cleanup += " UPDATE $setup SET [Deadlocks Enabled] = $wasDeadlocks;" }
    if ($wasStatements) { $cleanup += " UPDATE $setup SET [Collect Statement Values] = $wasStatements;" }
    if ($wasMinWait)    { $cleanup += " UPDATE $setup SET [Journal Min Wait (ms)] = $wasMinWait;" }
    if ($wasDocuments)  { $cleanup += " UPDATE $setup SET [Documents per Pass] = $wasDocuments;" }
    if ($wasPlatform)   { $cleanup += " UPDATE $setup SET [Platform Names Enabled] = $wasPlatform;" }
    if (-not $KeepJournal) { $cleanup += " DELETE FROM $episode;" }
    # Уборка сметает мишени по образцу имени, а не по двум именам: имя мишени может
    # смениться, а забытая таблица переживёт прогон и запутает следующий.
    $cleanup += " DECLARE @drop nvarchar(max) = N'';"
    $cleanup += " SELECT @drop = @drop + N'DROP TABLE [' + name + N'];' FROM sys.tables WHERE name LIKE 'LW Probe%';"
    # Тем же образцом имени сметаются и опытные логины, и сметаются они В ПОРЯДКЕ: сперва
    # пользователь базы, потом сам логин - иначе сервер не отдаст логин, у которого есть
    # пользователь. Забытый логин переживёт не прогон, а всю установку.
    $cleanup += " SELECT @drop = @drop + N'DROP USER [' + name + N'];' FROM sys.database_principals WHERE name LIKE 'LW Probe%' AND type = 'S';"
    $cleanup += " SELECT @drop = @drop + N'DROP LOGIN [' + name + N'];' FROM sys.server_principals WHERE name LIKE 'LW Probe%' AND type = 'S';"
    $cleanup += " IF @drop <> N'' EXEC sp_executesql @drop;"
    # Уборка судится по ФАКТУ, а не по намерению, и ключ -b здесь обязателен: без него
    # sqlcmd вернёт НОЛЬ и на ошибке, и провалившаяся уборка выглядела бы сделанной.
    $cleanupSaid = & sqlcmd -S $Server -d $Database -E -b -l 30 -t (QueryTimeoutSeconds) -h -1 -W -Q $cleanup 2>&1
    if ($LASTEXITCODE -ne 0) {
        $cleanupFail += "уборка отказала: sqlcmd вернул $LASTEXITCODE, $(($cleanupSaid -join ' ').Trim())"
    }
    $leftTables = [int](Scalar "SELECT COUNT(*) FROM sys.tables WHERE name LIKE 'LW Probe%';")
    $leftLogins = [int](Scalar "SELECT COUNT(*) FROM sys.server_principals WHERE name LIKE 'LW Probe%' AND type = 'S';")
    $leftRows   = [int](Scalar "SELECT COUNT(*) FROM $context WHERE [Table No_] BETWEEN $(BulkLowest) AND -1;")
    if ($leftTables -gt 0) { $cleanupFail += "таблиц опыта осталось $leftTables" }
    if ($leftLogins -gt 0) { $cleanupFail += "опытных логинов осталось $leftLogins - это чужак в списке безопасности сервера" }
    if ($leftRows   -gt 0) { $cleanupFail += "строк контекста опыта осталось $leftRows" }
    # Настройка спрашивается тем же счётом: возвращённая "почти" - это не возвращённая.
    # Сверяется она, только если была ПРОЧИТАНА: пустая находка - это не ноль, а нечитанная
    # строка, и сравнивать с ней нечего.
    if ($setupRead) {
        $backWas = "$wasDeadlocks|$wasStatements|$wasMinWait|$wasDocuments|$wasPlatform"
        $backNow = Scalar @"
SELECT ISNULL(CONVERT(varchar(2),[Deadlocks Enabled]),'') + '|' +
       ISNULL(CONVERT(varchar(2),[Collect Statement Values]),'') + '|' +
       ISNULL(CONVERT(varchar(11),[Journal Min Wait (ms)]),'') + '|' +
       ISNULL(CONVERT(varchar(11),[Documents per Pass]),'') + '|' +
       ISNULL(CONVERT(varchar(2),[Platform Names Enabled]),'')
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
if ($passed -lt $total) { Fail 'проверка на живой блокировке не пройдена' }
# Уборка - часть прогона, а не вежливость в конце: оставленный логин опыта увидит не этот
# прогон, а тот, кто придёт на стенд после, и разбирать его будет некому.
if ($cleanupFail) { Fail ("уборка за собой не обошлась:`n  " + ($cleanupFail -join "`n  ")) }
Write-Host 'Готово: проход проверен на настоящей блокировке' -ForegroundColor Green
