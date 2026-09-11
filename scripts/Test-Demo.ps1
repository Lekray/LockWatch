#requires -Version 7
<#
.SYNOPSIS
    Проверка кнопки показа: нажатие поднимает НАСТОЯЩЕЕ ожидание, сторож записывает его
    сам, а снятая галка в настройке запрещает показ, а не только гасит кнопку.

.DESCRIPTION
    Показ - единственное место инструмента, которое блокировку не наблюдает, а СОЗДАЁТ.
    Спрашивается с него поэтому вдвойне: и что он делает обещанное, и что он не делает
    обещанного, когда его выключили.

    Ожидание настоящее, и подделать его тут нечем: две фоновые сессии NAV спорят за одну
    строку собственной таблицы показа, одна держит её шесть секунд, другая стоит за ней в
    очереди сервера. Проход видит этот спор так же, как увидел бы спор двух людей.

    Проверок четыре, и две из них - про отказ. Отказ проверяется НАЖАТИЕМ, а не чтением
    кода: кнопка на странице недоступна, когда галка снята, но это украшение - вызвать
    кодюнит можно и мимо страницы, и обещание обязано держаться там же, где живёт.

    Сломано нарочно 10.09.2026, дважды. Первый раз тремя движениями сразу - удержание
    поднято за предел ожидания NAV, оба отказа сняты: 1 из 4, и красные ровно те три, что
    их меряют ("ожидание 7862 мс, строка показа говорит Held by the demo" и оба "вызов
    ОТРАБОТАЛ"). Второй раз ждущую сессию не заводили вовсе: спорить не с кем, ожидания
    не возникает, и прогон останавливается на первой же проверке.

.EXAMPLE
    pwsh scripts/Test-Demo.ps1
#>
[CmdletBinding()]
param(
    [string] $Server   = 'localhost',
    [string] $Database = $env:LW_DATABASE,
    [string] $Instance = $env:LW_INSTANCE,
    [string] $Company  = $env:LW_COMPANY,
    [int]    $TaskCodeunitId = 110236,
    [int]    $DemoCodeunitId = 110244,
    [switch] $StopInstance
)

$ErrorActionPreference = 'Stop'
$root   = Split-Path -Parent $PSScriptRoot
$outDir = Join-Path $root 'out'
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir | Out-Null }

# Отказ ВЫБРАСЫВАЕТСЯ, а не гасит процесс на месте, и причин тому две. Первая: итог
# обязан прозвучать. Прогон, который на первой же беде уходит молча, судить о себе не
# умеет - а сломанное место как раз и узнаётся по строке "пройдено N из M", ставшей
# меньше. Вторая измерена: exit изнутри try оставлял pwsh крутиться на finally с внешней
# командой - прогон висел сорок минут, сжигая ядро и не печатая ничего (10.09.2026).
function Fail([string]$message) { throw $message }
# Холодный отказ - до опыта, когда судить ещё не о чем и убирать за собой нечего.
function Stop-Cold([string]$message) { Write-Host "ОТКАЗ: $message" -ForegroundColor Red; exit 1 }
if (-not $Database) { Stop-Cold 'не задано имя базы: переменная LW_DATABASE' }
if (-not $Instance) { Stop-Cold 'не задан экземпляр службы: переменная LW_INSTANCE' }
if (-not $Company)  { Stop-Cold 'не задана компания: переменная LW_COMPANY' }

$episode = "[$Company`$LockWatch Episode]"
$setup   = "[$Company`$LockWatch Setup]"
$state   = "[$Company`$LockWatch Watchdog]"
$demoRow = "[$Company`$LockWatch Demo Row]"
$tasks   = '[dbo].[Scheduled Task]'
$service = "MicrosoftDynamicsNavServer`$$Instance"
# Имя таблицы показа так, как его называет журнал: имя SQL без приставки компании.
$demoName = 'LockWatch Demo Row'

function Invoke-Sql([string]$query) {
    # -w 500 обязателен: по умолчанию sqlcmd рвёт строку на 80 знаках, и длинное значение
    # приходит ДВУМЯ строками. Проверка, читающая первую, получает обрезок и судит по нему.
    # -b обязателен не меньше: без него sqlcmd возвращает НОЛЬ и на ошибке SQL.
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
function DemoEpisodes { [int](Scalar "SELECT COUNT(*) FROM $episode WHERE [NAV Table Name] = N'$demoName';") }

$passed = 0; $total = 0; $report = @(); $abort = ''
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

# Сколько ждать эпизода от показа. Показ держит строку шесть секунд, проход случается раз
# в три: сорок секунд - это запас вшестеро, и ждём мы наступления события, а не спим.
function DemoWaitSeconds { 40 }
# Сколько ждать, чтобы убедиться, что запрещённый показ НЕ случился. Отсутствие события
# ожиданием не поймать, его можно только выждать - и выждать надо дольше, чем живёт весь
# показ: шесть секунд удержания плюс пара периодов опроса.
function QuietSeconds { 15 }
# Предел ожидания блокировки у NAV. Ждущая сессия показа обязана уложиться в него с
# запасом: сорвись она по таймауту - и показ учил бы человека тому, чего на исправной
# системе не бывает.
function NavLockTimeoutMs { 10000 }
# Сколько ждать ответа платформы на ОДИН вызов. Показ - единственный вызов инструмента,
# который заводит ЧУЖИЕ сессии, и платформа на нём однажды не ответила вовсе: прогон
# провисел сорок минут молча, сжигая ядро (10.09.2026, после трёх брошенных прогонов
# подряд). Прогон, который умеет висеть вечно, судить о себе не умеет. Тридцать секунд -
# запас втрое: самый долгий вызов здесь заводит сессию и спит полсекунды, а перезапуск
# службы, который длится дольше, идёт мимо этой дороги.
function CallTimeoutSeconds { 30 }

$ps51 = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$navImport = "Import-Module 'C:\Program Files\Microsoft Dynamics NAV\110\Service\NavAdminTool.ps1' -DisableNameChecking -WarningAction SilentlyContinue | Out-Null"
function Write-Ps51([string]$path, [string]$body) {
    [IO.File]::WriteAllText($path, (($body -replace "`r`n", "`n") -replace "`n", "`r`n"), (New-Object System.Text.UTF8Encoding($true)))
}
$probeFile = Join-Path $outDir 'wait-nav.ps1'
Write-Ps51 $probeFile @"
$navImport
`$deadline = (Get-Date).AddMinutes(6)
while ((Get-Date) -lt `$deadline) {
    try { Get-NAVServerSession -ServerInstance $Instance -ErrorAction Stop | Out-Null; exit 0 } catch { Start-Sleep -Seconds 5 }
}
exit 1
"@
function Wait-Instance {
    & $ps51 -NoProfile -ExecutionPolicy Bypass -File $probeFile | Out-Null
    if ($LASTEXITCODE -ne 0) { Fail "экземпляр $Instance не ответил по порту управления" }
}

# Вызов возвращает и УСПЕХ, и отказ: половина проверок здесь про то, что вызов обязан
# НЕ отработать, и падать на этом прогон не должен.
function Try-Method([int]$codeunit, [string]$method) {
    $file = Join-Path $outDir "demo-call-$codeunit-$method.ps1"
    Write-Ps51 $file @"
`$ErrorActionPreference = 'Stop'
$navImport
Invoke-NAVCodeunit -ServerInstance $Instance -CompanyName '$Company' -CodeunitId $codeunit -MethodName $method -ErrorAction Stop
"@
    # Вызов идёт отдельным процессом с крайним сроком, а не трубой: труба ждёт молча и
    # без конца, и отличить "платформа думает" от "платформа не ответит никогда" по ней
    # нельзя. Не ответивший вызов - это ОТКАЗ, и назвать его надо отказом, а не висеть.
    $outFile = "$file.out"
    $errFile = "$file.err"
    $run = Start-Process -FilePath $ps51 -NoNewWindow -PassThru `
        -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $file `
        -RedirectStandardOutput $outFile -RedirectStandardError $errFile
    $answered = $run.WaitForExit((CallTimeoutSeconds) * 1000)
    if (-not $answered) { $run.Kill(); $run.WaitForExit() }
    $log = (Get-Content $outFile -Raw -ErrorAction SilentlyContinue) + (Get-Content $errFile -Raw -ErrorAction SilentlyContinue)
    if (-not $answered) { $log = "платформа не ответила за $(CallTimeoutSeconds) с - вызов снят. $log" }
    $short = ($log -replace '\s+', ' ').Trim()
    if ($short.Length -gt 200) { $short = $short.Substring(0, 200) + '...' }
    return [pscustomobject]@{ Ok = ($answered -and ($run.ExitCode -eq 0)); Log = $short }
}
function Invoke-Method([int]$codeunit, [string]$method) {
    $answer = Try-Method $codeunit $method
    if (-not $answer.Ok) { Fail "$method не отработал: $($answer.Log)" }
}

try {
    Write-Host 'Подготовка стенда'
    if ((Get-Service $service).Status -ne 'Running') { Start-Service $service }
    # Сбор взаимоблокировок на время опыта выключается: круги приходят в кольцевой буфер от
    # кого угодно, а проверки здесь считают строки журнала.
    # Галка показа ставится ДО перезапуска: строка настройки лежит в кэше службы, и правка
    # мимо NAV до сессии не доходит.
    Invoke-Sql "UPDATE $setup SET [SQL Server] = N'$Server', [Deadlocks Enabled] = 0, [Demo Enabled] = 1;" | Out-Null

    Write-Host "  перезапускаю службу $Instance и жду ответа порта управления"
    Restart-Service $service -Force
    Wait-Instance

    Write-Host '  гашу остатки прошлого прогона и жду тишины'
    Invoke-Method $TaskCodeunitId 'StopWatch'
    if (-not (Wait-For { (TaskCount) -eq 0 } 30)) { Fail 'задачи прошлого прогона не снялись' }
    $quiet = LastPass
    if (-not (Wait-For { $now = LastPass; if ($now -eq $quiet) { Start-Sleep -Seconds 5; (LastPass) -eq $quiet } else { $script:quiet = $now; $false } } 60)) {
        Fail 'проходы прошлого прогона не прекратились'
    }
    # Строка показа сносится нарочно: её обязан завести сам показ, а не прошлый прогон.
    Invoke-Sql "DELETE FROM $episode; DELETE FROM $demoRow;" | Out-Null

    Write-Host 'Завожу сторожа и жду, пока проход случится САМ'
    Invoke-Method $TaskCodeunitId 'StartWatch'
    $beforeStart = LastPass
    # "Опыт не удался" тут было неправдой: опыт к этому месту сделал ровно одно - позвал
    # StartWatch, и вызов отработал, иначе отказал бы сам Invoke-Method. Молчание цепочки -
    # беда инструмента или стенда, и отличить их может только замер: стоит ли выключатель,
    # есть ли задача в очереди и что сказал сам сторож.
    if (-not (Wait-For { (LastPass) -ne $beforeStart } 60)) {
        Fail ("прохода не случилось за 60 с, а опыт только завёл сторожа: выключатель " +
              "$(Scalar "SELECT CONVERT(varchar(2),[Enabled]) FROM $setup;"), задач в очереди $(TaskCount), " +
              "отметка последнего прохода [$(LastPass)], сторож пишет: $(Scalar "SELECT [Watchdog Message] FROM $state;")")
    }

    Write-Host 'Нажимаю показ и больше НИЧЕГО не нажимаю'
    Invoke-Method $DemoCodeunitId 'RunDemo'

    # Первое и главное: ожидание случилось НАСТОЯЩЕЕ и записано БЕЗ участия человека.
    # Имя таблицы сверяется по имени, а не на непустоту: показ обязан спорить за СВОЮ
    # строку. Спорь он за чужую - проверка бы это увидела, а журнал бы промолчал.
    # Обе стороны спора - сессии NAV, и это тоже спрашивается: показ, устроенный чужим
    # соединением, был бы уже не показом инструмента, а показом sqlcmd.
    $appeared = Wait-For { (DemoEpisodes) -gt 0 } (DemoWaitSeconds)
    $seen = Scalar @"
SELECT TOP 1 [NAV Table Name] + '|' + [Victim Program] + '|' + [Blocker Program]
FROM $episode WHERE [NAV Table Name] = N'$demoName' ORDER BY [Entry No_] DESC;
"@
    # Скобки @() тут не украшение. Пустой ответ SQL режется на ОДНУ строку, и без них
    # переменная остаётся строкой, а не массивом: у строки Count равен единице всегда, а
    # += дописывает знаки вместо элементов - и добивка полей уходит в вечный оборот.
    # Прогон при этом не падает, а ВИСИТ, сжигая ядро и не печатая ничего: ловилось
    # 10.09.2026, сорок минут молчания на пустом журнале.
    $f = @(($seen -split '\|') | ForEach-Object { $_.Trim() })
    while ($f.Count -lt 3) { $f += '' }
    Check 'показ поднимает настоящее ожидание, и сторож записывает его сам' `
        ($appeared -and ($f[0] -eq $demoName) -and ($f[1] -match '(?i)dynamics nav') -and ($f[2] -match '(?i)dynamics nav')) `
        "эпизодов показа $(DemoEpisodes), таблица [$($f[0])] при ожидаемой [$demoName], ждал [$($f[1])], держал [$($f[2])]"
    if (-not $appeared) { Fail 'эпизода от показа нет - дальше проверять нечего' }

    # Второе: показ кончается САМ и обычным эпизодом, а не отказом по пределу ожидания.
    # Отличить одно от другого по журналу нельзя - и там и там эпизод закрыт, - поэтому
    # спрашивается строка показа: отметку "дождался и взял" ставит ждущий ПОСЛЕ ожидания,
    # а сорвавшийся по таймауту не ставит ничего.
    $closed = Wait-For { ([int](Scalar "SELECT COUNT(*) FROM $episode WHERE [NAV Table Name] = N'$demoName' AND [Open] = 0;")) -gt 0 } (DemoWaitSeconds)
    $waited = [int](Scalar "SELECT TOP 1 [Max Wait (ms)] FROM $episode WHERE [NAV Table Name] = N'$demoName' ORDER BY [Entry No_] DESC;")
    $note = Scalar "SELECT TOP 1 [Note] FROM $demoRow;"
    Check 'ждущий ДОЖДАЛСЯ, а не сорвался по пределу ожидания' `
        ($closed -and ($waited -gt 0) -and ($waited -lt (NavLockTimeoutMs)) -and ($note -match 'Waited for it and got it|Дождался и взял')) `
        "ожидание $waited мс при пределе $(NavLockTimeoutMs), строка показа говорит [$note], эпизод $(if ($closed) { 'закрыт' } else { 'ОТКРЫТ' })"

    # Третье: показ показывает СТОРОЖА. Без заведённого сторожа ожидание случилось бы и
    # прошло, а в журнале не появилось бы ничего - и человек унёс бы вывод, что инструмент
    # не работает. Отказ словами честнее пустого экрана.
    Write-Host 'Останавливаю сторожа и жму показ снова'
    Invoke-Method $TaskCodeunitId 'StopWatch'
    $noWatch = Try-Method $DemoCodeunitId 'RunDemo'
    Check 'показ отказывается работать, пока сторож не заведён' (-not $noWatch.Ok) `
        "вызов $(if ($noWatch.Ok) { 'ОТРАБОТАЛ' } else { 'отказал' }): $($noWatch.Log)"

    # Четвёртое, и ради него всё: снятая галка обязана запрещать САМ ПОКАЗ, а не только
    # гасить кнопку. Кнопку на странице гасит свойство Enabled, но кодюнит зовут и мимо
    # страницы - командлетом, чужим кодом, - и обещание обязано держаться там, где живёт.
    # Сторож при этом ЗАВЕДЁН нарочно: иначе отказ был бы объясним и без галки, и проверка
    # мерила бы предыдущую.
    Write-Host 'Снимаю галку показа и жму снова - уже при заведённом стороже'
    Invoke-Sql "UPDATE $setup SET [Demo Enabled] = 0;" | Out-Null
    Restart-Service $service -Force
    Wait-Instance
    Invoke-Method $TaskCodeunitId 'StartWatch'
    $before = DemoEpisodes
    $switched = Try-Method $DemoCodeunitId 'RunDemo'
    # Отсутствие события ожиданием не поймать: его выжидают. Столько живёт весь показ.
    Start-Sleep -Seconds (QuietSeconds)
    $after = DemoEpisodes
    Check 'снятая галка запрещает сам показ, а не только гасит кнопку' `
        ((-not $switched.Ok) -and ($after -eq $before)) `
        "вызов $(if ($switched.Ok) { 'ОТРАБОТАЛ' } else { 'отказал' }), эпизодов показа было $before, стало $after"
}
catch {
    # Беду запоминаем, а не печатаем: сперва уборка, потом итог, и только потом причина.
    $abort = $_.Exception.Message
}
finally {
    # Галка возвращается в исходное - такой настройка заводится при создании. Оставленная
    # снятой, она сделала бы следующий прогон зелёным по неверной причине.
    $cleanup = "UPDATE $setup SET [Demo Enabled] = 1, [Enabled] = 0, [Deadlocks Enabled] = 1;"
    $cleanup += " DELETE FROM $episode; DELETE FROM $demoRow;"
    $cleanup += " DELETE FROM $tasks WHERE [Run Codeunit] = $TaskCodeunitId;"
    & sqlcmd -S $Server -d $Database -E -l 30 -h -1 -Q $cleanup 2>&1 | Out-Null
    if ($StopInstance) { Stop-Service $service -Force }
}

Write-Host ''
Write-Host "пройдено $passed из $total"
Write-Host ''
$report | ForEach-Object { Write-Host $_ }
if ($abort) { Stop-Cold $abort }
if ($passed -lt $total) { Stop-Cold 'показ проверку не прошёл' }
Write-Host 'Готово: показ поднимает настоящее ожидание и слушается своей галки' -ForegroundColor Green