#requires -Version 7
<#
.SYNOPSIS
    Цена прохода ЦЕЛИКОМ и под нагрузкой: сотня настоящих ждущих, живая очередь сервера,
    замер того, что делает фоновая задача, а не его половин по отдельности.

.DESCRIPTION
    Съём с DMV и запись в журнал меряны порознь: 12 мс при двухстах ждущих и 441 мс на
    пятистах строках. Вместе они делят одно соединение и один проход, и складывать два
    замера в уме - это не замер, а надежда. Здесь проход меряет сам себя: NAV пишет
    длительность в настройку, оттуда она и читается.

    Ждущие делаются НАСТОЯЩИМИ: один держатель берёт строку своей же таблицы, сотня
    соединений становится за ним в очередь. Все они живут в одном процессе Windows
    PowerShell 5.1 - там System.Data.SqlClient идёт с платформой, и сотня соединений
    стоит одного процесса вместо сотни.

.PARAMETER Waiters
    Сколько ждущих устроить. По умолчанию сто: столько уже похоже на шторм, но ещё не
    съедает рабочие потоки сервера на тесном стенде.

.EXAMPLE
    pwsh scripts/Test-Load.ps1 -Waiters 100
#>
[CmdletBinding()]
param(
    [string] $Server   = 'localhost',
    [string] $Database = $env:LW_DATABASE,
    [string] $Instance = $env:LW_INSTANCE,
    [string] $Company  = $env:LW_COMPANY,
    [int]    $Waiters  = 100,
    [int]    $TaskCodeunitId = 110232,
    [int]    $PassCodeunitId = 110230,
    [switch] $StopInstance
)

$ErrorActionPreference = 'Stop'
$root   = Split-Path -Parent $PSScriptRoot
$outDir = Join-Path $root 'out'
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir | Out-Null }

function Fail([string]$message) { Write-Host "ОТКАЗ: $message" -ForegroundColor Red; exit 1 }
function Warn-Cleanup([string]$message) { Write-Host "ВНИМАНИЕ: $message" -ForegroundColor Red }
function Invoke-CleanupSql([string]$query, [string]$why) {
    # -b обязателен: без него sqlcmd отдаёт НОЛЬ и на ошибке SQL, и уборка, не выполнившаяся
    # вовсе, выглядела бы сделанной. Отказ уборки прогон не роняет - о нём говорят словами:
    # к этому месту он либо уже отработал, либо отказал, и решает не она.
    $answer = & sqlcmd -S $Server -d $Database -E -b -l 30 -h -1 -Q $query 2>&1
    if ($LASTEXITCODE -ne 0) { Warn-Cleanup "$why не убралось: $(($answer -join ' ') -replace '\s+', ' ')" }
}
if (-not $Database) { Fail 'не задано имя базы: переменная LW_DATABASE' }
if (-not $Instance) { Fail 'не задан экземпляр службы: переменная LW_INSTANCE' }
if (-not $Company)  { Fail 'не задана компания: переменная LW_COMPANY' }

$episode = "[$Company`$LockWatch Episode]"
# Настройка и состояние - одни на базу, и приставки компании в их SQL-имени нет.
$setup   = '[LockWatch Setup]'
$state   = '[LockWatch Watchdog]'
# Спор идёт за строки таблицы контекста: настоящая её таблица начинается с номера 110232,
# а опытные строки лежат с отрицательными номерами и выключены. В журнале же таблица
# называется без приставки компании - так её разбирает SplitSqlObjectName.
$context = "[$Company`$LockWatch Context Table]"
$contextName = 'LockWatch Context Table'
$service = "MicrosoftDynamicsNavServer`$$Instance"

function Invoke-Sql([string]$query) {
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
function WaitingNow { [int](Scalar "SELECT COUNT(*) FROM sys.dm_os_waiting_tasks WHERE wait_type LIKE 'LCK[_]%';") }

# Потолок, который превысит ЛЮБОЙ проход. Единица - не "поменьше на глазок", а наименьшее,
# что принимает поле (MinValue=1): проход по пустой очереди стоит десяток миллисекунд, и
# ошибиться тут можно только в одну сторону.
function CeilingProbeMs { 1 }

$passed = 0; $total = 0; $report = @(); $timings = @()
function Check([string]$what, [bool]$ok, [string]$detail) {
    $script:total++
    if ($ok) { $script:passed++; $verdict = 'пройдено' } else { $verdict = 'ПРОВАЛ  ' }
    $script:report += "$verdict $what"
    $script:report += "         $detail"
}
function Wait-For([scriptblock]$condition, [int]$seconds) {
    $deadline = (Get-Date).AddSeconds($seconds)
    while ((Get-Date) -lt $deadline) {
        if (& $condition) { return $true }
        Start-Sleep -Milliseconds 300
    }
    return $false
}

$ps51 = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$navImport = "Import-Module 'C:\Program Files\Microsoft Dynamics NAV\110\Service\NavAdminTool.ps1' -DisableNameChecking -WarningAction SilentlyContinue | Out-Null"
function Write-Ps51([string]$path, [string]$body) {
    [IO.File]::WriteAllText($path, (($body -replace "`r`n", "`n") -replace "`n", "`r`n"), (New-Object System.Text.UTF8Encoding($true)))
}

$contextEsc = $context.Replace('$', '`$')
$stopFile = Join-Path $outDir 'load-stop.flag'
$loadFile = Join-Path $outDir 'load-waiters.ps1'
$crowd = $null
# Ноль значит "не успели снять": уборка тогда потолка не трогает вовсе, а не пишет ноль.
$ceilingWas = 0
# Пусто - "не прочиталось": тогда возвращается единица, но об этом говорится вслух.
$deadlocksWas = ''
# Порог записи в журнал на время опыта снимается: толпа встаёт в очередь постепенно, и
# последние ждущие к первому проходу ждали меньше двух секунд. С порогом по умолчанию
# они не дали бы строк вовсе, а проверки считают ЭПИЗОДЫ, а не увиденную очередь.
$minWaitWas = ''
# Пусто - "не прочиталось". Фоновый сторож на время замера гасится: его проход переписал бы
# строку состояния между нашим проходом и чтением её чисел, и измеренная цена оказалась бы
# чужой. Погашенный выключатель задачу не воскрешает - она просыпается, видит "выключено" и
# кончается сама.
$enabledWas = ''
# Трогали ли выключатель ВООБЩЕ. Сцена может отказать до того, как настройка прочитана, - и
# тогда уборка не вправе гасить чужой заведённый сторож по своему усмотрению.
$enabledTouched = $false

# Один процесс на всю толпу. Сотня процессов sqlcmd съела бы память рабочей станции, а
# память на этом стенде уже однажды уронила SQL Server: он перестал выдавать рабочие
# потоки, и вход в него начал отваливаться по таймауту.
# Параметров у скрипта толпы нет вовсе, значения вписаны в него при создании. Start-Process
# склеивает -ArgumentList пробелом БЕЗ кавычек, и имя таблицы в скобках и с пробелами
# рассыпалось бы на аргументы: процесс запускается, тут же тихо умирает, а выглядит это
# как "очередь не набралась".
Write-Ps51 $loadFile @"
`$ErrorActionPreference = 'Stop'
`$log = '$outDir\load-crowd.log'
try {
    `$conns = New-Object System.Collections.ArrayList
    `$cs = 'Server=$Server;Database=$Database;Trusted_Connection=True;Connect Timeout=15'
    `$hold = New-Object System.Data.SqlClient.SqlConnection(`$cs)
    `$hold.Open()
    `$c = `$hold.CreateCommand()
    `$c.CommandText = "SET LOCK_TIMEOUT -1; BEGIN TRAN; UPDATE $contextEsc SET [Table Name] = N'HELD' WHERE [Table No_] = -1;"
    `$c.ExecuteNonQuery() | Out-Null
    [void]`$conns.Add(`$hold)
    for (`$i = 0; `$i -lt $Waiters; `$i++) {
        `$w = New-Object System.Data.SqlClient.SqlConnection(`$cs + ';Asynchronous Processing=True')
        `$w.Open()
        `$cmd = `$w.CreateCommand()
        `$cmd.CommandTimeout = 0
        `$cmd.CommandText = "SET LOCK_TIMEOUT -1; BEGIN TRAN; UPDATE $contextEsc SET [Table Name] = N'WANT' WHERE [Table No_] = -1; ROLLBACK;"
        `$cmd.BeginExecuteNonQuery() | Out-Null
        [void]`$conns.Add(`$w)
    }
    'crowd ready: ' + `$conns.Count | Out-File -FilePath `$log -Encoding utf8
    while (-not (Test-Path '$stopFile')) { Start-Sleep -Milliseconds 300 }
    foreach (`$x in `$conns) { try { `$x.Close() } catch { } }
} catch {
    `$_.Exception.ToString() | Out-File -FilePath `$log -Encoding utf8
    exit 1
}
"@

function Invoke-Pass {
    $file = Join-Path $outDir 'invoke-load-pass.ps1'
    Write-Ps51 $file @"
`$ErrorActionPreference = 'Stop'
$navImport
Invoke-NAVCodeunit -ServerInstance $Instance -CompanyName '$Company' -CodeunitId $PassCodeunitId -MethodName RunPass -ErrorAction Stop
"@
    $log = & $ps51 -NoProfile -ExecutionPolicy Bypass -File $file 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { Fail "проход не отработал:`n$log" }
    $row = Scalar "SELECT CONVERT(varchar(11),[Last Pass (ms)]) + '|' + CONVERT(varchar(11),[Last Pass Rows]) + '|' + CONVERT(varchar(2),[Last Pass Truncated]) FROM $state;"
    return ($row -split '\|') | ForEach-Object { $_.Trim() }
}

try {
    Write-Host "Подготовка стенда, ждущих будет $Waiters"
    if (Test-Path $stopFile) { Remove-Item $stopFile -Force }
    if ((Get-Service $service).Status -ne 'Running') { Start-Service $service }
    # Сбор взаимоблокировок на время опыта выключается. Он берёт графы из КОЛЬЦЕВОГО
    # БУФЕРА сервера, а туда они попадают от кого угодно и когда угодно - хоть от прошлого
    # прогона, хоть от чужой работы на той же базе. Строка в журнале получилась бы законной,
    # но проверка "эпизод заведён ровно один" считает строки, и опыт судил бы инструмент по
    # чужим кругам. Две дороги - два прогона, и каждый отвечает только за свою.
    #
    # Здесь у этого есть и вторая причина: разбор буфера стоит около 150 мс, и раз в минуту
    # он лёг бы в худший проход. Цена буфера измерена отдельно и известна; смешивать её с
    # потолком NAV-половины значило бы мерить потолок тем, что от нагрузки не зависит.
    # Потолок опускается ЗДЕСЬ, до общего перезапуска. Правку настройки мимо NAV работающая
    # служба не видит - строка лежит у неё в кэше, - а отдельный перезапуск ради одной цифры
    # стоил бы дороже самой сцены.
    $ceilingWas = [int](Scalar "SELECT [Max Pass (ms)] FROM $setup;")
    if ($ceilingWas -le 0) { Fail 'потолок прохода в настройке не задан - сцену потолка мерить нечем' }
    # Выключатель сбора взаимоблокировок гасится на время опыта и возвращается ТЕМ, каким
    # его нашли: единица тут - догадка о чужой настройке, а не находка.
    $deadlocksWas = Scalar "SELECT CONVERT(varchar(2),[Deadlocks Enabled]) FROM $setup;"
    $minWaitWas = Scalar "SELECT CONVERT(varchar(11),[Journal Min Wait (ms)]) FROM $setup;"
    $enabledWas = Scalar "SELECT CONVERT(varchar(2),[Enabled]) FROM $setup;"
    Invoke-Sql "UPDATE $setup SET [SQL Server] = N'$Server', [Enabled] = 0, [Deadlocks Enabled] = 0, [Journal Min Wait (ms)] = 0, [Max Pass (ms)] = $(CeilingProbeMs);" | Out-Null
    $enabledTouched = $true
    Invoke-Sql "DELETE FROM $episode;" | Out-Null
    Invoke-Sql "DELETE FROM $context WHERE [Table No_] BETWEEN -6000 AND -1;" | Out-Null
    Invoke-Sql @"
INSERT INTO $context ([Table No_],[Table Name],[Document Field No_],[Document Field Name],[Document Caption],[Enabled])
VALUES (-1,N'LW Fixture',0,N'',N'',0);
"@ | Out-Null

    Write-Host "  перезапускаю службу $Instance и жду ответа порта управления"
    Restart-Service $service -Force
    $probeFile = Join-Path $outDir 'wait-nav.ps1'
    Write-Ps51 $probeFile @"
$navImport
`$deadline = (Get-Date).AddMinutes(6)
while ((Get-Date) -lt `$deadline) {
    try { Get-NAVServerSession -ServerInstance $Instance -ErrorAction Stop | Out-Null; exit 0 } catch { Start-Sleep -Seconds 5 }
}
exit 1
"@
    & $ps51 -NoProfile -ExecutionPolicy Bypass -File $probeFile | Out-Null
    if ($LASTEXITCODE -ne 0) { Fail "экземпляр $Instance не ответил по порту управления" }

    # ---------- потолок прохода: объявленное число обязано сравниваться с настоящим ----------
    # Потолок объявлен настройкой с первого дня, а сравнивал его с настоящей ценой только
    # этот прогон - снаружи и на стенде разработчика. На установке заказчика прогонов нет, и
    # проход, съедающий период целиком, выглядел там ровно как дешёвый: число ложилось в
    # строку состояния и молчало. Теперь сравнивает сам проход, и спрашивается это здесь.
    #
    # Спрашиваются ОБЕ стороны. Сказать о превышении - половина обещания; вторая половина -
    # ПРОМОЛЧАТЬ, когда его не было, и без неё проверку прошёл бы сторож, жалующийся всегда.
    # На такого перестают смотреть через неделю, и это хуже молчания.
    #
    # Арифметика самой границы проверяется без базы, в мерном прогоне разбора: там
    # спрашиваются и равенство потолку, и снятый потолок. Здесь спрашивается ДРУГОЕ - что
    # проход зовёт её со своим временем и своим потолком. Вынь вызов - мерный прогон
    # останется зелёным весь, а сторож замолчит.
    Write-Host "Сцена потолка: опущен до $(CeilingProbeMs) мс, столько не стоит ни один проход"
    Invoke-Pass | Out-Null
    $saidOver = Scalar "SELECT [Watchdog Message] FROM $state;"
    Invoke-Sql "UPDATE $setup SET [Max Pass (ms)] = $ceilingWas;" | Out-Null
    Restart-Service $service -Force
    & $ps51 -NoProfile -ExecutionPolicy Bypass -File $probeFile | Out-Null
    if ($LASTEXITCODE -ne 0) { Fail "экземпляр $Instance не ответил по порту управления" }
    Invoke-Pass | Out-Null
    $saidQuiet = Scalar "SELECT [Watchdog Message] FROM $state;"
    Check 'проход сам сравнивает себя с объявленным потолком и молчит, когда уложился' `
        (($saidOver -match 'declared ceiling|объявленном потолке') -and
         ($saidQuiet -notmatch 'declared ceiling|объявленном потолке')) `
        "при потолке $(CeilingProbeMs) мс сторож пишет: $saidOver; при потолке $ceilingWas мс: $saidQuiet"

    Write-Host 'Собираю толпу'
    $crowdLog = Join-Path $outDir 'load-crowd.log'
    if (Test-Path $crowdLog) { Remove-Item $crowdLog -Force }
    $crowd = Start-Process -FilePath $ps51 -PassThru -WindowStyle Hidden -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $loadFile
    )
    if (-not (Wait-For { (WaitingNow) -ge $Waiters } 180)) {
        $why = if (Test-Path $crowdLog) { (Get-Content $crowdLog -Raw).Trim() } else { 'толпа ничего не сказала' }
        Fail "очередь так и не набралась: ждущих $(WaitingNow) из $Waiters - опыт не удался, инструмент тут ни при чём.`n$why"
    }
    Write-Host "  ждущих в очереди сервера: $(WaitingNow)"

    Write-Host 'Проход первый - все эпизоды заводятся'
    $first = Invoke-Pass
    $timings += "открытие: {0} мс на {1} строк, {2} мкс на строку" -f $first[0], $first[1], [int]([int]$first[0] * 1000 / [Math]::Max(1,[int]$first[1]))
    Check 'проход увидел всю очередь' (([int]$first[1]) -ge $Waiters) "строк в проходе $($first[1]) при $Waiters ждущих, усечён $($first[2])"

    # Проходов обновления несколько нарочно. Первый проход после перезапуска службы несёт
    # разовую цену, которой в установившемся режиме нет вовсе: платформа поднимает сборку
    # System.Data, соединение открывается впервые, сервер компилирует планы запросов.
    # Выдать её за цену наблюдения значило бы напугать заказчика тем, чего не будет.
    Write-Host 'Проходы обновления - установившийся режим'
    $updateMs = @()
    for ($i = 1; $i -le 4; $i++) {
        $second = Invoke-Pass
        $updateMs += [int]$second[0]
        $timings += "обновление {0}: {1} мс на {2} строк, {3} мкс на строку" -f $i, $second[0], $second[1], [int]([int]$second[0] * 1000 / [Math]::Max(1,[int]$second[1]))
    }
    $steady = ($updateMs | Measure-Object -Minimum).Minimum
    $rows = [int](Scalar "SELECT COUNT(*) FROM $episode WHERE [NAV Table Name] = N'$contextName';")
    Check 'второй проход не наплодил строк' ($rows -eq [int]$first[1]) "строк в журнале по нашей таблице $rows при $($first[1]) в первом проходе"

    # Толпа стоит за ОДНОЙ строкой, и в журнале это обязано выглядеть одной бедой: у всех
    # строк один и тот же виновник, и он ни в одной из них не жертва. Числа "жертв за
    # головой" и "глубины" в v2 нет - цепочка не размечается полями, а СВОРАЧИВАЕТСЯ:
    # CollapseRow подставляет в строку ждущего голову, и по журналу видно, кто настоящий
    # держатель. Проверяется поэтому то же обещание, но его нынешними средствами.
    $heads  = [int](Scalar "SELECT COUNT(DISTINCT [Blocker SPID]) FROM $episode WHERE [NAV Table Name] = N'$contextName';")
    $headSpid = Scalar "SELECT TOP 1 CONVERT(varchar(11),[Blocker SPID]) FROM $episode WHERE [NAV Table Name] = N'$contextName' ORDER BY [Entry No_];"
    $selfBlocked = [int](Scalar "SELECT COUNT(*) FROM $episode WHERE [NAV Table Name] = N'$contextName' AND [Blocker SPID] = [Victim SPID];")
    Check 'одна беда сосчитана как одна' (($heads -eq 1) -and ($selfBlocked -eq 0) -and (([int]$headSpid) -gt 0)) `
        "виновников $heads (SPID $headSpid), жертв за ним $rows, строк, где виновник и жертва один сеанс: $selfBlocked"

    Write-Host 'Отпускаю толпу'
    New-Item -ItemType File -Path $stopFile -Force | Out-Null
    if (-not (Wait-For { (WaitingNow) -eq 0 } 120)) { Fail 'очередь не разошлась' }

    Write-Host 'Проход третий - все эпизоды закрываются'
    $third = Invoke-Pass
    $timings += "закрытие: {0} мс на {1} строк" -f $third[0], $rows
    $open = [int](Scalar "SELECT COUNT(*) FROM $episode WHERE [Open] = 1 AND [NAV Table Name] = N'$contextName';")
    Check 'ушедшая очередь закрыла все эпизоды' ($open -eq 0) "открытых осталось $open из $rows"

    $worst = [Math]::Max([Math]::Max([int]$first[0], ($updateMs | Measure-Object -Maximum).Maximum), [int]$third[0])
    $ceiling = [int](Scalar "SELECT [Max Pass (ms)] FROM $setup;")
    Check 'проход целиком укладывается в объявленный потолок' ($worst -le $ceiling) `
        "худший проход $worst мс при потолке $ceiling"
    # Разовая цена первого прохода ПЕЧАТАЕТСЯ, но не проверяется, и это не упущение.
    #
    # Здесь стояла проверка "установившийся проход заметно дешевле первого" с условием
    # steady <= first, где steady - МИНИМУМ из четырёх обновлений. Условие это выполняется
    # всегда, кроме случая, когда все четыре прохода оказались дороже первого, то есть
    # никогда. Имя обещало "заметно дешевле", код спрашивал "не дороже".
    #
    # Доказано замером 11.09.2026: перед первым проходом поставили прогревочный, холодного
    # старта не стало, надбавка упала с 1930 мс до 24 - и прогон остался зелёным, 6 из 6.
    # Проверять было нечего.
    #
    # Проверкой это и не может быть: величина холодного старта - свойство МАШИНЫ, а не
    # инструмента. На быстрой машине его нет вовсе, и красный цвет означал бы там удачу.
    # Что действительно обещано - что проход укладывается в потолок, - спрашивает проверка
    # выше, и спрашивает она ХУДШИЙ проход, первый в том числе.
    $timings += "разовая надбавка первого прохода: {0} мс (первый {1}, установившийся {2})" -f `
        ([int]$first[0] - $steady), $first[0], $steady
}
finally {
    New-Item -ItemType File -Path $stopFile -Force -ErrorAction SilentlyContinue | Out-Null
    if ($crowd -and -not $crowd.HasExited) { Start-Sleep -Seconds 2; if (-not $crowd.HasExited) { $crowd.Kill() } }
    # Выключатель сбора и потолок возвращаются НАЙДЕННЫМИ: прогон гасит сбор и опускает
    # потолок на время опыта, и вернуть им заводские значения значило бы судить о стенде по
    # своей привычке. Потолок возвращается и здесь: прогон, умерший посреди сцены, оставил бы
    # в настройке единицу, и следующий сказал бы "проход не уложился" на ровном месте.
    $deadlocksSet = if ($deadlocksWas -match '^\d+$') { $deadlocksWas } else { 1 }
    if ($deadlocksWas -notmatch '^\d+$') {
        Warn-Cleanup 'прежнее значение [Deadlocks Enabled] прочитать не удалось - вернул 1'
    }
    # Выключатель сторожа возвращается найденным. Гасился он как условие замера, а не потому,
    # что установке так лучше: с заведённой цепочкой её проход переписал бы строку состояния
    # между нашим проходом и чтением чисел. Погашенная задача просыпается, видит "выключено"
    # и кончается сама, а в очереди после неё ничего не остаётся - поэтому найденную единицу
    # мало вернуть галкой, цепочку надо ЗАВЕСТИ ЗАНОВО, иначе галка будет стоять над мёртвой
    # цепочкой. Заводим её ниже, когда служба ещё работает.
    $enabledBack = if ($enabledWas -match '^\d+$') { [int]$enabledWas } else { 0 }
    if ($enabledWas -notmatch '^\d+$') {
        Warn-Cleanup 'прежнее значение [Enabled] прочитать не удалось - вернул 0'
    }
    $setParts = @("[Deadlocks Enabled] = $deadlocksSet")
    if ($ceilingWas -gt 0) { $setParts += "[Max Pass (ms)] = $ceilingWas" }
    # Порог записи возвращается найденным, как и прочие поля настроек: ноль вернуть вместо
    # него значило бы оставить установку писать всё после прогона, который его снял.
    if ($minWaitWas -match '^\d+$') {
        $setParts += "[Journal Min Wait (ms)] = $minWaitWas"
    } else {
        Warn-Cleanup 'прежнее значение [Journal Min Wait (ms)] прочитать не удалось - порог оставлен нулём'
    }
    # Выключатель трогается только тогда, когда его вправду гасили: сцена могла отказать ДО
    # правки, и гасить чужой заведённый сторож в уборке было бы самоуправством.
    if ($enabledTouched) { $setParts += "[Enabled] = $enabledBack" }
    $restore = "DELETE FROM $context WHERE [Table No_] BETWEEN -6000 AND -1; DELETE FROM $episode; " +
               "UPDATE $setup SET " + ($setParts -join ', ')
    Invoke-CleanupSql "$restore;" 'уборка за прогоном'
    # Цепочка возвращается НАСТОЯЩИМ путём. Одной галки мало: задача прежней цепочки уже
    # проснулась и погасла, а новой никто не поставил. StartWatch читает строку из базы
    # (SELECTLATESTVERSION) и переживает правку мимо NAV - ту самую, которой мы её гасили.
    if ($enabledTouched -and ($enabledBack -eq 1)) {
        if ($StopInstance) {
            Warn-Cleanup 'сторож был заведён, а экземпляр по просьбе останавливается: цепочка не перевзведена, галка оставлена включённой'
        } else {
            $armFile = Join-Path $outDir 'rearm-watch.ps1'
            Write-Ps51 $armFile @"
`$ErrorActionPreference = 'Stop'
$navImport
Invoke-NAVCodeunit -ServerInstance $Instance -CompanyName '$Company' -CodeunitId $TaskCodeunitId -MethodName StartWatch -ErrorAction Stop
"@
            $armLog = & $ps51 -NoProfile -ExecutionPolicy Bypass -File $armFile 2>&1 | Out-String
            if ($LASTEXITCODE -ne 0) {
                Warn-Cleanup "сторож был заведён, а вернуть его цепочку не вышло: $(($armLog -replace '\s+', ' ').Trim())"
            }
        }
    }
    if (Test-Path $stopFile) { Remove-Item $stopFile -Force }
    if ($StopInstance) { Stop-Service $service -Force }
}

Write-Host ''
Write-Host "пройдено $passed из $total"
Write-Host ''
$report | ForEach-Object { Write-Host $_ }
Write-Host ''
$timings | ForEach-Object { Write-Host $_ }
if ($passed -lt $total) { Fail 'нагрузочный прогон не пройден' }
Write-Host 'Готово: проход измерен целиком и под нагрузкой' -ForegroundColor Green
