#requires -Version 7
<#
.SYNOPSIS
    Все проверки инструмента одним прогоном: в объявленном порядке, с ведомостью того,
    сколько проверок каждый обязан сделать, и с отдельным счётом невыполненного.

.DESCRIPTION
    Прогонов дюжина, и до сих пор порядок их и предусловия жили в голове того, кто их
    писал. Это ровно тот вид знания, который теряется первым, а потеря его дорога:
    прогоны мешают друг другу не отказом, а ЗЕЛЁНЫМ ЦВЕТОМ. Кольцевой буфер сервера один
    на всех, и взаимоблокировки, устроенные одним прогоном, попадают в журнал следующего;
    проход по очереди находит тогда эпизоды, которых сам не устраивал, и краснеет
    проверка, к которой это не имеет отношения. Ловилось на себе: проверка прохода дала
    5 из 12, и виноват был не проход.

    Поэтому здесь не список, а ПОРЯДОК, и у каждого места в нём записан довод.

    Ведомость - вторая половина замысла. Прогон, молча выполнивший три проверки вместо
    пятнадцати, выходит с нулевым кодом и был бы засчитан зелёным: отказа не было, отчёт
    есть, число в нём своё и сходится само с собой. Поэтому у каждого прогона записано,
    сколько проверок он делал, когда его писали. Меньше - красный цвет, больше - повод
    обновить ведомость, а не молчаливое согласие.

    Невыполненное считается ОТДЕЛЬНО и никогда не складывается с пройденным. Прогон,
    который нельзя выполнить, - не утверждение, и в сумму утверждений он не идёт.

    Четвёртый вид молчания - тот, что не кончается вовсе. Прогон, ушедший в вечный оборот,
    не даёт ни кода возврата, ни отчёта, и смета не оканчивается НИКОГДА: три мерки выше
    все до одной ждут конца прогона. Поэтому у каждого прогона крайний срок, и снятый по
    сроку считается провалившимся, а не пропущенным.

    Проверено вечным оборотом, поставленным в начало прогона меню 10.09.2026: смета сказала
    "прогон не кончился за 12 мин - снят вместе с выводком", дала 0 из 1 прогонов и вышла с
    кодом 1. На прежней смете тот же оборот не дал бы ничего - она ждала бы его до конца
    рабочего дня.

    Один отказ не обрывает сметы: остальные прогоны всё равно идут, иначе на каждую
    поломку уходил бы день - по одному красному за заход. Исключение одно и с доводом:
    если не встала выкладка, всё дальнейшее меряет вчерашние объекты, и зелёный цвет там
    хуже красного.

.EXAMPLE
    pwsh scripts/Test-All.ps1

.EXAMPLE
    pwsh scripts/Test-All.ps1 -Only onstand,pass

.EXAMPLE
    pwsh scripts/Test-All.ps1 -Skip load,platform -StopInstance
#>
[CmdletBinding()]
param(
    [string]   $Server   = 'localhost',
    [string]   $Database = $env:LW_DATABASE,
    [string]   $Instance = $env:LW_INSTANCE,
    [string]   $Company  = $env:LW_COMPANY,
    [string[]] $Only     = @(),
    [string[]] $Skip     = @(),
    [switch]   $StopInstance
)

$ErrorActionPreference = 'Stop'
$root   = Split-Path -Parent $PSScriptRoot
$outDir = Join-Path $root 'out'
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir | Out-Null }

# Вывод дочернего прогона приходит по трубе, и раскодировать его родитель обязан явно.
# Без этих двух строк кириллица приходит вопросительными знаками, отчёт читается как
# отчёт, а числа в нём разбираются - то есть сломанным выглядит только глаз человека.
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$OutputEncoding = [Text.UTF8Encoding]::new($false)

function Fail([string]$message) { Write-Host "ОТКАЗ: $message" -ForegroundColor Red; exit 1 }
if (-not $Database) { Fail 'не задано имя базы: переменная LW_DATABASE' }
if (-not $Instance) { Fail 'не задан экземпляр службы: переменная LW_INSTANCE' }
if (-not $Company)  { Fail 'не задана компания: переменная LW_COMPANY' }

$service = "MicrosoftDynamicsNavServer`$$Instance"
$pwshExe = (Get-Process -Id $PID).Path

# Сколько прогону позволено идти. Прогон, ушедший в вечный оборот, кода возврата не даёт,
# отчёта не даёт и сметы не оканчивает никогда - ловилось 10.09.2026: сорок минут молчания
# и сожжённое ядро на пустом ответе SQL, и смета в тот заход не пошла бы вовсе.
# Двенадцать минут - это втрое от самого долгого прогона ведомости (переходник, 3,6 мин) с
# запасом на холодный старт службы. Перешагнувший этот предел прогон не медленный, а мёртвый.
function RunDeadlineSeconds { 12 * 60 }

function Read-Shared([string]$path) {
    # Файл пишет ДРУГОЙ процесс, и открывать его надо с общим доступом: обычное чтение
    # спорит с пишущим и падает отказом в самый неудобный миг - посреди чужого прогона.
    if (-not (Test-Path $path)) { return '' }
    $stream = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try {
        $reader = New-Object IO.StreamReader($stream, (New-Object Text.UTF8Encoding($false)))
        return $reader.ReadToEnd()
    } finally { $stream.Dispose() }
}

function Show-Tail([string]$path, [int]$shown) {
    # Вывод показывается ПО МЕРЕ прибытия, иначе смета на двадцать минут превратилась бы в
    # двадцать минут пустого экрана, а человек - в того, кто не знает, идёт ли она вообще.
    $all = Read-Shared $path
    if ($all.Length -le $shown) { return $shown }
    Write-Host -NoNewline $all.Substring($shown)
    return $all.Length
}

function Stop-Tree([int]$id) {
    # Снимать надо ВЕСЬ выводок: у прогона свои дети - Windows PowerShell с модулем NAV и
    # sqlcmd, - и осиротевший ребёнок держал бы стенд ещё долго после того, как родителя
    # сняли. Дети снимаются первыми: снятый родитель их уже не назовёт.
    foreach ($child in @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$id" -ErrorAction SilentlyContinue)) {
        Stop-Tree $child.ProcessId
    }
    Stop-Process -Id $id -Force -ErrorAction SilentlyContinue
}

# Ведомость. Порядок значащий, число проверок - записанный замер, а не пожелание.
$runs = @(
    @{
        Name = 'onstand'; Script = 'Test-OnStand.ps1'; Extra = @('-Run')
        Checks = 46; Critical = $true; WithInstance = $true
        Why = 'выкладка первой: всё дальнейшее меряет то, что она положила на стенд'
        What = 'сборка пакета, выкладка компилятором, разбор без базы, мерный прогон журнала'
    }
    @{
        Name = 'pass'; Script = 'Test-Pass.ps1'; Extra = @()
        Checks = 26; WithInstance = $true
        Why = 'кратчайшая дорога до живого эпизода: сломан проход - дальше всё шум'
        What = 'проход на блокировке, документ, неразобранное имя, обе стороны по именам, очередь в два колена'
    }
    @{
        Name = 'pass-context'; Script = 'Test-Pass.ps1'; Extra = @('-ContextRoad')
        Checks = 26; WithInstance = $true
        Why = 'та же блокировка, но документ берётся отметкой переходника, а не очередью'
        What = 'вторая дорога к документу'
    }
    @{
        Name = 'document'; Script = 'Test-Document.ps1'; Extra = @()
        Checks = 11; WithInstance = $true; Needs = @('LW_DOC_TABLE_NO', 'LW_DOC_FIELD_NO')
        Why = 'дорога доводится до чужой таблицы после того, как проверена на своей'
        What = 'обратный поиск по хэшу на настоящей таблице установки, состязательный опыт'
    }
    @{
        Name = 'names'; Script = 'Test-Names.ps1'; Extra = @()
        # Двенадцать своих плюс три обкатки переходника: её отчёт печатается внутри и
        # считается ведомостью так же, как у прогона переходника. Проверки настоящие -
        # их делает платформа, а не прогон.
        Checks = 15; WithInstance = $true; Needs = @('LW_DOC_TABLE_NO', 'LW_DOC_FIELD_NO')
        Why = 'после дороги к документу: имя едет по той же отметке, что и он, и ставит НАСТОЯЩЕГО подписчика'
        What = 'цепочка «кто» целиком - подписчик кладёт отметку, журнал по ней называет человека'
    }
    @{
        Name = 'deadlock'; Script = 'Test-Deadlock.ps1'; Extra = @()
        Checks = 16; WithInstance = $true
        Why = 'устраивает настоящие круги и оставляет их в кольцевом буфере: после прогонов по очереди'
        What = 'взаимоблокировки из system_health, строка журнала того же вида, стороны не перепутаны'
    }
    @{
        Name = 'watch'; Script = 'Test-Watch.ps1'; Extra = @()
        Checks = 13; WithInstance = $true
        Why = 'сторожу нужен спокойный журнал: он судит по тому, что появилось САМО'
        What = 'фоновая задача заводится, идёт сама, не двоится, увозит журнал в историю и умирает по кнопке'
    }
    @{
        Name = 'demo'; Script = 'Test-Demo.ps1'; Extra = @()
        Checks = 4; WithInstance = $true
        Why = 'показывает сторожа и потому идёт сразу за ним: без заведённого сторожа показ отказывается работать'
        What = 'кнопка показа поднимает настоящее ожидание, а снятая галка запрещает сам показ, а не только кнопку'
    }
    @{
        Name = 'load'; Script = 'Test-Load.ps1'; Extra = @()
        Checks = 5; WithInstance = $true
        Why = 'сотня ждущих греет сервер: раньше сторожа нельзя, его цена мерялась бы на нагретом'
        What = 'цена прохода целиком и под нагрузкой'
    }
    @{
        Name = 'adapter'; Script = 'Test-Adapter.ps1'; Extra = @()
        Checks = 8; WithInstance = $true; Needs = @('LW_DOC_TABLE_NO', 'LW_DOC_FIELD_NO')
        Why = 'снимает со стенда штатный переходник; всё, кому он нужен целым, уже прошло'
        What = 'цена подписки тремя вариантами, сборщик переходника от начала до конца'
    }
    @{
        Name = 'menu'; Script = 'Test-Menu.ps1'; Extra = @()
        Checks = 4; WithInstance = $false
        Why = 'единственный прогон, пишущий в объект установки; ничто другое меню не трогает'
        What = 'врезка ставится, не удваивается и снимается байт в байт'
    }
    @{
        Name = 'platform'; Script = 'Test-Platform.ps1'; Extra = @()
        Checks = 5; WithInstance = $true
        Why = 'дважды перезапускает экземпляр: следующий вход платит за сборку business assemblies'
        What = 'дорога к имени человека от платформы и правдивость её сторожа'
    }
    @{
        Name = 'uninstall'; Script = 'Test-Uninstall.ps1'; Extra = @()
        Checks = 6; WithInstance = $true
        Why = 'снимает всё: после него мерить нечего, пока не выложишь заново'
        What = 'снятие РАБОТАЮЩЕГО инструмента и сверка по базе, что следа от него не осталось'
    }
    @{
        Name = 'redeploy'; Script = 'Test-OnStand.ps1'; Extra = @('-Run')
        Checks = 46; WithInstance = $true
        Why = 'возвращает стенд в рабочее состояние - и это же второй замер: выкладка на ОЧИЩЕННУЮ базу'
        What = 'повторная выкладка на базу, с которой инструмент только что сняли'
    }
)

# pwsh -File массивов не разбирает: "-Only a,b" приезжает ОДНОЙ строкой, и отбор молча
# не находит ничего. Разбираем сами, иначе пример из справки этого же файла не работает.
function Split-Names($values) {
    return @($values | ForEach-Object { "$_" -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}
$Only = Split-Names $Only
$Skip = Split-Names $Skip

$known = $runs | ForEach-Object { $_.Name }
foreach ($name in @($Only) + @($Skip)) {
    if ($name -notin $known) { Fail "прогона с именем '$name' нет. Есть: $($known -join ', ')" }
}

# Служба поднимается ОДИН раз на всю смету. Каждый прогон умеет поднять её сам, но платит
# за это холодным стартом: первый вход после запуска молча собирает business assemblies,
# и на полном наборе объектов это минуты. Десять холодных стартов подряд - это не проверка
# инструмента, а проверка терпения.
$startedByUs = $false
if ((Get-Service $service -ErrorAction SilentlyContinue) -and (Get-Service $service).Status -ne 'Running') {
    Write-Host "Поднимаю службу $Instance на всю смету"
    Start-Service $service
    $startedByUs = $true
}

$results = @()
$notRun  = @()
$stopped = $false

foreach ($run in $runs) {
    $index = "[$($results.Count + $notRun.Count + 1)/$($runs.Count)]"

    if ($stopped) {
        $notRun += @{ Name = $run.Name; Reason = 'смета оборвана: не встала выкладка'; Gap = $true }
        continue
    }
    if (($Only.Count -gt 0) -and ($run.Name -notin $Only)) {
        $notRun += @{ Name = $run.Name; Reason = 'не выбран ключом -Only'; Gap = $false }
        continue
    }
    if ($run.Name -in $Skip) {
        $notRun += @{ Name = $run.Name; Reason = 'снят ключом -Skip'; Gap = $false }
        continue
    }
    $missing = @($run.Needs | Where-Object { $_ -and -not [Environment]::GetEnvironmentVariable($_) })
    if ($missing.Count -gt 0) {
        $notRun += @{ Name = $run.Name; Reason = "не задано: $($missing -join ', ')"; Gap = $true }
        continue
    }

    Write-Host ''
    Write-Host "$index $($run.Name) - $($run.What)" -ForegroundColor Cyan
    Write-Host "        порядок: $($run.Why)" -ForegroundColor DarkGray

    $argList = @('-NoProfile', '-File', (Join-Path $PSScriptRoot $run.Script), '-Server', $Server, '-Database', $Database)
    if ($run.WithInstance) { $argList += @('-Instance', $Instance, '-Company', $Company) }
    $argList += $run.Extra

    # Ключ -StopInstance дочерним прогонам не передаётся никогда: службу гасит смета и
    # только в самом конце. Прогон, погасивший её посередине, заставил бы следующий
    # заплатить холодным стартом - и замер цены прохода стал бы замером разогрева.
    $log = Join-Path $outDir "all-$($run.Name).log"
    $errLog = "$log.err"
    Remove-Item $log, $errLog -Force -ErrorAction SilentlyContinue

    # Кавычки ставятся руками: имя компании бывает из двух слов, и Start-Process отдал бы
    # его дочернему прогону ДВУМЯ доводами. Ошибка вышла бы не отказом, а чужой компанией.
    $safeArgs = @($argList | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } })

    $began = Get-Date
    # Прогон идёт ОТДЕЛЬНЫМ процессом с крайним сроком, а не трубой: труба ждёт молча и без
    # конца, и отличить "прогон думает" от "прогон не кончится никогда" по ней нечем.
    $proc = Start-Process -FilePath $pwshExe -ArgumentList $safeArgs -NoNewWindow -PassThru `
        -RedirectStandardOutput $log -RedirectStandardError $errLog
    $hung = $false
    $shown = 0
    $until = $began.AddSeconds((RunDeadlineSeconds))
    while ($true) {
        $done = $proc.WaitForExit(500)
        $shown = Show-Tail $log $shown
        if ($done) { break }
        if ((Get-Date) -ge $until) {
            $hung = $true
            Stop-Tree $proc.Id
            [void]$proc.WaitForExit(10000)
            $shown = Show-Tail $log $shown
            break
        }
    }
    $code = if ($hung) { 1 } else { $proc.ExitCode }
    $spent = (Get-Date) - $began

    # Отказы прогона приходят отдельной трубой, и терять их нельзя: в них живёт причина.
    $errText = (Read-Shared $errLog).Trim()
    if ($errText) { Write-Host $errText -ForegroundColor Red }
    $text = (Read-Shared $log) + "`n" + $errText
    $sumPassed = 0; $sumTotal = 0; $lines = 0
    foreach ($m in [regex]::Matches($text, '(?:пройдено|passed)\s+(\d+)\s+(?:из|of)\s+(\d+)')) {
        $lines++
        $sumPassed += [int]$m.Groups[1].Value
        $sumTotal  += [int]$m.Groups[2].Value
    }

    # Отчёт судится четырьмя мерками, и каждая ловит свой вид молчания.
    $note = ''
    $ok = $true
    if ($hung) { $ok = $false; $note = "прогон не кончился за $([int]((RunDeadlineSeconds) / 60)) мин - снят вместе с выводком" }
    elseif ($code -ne 0) { $ok = $false; $note = "код возврата $code" }
    elseif ($lines -eq 0) {
        # Нулевой код при отсутствии итога - это не успех, а прогон, переставший
        # отчитываться. Отличить его от успеха по коду возврата нельзя.
        $ok = $false; $note = 'в отчёте нет ни одной строки итога'
    }
    elseif ($sumPassed -lt $sumTotal) { $ok = $false; $note = "в отчёте есть непройденное" }
    elseif ($sumTotal -lt $run.Checks) {
        $ok = $false; $note = "проверок $sumTotal вместо $($run.Checks) - часть их молча не выполнилась"
    }
    elseif ($sumTotal -gt $run.Checks) { $note = "проверок стало больше ($sumTotal против $($run.Checks)) - обнови ведомость" }

    $results += @{
        Name = $run.Name; Ok = $ok; Passed = $sumPassed; Total = $sumTotal
        Expected = $run.Checks; Spent = $spent; Note = $note
    }

    if ($ok) {
        Write-Host "$index $($run.Name): пройдено $sumPassed из $sumTotal" -ForegroundColor Green
    } else {
        Write-Host "$index $($run.Name): ПРОВАЛ - $note" -ForegroundColor Red
        if ($run.Critical) {
            $stopped = $true
            Write-Host 'Смета обрывается: без выкладки всё дальнейшее меряло бы вчерашние объекты' -ForegroundColor Red
        }
    }
}

# Снятие инструмента сносит таблицу настройки вместе с остальными, а повторная выкладка
# заводит её ЗАВОДСКОЙ: без имени сервера SQL каждый следующий проход падает, и стенд
# остаётся с включённым, но неработающим сторожем. Заметить это по зелёной смете нельзя -
# все прогоны выставляют имя сервера себе сами, а последний оставляет его пустым.
#
# Возвращается ровно то, что зависит от СРЕДЫ и чего в объектах нет: имя сервера. Остальное
# у заводской настройки правильное, и подставлять сюда чужие значения не наше дело.
if ($results.Count -gt 0) {
    $back = & sqlcmd -S $Server -d $Database -E -b -h -1 -W -Q `
        "SET NOCOUNT ON; UPDATE [dbo].[$Company`$LockWatch Setup] SET [SQL Server] = N'$Server'; SELECT @@ROWCOUNT;" 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Host ''
        Write-Host "Стенду возвращено имя сервера SQL в настройке (строк: $(($back -join '').Trim()))"
        Write-Host 'Настройка после снятия и выкладки - заводская. Строку таблицы документа,'
        Write-Host 'если она была, заводить заново: страница «Таблицы контекста».'
    } else {
        Write-Host ''
        Write-Host 'ВНИМАНИЕ: имя сервера SQL в настройку вернуть не удалось - сторож не пойдёт' -ForegroundColor Yellow
    }
}

if ($startedByUs -and $StopInstance) {
    Write-Host ''
    Write-Host "Останавливаю службу $Instance - её подняла смета, ей и гасить"
    Stop-Service $service -Force
}

$runsOk    = @($results | Where-Object { $_.Ok }).Count
$checksOk  = ($results | Measure-Object -Property Passed -Sum).Sum
$checksAll = ($results | Measure-Object -Property Total  -Sum).Sum
$gaps      = @($notRun | Where-Object { $_.Gap })

Write-Host ''
Write-Host "пройдено $runsOk из $($results.Count) прогонов"
Write-Host "проверок $checksOk из $checksAll"
Write-Host ''

foreach ($r in $results) {
    $mark = if ($r.Ok) { 'пройдено' } else { 'ПРОВАЛ  ' }
    $time = if ($r.Spent.TotalSeconds -lt 90) { "{0,5:n0} с  " -f $r.Spent.TotalSeconds } else { "{0,5:n1} мин" -f $r.Spent.TotalMinutes }
    Write-Host ("  {0} {1,-13} {2,3} из {3,-3} {4}  {5}" -f $mark, $r.Name, $r.Passed, $r.Total, $time, $r.Note)
}

if ($notRun.Count -gt 0) {
    Write-Host ''
    Write-Host 'НЕ ВЫПОЛНЕНО (проверка, которую нельзя выполнить, - не утверждение):' -ForegroundColor Yellow
    foreach ($s in $notRun) { Write-Host ("  {0,-13} {1}" -f $s.Name, $s.Reason) -ForegroundColor Yellow }
}

if ($results.Count -eq 0) { Fail 'не выполнено ни одного прогона - судить не о чем' }
if ($runsOk -lt $results.Count) { Fail 'смета не пройдена' }
if ($gaps.Count -gt 0) { Fail "прогонов не выполнено по нехватке предусловий: $($gaps.Count)" }

Write-Host ''
Write-Host 'Готово: вся смета зелёная' -ForegroundColor Green
