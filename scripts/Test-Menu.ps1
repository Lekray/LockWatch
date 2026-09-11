#requires -Version 7
<#
.SYNOPSIS
    Врезка в меню установки: слияние, импорт, повторное слияние и снятие врезки - с
    проверкой, что чужой объект возвращается байт в байт.

.DESCRIPTION
    Своего уровня MenuSuite инструменту не досталось: лицензия отказала во всех
    партнёрских уровнях. Значит, пункты приходится врезать в существующий объект уровня
    Company, а он принадлежит заказчику - и главный вопрос тут не "видно ли пункты", а
    "можно ли всё вернуть".

    Поэтому прогон проверяет не столько врезку, сколько ОБРАТИМОСТЬ: объект выгружается,
    сливается, выкладывается, сливается повторно (пункты не должны удвоиться), а потом
    врезка снимается, и объект обязан совпасть с исходным байт в байт. Проверка на
    совпадение и есть главная: без неё "мы всё вернули" - это обещание, а не факт.

    Видно ли пункты в клиенте, прогон сказать не может: клиент он не открывает. Он говорит
    другое - что объект собран, скомпилирован платформой и обратим.

.EXAMPLE
    pwsh scripts/Test-Menu.ps1
#>
[CmdletBinding()]
param(
    [string] $Server   = 'localhost',
    [string] $Database = $env:LW_DATABASE,
    [int]    $TargetId = 1090,
    [int]    $TimeoutMinutes = 3
)

$ErrorActionPreference = 'Stop'
$root   = Split-Path -Parent $PSScriptRoot
$outDir = Join-Path $root 'out'
$finsql = 'C:\Program Files (x86)\Microsoft Dynamics NAV\110\RoleTailored Client\finsql.exe'
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir | Out-Null }

function Fail([string]$message) { Write-Host "ОТКАЗ: $message" -ForegroundColor Red; exit 1 }
if (-not $Database) { Fail 'не задано имя базы: переменная LW_DATABASE или параметр -Database' }

$cp866 = [System.Text.Encoding]::GetEncoding(866)
$merge = Join-Path $PSScriptRoot 'Merge-MenuSuite.ps1'
$originalFile = Join-Path $outDir "menusuite-$TargetId-original.txt"
$mergedFile   = Join-Path $outDir "menusuite-$TargetId-merged.txt"
$keptFile     = Join-Path $outDir "menusuite-$TargetId-kept.txt"
# Файлов ДВА, и роли у них разные. kept - то, что вернётся на стенд в конце: чужой объект
# в том виде, в каком его застали. base - то, с чем сравнивают проверки: тот же объект, но
# заведомо БЕЗ нашей врезки. На чистом стенде это одно и то же, а на стенде, где врезку уже
# поставили (показом, например), - нет, и без этого различия прогон мерил бы врезку
# относительно врезки: слияние "не изменило ни строки", снятие "потеряло семьдесят семь".
$baseFile     = Join-Path $outDir "menusuite-$TargetId-base.txt"

$passed = 0; $total = 0; $report = @()
function Check([string]$what, [bool]$ok, [string]$detail) {
    $script:total++
    if ($ok) { $script:passed++; $verdict = 'пройдено' } else { $verdict = 'ПРОВАЛ  ' }
    $script:report += "$verdict $what"
    $script:report += "         $detail"
}
function Invoke-Sql([string]$query) {
    $answer = & sqlcmd -S $Server -d $Database -E -b -l 30 -w 500 -W -h -1 -Q "SET NOCOUNT ON; $query" 2>&1
    if ($LASTEXITCODE -ne 0) { Fail "SQL не выполнился: $($answer -join ' ')" }
    return ,@($answer | Where-Object { $_ -and ($_ -notmatch '^\(') })
}
function Invoke-Finsql([string]$argLine, [string]$logName) {
    $log = Join-Path $outDir $logName
    if (Test-Path $log) { Remove-Item $log -Force }
    $navArgs = "ServerName=$Server,Database=$Database,NTAuthentication=1,LogFile=`"$log`""
    $process = Start-Process -FilePath $finsql -PassThru -NoNewWindow -ArgumentList "$argLine,$navArgs"
    if (-not $process.WaitForExit($TimeoutMinutes * 60000)) { $process.Kill(); Fail 'finsql завис и снят' }
    if (Test-Path $log) {
        $text = ($cp866.GetString([IO.File]::ReadAllBytes($log))).Trim()
        if ($text) { Fail "finsql ($logName):`n$text" }
    }
}

function Run-Merge([string]$why, [string[]]$extra) {
    $log = & pwsh -NoProfile -File $merge -Server $Server -Database $Database -TargetId $TargetId @extra 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { Fail "$why не отработал:`n$log" }
    return $log
}
function Line-Diff([string]$a, [string]$b) {
    # Сравнение ПОСТРОЧНОЕ и по местам, а не по множествам. Compare-Object сравнивает
    # наборы строк, и подменённая строка "NextNodeID=[{нули}]" у него не пропадает вовсе:
    # ровно такая же стоит ещё у десятка чужих узлов. Проверка на множествах показала бы
    # ноль изменений там, где изменение есть, - и была бы пустой.
    $left  = ($cp866.GetString([IO.File]::ReadAllBytes($a))) -split "`r`n"
    $right = ($cp866.GetString([IO.File]::ReadAllBytes($b))) -split "`r`n"
    # Сравниваются строки ДО закрывающих скобок объекта. Наши записи дописываются перед
    # ними, и три хвостовые строки при этом просто съезжают вниз - позиционное сравнение
    # засчитало бы их за изменения, которых нет.
    $common = [Math]::Min($left.Count, $right.Count) - 3
    if ($common -lt 0) { $common = 0 }
    $changed = 0
    $changedText = ''
    for ($i = 0; $i -lt $common; $i++) {
        if ($left[$i] -ne $right[$i]) {
            $changed++
            if (-not $changedText) { $changedText = $right[$i] }
        }
    }
    return [pscustomobject]@{ Changed = $changed; Added = $right.Count - $left.Count; ChangedText = $changedText }
}

try {
    Write-Host 'Слияние без импорта'
    $first = Run-Merge 'слияние' @()
    if (-not (Test-Path $originalFile)) { Fail 'оригинал не выгрузился' }
    Copy-Item $originalFile $keptFile -Force

    # Врезка могла стоять в меню ещё до прогона - её ставит показ и оставляет нарочно.
    # Тогда прогон снимает её СЕБЕ для замера и возвращает в конце вместе с оригиналом:
    # проверять слияние на объекте, где оно уже сделано, значит проверять пустоту.
    if ($first -match 'прежняя врезка найдена') {
        Write-Host 'В меню уже стоит наша врезка - снимаю её на время замера'
        Run-Merge 'снятие прежней врезки' @('-Remove', '-Import') | Out-Null
        Run-Merge 'слияние на чистом меню' @() | Out-Null
    }
    Copy-Item $originalFile $baseFile -Force
    $diff = Line-Diff $baseFile $mergedFile
    Check 'слияние правит ровно один чужой узел' `
        (($diff.Changed -eq 1) -and ($diff.Added -gt 1) -and ($diff.ChangedText -match 'NextNodeID')) `
        "изменено строк $($diff.Changed), дописано $($diff.Added), изменённая строка про NextNodeID: $(if ($diff.ChangedText -match 'NextNodeID') { 'да' } else { 'нет' })"

    Write-Host 'Импорт слитого объекта'
    Run-Merge 'слияние с импортом' @('-Import') | Out-Null
    $compiled = (Invoke-Sql "SELECT CONVERT(varchar(2),[Compiled]) FROM [dbo].[Object] WHERE [Type] = 7 AND [ID] = $TargetId;")[0]
    Check 'слитый объект принят платформой и скомпилирован' `
        ("$compiled".Trim() -eq '1') `
        "признак компиляции $compiled"

    Write-Host 'Повторное слияние - пункты не должны удвоиться'
    $again = Run-Merge 'повторное слияние' @()
    $mergedAgain = Join-Path $outDir "menusuite-$TargetId-merged-again.txt"
    Copy-Item $mergedFile $mergedAgain -Force
    $diffAgain = Line-Diff $baseFile $mergedAgain
    Check 'повторное слияние не удваивает пункты' `
        (($diffAgain.Changed -eq $diff.Changed) -and ($diffAgain.Added -eq $diff.Added) -and ($again -match 'прежняя врезка найдена')) `
        "изменено $($diffAgain.Changed) при $($diff.Changed), дописано $($diffAgain.Added) при $($diff.Added), прежняя врезка замечена: $(if ($again -match 'прежняя врезка найдена') { 'да' } else { 'НЕТ' })"

    Write-Host 'Снятие врезки'
    Run-Merge 'снятие врезки' @('-Remove', '-Import') | Out-Null
    Run-Merge 'выгрузка после снятия' @('-Remove') | Out-Null
    # Возврат сверяется ПО БАЙТАМ, а построчный разбор идёт рядом и только ради диагноза.
    #
    # Построчным разбором "байт в байт" не доказать, и дело не в придирке: он сравнивает
    # строки ДО трёх последних, потому что при слиянии хвост съезжает вниз. При возврате
    # хвост не съезжает никуда, и эти три строки оказывались непроверенными вовсе.
    # Показано без стенда 11.09.2026: в предпоследнюю строку выгрузки чужого меню добавлен
    # ОДИН пробел - построчный разбор дал "изменено 0, дописано 0", то есть проверка
    # сказала бы "байт в байт" о файлах, различающихся на байт.
    #
    # Обещание это - из тех, что показывают службе безопасности: инструмент трогает ЧУЖОЙ
    # объект установки и обязан вернуть его нетронутым. Такое доказывают хэшем, а не
    # сравнением того, что нам удобно сравнить.
    $backDiff = Line-Diff $baseFile $originalFile
    $sameBytes = (Get-FileHash $baseFile -Algorithm SHA256).Hash -eq (Get-FileHash $originalFile -Algorithm SHA256).Hash
    Check 'снятие врезки возвращает чужой объект байт в байт' `
        ($sameBytes -and ($backDiff.Changed -eq 0) -and ($backDiff.Added -eq 0)) `
        ("байты $(if ($sameBytes) { 'совпали' } else { 'РАЗОШЛИСЬ' }), размеры $((Get-Item $baseFile).Length) и $((Get-Item $originalFile).Length); " +
         "построчно: изменено $($backDiff.Changed), дописано $($backDiff.Added)")
}
finally {
    # Чужой объект возвращается ИМПОРТОМ СОХРАНЁННОГО ОРИГИНАЛА, а не снятием врезки той
    # же логикой, которая могла и сломаться. Ловилось на себе: поломка слияния оставила
    # объект в состоянии, которое сам скрипт потом отказался трогать, - и вернуть его было
    # нечем. Файл оригинала от логики слияния не зависит вовсе.
    if (Test-Path $keptFile) {
        try {
            Invoke-Finsql "Command=ImportObjects,File=`"$keptFile`",ImportAction=overwrite" "restore-menu-$TargetId.log"
            Invoke-Finsql "Command=CompileObjects,Filter=`"Type=MenuSuite;ID=$TargetId`"" "restore-compile-$TargetId.log"
            Write-Host 'Оригинал меню возвращён импортом сохранённой выгрузки'
        } catch { Write-Host "ВНИМАНИЕ: оригинал меню вернуть не удалось, он лежит в $keptFile" -ForegroundColor Red }
        Remove-Item $keptFile -Force
    }
    if (Test-Path $baseFile) { Remove-Item $baseFile -Force }
}

Write-Host ''
Write-Host "пройдено $passed из $total"
Write-Host ''
$report | ForEach-Object { Write-Host $_ }
if ($passed -lt $total) { Fail 'врезка в меню проверку не прошла' }
Write-Host 'Готово: врезка ставится, не удваивается и снимается без следа' -ForegroundColor Green
