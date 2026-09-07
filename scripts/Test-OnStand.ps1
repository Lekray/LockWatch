#requires -Version 7
<#
.SYNOPSIS
    Сборка пакета из objects/, выкладка на стенд настоящим компилятором и прогон обкатки.

.DESCRIPTION
    Отвечает на один вопрос: СОБИРАЕТСЯ ли то, что лежит в objects/, и ПРОХОДИТ ли обкатка.
    Ни код возврата finsql, ни пустой лог импорта сами по себе ничего не доказывают -
    поэтому вердикт снимается из базы: поле [Compiled] и сверка [Date]/[Time] с файлом.

    Порядок:
      (a) собирает монолит из objects/ в порядке зависимостей Table -> Codeunit -> Report ->
          Page -> XMLport -> Query -> MenuSuite и перекодирует его в cp866;
      (b) ПРОВЕРЯЕТ, что перекодировка обратима: cp1251 и UTF-8 ломают кириллицу молча,
          а потерянный символ обнаружится только в клиенте;
      (c) импортирует и компилирует через finsql;
      (d) доказывает импорт сверкой Date/Time из OBJECT-PROPERTIES с [dbo].[Object];
      (e) сверяет число несобранных по ВСЕЙ базе с замером «до»: свой объект может
          собраться и при этом сломать зависимые;
      (f) при -Run поднимает экземпляр службы и гонит обкатку, которая судит сама.

    Имена базы, экземпляра и компании В КОД НЕ ПИШУТСЯ - берутся из переменных окружения
    LW_DATABASE, LW_INSTANCE, LW_COMPANY либо из параметров.

.PARAMETER Run
    После выкладки поднять службу, выполнить обкатку разбора и мерный прогон журнала.
    Модуль NAV грузится только в Windows PowerShell 5.1 - скрипт вызывает его сам,
    сам этот файл идёт под pwsh 7.

.PARAMETER StopInstance
    Остановить экземпляр службы после прогона. Полезно на стенде, где память в обрез:
    служба NAV с полным набором объектов заказчика стоит около гигабайта, и SQL Server
    при нехватке памяти перестаёт выдавать рабочие потоки - вход в него начинает
    отваливаться по таймауту, а причина выглядит как что угодно, кроме памяти.

.EXAMPLE
    pwsh scripts/Test-OnStand.ps1 -Run -StopInstance
#>
[CmdletBinding()]
param(
    [string] $Server         = 'localhost',
    [string] $Database       = $env:LW_DATABASE,
    [string] $Instance       = $env:LW_INSTANCE,
    [string] $Company        = $env:LW_COMPANY,
    [int]    $MgmtPort       = 7145,
    [int]    $TestCodeunitId = 110231,
    [int]    $BenchCodeunitId = 110233,
    [int]    $AdapterCodeunitId = 110237,
    [int]    $TimeoutMinutes = 3,
    [switch] $Run,
    [switch] $StopInstance
)

$ErrorActionPreference = 'Stop'
$root    = Split-Path -Parent $PSScriptRoot
$objects = Join-Path $root 'objects'
$outDir  = Join-Path $root 'out'
$finsql  = 'C:\Program Files (x86)\Microsoft Dynamics NAV\110\RoleTailored Client\finsql.exe'

function Fail([string]$message) { Write-Host "ОТКАЗ: $message" -ForegroundColor Red; exit 1 }

if (-not $Database) { Fail 'не задано имя базы: переменная LW_DATABASE или параметр -Database' }
if (-not (Test-Path $finsql)) { Fail "нет finsql.exe: $finsql" }
if (-not (Test-Path $objects)) { Fail "нет каталога объектов: $objects" }
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir | Out-Null }

# Порядок компиляции значим: таблица должна существовать раньше того, кто её объявляет.
$typeOrder = @{ 't' = 1; 'c' = 2; 'r' = 3; 'p' = 4; 'x' = 5; 'q' = 6; 'm' = 7 }
$files = Get-ChildItem (Join-Path $objects '*.txt') |
    Sort-Object @{ Expression = { $order = $typeOrder[$_.Name.Substring(0,1)]; if ($order) { $order } else { 99 } } }, Name
if (-not $files) { Fail "в $objects нет ни одного объекта" }

# "Служба запущена" по мнению SCM и "служба отвечает по порту управления" - разные события,
# и между ними минуты: первый старт компилирует business assemblies. Проверять ОТКРЫТОСТЬ
# порта бесполезно - он слушает задолго до готовности, это проверено. Ждать надо ответа с
# того же конца, каким пользуется finsql: пока порт управления не отвечает, компиляция
# таблицы падает с пустыми координатами и "Management Port: 0". Выглядит это как
# потерянные параметры службы, а на деле - гонка со стартом, и на прогретой службе она не
# воспроизводится вовсе.
function Wait-ForManagement([int]$minutes = 6) {
    $probe = Join-Path $outDir 'wait-management.ps1'
    $body = @"
Import-Module 'C:\Program Files\Microsoft Dynamics NAV\110\Service\NavAdminTool.ps1' -DisableNameChecking -WarningAction SilentlyContinue | Out-Null
`$deadline = (Get-Date).AddMinutes($minutes)
while ((Get-Date) -lt `$deadline) {
    try { Get-NAVServerSession -ServerInstance $Instance -ErrorAction Stop | Out-Null; exit 0 } catch { Start-Sleep -Seconds 5 }
}
exit 1
"@
    [IO.File]::WriteAllText($probe, (($body -replace "`r`n", "`n") -replace "`n", "`r`n"), (New-Object System.Text.UTF8Encoding($true)))
    Write-Host '  жду ответа порта управления'
    & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File $probe | Out-Null
    if ($LASTEXITCODE -ne 0) { Fail "порт управления экземпляра $Instance не отвечает - служба не готова" }
}

function Ensure-Instance([string]$why) {
    if (-not $Instance) { Fail "нужен экземпляр службы ($why): переменная LW_INSTANCE или параметр -Instance" }
    $svc = "MicrosoftDynamicsNavServer`$$Instance"
    if ((Get-Service $svc).Status -ne 'Running') {
        Write-Host "  поднимаю службу $Instance ($why)"
        Start-Service $svc
        $deadline = (Get-Date).AddMinutes(5)
        while ((Get-Service $svc).Status -ne 'Running' -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 5 }
        if ((Get-Service $svc).Status -ne 'Running') { Fail "служба $Instance не поднялась" }
    }
    Wait-ForManagement
}

# Схему таблиц синхронизирует СЛУЖБА, а не finsql. Без поднятого экземпляра импорт с
# SynchronizeSchemaChanges=Force даёт "Unable to process table changes ... Management Port: 0",
# и отказ этот тянет за собой всю пачку - она откатывается целиком.
$hasTables = @($files | Where-Object { $_.Name.Substring(0,1) -eq 't' }).Count -gt 0
$navServerArgs = ''
if ($hasTables) {
    Ensure-Instance 'в пакете есть таблицы'
    $navServerArgs = ",NavServerName=$Server,NavServerInstance=$Instance,NavServerManagementPort=$MgmtPort"
}

function Invoke-Sql([string]$query) {
    # -w 500 обязателен: по умолчанию sqlcmd рвёт строку на 80 знаках, и длинное значение
    # приходит ДВУМЯ строками. Проверка, читающая первую, получает обрезок и судит по нему.
    $answer = & sqlcmd -S $Server -d $Database -E -l 30 -w 500 -W -s '|' -h -1 -Q "SET NOCOUNT ON; $query" 2>&1
    if ($LASTEXITCODE -ne 0) { Fail "SQL не выполнился: $($answer -join ' ')" }
    # Запятая обязательна. Без неё PowerShell разворачивает массив из одной строки в скаляр,
    # и $row[0] берёт ПЕРВЫЙ СИМВОЛ строки: дата превращается в "0", а [int] от символа "2"
    # даёт 50 - его код. Обе подмены выглядят как настоящие числа и врут молча.
    return ,@($answer | Where-Object { $_ -and ($_ -notmatch '^\(') })
}

function Invoke-Finsql([string]$argLine, [string]$logName) {
    $log = Join-Path $outDir $logName
    $navArgs = "ServerName=$Server,Database=$Database,NTAuthentication=1,LogFile=`"$log`""
    $process = Start-Process -FilePath $finsql -PassThru -NoNewWindow -ArgumentList "$argLine,$navArgs"
    if (-not $process.WaitForExit($TimeoutMinutes * 60000)) {
        $process.Kill()
        Fail "finsql завис дольше $TimeoutMinutes мин и снят. Обычная причина - невидимое модальное окно"
    }
    if (Test-Path $log) {
        $text = ([System.Text.Encoding]::GetEncoding(866).GetString([IO.File]::ReadAllBytes($log))).Trim()
        if ($text) { Fail "finsql ($logName):`n$text" }
    }
}

Write-Host 'Сборка пакета'
$monolith = (($files | ForEach-Object { [IO.File]::ReadAllText($_.FullName) }) -join '')
$monolith = ($monolith -replace "`r`n", "`n") -replace "`n", "`r`n"
$cp866 = [System.Text.Encoding]::GetEncoding(866)

# Перекодировка обязана быть обратимой. Символ, которого нет в cp866, пропадает молча,
# и обнаружится он не здесь, а в клиенте - в виде вопросительного знака в сообщении.
$roundTrip = $cp866.GetString($cp866.GetBytes($monolith))
if ($roundTrip -ne $monolith) {
    $lost = for ($i = 0; $i -lt $monolith.Length; $i++) {
        if ($monolith[$i] -ne $roundTrip[$i]) { "$([int][char]$monolith[$i]) '$($monolith[$i])'" }
    }
    Fail "cp866 теряет символы: $(($lost | Select-Object -Unique) -join ', ')"
}

$packUtf = Join-Path $outDir 'LockWatch.txt'
$pack    = Join-Path $outDir 'LockWatch.cp866.txt'
[IO.File]::WriteAllText($packUtf, $monolith, (New-Object System.Text.UTF8Encoding($false)))
[IO.File]::WriteAllBytes($pack, $cp866.GetBytes($monolith))
Write-Host ("  объектов {0}, пакет {1:N0} байт" -f $files.Count, (Get-Item $pack).Length)

# Состояние ДО: чужой отказ не должен засчитываться нашей выкладке.
$uncompiledBefore = [int]((Invoke-Sql 'SELECT COUNT(*) FROM [dbo].[Object] WHERE [Compiled] = 0;')[0])
Write-Host "  несобранных в базе до выкладки: $uncompiledBefore"

Write-Host 'Импорт и компиляция'
$stamp = Get-Date -Format 'HHmmss'
Invoke-Finsql "Command=ImportObjects,File=`"$pack`",ImportAction=overwrite,SynchronizeSchemaChanges=Force$navServerArgs" "import-$stamp.log"

$typeNo = @{ 't' = 1; 'c' = 5; 'r' = 3; 'p' = 8; 'x' = 6; 'q' = 9; 'm' = 4 }
$typeNm = @{ 't' = 'Table'; 'c' = 'Codeunit'; 'r' = 'Report'; 'p' = 'Page'; 'x' = 'XMLport'; 'q' = 'Query'; 'm' = 'MenuSuite' }
$declared = foreach ($file in $files) {
    $head = (Get-Content $file.FullName -TotalCount 12) -join "`n"
    if ($head -notmatch '(?m)^OBJECT\s+(\w+)\s+(\d+)\s') { Fail "не разобрать заголовок объекта: $($file.Name)" }
    $kind = $Matches[1]; $id = [int]$Matches[2]
    if ($head -notmatch '(?m)^\s*Date=([\d\.]+);') { Fail "нет Date в $($file.Name)" }
    $date = $Matches[1]
    if ($head -notmatch '(?m)^\s*Time=([\d:]+);') { Fail "нет Time в $($file.Name)" }
    [pscustomobject]@{ Kind = $kind; Id = $id; Date = $date; Time = $Matches[1]; Letter = $file.Name.Substring(0,1) }
}

foreach ($group in $declared | Group-Object Letter) {
    $ids = ($group.Group.Id | Sort-Object) -join '|'
    # Координаты службы нужны и компиляции, а не только импорту: таблицу компилятор
    # синхронизирует со схемой SQL через ту же службу, и без них падает с
    # "Management Port: 0" - при этом ИМПОРТ уже прошёл, и отказ выглядит внезапным.
    # Схему таблиц синхронизирует компиляция, и разрушительные изменения (удалённое поле,
    # сузившийся тип) она по умолчанию ОТКАЗЫВАЕТСЯ проводить - и правильно делает.
    # На стенде это разрешено явно: данные здесь свои и одноразовые. В пакет для установки
    # такой ключ не попадает - там удаление поля это решение человека, а не скрипта.
    Invoke-Finsql "Command=CompileObjects,Filter=`"Type=$($typeNm[$group.Name]);ID=$ids`",SynchronizeSchemaChanges=Force$navServerArgs" "compile-$($group.Name)-$stamp.log"
}

Write-Host 'Вердикт по базе, а не по логу'
$failed = @()
foreach ($object in $declared) {
    $row = (Invoke-Sql "SELECT CONVERT(varchar(10),[Date],104) + '|' + CONVERT(varchar(8),[Time],108) + '|' + CONVERT(varchar(2),[Compiled]) FROM [dbo].[Object] WHERE [Type]=$($typeNo[$object.Letter]) AND [ID]=$($object.Id);")
    if (-not $row) { $failed += "$($object.Kind) $($object.Id): в базе нет вовсе - импорт не состоялся"; continue }
    $parts = ($row[0] -split '\|').Trim()
    $wantDate = ([datetime]::ParseExact($object.Date, 'dd.MM.yy', $null)).ToString('dd.MM.yyyy')
    if ($parts[0] -ne $wantDate) { $failed += "$($object.Kind) $($object.Id): в базе дата $($parts[0]), в файле $wantDate - импортировалось не это" }
    elseif ($parts[2] -ne '1')   { $failed += "$($object.Kind) $($object.Id): НЕ СОБРАН" }
    else { Write-Host "  $($object.Kind) $($object.Id): собран, $($parts[0]) $($parts[1])" }
}
if ($failed) { Fail ($failed -join "`n       ") }

$uncompiledAfter = [int]((Invoke-Sql 'SELECT COUNT(*) FROM [dbo].[Object] WHERE [Compiled] = 0;')[0])
if ($uncompiledAfter -gt $uncompiledBefore) {
    Fail "несобранных стало больше: было $uncompiledBefore, стало $uncompiledAfter - выкладка сломала зависимые объекты"
}
Write-Host "  несобранных в базе после: $uncompiledAfter"

if (-not $Run) { Write-Host 'Готово: собрано. Обкатка не запускалась (нет -Run)' -ForegroundColor Green; exit 0 }

if (-not $Instance) { Fail 'не задан экземпляр службы: переменная LW_INSTANCE или параметр -Instance' }
if (-not $Company)  { Fail 'не задана компания: переменная LW_COMPANY или параметр -Company' }

$service = "MicrosoftDynamicsNavServer`$$Instance"
# Служба NAV держит СВОЙ кэш метаданных: после finsql-импорта работающий экземпляр
# продолжает исполнять ПРЕЖНЮЮ версию объекта. Без перезапуска обкатка проверяет не то,
# что только что выложено, и выглядит это как успех - самый дорогой вид лжи в прогоне.
$wasRunning = (Get-Service $service).Status -eq 'Running'
if ($wasRunning) {
    Write-Host "Перезапускаю службу $Instance - иначе она исполнит прежнюю версию объекта"
    Stop-Service $service -Force
} else {
    Write-Host "Поднимаю службу $Instance (первый вход компилирует business assemblies - это не зависание)"
}
Start-Service $service
$deadline = (Get-Date).AddMinutes(5)
while ((Get-Service $service).Status -ne 'Running' -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 5 }
if ((Get-Service $service).Status -ne 'Running') { Fail "служба $Instance не поднялась" }
Wait-ForManagement

# Модуль NAV грузится только в Windows PowerShell 5.1 - pwsh 7 падает на RealProxy.
$runner = Join-Path $outDir 'invoke-selftest.ps1'
$body = @"
`$ErrorActionPreference = 'Stop'
Import-Module 'C:\Program Files\Microsoft Dynamics NAV\110\Service\NavAdminTool.ps1' -DisableNameChecking -WarningAction SilentlyContinue | Out-Null
Invoke-NAVCodeunit -ServerInstance $Instance -CompanyName '$Company' -CodeunitId $TestCodeunitId -MethodName SelfTest -ErrorAction Stop
Invoke-NAVCodeunit -ServerInstance $Instance -CompanyName '$Company' -CodeunitId $BenchCodeunitId -MethodName Bench -ErrorAction Stop
Invoke-NAVCodeunit -ServerInstance $Instance -CompanyName '$Company' -CodeunitId $AdapterCodeunitId -MethodName SelfTest -ErrorAction Stop
"@
[IO.File]::WriteAllText($runner, (($body -replace "`r`n", "`n") -replace "`n", "`r`n"), (New-Object System.Text.UTF8Encoding($true)))

# Обкатка и мерный прогон идут одной сессией: первая проверяет разбор без базы, второй -
# NAV-половину прохода на пятистах строках. Второй меряет ЦЕНУ, поэтому и он судит сам:
# число без сравнения с объявленным потолком - это не замер, а строка в отчёте.
Write-Host 'Обкатка и мерный прогон'
$report = & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File $runner 2>&1 | Out-String
$testFailed = $LASTEXITCODE -ne 0
Write-Host $report.Trim()

if ($StopInstance) {
    Write-Host "Останавливаю службу $Instance - на стенде с тесной памятью это не мелочь"
    Stop-Service $service -Force
}

# Обкатка судит сама: при провале она выходит ошибкой, а не сообщением.
if ($testFailed -or ($report -match 'FAIL')) { Fail 'обкатка не пройдена - см. отчёт выше' }
Write-Host 'Готово: собрано и обкатано' -ForegroundColor Green
