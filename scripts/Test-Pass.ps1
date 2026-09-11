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

    Сцен три. Первая - спор за СТРОКУ, с именем таблицы, ключом, документом и ОБОИМИ
    людьми: у виновника и у жертвы свои отметки, свои учётные записи NAV, свои логины SQL
    и свои узлы, и перепутанные местами колонки красят проверку сразу. Вторая - спор за
    ОБЪЕКТ, имя которого разбор не понимает: каталог SQL отвечает не только про таблицы
    NAV, и такое имя обязано доехать до журнала сырым и с пометкой "не опознано", а не
    потеряться молча.
    Третья - очередь в ДВА КОЛЕНА: имя виновника обязано прийти из отметки ГОЛОВЫ, а не
    соседа, который сам стоит в очереди.

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
    [switch] $ContextRoad,
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
$setup   = "[$Company`$LockWatch Setup]"
$state   = "[$Company`$LockWatch Watchdog]"
$mark    = "[$Company`$LockWatch Context Mark]"
$coverage = "[$Company`$LockWatch Coverage]"
$alert    = "[$Company`$LockWatch Alert]"
$alertSource = 'LockWatch'
$alertThresholdMs = 1000
# Сколько позволено разойтись отметке начала транзакции с часами сервера. Транзакция
# держателя открыта секунды назад, и минуты хватает с избытком; ошибка же в часовой пояс
# даёт часы, и такой запас её не спрячет.
function ClockSlackSeconds { 120 }
# Пустая дата NAV в SQL. Ни NULL, ни ноль: столбец NOT NULL, а нулю отвечает 1900 год.
$blankDate = "CONVERT(datetime,'17530101')"
$service = "MicrosoftDynamicsNavServer`$$Instance"
# Мишени второй сцены. Имя, которого разбор не понимает, нужно НАСТОЯЩЕЕ, и брать его у
# платформы нельзя: своих таблиц $ndo$ у неё на базу около дюжины, но их читает сама служба,
# и запертая на десяток секунд таблица планировщика уронила бы сеанс, а не проверила
# инструмент. Поэтому имена свои, заведомо ничьи, и ломают они то же правило вторым
# способом: после $VSIFT$ стоит не число (FINDINGS, раздел 5). Обе пусты и уходят в уборке.
#
# Слова LockWatch в имени нет НАРОЧНО: снятие считает след по нему («таблиц SQL не
# осталось»), и мишень, пережившая упавший прогон, покрасила бы чужую проверку.
# Имя РАЗОВОЕ, своё у каждого захода, и это не осторожность, а лечение измеренной беды.
# Повторное имя вытаскивает из кэша планов номер ПРЕЖНЕГО объекта - того, что удалён
# смёткой в начале сцены. Замер 09.09.2026, два захода подряд: каталог называет новый номер
# 1899362031, а держатель держит блокировки на ОБОИХ - и на новом, и на призраке 1867361917;
# ждущий встаёт в очередь за призраком, потому что до него добирается первым. Ожидание при
# этом настоящее, только не за тем объектом, и отказ выглядит как "инструмент не увидел".
# Разовое имя убирает и повторное использование плана, и повторное использование номера.
$probeTag   = "$PID-$((Get-Date).ToString('HHmmss'))"
$probeAName = "LW Probe`$VSIFT`$A$probeTag"
$probeBName = "LW Probe`$VSIFT`$B$probeTag"
$probeA = "[$probeAName]"
$probeB = "[$probeBName]"
# Имя таблицы отметок без скобок: им спрашивается каталог, а туда имя едет значением.
$markName = "$Company`$LockWatch Context Mark"
# Учётные записи опыта. Их три, и они разные НАРОЧНО. Весь вопрос "кто кого" в том, что
# людей двое; опыт, где обе стороны ходят под одним именем, пропустит подмену виновника
# жертвой молча - имя совпадёт при любой ошибке, и красить будет нечему. Ловилось на
# прогоне дороги к имени: там обе сессии NAV идут под учётной записью запускающего, и
# написано об этом прямо в его же заголовке.
$holderUser = 'STAND-HOLDER'
$victimUser = 'STAND-VICTIM'
$middleUser = 'STAND-MIDDLE'
# Имена рабочих станций. Их sqlcmd называет ключом -H, и без них проверка "сервер назвал
# узел" проходит и на перепутанных местами колонках.
$holderHost = 'LW-HOLDER'
$victimHost = 'LW-VICTIM'
$middleHost = 'LW-MIDDLE'
# Логины сторон спора. Прежде логин у всех своих соединений был ОДИН - учётная запись, под
# которой идёт прогон, - и колонку "кто держит" проверять было нечем, кроме непустоты. А в
# бою по этой колонке называют виновника, когда он не сессия NAV: у чужого соединения нет
# ни отметки контекста, ни учётной записи NAV, и логин - единственное имя, какое есть.
#
# Подключиться логином SQL нельзя: смешанный режим проверки подлинности на стенде выключен
# (SERVERPROPERTY('IsIntegratedSecurityOnly') = 1). Поэтому соединение остаётся своим, а в
# чужой логин сессия входит через EXECUTE AS - он подменяет ровно ту колонку, которую
# читает инструмент: sys.dm_exec_sessions.login_name. Замер 10.09.2026: внутри EXECUTE AS
# login_name - имя опытного логина, а original_login_name остаётся прежним.
$holderLogin = 'LW Probe Holder'
$victimLogin = 'LW Probe Waiter'

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
# Запрос уезжает ФАЙЛОМ, а не параметром -Q. Start-Process склеивает элементы -ArgumentList
# пробелом и кавычек вокруг них не ставит: запрос с пробелами рассыпается на аргументы,
# sqlcmd молча выходит с ошибкой, а выглядит это как "блокировка не случилась".
function Start-Sqlcmd([string]$name, [string]$sql, [string]$workstation = '') {
    $file = Join-Path $outDir $name
    [IO.File]::WriteAllText($file, (($sql -replace "`r`n", "`n") -replace "`n", "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
    # Ключ -H кладёт имя рабочей станции в host_name сеанса. Это единственное, чем два
    # своих соединения отличаются друг от друга на сервере: логин и программа у них общие.
    $sqlArgs = @('-S', $Server, '-d', $Database, '-E', '-b', '-l', '30', '-i', $file)
    if ($workstation) { $sqlArgs += @('-H', $workstation) }
    Start-Process -FilePath 'sqlcmd' -PassThru -WindowStyle Hidden -ArgumentList $sqlArgs
}
# Логин заводится прогоном и им же убирается: оставленный на стенде опытный логин - это
# чужая учётная запись в списке безопасности сервера, которую никто не заказывал.
function New-ProbeLogin([string]$login) {
    # Пароль случайный и никуда не записывается. Войти этим логином всё равно нельзя -
    # смешанный режим выключен, - но синтаксис CREATE LOGIN пароля требует.
    # Права даются РОВНО на строку-мишень: под этим логином идёт спор за неё, и ничего
    # другого опытной учётной записи знать не положено.
    $password = [Guid]::NewGuid().ToString('N') + 'Aa1!'
    Invoke-Sql @"
IF SUSER_ID(N'$login') IS NULL CREATE LOGIN [$login] WITH PASSWORD = '$password', CHECK_POLICY = OFF;
IF DATABASE_PRINCIPAL_ID(N'$login') IS NULL CREATE USER [$login] FOR LOGIN [$login];
GRANT SELECT, UPDATE ON $mark TO [$login];
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
    # Сбор взаимоблокировок на время опыта выключается. Он берёт графы из КОЛЬЦЕВОГО
    # БУФЕРА сервера, а туда они попадают от кого угодно и когда угодно - хоть от прошлого
    # прогона, хоть от чужой работы на той же базе. Строка в журнале получилась бы законной,
    # но проверка "эпизод заведён ровно один" считает строки, и опыт судил бы инструмент по
    # чужим кругам. Две дороги - два прогона, и каждый отвечает только за свою.
    # Текст запроса снимается только при включённом признаке, и признак этот по умолчанию
    # выключен: в операторе едут ЗНАЧЕНИЯ, а это решение заказчика, а не наше умолчание.
    # Прогон включает его сам и возвращает как было.
    Invoke-Sql "UPDATE $setup SET [SQL Server] = N'$Server', [Deadlocks Enabled] = 0, [Collect Statement Values] = 1; UPDATE $state SET [Watchdog Message] = N'';" | Out-Null
    # Накопительный слой, наоборот, чистится и остаётся ВКЛЮЧЁННЫМ: без чистки проверка
    # прошла бы на строках прошлого прогона, то есть не проверяла бы ничего.
    Invoke-Sql "DELETE FROM $coverage; UPDATE $setup SET [Coverage Enabled] = 1; UPDATE $state SET [Coverage Since] = $blankDate;" | Out-Null
    # Тревога включается НАРУЖУ и с низким порогом: опыт держит блокировку около пяти
    # секунд, и порог по умолчанию она перевалила бы на самой границе. Проверка, стоящая
    # на границе, проверяет часы, а не тревогу.
    Invoke-Sql @"
DELETE FROM $alert;
UPDATE $setup SET [Alert Channel] = 2, [Alert Threshold (ms)] = $alertThresholdMs, [Alert Event Source] = N'$alertSource';
"@ | Out-Null
    $alertSince = Get-Date
    if (-not $KeepJournal) { Invoke-Sql "DELETE FROM $episode;" | Out-Null }
    # Дорога по хэшу самой блокировки включается ДО перезапуска службы: список таблиц
    # контекста служба держит в кэше, и строка, вставленная запросом при работающей службе,
    # до сессии не дойдёт - разбор просто не увидит её и промолчит.
    Invoke-Sql "DELETE FROM $context WHERE [Table No_] = 110233;" | Out-Null
    if ($ContextRoad) {
        Invoke-Sql @"
INSERT INTO $context ([Table No_],[Table Name],[Document Field No_],[Document Field Name],[Document Caption],[Enabled])
VALUES (110233,N'LockWatch Context Mark',13,N'Document No.',N'Отметка контекста',1);
"@ | Out-Null
    }
    # Отметки ДВЕ, и учётные записи в них разные. Отметка жертвы - не украшение опыта: имя
    # ждущего инструмент берёт из ЕЁ отметки, найденной по её же ВЫДАННОЙ блокировке, а не
    # из отметки виновника. Пока отметка была одна, дорога к имени жертвы на живой
    # блокировке не проверялась вовсе, а перепутанные местами колонки прошли бы молча.
    # Документ у жертвы свой и заведомо чужой спору: если он окажется в журнале, значит из
    # отметки жертвы взято лишнее.
    Invoke-Sql @"
DELETE FROM $mark WHERE [Server Instance Id] BETWEEN -29 AND -1;
INSERT INTO $mark ([Server Instance Id],[Session Id],[User Id],[Company Name],[Table No_],[Document No_],[Marked At])
VALUES (-1,-1,N'$holderUser',N'$Company',0,N'LOCK-TARGET',GETUTCDATE()),
       (-2,-2,N'$victimUser',N'$Company',0,N'VICTIM-DOC',GETUTCDATE());
"@ | Out-Null

    Write-Host "  перезапускаю службу $Instance и жду ответа порта управления"
    Restart-Service $service -Force
    & $ps51 -NoProfile -ExecutionPolicy Bypass -File $probeFile | Out-Null
    if ($LASTEXITCODE -ne 0) { Fail "экземпляр $Instance не ответил по порту управления" }

    Write-Host 'Устраиваю блокировку - стороны под РАЗНЫМИ логинами'
    New-ProbeLogin $holderLogin
    New-ProbeLogin $victimLogin
    # EXECUTE AS стоит ПЕРВЫМ и до открытия транзакции: сессия должна встать в очередь уже
    # под своим логином, иначе сервер назовёт в очереди прежнюю учётную запись.
    $hold = "EXECUTE AS LOGIN = N'$holderLogin'`nSET LOCK_TIMEOUT -1`nBEGIN TRAN`nUPDATE $mark SET [Document No_] = N'HELD' WHERE [Server Instance Id] = -1`nWAITFOR DELAY '00:05:00'`nROLLBACK`n"
    # Жертва правит СВОЮ отметку и только после этого встаёт в очередь за чужой строкой.
    # Порядок обязателен: без выданной блокировки на своей отметке искать её имя не по чему.
    $want = "EXECUTE AS LOGIN = N'$victimLogin'`nSET LOCK_TIMEOUT -1`nBEGIN TRAN`nUPDATE $mark SET [Document No_] = N'VICTIM-DOC' WHERE [Server Instance Id] = -2`nUPDATE $mark SET [Document No_] = N'WANT' WHERE [Server Instance Id] = -1`nROLLBACK`n"
    $blocker = Start-Sqlcmd 'lock-hold.sql' $hold $holderHost
    Start-Sleep -Seconds 2
    $waiter = Start-Sqlcmd 'lock-want.sql' $want $victimHost

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

    $watchdog = Scalar "SELECT [Watchdog Message] FROM $state;"
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
  CONVERT(varchar(11),[Max Wait (ms)]) + '|' + [Wait Type] + '|' +
  [Document No_] + '|' + CONVERT(varchar(11),[Document Source]) + '|' +
  [User Name] + '|' + CONVERT(varchar(11),[User Source]) + '|' + [No Document Reason] + '|' +
  [Blocker Login] + '|' + [Blocker Host] + '|' + [Blocker Program] + '|' +
  [Victim Login] + '|' + [Victim Program] + '|' +
  [Victim User Name] + '|' + [Victim Host]
FROM $episode ORDER BY [Entry No_] DESC;
"@
    if (-not $row) { Fail 'в журнале пусто - дальше проверять нечего' }
    $f = ($row -split '\|') | ForEach-Object { $_.Trim() }
    if ($f.Count -lt 26) { Fail "строка журнала пришла неполной: $($f.Count) колонок" }

    Check 'жертва и виновник те самые' ((([int]$f[0]) -eq $waiterSpid) -and (([int]$f[2]) -eq $blockerSpid)) `
        "жертва $($f[0]) при ожидаемой $waiterSpid, виновник $($f[2]) при ожидаемом $blockerSpid"
    Check 'ресурс разобран, а не показан сырым' (($f[5] -eq 'KEYLOCK') -and ($f[6] -ne '0') -and ($f[9] -eq '0')) `
        "род [$($f[5])], hobt $($f[6]), не опознан $($f[9]), чего ждёт [$($f[13])]"
    Check 'имя таблицы и номер ключа сняты с SQL' (($f[8] -eq 'LockWatch Context Mark') -and ($f[7] -eq '0')) `
        "таблица [$($f[8])], ключ NAV $($f[7])"
    Check 'цепочка размотана до головы' ((([int]$f[1]) -eq $blockerSpid) -and ($f[3] -eq '1') -and ($f[4] -eq '1')) `
        "голова $($f[1]), глубина $($f[3]), жертв за головой $($f[4])"
    Check 'чужая сессия названа чужой' ($f[10] -eq '2') "признак сессии NAV $($f[10]) при ожидаемом 2 (нет)"

    # Текст запроса. Проверка СОСТЯЗАТЕЛЬНАЯ: виновник пишет в строку HELD, жертва - WANT,
    # и перепутанные местами колонки провалят обе проверки разом. Проверка "текст непустой"
    # прошла бы и на тексте не того сеанса, а чужой запрос выглядит так же убедительно,
    # как свой, и опровергнуть его читателю нечем.
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
    # У жертвы значения искать бессмысленно, и это не мелочь, а свойство дороги: её запрос
    # берётся из КЭША ПЛАНОВ и приходит параметризованным - "set [Document No_] = @1".
    # Виновников берётся из его соединения сырым батчем, со всеми литералами. Поэтому
    # состязательность здесь другая: у жертвы обязан быть UPDATE и не быть WAITFOR, который
    # есть только в батче виновника.
    Check 'запрос жертвы лёг в журнал, и это ЕЁ запрос' `
        (($q[4] -eq '1') -and ($q[5] -eq '0') -and ([int]$q[1] -gt 0)) `
        "байтов $($q[1]), UPDATE внутри $($q[4]), WAITFOR внутри $($q[5])"
    # Колонка списка обязана что-то показывать: иначе за каждым запросом придётся лезть
    # в отдельное окно, а список перестаёт отвечать на вопрос "чем они все заняты".
    Check 'начало запроса видно в списке, одной строкой' `
        (($q[6] -ne '') -and ($q[6] -notmatch "[`r`n]")) `
        "в колонке [$($q[6])]"
    # Имя названо по тому, что спрашивается: "не нулевая", а не "растёт". Проход здесь ОДИН,
    # и роста по одному наблюдению не видно - видно только, что длительность вообще снята.
    # Что она ПРИРАСТАЕТ при следующем наблюдении того же эпизода, спрашивает мерный прогон
    # журнала: там два прохода подряд, и сводка сверяет "Max Wait (ms)" со вторым значением.
    Check 'эпизод открыт, и длительность у него не нулевая' (($f[11] -eq '1') -and (([int]$f[12]) -gt 0)) `
        "открыт $($f[11]), длительность $($f[12]) мс"

    # Виновник держит блокировку на строке отметки контекста и своим же UPDATE поставил
    # ей номер документа. Мост обязан пройти: транзакция -> её блокировка -> хэш ключа ->
    # обратный поиск -> строка -> документ и учётная запись. Ни одного нового права.
    # Дорог к документу две, и различает их не значение, а ИСТОЧНИК. Значение здесь у обеих
    # одно и то же нарочно: спорная строка и есть отметка контекста, поэтому проверка ловит
    # именно ту дорогу, которую включили, а не совпадение ответов.
    if ($ContextRoad) { $wantSource = '1'; $wantRoad = 'по хэшу блокировки' } else { $wantSource = '2'; $wantRoad = 'по отметке' }
    Check "документ назван, дорога $wantRoad" (($f[14] -eq 'HELD') -and ($f[15] -eq $wantSource)) `
        "документ [$($f[14])], откуда $($f[15]) при ожидаемом $wantSource, причина [$($f[18])]"
    # Имя виновника здесь известно при ОБЕИХ дорогах, и ветки на это больше нет. Спорная
    # строка в этом опыте и есть отметка контекста, а отметку кладёт сам виновник в своей
    # транзакции: имя берётся из неё независимо от того, какая дорога назвала документ.
    # Так и задумано - другой дороги к имени у инструмента нет вовсе.
    #
    # Проверку "имя не выдумывается там, где его никто не называл" этот опыт поставить не
    # может по своему устройству: для неё нужна спорная строка НЕ из таблицы отметок. Она
    # стоит в Test-Document.ps1, где спорят за строку настоящей таблицы установки.
    Check 'виновник назван по имени, без права платформы' (($f[16] -eq $holderUser) -and ($f[17] -eq '1')) `
        "учётная запись [$($f[16])] при ожидаемой [$holderUser], откуда $($f[17]) при ожидаемом 1 (по отметке)"

    # Вторая половина ответа на "кто кого", и до сих пор её на живой блокировке не
    # проверяло ничто. Имя ждущего берётся из ЕГО отметки, найденной по его же выданной
    # блокировке; имя виновника - из отметки головы. Отметки лежат рядом, и перепутать их
    # дороже, чем не найти ни одной: обвинён будет живой человек, и обвинён убедительно.
    # Проверка состязательная: учётные записи у сторон разные, и перестановка колонок
    # местами красит её сразу. На прежнем опыте (одна отметка на обоих) жертва оставалась
    # без имени вовсе. Сломано нарочно 09.09.2026 - отметка жертвы спрошена у ГОЛОВЫ, - и
    # даёт "кто ждал [STAND-HOLDER] при ожидаемом [STAND-VICTIM]": имя настоящее, живого
    # человека, и по виду журнала подмену не отличить.
    Check 'жертва названа СВОЕЙ отметкой, а не отметкой виновника' `
        (($f[24] -eq $victimUser) -and ($f[24] -ne $f[16])) `
        "кто ждал [$($f[24])] при ожидаемом [$victimUser], виновник [$($f[16])]"

    # Второй ответ на "кто", и он о ДРУГОМ. Учётную запись NAV даёт отметка, а её кладёт
    # только сессия NAV; за чужим соединением - утилитой, заданием, чьим-то окном запросов -
    # никакой учётной записи NAV нет и быть не может. Сервер же знает о держателе логин,
    # узел и программу с самого начала: соединение с sys.dm_exec_sessions ради него уже
    # сделано, и молчать было нечем оправдаться. Здесь держит sqlcmd, и он себя называет.
    # На прежнем коде: этих трёх полей не было вовсе, столбец "кто" у чужого держателя
    # оставался пустым, и пустота читалась как "инструмент не знает".
    # Логин и узел сверяются ПО ИМЕНИ, а не на непустоту. Пока стороны ходили под одним
    # логином, проверять его было нечем: непустота проходит и на перепутанных колонках -
    # логин-то есть у обоих, и он у обоих ОДИН И ТОТ ЖЕ. Теперь у каждой стороны свой.
    #
    # Сломано нарочно 10.09.2026 - bs.login_name и vs.login_name переставлены местами в
    # запросе очереди: 23 из 25, красные обе эти проверки. На прежнем условии перестановка
    # прошла бы молча: обе колонки были непусты и обе содержали одно и то же имя.
    Check 'сервер назвал держателя: логин, узел, программа' `
        (($f[19] -eq $holderLogin) -and ($f[20] -eq $holderHost) -and ($f[21] -match '(?i)sqlcmd')) `
        "логин [$($f[19])] при ожидаемом [$holderLogin], узел [$($f[20])] при ожидаемом [$holderHost], программа [$($f[21])]"

    # И жертву - тем же способом. Соединение с её сеансом в запросе очереди стоит ПЕРВЫМ:
    # им уже берутся узел, процесс и программа, и логин из той же строки не стоит ничего.
    # Без него жертва была названа хуже виновника: у того три ответа, у неё был один узел,
    # а вопрос "кто ждал" задают ровно так же часто. Учётная запись NAV рядом - из отметки
    # контекста, и её нет у чужого соединения; логин есть ВСЕГДА.
    # На прежнем коде: этих двух полей не было вовсе.
    # Логины сторон сверяются и МЕЖДУ СОБОЙ. Равенство каждого своему имени уже красит
    # перестановку колонок, но условие "они разные" стоит рядом нарочно: оно краснеет и
    # тогда, когда логин на обе колонки приедет один - а именно так выглядит инструмент,
    # читающий не ту колонку сессии (original_login_name вместо login_name) или берущий
    # обе стороны из одной строки очереди.
    Check 'сервер назвал и жертву: логин, узел и программа' `
        (($f[22] -eq $victimLogin) -and ($f[22] -ne $f[19]) -and
         ($f[25] -eq $victimHost) -and ($f[23] -match '(?i)sqlcmd')) `
        "логин жертвы [$($f[22])] при ожидаемом [$victimLogin], логин виновника [$($f[19])], узел [$($f[25])] при ожидаемом [$victimHost], программа [$($f[23])]"

    # Момент начала транзакции виновника приходит с часов SQL, а лежит в колонке, которую
    # NAV считает UTC. Спрашивается поэтому шкала: транзакция держателя открыта секунды
    # назад, и отметка обязана сойтись с UTC-часами сервера, а не с местными. На местных
    # она разошлась бы ровно на часовой пояс - три часа на этом стенде.
    $tranClock = Scalar @"
SELECT TOP 1 CONVERT(varchar(11),ABS(DATEDIFF(second,SYSUTCDATETIME(),[Blocker Tran Began At]))) + '|' +
             CONVERT(varchar(11),DATEDIFF(minute,SYSUTCDATETIME(),SYSDATETIME()))
FROM $episode ORDER BY [Entry No_] DESC;
"@
    $tc = @(($tranClock -split '\|') | ForEach-Object { $_.Trim() })
    while ($tc.Count -lt 2) { $tc += '0' }
    Check 'начало транзакции виновника записано по UTC, а не местным временем' `
        (([int]$tc[0]) -le (ClockSlackSeconds)) `
        "расходится с UTC на $($tc[0]) с при запасе $(ClockSlackSeconds), пояс сервера $($tc[1]) мин"

    Write-Host 'Отпускаю блокировку и делаю второй проход'
    Stop-Sqlcmd $blocker
    Stop-Sqlcmd $waiter
    $deadline = (Get-Date).AddSeconds(20)
    while ((Get-Date) -lt $deadline) {
        $still = Scalar "SELECT TOP 1 CONVERT(varchar(11),session_id) FROM sys.dm_os_waiting_tasks WHERE wait_type LIKE 'LCK[_]%' AND session_id = $waiterSpid;"
        if (-not $still) { break }
        Start-Sleep -Milliseconds 500
    }

    # Накопитель сервера прирастает НЕ в момент начала ожидания, а в момент его конца, и
    # приходит туда не мгновенно. Ждём этого фактом, а не сном: без ожидания второй проход
    # успевает прочитать нулевой счётчик, и проверка охвата краснеет, хотя читает
    # правильно. Раньше это было незаметно - счётчик копился ПРОШЛЫМИ прогонами, условие
    # "больше нуля" выполнялось само собой, и проверяли мы не своё ожидание, а историю
    # машины. Перезапуск SQL (счётчик живёт в памяти) историю стирает.
    $svcWaitMs = 0
    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $deadline) {
        $svcWaitMs = [int64](Scalar @"
SELECT CONVERT(varchar(20),ISNULL(SUM(s.row_lock_wait_in_ms + s.page_lock_wait_in_ms),0))
FROM sys.dm_db_index_operational_stats(DB_ID(),NULL,NULL,NULL) s
WHERE OBJECT_NAME(s.object_id) = N'$markName';
"@)
        if ($svcWaitMs -gt 0) { break }
        Start-Sleep -Milliseconds 500
    }
    if ($svcWaitMs -le 0) { Fail 'сервер ожидание на таблице отметок не засчитал - опыт не удался, инструмент тут ни при чём' }
    Write-Host "  сервер засчитал ожидание: $svcWaitMs мс на таблице отметок"

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

    $alertRow = Scalar @"
SELECT TOP 1 CONVERT(varchar(11),[Channel]) + '|' + CONVERT(varchar(11),[Episodes]) + '|' +
  CONVERT(varchar(11),[Max Wait (ms)]) + '|' + CONVERT(varchar(11),[Head SPID])
FROM $alert ORDER BY [Entry No_] DESC;
"@
    $alertCount = [int](Scalar "SELECT COUNT(*) FROM $alert;")
    $al = ($alertRow -split '\|') | ForEach-Object { $_.Trim() }
    # Канал наружу - единственная часть тревоги, которую нельзя проверить внутри NAV:
    # запись в журнал событий Windows либо есть, либо её нет, и спросить об этом можно
    # только сам журнал.
    $written = @(Get-WinEvent -FilterHashtable @{ LogName = 'Application'; ProviderName = $alertSource; StartTime = $alertSince } -ErrorAction SilentlyContinue)
    Check 'тревога поднята одной строкой на голову цепочки' `
        (($alertCount -eq 1) -and ($al.Count -eq 4) -and ([int]$al[1] -ge 1) -and ([int]$al[2] -ge $alertThresholdMs)) `
        "строк тревоги $alertCount, эпизодов за защёлкой $($al[1]), самое долгое $($al[2]) мс, голова $($al[3])"
    Check 'тревога ушла наружу, в журнал событий Windows' `
        (($al[0] -eq '1') -and ($written.Count -ge 1)) `
        "канал $($al[0]) при ожидаемом 1 (журнал событий), записей в журнале Windows $($written.Count)"

    # Накопительный слой проверяется здесь ровно на том, чего не может проверить мерный
    # прогон: что счётчики читаются с НАСТОЯЩЕГО сервера и что имя индекса разбирается в
    # номер ключа NAV. Арифметика приростов проверена без базы, в мерном прогоне.
    #
    # Прироста тут ждать нельзя, и это не недосмотр: индекс, впервые попавший в чтение,
    # даёт только отметку. Приписать наблюдению всё, что счётчик насчитал до его начала,
    # значило бы соврать в первом же числе.
    $covRow = Scalar @"
SELECT TOP 1 CONVERT(varchar(11),[NAV Key No_]) + '|' + CONVERT(varchar(30),[Last Wait (ms)]) + '|' +
  CONVERT(varchar(11),[On SIFT])
FROM $coverage WHERE [NAV Table Name] = N'LockWatch Context Mark' ORDER BY [Last Wait (ms)] DESC;
"@
    $cv = ($covRow -split '\|') | ForEach-Object { $_.Trim() }
    # Сверяется с ЧИСЛОМ СЕРВЕРА, а не с нулём: "больше нуля" проходило на любом счётчике,
    # накопленном когда угодно и кем угодно, а совпадение с тем, что сервер показывает сам,
    # проверяет ровно то, ради чего слой заведён. Не равенство, а "не меньше": между
    # замером и проходом счётчик мог ещё подрасти, а уменьшиться он не может.
    Check 'счётчики охвата прочитаны с сервера, и ключ у них разобран' `
        (($cv.Count -eq 3) -and ($cv[0] -eq '0') -and ($cv[2] -eq '0') -and
         ($cv[1] -ne '') -and ([int64]$cv[1] -ge $svcWaitMs)) `
        "ключ NAV $($cv[0]) при ожидаемом 0, счётчик мс $($cv[1]) при серверных $svcWaitMs, на SIFT $($cv[2])"

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
    # ждущий берёт первый объект сам и встаёт за вторым, ожидания на первом не возникает
    # вовсе. Ловилось на себе - pass прошёл, pass-context упал на той же секунде.
    # Имя переводится в номер ЗАПРОСОМ К КАТАЛОГУ на каждом заходе, а не наоборот. Обратное -
    # OBJECT_NAME от resource_associated_entity_id - падает переполнением: функция берёт int,
    # а в столбце у блокировки рода KEY лежит hobt, число под 72 квадриллиона. Отбор по
    # resource_type от этого не спасает: порядок вычисления условий сервер не обещает, и
    # запрос роняет то, что в очереди в этот миг, а не то, что мы ищем. Ловилось на себе:
    # обычная ветка прошла, ветка контекста упала "ошибка арифметического переполнения".
    #
    # Спрашивается номер каждый раз заново, а не снимается до опыта: снятый заранее живёт
    # ровно до пересоздания таблицы и однажды разошёлся с тем, что стояло в очереди.
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
    # Ждём, пока ожидание появится в очереди СЕРВЕРА, и только потом идём проходом. Иначе
    # красная проверка означала бы "опыт не удался", а читалась бы как "инструмент не
    # увидел блокировку" - самая дорогая подмена, какая бывает в прогоне.
    #
    # Минута, а не сорок секунд: на загруженной машине один запуск sqlcmd стоит секунд, и
    # ждём мы здесь не блокировку, а ЗАПУСК процесса. Умерший ждущий - сразу отказ: он уже
    # ничего не дождётся, и досиживать до конца срока незачем.
    # Номер объекта спрашивается по имени КАЖДЫЙ РАЗ, а не снимается до опыта: снятый
    # заранее живёт ровно до пересоздания таблицы и однажды разошёлся с тем, что стояло в
    # очереди - отказ показывал "ждём 1147359352, а в очереди 1099359181", и выглядело это
    # как ошибка опыта, хотя ждущий был свой и ждал он честно. Обратный перевод (имя от
    # номера) применять нельзя - см. довод у Wait-ObjectHeld.
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
    # чему потом отличают "опыт не удался" от "инструмент не увидел". Номер ПРОЦЕССА рядом с
    # каждым ожиданием обязателен: без него чужое ожидание в очереди читается как своё, а
    # ждущий, который на самом деле не стартовал, выглядит как ждущий не на том объекте.
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
        # Каталог рядом с очередью: без него "ждёт не тот объект" не отличить от "номер
        # объекта у нас устарел", а это разные беды с одинаковым видом.
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
  CONVERT(varchar(11),[Resource Unresolved]) + '|' + CONVERT(varchar(11),[NAV Key No_]) + '|' +
  [Resource Kind]
FROM $episode WHERE [Resource Kind] = 'OBJECTLOCK' ORDER BY [Entry No_];
"@
    $u = @(($un -split '\|') | ForEach-Object { $_.Trim() })
    while ($u.Count -lt 5) { $u += '' }
    # На прежнем коде: сырое имя пустое, "не опознано" ноль - строка без имени ВОВСЕ, и
    # читается она как "сервер таблицы не назвал", хотя сервер её назвал.
    Check 'имя, которого разбор не понял, показано сырым и помечено' `
        (($u[0] -eq $probeAName) -and ($u[1] -eq '') -and ($u[2] -eq '1') -and ($u[3] -eq '-1')) `
        "сырое имя [$($u[0])], таблица NAV [$($u[1])], не опознано $($u[2]), ключ $($u[3])"

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
    # Имя тут не украшение, а РАЗДЕЛИТЕЛЬ: по остальным полям эпизоды неразличимы. Порознь
    # их держит ещё и признак "счётчик ожидания пошёл назад", но он о другом и срабатывает
    # не всегда - зависит от того, каким проходом эпизод застали. На прежнем коде эпизодов
    # выходило два, а разных имён в них одно: читателю не за что зацепиться.
    Check 'эпизоды на разных объектах различимы: у каждого своё имя' `
        (($pr[0] -eq '2') -and ($pr[1] -eq '2')) `
        "эпизодов $($pr[0]), разных имён $($pr[1]) при ожидаемых 2 и 2"

    # Мишени второй сцены отпускаются здесь, а не в уборке: третья сцена меряет ИМЕНА, и
    # чужие ожидания в очереди ей ни к чему - место разбора в проходе не бесконечно.
    Stop-Sqlcmd $probeHoldB
    Stop-Sqlcmd $probeWaiter

    Write-Host 'Сцена третья: очередь в два колена - у кого спрашивать имя виновника'
    # Самое тонкое место всей дороги к имени, и до сих пор не проверенное ничем. В очереди
    # A -> B -> C непосредственный виновник у C - это B, но B сам стоит за A: отметка B
    # рассказывает про то, чем занят ПОСТРАДАВШИЙ, а строку держит A. Назвать соседа
    # виновником - ошибка того же рода, что обвинить пострадавшего, только правдоподобнее:
    # имя настоящее, живого человека, и опровергнуть его читателю нечем.
    #
    # Спорной строкой у каждого служит его же отметка - тем же приёмом, что и в первой
    # сцене. Так каждая сессия держит ровно одну выданную блокировку на таблице отметок, и
    # "какую из них взяли" не превращается в отдельную загадку.
    Invoke-Sql @"
DELETE FROM $mark WHERE [Server Instance Id] BETWEEN -29 AND -20;
INSERT INTO $mark ([Server Instance Id],[Session Id],[User Id],[Company Name],[Table No_],[Document No_],[Marked At])
VALUES (-21,-21,N'$holderUser',N'$Company',0,N'CHAIN-HEAD',GETUTCDATE()),
       (-22,-22,N'$middleUser',N'$Company',0,N'CHAIN-MID',GETUTCDATE()),
       (-23,-23,N'$victimUser',N'$Company',0,N'CHAIN-TAIL',GETUTCDATE());
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
    # Захват ждём ФАКТОМ - выданной блокировкой рода KEY на таблице отметок, - а не сном.
    # Опоздавшее колено меняет опыт целиком: цепочка выходит короче, и красная проверка
    # означала бы "опыт не удался", а читалась бы как "инструмент спросил не у того".
    function Wait-MarkHeld([int]$spid) {
        $stop = (Get-Date).AddSeconds(60)
        while ((Get-Date) -lt $stop) {
            $held = Scalar @"
SELECT TOP 1 CONVERT(varchar(11),l.request_session_id)
FROM sys.dm_tran_locks l
JOIN sys.partitions p ON p.hobt_id = l.resource_associated_entity_id
WHERE l.resource_type = 'KEY' AND l.request_status = 'GRANT'
  AND l.request_session_id = $spid AND OBJECT_NAME(p.object_id) = N'$markName';
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

    $chainA = "SET LOCK_TIMEOUT -1`nBEGIN TRAN`nUPDATE $mark SET [Document No_] = N'CHAIN-HEAD' WHERE [Server Instance Id] = -21`nWAITFOR DELAY '00:05:00'`nROLLBACK`n"
    $chainB = "SET LOCK_TIMEOUT -1`nBEGIN TRAN`nUPDATE $mark SET [Document No_] = N'CHAIN-MID' WHERE [Server Instance Id] = -22`nUPDATE $mark SET [Document No_] = N'WANT-HEAD' WHERE [Server Instance Id] = -21`nROLLBACK`n"
    $chainC = "SET LOCK_TIMEOUT -1`nBEGIN TRAN`nUPDATE $mark SET [Document No_] = N'CHAIN-TAIL' WHERE [Server Instance Id] = -23`nUPDATE $mark SET [Document No_] = N'WANT-MID' WHERE [Server Instance Id] = -22`nROLLBACK`n"

    $headProc = Start-Sqlcmd 'chain-head.sql' $chainA $holderHost
    $spidHead = Get-Spid $headProc
    if ($spidHead -eq 0) { Fail 'голова цепочки не подключилась - опыт не удался' }
    if (-not (Wait-MarkHeld $spidHead)) { Fail 'голова цепочки свою отметку не взяла - опыт не удался' }

    $midProc = Start-Sqlcmd 'chain-mid.sql' $chainB $middleHost
    $spidMid = Get-Spid $midProc
    if ($spidMid -eq 0) { Fail 'среднее колено не подключилось - опыт не удался' }
    if (-not (Wait-MarkHeld $spidMid)) { Fail 'среднее колено свою отметку не взяло - опыт не удался' }
    if (-not (Wait-BlockedBy $spidMid $spidHead)) { Fail 'среднее колено за голову не встало - опыт не удался' }

    $tailProc = Start-Sqlcmd 'chain-tail.sql' $chainC $victimHost
    $spidTail = Get-Spid $tailProc
    if ($spidTail -eq 0) { Fail 'хвост цепочки не подключился - опыт не удался' }
    if (-not (Wait-BlockedBy $spidTail $spidMid)) { Fail 'хвост цепочки за среднее колено не встал - опыт не удался' }
    Write-Host "  цепочка собрана: $spidTail ждёт $spidMid, $spidMid ждёт $spidHead"

    # Проходов до трёх, а не один. Отметку разбор ищет по блокировке, которую держат ПРЯМО
    # СЕЙЧАС, и первый заход после открытия эпизода вполне может застать очередь в
    # промежуточном виде. Больше трёх ждать незачем: потолок попыток назвать и без того
    # ниже, а молчание после трёх - это ответ, а не задержка.
    $chainRow = ''
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        Invoke-Pass "проход по цепочке, заход $attempt"
        $chainRow = Scalar @"
SELECT TOP 1 CONVERT(varchar(11),[Chain Depth]) + '|' + [User Name] + '|' + [Victim User Name]
FROM $episode WHERE [Victim SPID] = $spidTail AND [Open] = 1 ORDER BY [Entry No_] DESC;
"@
        $tail = @(($chainRow -split '\|') | ForEach-Object { $_.Trim() })
        if (($tail.Count -ge 2) -and ($tail[1] -ne '')) { break }
    }
    while ($tail.Count -lt 3) { $tail += '' }

    $midRow = Scalar @"
SELECT TOP 1 CONVERT(varchar(11),[Chain Depth]) + '|' + [User Name] + '|' + [Victim User Name]
FROM $episode WHERE [Victim SPID] = $spidMid AND [Open] = 1 ORDER BY [Entry No_] DESC;
"@
    $mid = @(($midRow -split '\|') | ForEach-Object { $_.Trim() })
    while ($mid.Count -lt 3) { $mid += '' }

    # Сломано нарочно 09.09.2026 - отметка спрошена у непосредственного блокирующего вместо
    # головы, - и даёт "виновник [STAND-MIDDLE] при ожидаемом [STAND-HOLDER]": имя
    # пострадавшего в колонке виновника, и выглядит это правдой.
    Check 'в очереди из двух колен виновник взят у ГОЛОВЫ, а не у соседа' `
        (($tail[0] -eq '2') -and ($tail[1] -eq $holderUser) -and ($tail[2] -eq $victimUser)) `
        "глубина $($tail[0]) при ожидаемой 2, виновник [$($tail[1])] при ожидаемом [$holderUser] (сосед - [$middleUser]), ждал [$($tail[2])]"

    # Тот же сеанс в соседнем эпизоде стоит ДРУГОЙ стороной, и колонки обязаны это
    # различать: здесь он пострадавший, а виновник у него - та же голова. На сломанном
    # коде даёт "ждал [STAND-HOLDER] при ожидаемом [STAND-MIDDLE]".
    #
    # Обе поломки разом дают 22 из 25, и красные - ровно эти три проверки.
    Check 'сосед по цепочке в своём эпизоде назван пострадавшим, а не виновником' `
        (($mid[0] -eq '1') -and ($mid[1] -eq $holderUser) -and ($mid[2] -eq $middleUser)) `
        "глубина $($mid[0]) при ожидаемой 1, виновник [$($mid[1])] при ожидаемом [$holderUser], ждал [$($mid[2])] при ожидаемом [$middleUser]"
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
    # Убираем за собой И строку-мишень, И эпизоды. Оставленный эпизод - не мусор, а помеха:
    # мерный прогон журнала отказывается работать по непустому журналу, и следующий прогон
    # упал бы с виду беспричинно. Оставить его можно нарочно, ключом -KeepJournal.
    # Признак возвращается в исходное - таким он заводится при создании настройки.
    # Отметки сметаются диапазоном, а не по одному номеру: сцен, кладущих свои отметки,
    # теперь три, и забытая отметка переживёт прогон и запутает следующий.
    $cleanup = "DELETE FROM $mark WHERE [Server Instance Id] BETWEEN -29 AND -1; DELETE FROM $context WHERE [Table No_] = 110233;"
    $cleanup += " UPDATE $setup SET [Deadlocks Enabled] = 1, [Collect Statement Values] = 0;"
    $cleanup += " DELETE FROM $coverage; UPDATE $state SET [Coverage Since] = $blankDate;"
    # Настройка тревоги возвращается в исходное: порог и канал - то, чем инструмент
    # заводится, и оставлять их сдвинутыми после прогона нельзя.
    $cleanup += " DELETE FROM $alert; UPDATE $setup SET [Alert Channel] = 1, [Alert Threshold (ms)] = 5000;"
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
    & sqlcmd -S $Server -d $Database -E -l 30 -h -1 -Q $cleanup 2>&1 | Out-Null
    if ($StopInstance) { Stop-Service $service -Force }
}

Write-Host ''
Write-Host "пройдено $passed из $total"
Write-Host ''
$report | ForEach-Object { Write-Host $_ }
if ($passed -lt $total) { Fail 'проверка на живой блокировке не пройдена' }
Write-Host 'Готово: проход проверен на настоящей блокировке' -ForegroundColor Green
