#requires -Version 7
<#
.SYNOPSIS
    Снятие инструмента, который РАБОТАЕТ.

.DESCRIPTION
    Снятие судит себя само, и проверки живут в нём же. Но одна из них - что сторож
    остановлен своим путём, а не выломан из планировщика - на тихой базе пуста: строк
    задач там нет и до остановки, и обе дороги неотличимы по итогу.

    Поэтому сторож заводится НАРОЧНО, и снимают его на ходу. Это и есть тот случай,
    который случится у человека: инструмент снимают не с мёртвой базы, а с работающей.

.EXAMPLE
    pwsh scripts/Test-Uninstall.ps1
#>
[CmdletBinding()]
param(
    [string] $Server   = 'localhost',
    [string] $Database = $env:LW_DATABASE,
    [string] $Instance = $env:LW_INSTANCE,
    [string] $Company  = $env:LW_COMPANY,
    [int]    $TaskCodeunitId = 110236,
    [int]    $AdapterObjectNo = 0,
    [int]    $MenuTargetId = 0
)

$ErrorActionPreference = 'Stop'
$root   = Split-Path -Parent $PSScriptRoot
$outDir = Join-Path $root 'out'
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir | Out-Null }

function Fail([string]$message) { Write-Host "ОТКАЗ: $message" -ForegroundColor Red; exit 1 }
if (-not $Database) { Fail 'не задано имя базы: переменная LW_DATABASE' }
if (-not $Instance) { Fail 'не задан экземпляр службы: переменная LW_INSTANCE' }
if (-not $Company)  { Fail 'не задана компания: переменная LW_COMPANY' }

$ps51  = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$tasks = '[dbo].[Scheduled Task]'
$setup = "[$Company`$LockWatch Setup]"
$state = "[$Company`$LockWatch Watchdog]"

function Scalar([string]$query) {
    # -b обязателен: без него sqlcmd возвращает НОЛЬ и на ошибке SQL, и проверка кода
    # возврата проходит вхолостую, а запрос не выполнен вовсе.
    $answer = & sqlcmd -S $Server -d $Database -E -b -l 30 -w 500 -W -h -1 -Q "SET NOCOUNT ON; $query" 2>&1
    if ($LASTEXITCODE -ne 0) { Fail "SQL не выполнился: $($answer -join ' ')" }
    $rows = @($answer | Where-Object { $_ -and ($_ -notmatch '^\(') })
    if ($rows.Count -eq 0) { return '' }
    return "$($rows[0])".Trim()
}
# Пустая дата NAV (1753 год) - это "прохода не было", а не отметка: строку состояния заводит
# сам завод, и путать её появление с проходом нельзя.
function PassStamp {
    Scalar "SELECT ISNULL(CONVERT(varchar(30),NULLIF([Last Pass At],CONVERT(datetime,'17530101')),121),'') FROM $state;"
}
function TaskCount {
    [int](Scalar "SELECT COUNT(*) FROM $tasks WHERE [Run Codeunit] = $TaskCodeunitId AND [Company] = N'$Company';")
}

Write-Host 'Завожу сторожа: снимать будем РАБОТАЮЩИЙ инструмент'
$beforePass = PassStamp
$runner = Join-Path $outDir 'test-uninstall-start.ps1'
$body = @"
`$ErrorActionPreference = 'Stop'
Import-Module 'C:\Program Files\Microsoft Dynamics NAV\110\Service\NavAdminTool.ps1' -DisableNameChecking -WarningAction SilentlyContinue | Out-Null
Invoke-NAVCodeunit -ServerInstance $Instance -CompanyName '$Company' -CodeunitId $TaskCodeunitId -MethodName StartWatch -ErrorAction Stop
"@
# Модуль NAV живёт только в Windows PowerShell 5.1, а он читает файл без BOM как ANSI и
# ломается на кириллице в кавычках - потому BOM здесь обязателен.
[IO.File]::WriteAllText($runner, (($body -replace "`r`n", "`n") -replace "`n", "`r`n"), (New-Object System.Text.UTF8Encoding($true)))
# Ответ вызова НЕ выбрасывается: сторож не заводится по разным причинам, и платформа их
# называет сама. Отказ, съевший этот текст, посылает искать причину заново.
$startLog = & $ps51 -NoProfile -ExecutionPolicy Bypass -File $runner 2>&1 | Out-String
if ($LASTEXITCODE -ne 0) {
    Fail "сторож не завёлся - снимать работающий инструмент не выйдет: $(($startLog -replace '\s+', ' ').Trim())"
}

# Ждём ФАКТА, и факт этот - ПРОХОД, а не строка задачи. Строка появляется и там, где
# проходов не будет никогда: замер 12.09.2026 - при EnableTaskScheduler = false у экземпляра
# StartWatch отрабатывает МОЛЧА, задача встаёт в очередь, выключатель в настройке стоит, а
# за сорок секунд не случается ни одного прохода; сторож при этом пишет "первый проход
# вот-вот" и будет писать это всегда. Прежняя мерка на таком стенде пропускала прогон
# целиком, и все шесть проверок снятия зеленели на инструменте, который не работал ни разу.
#
# Сравнение идёт с отметкой, снятой ДО завода: "отметка непуста" выполнилось бы прошлым
# проходом прошлого прогона, то есть состоянием, которого опыт не создавал.
# Тридцати секунд хватает с запасом - первая задача встаёт через секунду после завода, а
# проход по пустой очереди укладывается в объявленный потолок в тысячу миллисекунд.
$armed = $false
$deadline = (Get-Date).AddSeconds(30)
while ((Get-Date) -lt $deadline) {
    if (((TaskCount) -gt 0) -and ((PassStamp) -ne $beforePass)) { $armed = $true; break }
    Start-Sleep -Milliseconds 500
}
# "Опыт не удался" тут было неправдой дважды. Опыт к этому месту позвал ровно StartWatch, и
# вызов отработал - иначе отказ был бы выше. Проходы - дело инструмента и стенда, и молчание
# их надо не назвать одним словом, а РАЗДЕЛИТЬ: задачи нет вовсе - это одно, задача стоит и
# не исполняется - совсем другое, и именно так выглядит выключенный планировщик экземпляра.
if (-not $armed) {
    $tasksNow = TaskCount
    Fail ("StartWatch отработал, а прохода за 30 с не случилось - отвечает за это инструмент " +
          "или стенд, но не опыт: он только завёл сторожа. Задач в очереди $tasksNow" +
          $(if ($tasksNow -gt 0) { ' - задача стоит и не исполняется, так выглядит экземпляр с EnableTaskScheduler = false' }
            else { ' - задача не встала вовсе' }) +
          ", выключатель $(Scalar "SELECT CONVERT(varchar(2),[Enabled]) FROM $setup;")" +
          ", отметка прохода [$(PassStamp)], сторож пишет: $(Scalar "SELECT [Watchdog Message] FROM $state;")")
}
Write-Host "  сторож заведён и ПРОШЁЛ: задач в планировщике $(TaskCount), отметка прохода $(PassStamp)"

Write-Host ''
$argList = @('-NoProfile', '-File', (Join-Path $PSScriptRoot 'Uninstall-LockWatch.ps1'),
             '-Server', $Server, '-Database', $Database, '-Instance', $Instance, '-Company', $Company, '-Yes')
if ($AdapterObjectNo -gt 0) { $argList += @('-AdapterObjectNo', $AdapterObjectNo) }
if ($MenuTargetId -gt 0)    { $argList += @('-MenuTargetId', $MenuTargetId) }
& pwsh @argList
exit $LASTEXITCODE