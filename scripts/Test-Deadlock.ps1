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
function Start-Sqlcmd([string]$name, [string]$sql) {
    $file = Join-Path $outDir $name
    [IO.File]::WriteAllText($file, (($sql -replace "`r`n", "`n") -replace "`n", "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
    Start-Process -FilePath 'sqlcmd' -PassThru -WindowStyle Hidden -ArgumentList @(
        '-S', $Server, '-d', $Database, '-E', '-l', '30', '-i', $file
    )
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
$graphCount = @"
SELECT COUNT(*) FROM (
  SELECT CONVERT(xml, t.target_data) AS x
  FROM sys.dm_xe_session_targets t
  JOIN sys.dm_xe_sessions s ON s.address = t.event_session_address
  WHERE s.name = 'system_health' AND t.target_name = 'ring_buffer') q
CROSS APPLY q.x.nodes('/RingBufferTarget/event[@name=''xml_deadlock_report'']') AS n(e);
"@

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
function Invoke-Deadlock([string]$why) {
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
        $before = [int](Scalar $graphCount)
        # Жертва назначается ключом: без него сервер выбирает по стоимости отката, и проверка
        # "жертва та самая" стала бы угадыванием.
        $a = "SET DEADLOCK_PRIORITY LOW`nBEGIN TRAN`nUPDATE $mark SET [Document No_]=N'A1' WHERE [Server Instance Id]=-11`nWAITFOR DELAY '$(CircleHold)'`nUPDATE $mark SET [Document No_]=N'A2' WHERE [Server Instance Id]=-12`nCOMMIT`n"
        $b = "SET DEADLOCK_PRIORITY HIGH`nBEGIN TRAN`nUPDATE $mark SET [Document No_]=N'B1' WHERE [Server Instance Id]=-12`nWAITFOR DELAY '$(CircleHold)'`nUPDATE $mark SET [Document No_]=N'B2' WHERE [Server Instance Id]=-11`nCOMMIT`n"
        $script:pa = Start-Sqlcmd 'dead-a.sql' $a
        $script:pb = Start-Sqlcmd 'dead-b.sql' $b
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
                if ([int](Scalar $graphCount) -gt $before) { break }
                Start-Sleep -Milliseconds 500
            }
            $after = [int](Scalar $graphCount)
            if ($after -gt $before) {
                $note = if ($attempt -gt 1) { ", попыток $attempt" } else { '' }
                Write-Host "  $why - жертва $victim, победитель $winner, графов в буфере $after$note"
                return @($victim, $winner)
            }
            Write-Host "  $why - круг с попытки $attempt не состоялся, графа в буфере нет" -ForegroundColor Yellow
        } else {
            Write-Host "  $why - сеансы опыта с попытки $attempt не опознаны" -ForegroundColor Yellow
        }
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
    Invoke-Sql @"
UPDATE $setup SET [SQL Server] = N'$Server', [Deadlocks Enabled] = 1;
$stateSeed
UPDATE $state SET [Watchdog Message] = N'',
  [Deadlocks Read Until] = GETDATE(), [Deadlocks Read At] = $blankDate;
"@ | Out-Null
    $mark0 = Scalar "SELECT CONVERT(varchar(30),[Deadlocks Read Until],126) FROM $state;"
    Invoke-Sql "DELETE FROM $episode;" | Out-Null
    Invoke-Sql "DELETE FROM $mark WHERE [Server Instance Id] IN (-11,-12);" | Out-Null
    Invoke-Sql @"
INSERT INTO $mark ([Server Instance Id],[Session Id],[User Id],[Company Name],[Table No_],[Document No_],[Marked At])
VALUES (-11,-11,N'STAND',N'$Company',0,N'DEAD-ONE',GETDATE()),
       (-12,-12,N'STAND',N'$Company',0,N'DEAD-TWO',GETDATE());
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
  CONVERT(varchar(11),[NAV Key No_]) + '|' + [Blocker Statement]
FROM $episode ORDER BY [Entry No_] DESC;
"@
    $f = ($row -split '\|') | ForEach-Object { $_.Trim() }
    if ($f.Count -lt 15) { Fail "строка журнала пришла неполной: $($f.Count) колонок" }

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

    $rows2 = [int](Scalar "SELECT COUNT(*) FROM $episode;")
    $ids = [int](Scalar "SELECT COUNT(DISTINCT [Deadlock Id]) FROM $episode;")
    Check 'повторно прочитанный граф не удваивает строку' (($rows2 -eq 2) -and ($ids -eq 2)) `
        "строк в журнале $rows2 при ожидаемых 2, разных отпечатков $ids"
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
    $cleanup += " UPDATE $state SET [Deadlocks Read Until] = GETDATE(), [Deadlocks Read At] = $blankDate;"
    if (-not $KeepJournal) { $cleanup += " DELETE FROM $episode;" }
    & sqlcmd -S $Server -d $Database -E -b -l 30 -h -1 -Q $cleanup 2>&1 | Out-Null
    if ($StopInstance) { Stop-Service $service -Force }
}

Write-Host ''
Write-Host "пройдено $passed из $total"
Write-Host ''
$report | ForEach-Object { Write-Host $_ }
if ($passed -lt $total) { Fail 'взаимоблокировки из буфера не собраны' }
Write-Host 'Готово: круг разорван сервером, а журнал его записал' -ForegroundColor Green
