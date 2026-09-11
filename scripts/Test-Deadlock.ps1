#requires -Version 7
<#
.SYNOPSIS
    Взаимоблокировки из кольцевого буфера сервера: настоящий круг между двумя сеансами,
    граф в system_health, и строка журнала того же вида, что и обычный эпизод.

.DESCRIPTION
    Устроить взаимоблокировку можно только по-настоящему: сервер разрывает круг сам, и
    подделать его нечем. Два соединения берут две строки в обратном порядке, сервер выбирает
    жертву, граф ложится в кольцевой буфер, а проход обязан достать оттуда ровно одну строку
    и назвать в ней жертву, победителя, таблицу и время.

    Жертва назначается заранее ключом DEADLOCK_PRIORITY: без него сервер выбирает по
    стоимости отката, и проверка "жертва та самая" превратилась бы в угадывание.

    Опыт ставится ДВАЖДЫ и с перерывом дольше периода чтения буфера. Это единственный
    способ проверить то, ради чего заведён отпечаток графа: первый граф остаётся в буфере
    и читается ВТОРОЙ раз, а в журнале обязан остаться одной строкой. Отметка "прочитано
    до" от повтора не спасает нарочно - отбор по ней нестрогий, иначе два события в одну
    миллисекунду теряли бы второе.

    Проверено поломкой 07.09.2026, и поломка нашла настоящий дефект, а не подтвердила
    проверку. Со снятой проверкой отпечатка прогон обязан был покраснеть - и не покраснел:
    отметка "прочитано до" ехала в запрос через тип datetime с шагом 3,33 мс, округлялась
    ВВЕРХ, и пограничное событие пропускалось молча. То есть повтора просто не случалось, а
    нестрогий отбор не работал вовсе. После правки на datetime2(3) целый код даёт 13 из 13,
    а со снятой проверкой - 12 из 13: в журнале три строки вместо двух при двух разных
    отпечатках, и краснеет проверка "повторно прочитанный граф не удваивает строку".

.EXAMPLE
    pwsh scripts/Test-Deadlock.ps1
#>
[CmdletBinding()]
param(
    [string] $Server   = 'localhost',
    [string] $Database = $env:LW_DATABASE,
    [string] $Instance = $env:LW_INSTANCE,
    [string] $Company  = $env:LW_COMPANY,
    [int]    $TaskCodeunitId = 110236,
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
$state   = "[$Company`$LockWatch Watchdog]"
$mark    = "[$Company`$LockWatch Context Mark]"
$service = "MicrosoftDynamicsNavServer`$$Instance"
# Имена рабочих станций сторон. Логин у обоих соединений один - учётная запись, под которой
# идёт прогон, - и программа одна, sqlcmd; узел остаётся единственным, чем они отличаются.
# Кто из них жертва, решает не случай, а ключ DEADLOCK_PRIORITY, поэтому имена закреплены.
$victimHost = 'LW-DEAD-VICTIM'
$winnerHost = 'LW-DEAD-WINNER'
# Логины сторон круга. Граф называет обоих участников сам, и логин берёт из того же узла
# процесса, что и узел с программой; пока логин у сторон был ОДИН - учётная запись, из-под
# которой идёт прогон, - проверять его было нечем, кроме непустоты, и перестановка колонок
# местами прошла бы молча. Подключиться логином SQL стенд не даёт (смешанный режим
# выключен), поэтому сессия входит в свой логин через EXECUTE AS.
#
# Вопрос "а несёт ли ГРАФ подменённый логин или подключённый" решён замером 10.09.2026:
# несёт подменённый. Граф пишет в узел процесса тот логин, под которым сессия держала
# блокировку, - тот же самый, что показывает sys.dm_exec_sessions.login_name.
$victimLogin = 'LW Probe Dead Victim'
$winnerLogin = 'LW Probe Dead Winner'
# Пустая дата NAV в SQL. Ни NULL, ни ноль: столбец NOT NULL, а нулю отвечает 1900 год.
# Строку состояния сторожа заводит первый же проход, но здесь она нужна РАНЬШЕ: отметку
# "прочитано до" надо поставить прежде, чем проход впервые откроет кольцевой буфер, иначе
# в журнал приедут чужие круги. Умолчаний NAV в SQL не создаёт, а столбцы объявляет
# NOT NULL, поэтому строка заводится со всеми столбцами разом.
$blankDate = "CONVERT(datetime,'17530101')"
$stateSeed = @"
IF NOT EXISTS (SELECT 1 FROM $state)
  INSERT INTO $state ([Primary Key],[Deadlocks Read Until],[Deadlocks Read At],[Coverage Since],
                      [Last Pass At],[Last Pass (ms)],[Last Pass Rows],[Last Pass Truncated],[Watchdog Message])
  VALUES (N'',$blankDate,$blankDate,$blankDate,$blankDate,0,0,0,N'');
"@

function Invoke-Sql([string]$query) {
    # SET QUOTED_IDENTIFIER ON обязателен: sqlcmd включает его ВЫКЛЮЧЕННЫМ, а без него
    # отказывает любой метод XML - и отказ называет не причину, а список требований.
    # -b столь же обязателен: без него sqlcmd возвращает ноль и на ошибке SQL.
    $answer = & sqlcmd -S $Server -d $Database -E -b -l 30 -w 900 -W -s '|' -h -1 `
        -Q "SET QUOTED_IDENTIFIER ON; SET NOCOUNT ON; $query" 2>&1
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

$pa = $null; $pb = $null
function Start-Sqlcmd([string]$name, [string]$sql, [string]$workstation = '') {
    $file = Join-Path $outDir $name
    [IO.File]::WriteAllText($file, (($sql -replace "`r`n", "`n") -replace "`n", "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
    # Ключ -H кладёт имя рабочей станции в host_name сеанса, а граф берёт его из узла
    # процесса. Без него обе стороны опыта на сервере выглядят одинаково.
    $sqlArgs = @('-S', $Server, '-d', $Database, '-E', '-l', '30', '-i', $file)
    if ($workstation) { $sqlArgs += @('-H', $workstation) }
    Start-Process -FilePath 'sqlcmd' -PassThru -WindowStyle Hidden -ArgumentList $sqlArgs
}

# Логин заводится прогоном и им же убирается: оставленный на стенде опытный логин - это
# чужая учётная запись в списке безопасности сервера, которую никто не заказывал.
function New-ProbeLogin([string]$login) {
    # Пароль случайный и никуда не записывается. Войти этим логином всё равно нельзя -
    # смешанный режим выключен, - но синтаксис CREATE LOGIN пароля требует. Права даются
    # РОВНО на строки-мишени: за них идёт круг, и ничего другого опытной учётной записи
    # знать не положено.
    $password = [Guid]::NewGuid().ToString('N') + 'Aa1!'
    Invoke-Sql @"
IF SUSER_ID(N'$login') IS NULL CREATE LOGIN [$login] WITH PASSWORD = '$password', CHECK_POLICY = OFF;
IF DATABASE_PRINCIPAL_ID(N'$login') IS NULL CREATE USER [$login] FOR LOGIN [$login];
GRANT SELECT, UPDATE ON $mark TO [$login];
"@ | Out-Null
}

$probeFile = Join-Path $outDir 'wait-nav.ps1'
$passFile  = Join-Path $outDir 'invoke-pass.ps1'
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
Write-Ps51 $passFile @"
`$ErrorActionPreference = 'Stop'
$navImport
Invoke-NAVCodeunit -ServerInstance $Instance -CompanyName '$Company' -CodeunitId $PassCodeunitId -MethodName RunPass -ErrorAction Stop
"@
$ps51 = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
function Invoke-Pass([string]$why) {
    $log = & $ps51 -NoProfile -ExecutionPolicy Bypass -File $passFile 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { Fail "$why не отработал:`n$log" }
}

# Число графов в буфере. По нему видно, что опыт УДАЛСЯ, а не что инструмент промолчал.
#
# Имя события взято в ОДИНАРНЫЕ кавычки, удвоенные для T-SQL. Двойная кавычка внутри
# аргумента -Q рвёт разбор командной строки sqlcmd, и отказ он объявляет не про кавычку,
# а про "непредвиденный аргумент". Инструмента это не касается: там текст запроса уходит
# драйверу, а не через командную строку, и двойные кавычки в нём законны.
# Самое свежее событие в буфере. Именно оно, а не СЧЁТ событий, говорит, что круг случился:
# буфер кольцевой, и на забитом дневными опытами кольце сервер вытесняет столько же,
# сколько кладёт. Счёт при этом стоит на месте, опыт объявляет "круга не вышло" там, где
# круг был, ставит его заново - и в журнал приезжают лишние НАСТОЯЩИЕ круги, а красной
# оказывается проверка на повтор. Ловилось 08.09.2026 на кольце из 23 чужих графов.
$graphNewest = @"
SELECT ISNULL(MAX(CONVERT(varchar(30),n.e.value('@timestamp','datetime2(3)'),126)),'') FROM (
  SELECT CONVERT(xml, t.target_data) AS x
  FROM sys.dm_xe_session_targets t
  JOIN sys.dm_xe_sessions s ON s.address = t.event_session_address
  WHERE s.name = 'system_health' AND t.target_name = 'ring_buffer') q
CROSS APPLY q.x.nodes('/RingBufferTarget/event[@name=''xml_deadlock_report'']') AS n(e);
"@
$graphCount = @"
SELECT COUNT(*) FROM (
  SELECT CONVERT(xml, t.target_data) AS x
  FROM sys.dm_xe_session_targets t
  JOIN sys.dm_xe_sessions s ON s.address = t.event_session_address
  WHERE s.name = 'system_health' AND t.target_name = 'ring_buffer') q
CROSS APPLY q.x.nodes('/RingBufferTarget/event[@name=''xml_deadlock_report'']') AS n(e);
"@

# Сколько позволено разойтись меткам графа с часами сервера. Круг случился минуту назад,
# но попыток бывает до трёх, и каждая держит первую блокировку десять секунд: пять минут
# покрывают самый долгий заход. Ошибка в часовой пояс даёт часы и в этот запас не влезет.
function ClockSlackSeconds { 300 }
function CircleAttempts {
    # Три. Одной мало - круг вероятностный; больше трёх значит, что не состоится он и на
    # десятой: причина тогда не в невезении, а в устройстве опыта, и её надо искать.
    return 3
}
function CircleHold {
    # Десять секунд удержания первой блокировки - вдвое против прежних пяти. Столько
    # держится окно, в которое обязана успеть вторая сторона; при пяти секундах она однажды
    # не успела, и круг не состоялся вовсе.
    return '00:00:10'
}
$staleRing = $false
# Кольцо, которое не отдаёт НИЧЕГО, - не то же самое, что кольцо, отдающее с запозданием.
# Первое видно только по счётчику сервера, второе - по метке времени в самой выдаче.
$blindRing = $false

function ServerCircles {
    # Сколько кругов насчитал САМ сервер с запуска. Единственное место, по которому
    # "круга не вышло" отличается от "круг был, а кольцо смолчало": выдача кольца об этом
    # не говорит ничего. Счётчик накопительный и общий на весь экземпляр - сравнивается
    # только прирост за время одного захода, а не значение.
    return [int64](Scalar "SELECT CONVERT(varchar(20),cntr_value) FROM sys.dm_os_performance_counters WHERE counter_name LIKE 'Number of Deadlocks/sec%' AND instance_name = '_Total';")
}
function Invoke-Deadlock([string]$why) {
    # Стороны круга выходят на сервер каждая под своим логином. Заводить их здесь можно
    # столько раз, сколько будет кругов: заводчик спрашивает, есть ли логин, прежде чем
    # создавать.
    New-ProbeLogin $victimLogin
    New-ProbeLogin $winnerLogin

    # Круг - опыт ВЕРОЯТНОСТНЫЙ, и это его свойство, а не недоделка. Обе стороны обязаны
    # взять свою первую блокировку прежде, чем первая пойдёт за второй; если одна из них
    # запаздывает со стартом дольше паузы, круга не выйдет вовсе - обе отработают по
    # очереди и выйдут с нулём. Ловилось на себе 08.09.2026: сметный прогон дал "граф в
    # буфер не попал" там, где двумя заходами раньше выходило 13 из 13, и виноват был
    # запуск процесса на занятой машине, а не инструмент.
    #
    # Лечится двумя вещами разом: пауза вдвое длиннее прежней и три попытки вместо одной.
    # Одна попытка красит смету случайным цветом, а смета со случайным цветом хуже
    # отсутствующей: её перестают читать.
    for ($attempt = 1; $attempt -le (CircleAttempts); $attempt++) {
        $before = Scalar $graphNewest
        # Сколько кругов сервер насчитал ДО захода. Счётчик накопительный и общий на весь
        # экземпляр; сравниваются не значения, а прирост, и только за время одного захода.
        $circlesBefore = ServerCircles
        # Момент круга спрашивается У СЕРВЕРА и по UTC - в этой же шкале буфер метит
        # события. Взять его у часов этой машины значило бы сравнивать две шкалы.
        $circleAt = Scalar "SELECT CONVERT(varchar(30),SYSUTCDATETIME(),126);"
        # Жертва назначается ключом: без него сервер выбирает по стоимости отката, и проверка
        # "жертва та самая" стала бы угадыванием.
        # EXECUTE AS стоит ДО открытия транзакции: в граф обязан попасть тот логин, под
        # которым сессия взяла блокировку, а не тот, под которым она подключилась.
        $a = "EXECUTE AS LOGIN = N'$victimLogin'`nSET DEADLOCK_PRIORITY LOW`nBEGIN TRAN`nUPDATE $mark SET [Document No_]=N'A1' WHERE [Server Instance Id]=-11`nWAITFOR DELAY '$(CircleHold)'`nUPDATE $mark SET [Document No_]=N'A2' WHERE [Server Instance Id]=-12`nCOMMIT`n"
        $b = "EXECUTE AS LOGIN = N'$winnerLogin'`nSET DEADLOCK_PRIORITY HIGH`nBEGIN TRAN`nUPDATE $mark SET [Document No_]=N'B1' WHERE [Server Instance Id]=-12`nWAITFOR DELAY '$(CircleHold)'`nUPDATE $mark SET [Document No_]=N'B2' WHERE [Server Instance Id]=-11`nCOMMIT`n"
        $script:pa = Start-Sqlcmd 'dead-a.sql' $a $victimHost
        $script:pb = Start-Sqlcmd 'dead-b.sql' $b $winnerHost
        $pa = $script:pa
        $pb = $script:pb

        # Номера сеансов снимаются ПОКА они живы: после отката процесса нет, и связать строку
        # журнала с опытом было бы нечем.
        $victim = 0; $winner = 0
        $deadline = (Get-Date).AddSeconds(20)
        while ((Get-Date) -lt $deadline) {
            $victim = [int](Scalar "SELECT TOP 1 CONVERT(varchar(11),session_id) FROM sys.dm_exec_sessions WHERE host_process_id = $($pa.Id);")
            $winner = [int](Scalar "SELECT TOP 1 CONVERT(varchar(11),session_id) FROM sys.dm_exec_sessions WHERE host_process_id = $($pb.Id);")
            if (($victim -gt 0) -and ($winner -gt 0)) { break }
            Start-Sleep -Milliseconds 300
        }

        $pa.WaitForExit(60000) | Out-Null
        $pb.WaitForExit(60000) | Out-Null

        if (($victim -gt 0) -and ($winner -gt 0)) {
            $deadline = (Get-Date).AddSeconds(30)
            while ((Get-Date) -lt $deadline) {
                if ((Scalar $graphNewest) -ne $before) { break }
                Start-Sleep -Milliseconds 500
            }
            $after = Scalar $graphNewest
            # Изменившаяся отметка ещё НЕ значит, что в выдаче наш круг. Кольцо отдаёт XML
            # не мгновенно, и на забитом дневными опытами буфере в выдаче всплывает граф
            # ПРЕДЫДУЩЕГО захода - отметка меняется, а нашего события там нет. Опыт тогда
            # объявляет успех, проход законно не находит ничего нового, и прогон краснеет
            # на "в журнале пусто", называя виноватым инструмент.
            #
            # Измерено 11.09.2026: круг состоялся, стороны названы, счёт графов вырос с 16
            # до 17 - а новейшая отметка в выдаче отставала от круга на одиннадцать минут.
            # После очистки сессии system_health тот же прогон дал 16 из 16.
            if (($after -ne $before) -and ($after -lt $circleAt)) {
                $script:staleRing = $true
                Write-Host "  $why - кольцо отдало граф СТАРШЕ круга: $after при круге в $circleAt" -ForegroundColor Yellow
                continue
            }
            if ($after -ne $before) {
                $note = if ($attempt -gt 1) { ", попыток $attempt" } else { '' }
                Write-Host "  $why - жертва $victim, победитель $winner, графов в буфере $(Scalar $graphCount)$note"
                return @($victim, $winner)
            }
            # "Графа в буфере нет" и "круга не вышло" - РАЗНЫЕ вещи, и различает их счётчик
            # сервера. Прежде прогон объявлял вторую, а видел только первую, и отказ его
            # звучал "опыт не удался, инструмент тут ни при чём" - при том, что опыт удался
            # трижды, а молчало кольцо.
            #
            # Измерено 11.09.2026: за заход счётчик вырос с 43 до 46 - по кругу на попытку, -
            # а выдача кольца не шелохнулась: двадцать графов, новейший на четыре часа
            # старше. Причина найдена там же: target_data кольцевого приёмника упёрлась в
            # 8 382 784 байта, это 4 191 392 знака, и новые события в выдачу перестали
            # попадать вовсе - при droppedCount, равном нулю (FINDINGS, раздел 62).
            $circlesAfter = ServerCircles
            $grew = $circlesAfter - $circlesBefore
            if ($grew -gt 0) {
                $script:blindRing = $true
                Write-Host "  $why - круг СОСТОЯЛСЯ (сервер насчитал $grew), а кольцо не отдало ничего" -ForegroundColor Yellow
            } else {
                Write-Host "  $why - круг с попытки $attempt не состоялся, сервер кругов не считал, графа в буфере нет" -ForegroundColor Yellow
            }
        } else {
            Write-Host "  $why - сеансы опыта с попытки $attempt не опознаны" -ForegroundColor Yellow
        }
    }
    if ($blindRing) {
        Fail ("$why - круги СОСТОЯЛИСЬ, их насчитал сам сервер, а кольцо system_health не отдало " +
              'ни одного события. Выдача кольцевого приёмника имеет предел, и по достижении его ' +
              'новые события в неё не попадают вовсе - при нулевом droppedCount и работающей ' +
              'сессии. Лечится перезаводом: ALTER EVENT SESSION [system_health] ON SERVER ' +
              'STATE = STOP, затем START. Опыт удался, а дорога к графу мертва.')
    }
    if ($staleRing) {
        Fail ("$why - круги случались, но кольцо system_health отдаёт события с задержкой: в выдаче " +
              'графы старше самого круга. Буфер забит опытами, и лечится это очисткой сессии - ' +
              'ALTER EVENT SESSION [system_health] ON SERVER STATE = STOP, затем START. Инструмент тут ни при чём.')
    }
    Fail "$why - круга не вышло за $(CircleAttempts) попытки, опыт не удался, инструмент тут ни при чём"
}

try {
    Write-Host 'Подготовка стенда'
    if ((Get-Service $service).Status -ne 'Running') { Start-Service $service }
    # Настройка правится ДО перезапуска: при работающей службе строка лежит в кэше, и
    # запрос до сессии не доходит вовсе.
    # Отметка "прочитано до" ставится на СЕЙЧАС, а не в пустую дату. Буфер кольцевой и
    # хранит всё, что сервер записал раньше: с пустой отметкой проход законно вычитал бы
    # чужие круги, и проверка "строка ровно одна" краснела бы не по вине инструмента.
    #
    # Пустая дата у NAV в SQL, кстати, не NULL, а 1753-01-01: столбцы объявлены NOT NULL.
    # Отметку "когда читали" обнуляем именно ею - иначе первый проход буфер не откроет.
    # Сторож гасится нарочно, и это не уборка, а условие опыта. Буфер взаимоблокировок
    # проход читает не чаще раза в минуту, и отметку "читали в" ставит СЕБЕ любой проход -
    # в том числе фоновый. Заведённый сторож успевает пройти между подготовкой и кругом,
    # находит пустой буфер, закрывает окно чтения на минуту - и проход этого прогона буфер
    # уже не открывает. В журнале тогда пусто, прогон краснеет, а инструмент ни при чём.
    # Измерено 11.09.2026: круг состоялся, граф в буфере лежал, журнал остался пустым.
    # Проходы здесь делаются РУКАМИ, и сторож прогону не нужен вовсе.
    Invoke-Sql @"
UPDATE $setup SET [SQL Server] = N'$Server', [Deadlocks Enabled] = 1, [Enabled] = 0;
DELETE FROM [dbo].[Scheduled Task] WHERE [Run Codeunit] = $TaskCodeunitId;
$stateSeed
UPDATE $state SET [Watchdog Message] = N'',
  [Deadlocks Read Until] = GETUTCDATE(), [Deadlocks Read At] = $blankDate;
"@ | Out-Null
    $mark0 = Scalar "SELECT CONVERT(varchar(30),[Deadlocks Read Until],126) FROM $state;"
    Invoke-Sql "DELETE FROM $episode;" | Out-Null
    Invoke-Sql "DELETE FROM $mark WHERE [Server Instance Id] IN (-11,-12);" | Out-Null
    Invoke-Sql @"
INSERT INTO $mark ([Server Instance Id],[Session Id],[User Id],[Company Name],[Table No_],[Document No_],[Marked At])
VALUES (-11,-11,N'STAND',N'$Company',0,N'DEAD-ONE',GETUTCDATE()),
       (-12,-12,N'STAND',N'$Company',0,N'DEAD-TWO',GETUTCDATE());
"@ | Out-Null

    Write-Host "  перезапускаю службу $Instance и жду ответа порта управления"
    Restart-Service $service -Force
    & $ps51 -NoProfile -ExecutionPolicy Bypass -File $probeFile | Out-Null
    if ($LASTEXITCODE -ne 0) { Fail "экземпляр $Instance не ответил по порту управления" }

    Write-Host 'Круг первый'
    $one = Invoke-Deadlock 'круг первый'
    Invoke-Pass 'проход после первого круга'

    $watchdog = Scalar "SELECT [Watchdog Message] FROM $state;"
    Check 'проход отчитался, а не промолчал' (($watchdog -ne '') -and ($watchdog -notmatch 'не прочитаны') -and ($watchdog -notmatch 'не работает')) `
        "сторож пишет: $watchdog"

    $rows = [int](Scalar "SELECT COUNT(*) FROM $episode;")
    Check 'взаимоблокировка попала в журнал одной строкой' ($rows -eq 1) "строк в журнале $rows"
    if ($rows -lt 1) { Fail 'в журнале пусто - дальше проверять нечего' }

    $row = Scalar @"
SELECT TOP 1 CONVERT(varchar(11),[Class]) + '|' + CONVERT(varchar(11),[Outcome]) + '|' +
  CONVERT(varchar(11),[Victim SPID]) + '|' + CONVERT(varchar(11),[Blocker SPID]) + '|' +
  CONVERT(varchar(11),[Chain Ring]) + '|' + CONVERT(varchar(11),[Open]) + '|' +
  [NAV Table Name] + '|' + [Resource Kind] + '|' + [Deadlock Id] + '|' +
  CONVERT(varchar(11),CASE WHEN [Ended At] > [Started At] THEN 1 ELSE 0 END) + '|' +
  CONVERT(varchar(11),[Max Wait (ms)]) + '|' + [Held Mode] + '|' + [Wait Type] + '|' +
  CONVERT(varchar(11),[NAV Key No_]) + '|' + [Blocker Statement] + '|' +
  [Blocker Login] + '|' + [Blocker Program] + '|' +
  [Victim Login] + '|' + [Victim Program] + '|' +
  [Victim Host] + '|' + [Blocker Host]
FROM $episode ORDER BY [Entry No_] DESC;
"@
    $f = ($row -split '\|') | ForEach-Object { $_.Trim() }
    if ($f.Count -lt 21) { Fail "строка журнала пришла неполной: $($f.Count) колонок" }

    # Обоих участников граф называет сам - узлом процесса, из которого уже взяты машина,
    # процесс и программа. Дорога эта отдельная от очереди, и своих номеров колонок у неё
    # столько же: назвать по ней участников и не проверить этого значило бы держать вторую
    # половину журнала на честном слове.
    # На прежнем коде: у жертвы этих двух полей не было, а у виновника они были и не
    # проверялись ни одной проверкой.
    # Логины сверяются ПО ИМЕНИ: у сторон они теперь разные, и перестановка колонок красит
    # проверку сразу. Пока логин был один на обоих, непустота проходила при любой ошибке -
    # логин-то есть у обоих, и он совпал бы при любой путанице.
    #
    # Сломано нарочно 10.09.2026 - номера колонок читателя у двух логинов переставлены
    # местами в разборе графа: 14 из 15, и красная эта проверка, "виновник [LW Probe Dead
    # Victim] при ожидаемом [LW Probe Dead Winner]". На прежнем условии перестановка
    # прошла бы молча: обе колонки непусты и обе содержали одно и то же имя.
    Check 'граф назвал обоих: логины и программы' `
        (($f[15] -eq $winnerLogin) -and ($f[17] -eq $victimLogin) -and
         ($f[16] -match '(?i)sqlcmd') -and ($f[18] -match '(?i)sqlcmd')) `
        "виновник [$($f[15])] при ожидаемом [$winnerLogin] / [$($f[16])], жертва [$($f[17])] при ожидаемом [$victimLogin] / [$($f[18])]"

    # Непустота обеих колонок ещё не значит, что они не перепутаны местами: логин и
    # программа у сторон опыта одинаковые, и перестановка прошла бы молча. Узел - это то
    # единственное, чем они отличаются, а кто из них жертва, решает ключ приоритета, а не
    # случай. Граф берёт узел из того же узла процесса, что и логин: разъехались они -
    # значит стороны разъехались тоже, и обвинён не тот.
    Check 'граф не перепутал стороны: узел жертвы и узел виновника те самые' `
        (($f[19] -eq $victimHost) -and ($f[20] -eq $winnerHost)) `
        "узел жертвы [$($f[19])] при ожидаемом [$victimHost], узел виновника [$($f[20])] при ожидаемом [$winnerHost]"

    # Обе метки графа приходят от сервера, и шкалы у них РАЗНЫЕ: время события буфер
    # событий пишет по UTC, а @lasttranstarted сервер кладёт по местным часам. В журнале
    # они обязаны лежать одной шкалой - той, в какой NAV хранит DateTime, то есть по UTC.
    # Проверка эта и решает вопрос, который иначе пришлось бы брать на веру из описания
    # формата: разойдись любая из двух с часами сервера на часовой пояс - покраснеет.
    $graphClock = Scalar @"
SELECT TOP 1 CONVERT(varchar(11),ABS(DATEDIFF(second,SYSUTCDATETIME(),[Started At]))) + '|' +
             CONVERT(varchar(11),ABS(DATEDIFF(second,SYSUTCDATETIME(),[Blocker Tran Began At]))) + '|' +
             CONVERT(varchar(11),DATEDIFF(minute,SYSUTCDATETIME(),SYSDATETIME()))
FROM $episode ORDER BY [Entry No_] DESC;
"@
    $gc = @(($graphClock -split '\|') | ForEach-Object { $_.Trim() })
    while ($gc.Count -lt 3) { $gc += '0' }
    Check 'обе метки графа записаны по UTC, а не по местным часам' `
        ((([int]$gc[0]) -le (ClockSlackSeconds)) -and (([int]$gc[1]) -le (ClockSlackSeconds))) `
        "время события расходится с UTC на $($gc[0]) с, начало транзакции - на $($gc[1]) с при запасе $(ClockSlackSeconds), пояс сервера $($gc[2]) мин"

    Check 'класс и исход названы, а не оставлены неизвестными' (($f[0] -eq '3') -and ($f[1] -eq '3')) `
        "класс $($f[0]) при ожидаемом 3 (взаимоблокировка), исход $($f[1]) при ожидаемом 3 (откат сервером)"
    Check 'жертва и победитель те самые' ((([int]$f[2]) -eq $one[0]) -and (([int]$f[3]) -eq $one[1])) `
        "жертва $($f[2]) при ожидаемой $($one[0]), победитель $($f[3]) при ожидаемом $($one[1])"
    # Кольцо - не догадка разбора цепочки, а факт из графа: ждали оба.
    Check 'цепочка помечена замкнутой' ($f[4] -eq '1') "признак кольца $($f[4])"
    Check 'эпизод приехал законченным' (($f[5] -eq '0') -and ($f[9] -eq '1') -and (([int]$f[10]) -gt 0)) `
        "открыт $($f[5]), конец позже начала $($f[9]), ожидание $($f[10]) мс"
    Check 'таблица и род блокировки сняты с графа' (($f[6] -eq 'LockWatch Context Mark') -and ($f[7] -eq 'KEYLOCK')) `
        "таблица [$($f[6])], род [$($f[7])], ключ NAV $($f[13]), режимы [$($f[11])] и [$($f[12])]"
    Check 'отпечаток графа снят' ($f[8] -ne '') "отпечаток [$($f[8])]"
    # Текст оператора едет со значениями. Галка выключена - колонка обязана быть пустой.
    Check 'текст оператора без разрешения не собран' ($f[14] -eq '') "оператор [$($f[14])]"

    $mark1 = Scalar "SELECT CONVERT(varchar(30),[Deadlocks Read Until],126) FROM $state;"
    Check 'отметка прочитанного сдвинулась' (($mark1 -ne '') -and ($mark1 -gt $mark0)) `
        "прочитано до [$mark1] при исходном [$mark0]"

    # Второй круг ставится после паузы дольше периода чтения буфера: иначе проход буфер
    # даже не откроет, и проверка на повтор прошла бы вхолостую.
    Write-Host 'Жду, пока истечёт период чтения буфера'
    Start-Sleep -Seconds 65
    Write-Host 'Круг второй'
    $two = Invoke-Deadlock 'круг второй'
    Invoke-Pass 'проход после второго круга'

    $watchdog2 = Scalar "SELECT [Watchdog Message] FROM $state;"
    Check 'второй проход тоже отчитался' (($watchdog2 -ne '') -and ($watchdog2 -notmatch 'не прочитаны') -and ($watchdog2 -notmatch 'не работает')) `
        "сторож пишет: $watchdog2"

    # Проверяется ОТПЕЧАТОК, а не число строк. Кольцевой буфер общий: чужой круг, случившийся
    # между двумя проходами, - законная строка журнала, а не признак поломки, и считать
    # строки значило бы судить инструмент по чужой работе. Повтор ловится точнее: первый круг
    # второй проход прочитал ЗАНОВО - отбор по отметке нестрогий нарочно, - и остаться он
    # обязан одной строкой, а дублей не должно быть ни у кого.
    $rows2 = [int](Scalar "SELECT COUNT(*) FROM $episode;")
    $ids = [int](Scalar "SELECT COUNT(DISTINCT [Deadlock Id]) FROM $episode;")
    $firstAgain = [int](Scalar "SELECT COUNT(*) FROM $episode WHERE [Deadlock Id] = N'$($f[8])';")
    Check 'повторно прочитанный граф не удваивает строку' (($rows2 -eq $ids) -and ($firstAgain -eq 1)) `
        "строк в журнале $rows2 при $ids разных отпечатках, строк первого круга $firstAgain при ожидаемой 1"
    # ---------- кольцо, замолчавшее целиком ----------
    # Два соседних случая инструмент различал и до сих пор: выключенную сессию и вытеснение
    # событий из кольца. Третий - сессия работает, а выдача кольца замерла - не ловил ни
    # один из них, и на давно работающем сервере инструмент не увидел бы НИ ОДНОЙ
    # взаимоблокировки и смолчал бы (FINDINGS, раздел 62).
    #
    # Настоящую замершую выдачу здесь не устроить: её набивают часами, до четырёх миллионов
    # знаков. Устраивается ровно то СОСТОЯНИЕ, которое она создаёт: круг случился, сервер
    # его посчитал, а инструменту из кольца нового не досталось. Отметка прочитанного
    # двигается вперёд, за круг, - и проход честно не находит ничего при выросшем счёте.
    #
    # Спрашивается и вторая сторона: на проходе, который граф ПРОЧИТАЛ, слова быть не
    # должно. Без неё проверку прошёл бы сторож, ругающий кольцо всегда.
    Write-Host 'Круг третий: сервер его считает, а из кольца инструменту ничего не достаётся'
    Invoke-Deadlock 'круг третий' | Out-Null
    Invoke-Sql @"
UPDATE $state SET [Deadlocks Read Until] = DATEADD(minute,1,SYSUTCDATETIME()),
                  [Deadlocks Read At] = DATEADD(minute,-10,SYSUTCDATETIME());
"@ | Out-Null
    Invoke-Pass 'проход при замолчавшем кольце'
    $saidBlind = Scalar "SELECT [Watchdog Message] FROM $state;"
    Check 'кольцо, не отдавшее круг, названо, а отдавшее - не оболгано' `
        (($saidBlind -match 'gave back none|не отдало ни одного') -and
         ($watchdog2 -notmatch 'gave back none|не отдало ни одного')) `
        "при молчащем кольце сторож пишет: $saidBlind; на прочитанном графе писал: $watchdog2"

    $second = Scalar "SELECT TOP 1 CONVERT(varchar(11),[Victim SPID]) + '|' + CONVERT(varchar(11),[Blocker SPID]) FROM $episode ORDER BY [Entry No_] DESC;"
    $s = ($second -split '\|') | ForEach-Object { $_.Trim() }
    Check 'новый граф подхвачен, а не пропущен по отметке' ((([int]$s[0]) -eq $two[0]) -and (([int]$s[1]) -eq $two[1])) `
        "жертва $($s[0]) при ожидаемой $($two[0]), победитель $($s[1]) при ожидаемом $($two[1])"
}
finally {
    # Снимаются ТОЛЬКО свои два процесса. Чистка по имени задела бы чужие соединения на
    # той же машине, а прогон не вправе трогать ничего, кроме того, что завёл сам.
    foreach ($p in @($pa, $pb)) {
        if ($p -and -not $p.HasExited) { try { $p.Kill(); $p.WaitForExit(5000) | Out-Null } catch { } }
    }
    $cleanup = "DELETE FROM $mark WHERE [Server Instance Id] IN (-11,-12);"
    # Отметка оставляется на СЕЙЧАС, а не пустой. Пустая означает "буфер не читан вовсе",
    # и следующий же проход вычитал бы из кольца все графы разом - включая устроенные этим
    # опытом. Прогон убрал бы за собой в журнале и оставил мину в настройке.
    $cleanup += " UPDATE $state SET [Deadlocks Read Until] = GETUTCDATE(), [Deadlocks Read At] = $blankDate;"
    if (-not $KeepJournal) { $cleanup += " DELETE FROM $episode;" }
    # Опытные логины сметаются по образцу имени и В ПОРЯДКЕ: сперва пользователь базы,
    # потом сам логин - иначе сервер не отдаст логин, у которого есть пользователь.
    # Забытый логин переживёт не прогон, а всю установку.
    $cleanup += " DECLARE @drop nvarchar(max) = N'';"
    $cleanup += " SELECT @drop = @drop + N'DROP USER [' + name + N'];' FROM sys.database_principals WHERE name LIKE 'LW Probe%' AND type = 'S';"
    $cleanup += " SELECT @drop = @drop + N'DROP LOGIN [' + name + N'];' FROM sys.server_principals WHERE name LIKE 'LW Probe%' AND type = 'S';"
    $cleanup += " IF @drop <> N'' EXEC sp_executesql @drop;"
    & sqlcmd -S $Server -d $Database -E -b -l 30 -h -1 -Q $cleanup 2>&1 | Out-Null
    if ($StopInstance) { Stop-Service $service -Force }
}

Write-Host ''
Write-Host "пройдено $passed из $total"
Write-Host ''
$report | ForEach-Object { Write-Host $_ }
if ($passed -lt $total) { Fail 'взаимоблокировки из буфера не собраны' }
Write-Host 'Готово: круг разорван сервером, а журнал его записал' -ForegroundColor Green
