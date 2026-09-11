#requires -Version 7
<#
.SYNOPSIS
    Снятие инструмента: что уходит, в каком порядке и что уйти не может. Без ключа -Yes
    ничего не удаляет, а только перечисляет след - и это же ответ на вопрос службы
    безопасности «что от него останется».

.DESCRIPTION
    Спрашивают обычно не «что он делает», а «что после него остаётся», и ответ на это
    обязан быть проверяемым. Поэтому снятие здесь не список действий, а прогон: он
    убирает, потом СВЕРЯЕТ по базе, что убралось, и судит себя сам.

    Порядок не произволен, и у каждого шага довод.

    **Сторож снимается первым.** Строка задачи лежит в общей на базу таблице планировщика
    и переживает удаление объектов. Измерено на стенде: проснувшись к несуществующему
    кодюниту, задача кладёт в журнал событий Windows ОШИБКУ с трассировкой стека -
    NavNCLMetadataObjectNotFoundException, категория TaskScheduling, - после чего платформа
    убирает строку сама. Бесконечного повторения нет, и это лучше, чем ожидалось; но ошибка
    появляется на пустом месте и уже после того, как инструмент сняли, а разбирать её будет
    тот, у кого его больше нет.

    **Врезка в меню снимается до удаления страниц.** Иначе остаётся окно, в котором чужое
    меню ссылается на объекты, которых уже нет.

    **Собранный переходник уходит раньше прочих объектов.** Он единственный исполняется
    на чужой записи, и пока он есть, подписка срабатывает посреди разборки.

    **Свои объекты удаляются в обратном порядке сборки**: страницы, кодюниты, таблицы.
    Вместе с таблицами уходят и ДАННЫЕ - журнал эпизодов, тревоги, охват и настройка.
    Обратного хода у этого нет, поэтому без ключа -Yes скрипт только показывает, что снял
    бы, и ничего не трогает.

    Вердикт снимается из базы, а не из лога finsql: удаление несуществующего объекта - не
    отказ, а пустое место, и различать эти два случая по тексту в логе значит гадать.

    **Чего снять нельзя**, перечислено отдельно и со снятым не смешивается. Источник
    событий Windows заводится администратором и живёт в реестре машины; серверная сессия
    Extended Events, если ключ мониторинга когда-нибудь включали, переживает снятие
    инструмента и уходит только обратным выключением ключа.

.EXAMPLE
    pwsh scripts/Uninstall-LockWatch.ps1

.EXAMPLE
    pwsh scripts/Uninstall-LockWatch.ps1 -Yes -AdapterObjectNo 110250 -MenuTargetId 1090
#>
[CmdletBinding()]
param(
    [string] $Server   = 'localhost',
    [string] $Database = $env:LW_DATABASE,
    [string] $Instance = $env:LW_INSTANCE,
    [string] $Company  = $env:LW_COMPANY,
    [int]    $MgmtPort = 7145,
    [int]    $AdapterObjectNo = 0,
    [int]    $MenuTargetId    = 0,
    [int]    $TimeoutMinutes  = 3,
    [switch] $Yes
)

$ErrorActionPreference = 'Stop'
$root   = Split-Path -Parent $PSScriptRoot
$outDir = Join-Path $root 'out'
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir | Out-Null }

function Fail([string]$message) { Write-Host "ОТКАЗ: $message" -ForegroundColor Red; exit 1 }
if (-not $Database) { Fail 'не задано имя базы: переменная LW_DATABASE' }
if (-not $Instance) { Fail 'не задан экземпляр службы: переменная LW_INSTANCE' }
if (-not $Company)  { Fail 'не задана компания: переменная LW_COMPANY' }

# Диапазон объявлен за инструментом целиком, и удаляется он тоже целиком, а не по списку
# номеров. Список пришлось бы править вместе с каждым новым объектом, и забытый в нём
# номер остался бы на установке навсегда - при зелёном отчёте о снятии.
$rangeFrom = 110230
$rangeTo   = 110249

# Задачу ставит кодюнит сторожа, и он же её снимает. Отбор по ДИАПАЗОНУ, а не по одному
# номеру: если фоновых задач когда-нибудь станет две, вторая иначе останется в таблице.
$tasksTable = '[dbo].[Scheduled Task]'
$service    = "MicrosoftDynamicsNavServer`$$Instance"
$finsql     = 'C:\Program Files (x86)\Microsoft Dynamics NAV\110\RoleTailored Client\finsql.exe'
$ps51       = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$nodesFile  = Join-Path $root 'templates\menu-nodes.txt'
if (-not (Test-Path $finsql)) { Fail "не найден finsql: $finsql" }

function Invoke-Sql([string]$query) {
    # -b обязателен: без него sqlcmd возвращает НОЛЬ и на ошибке SQL, и проверка кода
    # возврата проходит вхолостую, а запрос при этом не выполнен вовсе.
    $answer = & sqlcmd -S $Server -d $Database -E -b -l 30 -w 500 -W -s '|' -h -1 -Q "SET NOCOUNT ON; $query" 2>&1
    if ($LASTEXITCODE -ne 0) { Fail "SQL не выполнился: $($answer -join ' ')" }
    return ,@($answer | Where-Object { $_ -and ($_ -notmatch '^\(') })
}
function Scalar([string]$query) {
    $rows = Invoke-Sql $query
    if ($rows.Count -eq 0) { return '' }
    return "$($rows[0])".Trim()
}
function Count-Sql([string]$query) { [int](Scalar $query) }

function Invoke-Finsql([string]$argLine, [string]$logName) {
    # Лог здесь не вердикт, а заметка: finsql пишет в него и тогда, когда удалять было
    # нечего. Судит по базе сверка в конце, а текст лога просто показывается человеку.
    $log = Join-Path $outDir $logName
    if (Test-Path $log) { Remove-Item $log -Force }
    $navArgs = "ServerName=$Server,Database=$Database,NTAuthentication=1,LogFile=`"$log`""
    $process = Start-Process -FilePath $finsql -PassThru -NoNewWindow -ArgumentList "$argLine,$navArgs"
    if (-not $process.WaitForExit($TimeoutMinutes * 60000)) {
        $process.Kill()
        Fail "finsql завис дольше $TimeoutMinutes мин и снят. Обычная причина - невидимое модальное окно"
    }
    if (Test-Path $log) {
        $text = ([System.Text.Encoding]::GetEncoding(866).GetString([IO.File]::ReadAllBytes($log))).Trim()
        if ($text) { Write-Host "  finsql сказал: $($text -replace '\s+', ' ')" -ForegroundColor DarkGray }
    }
}

function Objects-In-Range { Count-Sql "SELECT COUNT(*) FROM [dbo].[Object] WHERE [ID] BETWEEN $rangeFrom AND $rangeTo;" }
function Footprint {
    # У таблицы в Object ДВЕ строки: сам объект и отдельно её данные. Сложить их и назвать
    # сумму «объектами» значит соврать в описи - а читают её именно как опись.
    $names = @{ '0' = 'данные таблиц'; '1' = 'таблиц'; '3' = 'отчётов'; '5' = 'кодюнитов';
                '6' = 'XMLport'; '7' = 'меню'; '8' = 'страниц'; '9' = 'запросов' }
    $out = @()
    foreach ($row in (Invoke-Sql "SELECT [Type], COUNT(*) FROM [dbo].[Object] WHERE [ID] BETWEEN $rangeFrom AND $rangeTo GROUP BY [Type] ORDER BY [Type];")) {
        $parts = "$row".Split('|')
        if ($parts.Count -lt 2) { continue }
        $kind = $parts[0].Trim()
        $name = if ($names.ContainsKey($kind)) { $names[$kind] } else { "тип $kind" }
        $out += "$($parts[1].Trim()) $name"
    }
    if ($out.Count -eq 0) { return 'ничего' }
    return ($out -join ', ')
}
function Task-Rows        { Count-Sql "SELECT COUNT(*) FROM $tasksTable WHERE [Run Codeunit] BETWEEN $rangeFrom AND $rangeTo;" }
# Сколько ждать тишины в планировщике после остановки сторожа. Строка идущей задачи уходит
# тогда, когда проход кончится; на тихой базе проход стоит десятки миллисекунд, а на занятой
# упирается в предел ожидания блокировки у NAV - десять секунд. Берём вдвое: ждать здесь
# дёшево и один раз, а поторопиться - значит объявить снятие неполным на ровном месте.
function WatchQuietSeconds { 20 }
function Sql-Tables       { Count-Sql "SELECT COUNT(*) FROM sys.tables WHERE [name] LIKE '%LockWatch%';" }
# Сколько строк лежит во ВСЕХ наших таблицах, а не в одном журнале. Обещание "данные ушли
# вместе с таблицами" журналом мерить нельзя: он пуст у всякого, кто ещё не видел ни одной
# блокировки, и на смете 11.09.2026 рядом стояло ровно это - "строк в журнале эпизодов: 0".
# Строки настройки, контекста и состояния есть у любой живой установки, и ноль здесь
# означает одно: сносить было нечего.
function Our-Rows {
    Count-Sql "SELECT ISNULL(SUM(p.[rows]),0) FROM sys.tables t JOIN sys.partitions p ON p.object_id = t.object_id AND p.index_id IN (0,1) WHERE t.[name] LIKE '%LockWatch%';"
}
# Собранный переходник ставится ВНЕ объявленного диапазона - номер ему выбирают под
# установку. Забытый при снятии, он остаётся подписан на чужую таблицу, потребителя у
# которой уже нет: подписка срабатывает на каждой записи и падает. Ищется он по имени -
# сборщик зовёт его "LockWatch Adapter <номер таблицы>", и это единственный след, который
# не зависит от того, вспомнил ли человек номер.
function Named-Objects { Count-Sql "SELECT COUNT(*) FROM [dbo].[Object] WHERE [Name] LIKE 'LockWatch%';" }
function Named-Outside {
    $rows = Invoke-Sql "SELECT [Type], [ID], [Name] FROM [dbo].[Object] WHERE [Name] LIKE 'LockWatch%' AND ([ID] < $rangeFrom OR [ID] > $rangeTo) ORDER BY [ID];"
    return @($rows | ForEach-Object { ("$_" -replace '\s*\|\s*', ' ').Trim() })
}
function Episode-Rows {
    # -1 значит "таблицы нет вовсе", и это не то же самое, что "строк ноль".
    $name = "$Company`$LockWatch Episode"
    if ((Count-Sql "SELECT COUNT(*) FROM sys.tables WHERE [name] = N'$name';") -eq 0) { return -1 }
    Count-Sql "SELECT COUNT(*) FROM [$name];"
}
function Adapter-Rows {
    if ($AdapterObjectNo -le 0) { return 0 }
    Count-Sql "SELECT COUNT(*) FROM [dbo].[Object] WHERE [ID] = $AdapterObjectNo;"
}

# GUID узлов берутся из той же заготовки, по которой врезка и ставилась: сверять снятие по
# числу, набранному отдельно, значит сверять его с собственной опечаткой.
#
# Разбор тот же, что у слияния - из ЗАГОЛОВКА записи узла. Наивное 'ID=[{...}]' цепляется и
# к ParentNodeID, и к NextNodeID, а первым в заготовке стоит нулевой GUID: он есть в любом
# чужом объекте, и проверка "врезка снята" краснела бы ВСЕГДА. Ловилось на себе 08.09.2026,
# и нашлось только тогда, когда снятие впервые погнали с врезкой на месте.
function Our-Menu-Ids {
    if (-not (Test-Path $nodesFile)) { return @() }
    $text = [IO.File]::ReadAllText($nodesFile, [Text.UTF8Encoding]::new($false))
    $ids = @()
    foreach ($m in [regex]::Matches($text, '(?m)^\s*\{\s*\S+\s*;\[\{([0-9A-Fa-f-]{36})\}\]')) {
        $ids += $m.Groups[1].Value.ToUpper()
    }
    return $ids
}
# Ищутся ВСЕ наши узлы, а не одно меню: врезка, снятая наполовину, оставила бы пункты без
# меню - и одиночная проверка по меню назвала бы это чистотой.
function Menu-Ours-Left {
    if ($MenuTargetId -le 0) { return @() }
    $ids = Our-Menu-Ids
    if ($ids.Count -eq 0) { Fail "не разобрать GUID наших узлов в $nodesFile" }
    $dump = Join-Path $outDir 'uninstall-menu-check.txt'
    if (Test-Path $dump) { Remove-Item $dump -Force }
    Invoke-Finsql "Command=ExportObjects,File=`"$dump`",Filter=`"Type=MenuSuite;ID=$MenuTargetId`"" 'uninstall-menu-export.log'
    if (-not (Test-Path $dump)) { Fail "не выгрузился MenuSuite $MenuTargetId - сверить снятие врезки нечем" }
    $up = ([System.Text.Encoding]::GetEncoding(866).GetString([IO.File]::ReadAllBytes($dump))).ToUpper()
    return @($ids | Where-Object { $up.Contains($_) })
}

Write-Host "След инструмента в базе $Database"
Write-Host ("  в диапазоне {0}-{1}: {2}" -f $rangeFrom, $rangeTo, (Footprint))
Write-Host ("  таблиц SQL с именем LockWatch: {0}" -f (Sql-Tables))
$episodesBefore = Episode-Rows
if ($episodesBefore -ge 0) { Write-Host ("  строк в журнале эпизодов: {0} - уйдут вместе с таблицей" -f $episodesBefore) }
$rowsBefore = Our-Rows
Write-Host ("  строк во всех наших таблицах: {0} - уйдут вместе с ними" -f $rowsBefore)
Write-Host ("  строк в планировщике задач: {0}" -f (Task-Rows))
$objectsBefore = Objects-In-Range
$tablesBefore  = Sql-Tables
$namedBefore   = Named-Objects
# Источник событий берётся из настройки, пока она ещё есть: после удаления таблиц
# спросить будет не у кого, а имя источника выбирает установка, а не мы.
$eventSource = 'LockWatch'
if ((Count-Sql "SELECT COUNT(*) FROM sys.tables WHERE [name] = N'$Company`$LockWatch Setup';") -gt 0) {
    $fromSetup = Scalar "SELECT TOP 1 ISNULL([Alert Event Source],'') FROM [$Company`$LockWatch Setup];"
    if ($fromSetup) { $eventSource = $fromSetup }
}
$outside = Named-Outside
if ($outside.Count -gt 0) {
    Write-Host '  ВНЕ ДИАПАЗОНА нашлись объекты с нашим именем:' -ForegroundColor Yellow
    $outside | ForEach-Object { Write-Host "    $_" -ForegroundColor Yellow }
    if ($AdapterObjectNo -le 0) {
        Write-Host '    Номер их не назван ключом -AdapterObjectNo, и сам скрипт их не тронет:' -ForegroundColor Yellow
        Write-Host '    удалять объект, которого никто не называл, он не вправе. Сверка это заметит.' -ForegroundColor Yellow
    }
}
if ($AdapterObjectNo -gt 0) { Write-Host ("  собранный переходник {0}: {1}" -f $AdapterObjectNo, (Adapter-Rows)) }
if ($MenuTargetId -gt 0) {
    $ourNodes = @(Our-Menu-Ids)
    $standing = @(Menu-Ours-Left)
    Write-Host ("  врезка в MenuSuite {0}: наших узлов в объекте {1} из {2}" -f $MenuTargetId, $standing.Count, $ourNodes.Count)
}

if (-not $Yes) {
    Write-Host ''
    Write-Host 'Ничего не удалено: это перечисление следа, а не снятие.' -ForegroundColor Yellow
    Write-Host 'Снять по-настоящему - тот же вызов с ключом -Yes. Вместе с таблицами уйдут' -ForegroundColor Yellow
    Write-Host 'и данные: журнал эпизодов, тревоги, охват и настройка. Обратного хода нет.' -ForegroundColor Yellow
    exit 0
}

# ---------- 0. отказ, если снять получится только половину ----------
# Таблицы без службы не снять: схему SQL меняет она, и finsql без её координат отвечает
# "Unable to process table changes ... Management Port: 0". Измерено 08.09.2026: страницы и
# кодюниты при этом УХОДЯТ, а семь таблиц с данными остаются - снятие делает полдела и
# оставляет базу с таблицами без кода. Это хуже отказа, поэтому отказ стоит здесь, ДО
# первого удаления, а не разбор последствий после него.
$svc = Get-Service $service -ErrorAction SilentlyContinue
if ((-not $svc) -or ($svc.Status -ne 'Running')) {
    Fail ("экземпляр $Instance не запущен, а без него снимаются только страницы и кодюниты: " +
          "схему SQL меняет служба, и таблицы с данными остались бы в базе без кода. " +
          "Запустите экземпляр и повторите. Опись следа читается и без службы - тот же вызов без -Yes.")
}

# ---------- 1. сторож ----------
Write-Host ''
Write-Host 'Снимаю сторожа'
# Сначала своим же путём: кодюнит гасит ВЫКЛЮЧАТЕЛЬ и снимает задачу. Прямое удаление
# строки выключателя не трогает, а идущий проход перевзводит себя сам - строка возвращается
# уже после удаления, и снятие объявляет себя неполным.
#
# Этот блок стоял в голых фигурных скобках, и PowerShell считает такое ВЫРАЖЕНИЕМ: он
# печатает текст блока в вывод и не выполняет его. Снятие ни разу не звало StopWatch, а
# смета этого не замечала, потому что строки задач всё равно добирались напрямую, и
# перевзвод случается только тогда, когда проход идёт прямо в этот миг.
$runner = Join-Path $outDir 'uninstall-stopwatch.ps1'
$body = @"
`$ErrorActionPreference = 'Stop'
Import-Module 'C:\Program Files\Microsoft Dynamics NAV\110\Service\NavAdminTool.ps1' -DisableNameChecking -WarningAction SilentlyContinue | Out-Null
Invoke-NAVCodeunit -ServerInstance $Instance -CompanyName '$Company' -CodeunitId 110236 -MethodName StopWatch -ErrorAction Stop
"@
[IO.File]::WriteAllText($runner, (($body -replace "`r`n", "`n") -replace "`n", "`r`n"), (New-Object System.Text.UTF8Encoding($true)))
& $ps51 -NoProfile -ExecutionPolicy Bypass -File $runner 2>&1 | Out-Null
$stopWorked = ($LASTEXITCODE -eq 0)
if (-not $stopWorked) { Write-Host '  свой путь не отработал - добираю строки задач напрямую' -ForegroundColor Yellow }

# Ждём ФАКТА, а не мгновения. Строка ИДУЩЕЙ задачи в планировщике есть, и снятие её не
# берёт: она уходит сама, когда проход кончится. Погашенный выключатель не даст ему
# перевзвестись, и число садится на ноль само - а если выключатель не погашен, ноля не
# будет вовсе, сколько ни жди.
$quietBy = (Get-Date).AddSeconds((WatchQuietSeconds))
while (((Get-Date) -lt $quietBy) -and ((Task-Rows) -gt 0)) { Start-Sleep -Milliseconds 500 }
$tasksAfterStop = Task-Rows
if ($tasksAfterStop -eq 0) {
    Write-Host '  сторож остановлен своим путём, планировщик пуст'
} else {
    Write-Host "  строк задач осталось после остановки: $tasksAfterStop" -ForegroundColor Yellow
}

$left = Task-Rows
if ($left -gt 0) {
    Invoke-Sql "DELETE FROM $tasksTable WHERE [Run Codeunit] BETWEEN $rangeFrom AND $rangeTo;" | Out-Null
    Write-Host "  строк задач добрано напрямую: $left"
}

# ---------- 2. врезка в меню ----------
if ($MenuTargetId -gt 0) {
    Write-Host ''
    Write-Host "Снимаю врезку в MenuSuite $MenuTargetId"
    & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'Merge-MenuSuite.ps1') `
        -Remove -Import -Server $Server -Database $Database -TargetId $MenuTargetId -TimeoutMinutes $TimeoutMinutes
    if ($LASTEXITCODE -ne 0) { Fail 'врезку снять не удалось - объекты не трогаю, иначе меню останется со ссылками в пустоту' }
}

# ---------- 3. собранный переходник ----------
if ($AdapterObjectNo -gt 0) {
    Write-Host ''
    Write-Host "Удаляю собранный переходник $AdapterObjectNo"
    Invoke-Finsql "Command=DeleteObjects,Filter=`"Type=Codeunit;ID=$AdapterObjectNo`"" 'uninstall-adapter.log'
}

# ---------- 4. свои объекты ----------
Write-Host ''
Write-Host 'Удаляю объекты инструмента'
# Координаты службы нужны таблицам: их снятие - это изменение схемы SQL, и проводит его
# служба. Без них finsql падает с "Management Port: 0" уже после удаления страниц.
$navServerArgs = ",NavServerName=$Server,NavServerInstance=$Instance,NavServerManagementPort=$MgmtPort"
# Порядок не случайный, и XMLport стоит в нём ПЕРЕД таблицей: он на неё ссылается, а
# удалённая таблица оставила бы ссылку в никуда. Своего XMLport инструмент больше не ставит,
# но снимать его продолжает: в базе, где стояла версия с выгрузкой истории в файл, он
# пережил бы снятие и остался в чужой базе один. Список типов - место, о котором забывают:
# новый тип объекта в проекте появляется раз в полгода, а снятие его не заметит и уйдёт
# зелёным, оставив объект в чужой базе. Сверка ниже ловит это по диапазону, а не по списку.
foreach ($type in 'Page', 'XMLport', 'Codeunit', 'Table') {
    Write-Host "  $type"
    Invoke-Finsql "Command=DeleteObjects,Filter=`"Type=$type;ID=$rangeFrom..$rangeTo`",SynchronizeSchemaChanges=Force$navServerArgs" "uninstall-$type.log"
}

# ---------- 5. сверка по базе ----------
$passed = 0; $total = 0; $report = @()
function Check([string]$what, [bool]$ok, [string]$detail) {
    $script:total++
    if ($ok) { $script:passed++; $verdict = 'пройдено' } else { $verdict = 'ПРОВАЛ  ' }
    $script:report += "$verdict $what"
    $script:report += "         $detail"
}

Write-Host ''
Write-Host 'Сверка по базе'
# Первой мерится не пустота, а РАЗНИЦА. Все три проверки ниже проходят на базе, где
# инструмент не стоял никогда: ноль объектов там и до снятия, и после. Прогон, который
# на такой базе объявил бы "снято", доказывал бы не снятие, а собственную бесполезность.
Check 'до снятия было что снимать' (($objectsBefore -gt 0) -or ($tablesBefore -gt 0) -or ($namedBefore -gt 0)) `
    "до снятия объектов $objectsBefore, таблиц SQL $tablesBefore, с нашим именем $namedBefore"
$objectsLeft = Objects-In-Range
Check 'объектов инструмента в базе не осталось' ($objectsLeft -eq 0) `
    "в диапазоне $rangeFrom-$rangeTo осталось: $(Footprint)"
$namedLeft = Named-Objects
# Остаток бывает и ВНУТРИ диапазона, и вне его, и печатать надо тот, который есть: пустой
# список при ненулевом счёте читается как сбой отчёта, а не как ответ.
$outsideLeft = @(Named-Outside)
$namedNote = "было $namedBefore, осталось $namedLeft"
if ($namedLeft -gt 0) {
    if ($outsideLeft.Count -gt 0) { $namedNote += ", вне диапазона: $($outsideLeft -join '; ')" }
    else { $namedNote += ", в диапазоне: $(Footprint)" }
}
Check 'объектов с нашим именем не осталось нигде, и вне диапазона тоже' ($namedLeft -eq 0) $namedNote
$tablesLeft = Sql-Tables
# Имя проверки обещало две вещи, а условие спрашивало одну: "и данные ушли с ними" не
# проверялось ничем. На смете 11.09.2026 рядом стояло "строк в журнале эпизодов: 0" - то
# есть уходить было нечему, а проверка про ушедшие данные всё равно зеленела.
#
# Спросить вторую половину условием нельзя, и это не лень: строк может не быть у честной
# установки, ещё не видевшей ни одной блокировки, и краснеть на ней снятию не за что.
# Зато число можно НАЗВАТЬ - снятие его и так снимает, - и тогда читатель видит, что
# именно ушло, а не верит на слово. Имя теперь равно тому, что спрашивается.
Check 'таблиц SQL с нашим именем не осталось' ($tablesLeft -eq 0) `
    "было $tablesBefore, осталось $tablesLeft; строк в них лежало $rowsBefore - ушли вместе с таблицами"
# Мерится не итог, а СВОЙ ПУТЬ: строки задач всё равно добираются прямым удалением, и по
# итогу обе дороги неотличимы. Здесь спрашивается число ДО прямого удаления - остановка
# обязана была увести его в ноль сама. Проверка непуста только на заведённом стороже: на
# тихой базе строк нет и до остановки, поэтому смета сторожа перед снятием заводит нарочно.
#
# Сломано нарочно 09.09.2026 - блок остановки возвращён в голые фигурные скобки: 5 из 6, и
# красная эта проверка, "строк задач после остановки 1, свой путь НЕ отработал".
Check 'сторож остановлен своим путём, а не выломан из планировщика' ($tasksAfterStop -eq 0) `
    "строк задач после остановки $tasksAfterStop, свой путь $(if ($stopWorked) { 'отработал' } else { 'НЕ отработал' })"
$tasksLeft = Task-Rows
Check 'в планировщике задач наших строк нет' ($tasksLeft -eq 0) `
    "строк с нашим кодюнитом $tasksLeft"
if ($AdapterObjectNo -gt 0) {
    $adapterLeft = Adapter-Rows
    Check 'собранный переходник удалён' ($adapterLeft -eq 0) "объектов с номером $AdapterObjectNo $adapterLeft"
}
if ($MenuTargetId -gt 0) {
    $menuLeft = @(Menu-Ours-Left)
    Check 'врезки в чужом меню не осталось' ($menuLeft.Count -eq 0) `
        "наших узлов в выгрузке MenuSuite $MenuTargetId $($menuLeft.Count) из $(@(Our-Menu-Ids).Count)"
}

Write-Host ''
Write-Host "пройдено $passed из $total"
Write-Host ''
$report | ForEach-Object { Write-Host $_ }

# ---------- 6. чего снять нельзя ----------
$leftovers = @()
# Чтение реестра может быть и запрещено, а падать этим ПОСЛЕ удачного снятия - худшее из
# возможных: работа сделана, а прогон объявляет отказ.
try {
    if ([System.Diagnostics.EventLog]::SourceExists($eventSource)) {
        $leftovers += "Источник событий Windows $eventSource - в реестре машины, не в базе."
        $leftovers += "Снимает администратор: Remove-EventLog -Source $eventSource"
    }
} catch {
    $leftovers += "Источник событий Windows $eventSource - проверить не удалось: $($_.Exception.Message)"
}
# Сессию мониторинга платформа зовёт по имени базы: <база>_deadlock_monitor (замер
# 09.09.2026). Значит на сервере с несколькими базами отбор по одному лишь роду сессии
# поймал бы и ЧУЖИЕ - и снятие велело бы гасить ключ у чужой установки. Своя считается по
# точному имени, чужие называются отдельно и как чужие.
$xeOurs = Count-Sql "SELECT COUNT(*) FROM sys.server_event_sessions WHERE [name] = DB_NAME() + N'_deadlock_monitor';"
$xeAll  = Count-Sql "SELECT COUNT(*) FROM sys.server_event_sessions WHERE [name] LIKE '%deadlock_monitor%';"
if ($xeOurs -gt 0) {
    $leftovers += 'Серверная сессия Extended Events этой базы - её завела платформа по ключу'
    $leftovers += 'EnableDeadlockMonitoring и переживёт снятие инструмента (проверено замером).'
    $leftovers += 'Уходит она только обратным выключением ключа в CustomSettings.config и'
    $leftovers += 'перезапуском экземпляра.'
}
if ($xeAll -gt $xeOurs) {
    $leftovers += "Ещё сессий того же рода на сервере: $($xeAll - $xeOurs) - они носят имена ДРУГИХ"
    $leftovers += 'баз этого сервера. К инструменту они отношения не имеют, и трогать их нельзя.'
}
if ($leftovers.Count -gt 0) {
    Write-Host ''
    Write-Host 'ОСТАЛОСЬ, И СНЯТЬ ЭТО ОТСЮДА НЕЛЬЗЯ:' -ForegroundColor Yellow
    $leftovers | ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow }
}

if ($passed -lt $total) { Fail 'снятие неполное - см. сверку выше' }
Write-Host ''
Write-Host 'Готово: инструмент снят, и это проверено по базе' -ForegroundColor Green
