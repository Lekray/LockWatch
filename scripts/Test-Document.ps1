#requires -Version 7
<#
.SYNOPSIS
    Дорога к документу на НАСТОЯЩЕЙ таблице установки: обратный поиск по хэшу блокировки
    возвращает номер документа из той самой таблицы, за строку которой идёт спор.

.DESCRIPTION
    Проверка прохода (Test-Pass.ps1) устраивает блокировку на своей же таблице отметок:
    там и документ, и учётная запись лежат в колонках, которые инструмент сам и завёл.
    Это доказывает мост "транзакция -> блокировка -> хэш -> строка", но не доказывает
    главного: что дорога доходит до ЧУЖОЙ таблицы, чьи имена инструмент видит впервые.

    Здесь она доходит. Таблица и поле задаются снаружи - номерами, а не именами; имена
    прогон спрашивает у самого NAV тем же способом, каким их узнаёт инструмент, и только
    потом переводит их в имена SQL. Ни номера, ни имени доработанного объекта в этом файле
    нет и быть не может: репозиторий считаем публичным.

    Строку в целевой таблице прогон заводит сам и сам же убирает. Значения собираются по
    ТИПАМ столбцов, а не по умолчаниям: умолчаний NAV в SQL не создаёт вовсе - в целевой
    таблице стенда 201 столбец NOT NULL и ни одного DEFAULT.

    Непустота проверки доказана без поломки кода: опыт ставится ДВАЖДЫ, с разными номерами
    документа, и второй ответ обязан отличаться от первого. Проверка, которая печатает
    заранее известное число, прошла бы и на выключенном разборе.

    Третий опыт про другое. Виновник трогает ДВЕ строки, а спор идёт за одну, и журнал
    обязан назвать спорную. Это самый дорогой из возможных промахов: чужой номер документа
    выглядит ровно так же убедительно, как свой, и опровергнуть его читателю нечем.

    Третий опыт СОСТЯЗАТЕЛЬНЫЙ. Спорной делается та из двух строк, чей хэш ключа больше:
    набор блокировок приходит от сервера упорядоченным по хэшу, и ответ "первая попавшаяся
    из тронутых виновником" тогда заведомо указывает на другую строку. Без этого выбора
    опыт был бы подбрасыванием монеты и прошёл бы на любом коде через раз.

    Проверено поломкой 07.09.2026: на прежнем коде, бравшем хэш со стороны ВИНОВНИКА,
    прогон даёт 10 из 11 и краснеет именно эта проверка - назван LOCKWATCH-DOC-3 при
    спорном LOCKWATCH-DOC-0. На исправленном коде 11 из 11. Первый заход этой же проверки,
    где роли назначались не по хэшу, прошёл на ОБОИХ кодах - и был бесполезен.

.PARAMETER TableNo
    Номер целевой таблицы. По умолчанию берётся из LW_DOC_TABLE_NO. Умолчания в коде нет
    нарочно: писать в таблицу, которую никто не выбирал, прогон не вправе.

.PARAMETER FieldNo
    Номер поля, несущего номер документа. По умолчанию из LW_DOC_FIELD_NO.

.EXAMPLE
    $env:LW_DOC_TABLE_NO = 37; $env:LW_DOC_FIELD_NO = 3; pwsh scripts/Test-Document.ps1
#>
[CmdletBinding()]
param(
    [string] $Server   = 'localhost',
    [string] $Database = $env:LW_DATABASE,
    [string] $Instance = $env:LW_INSTANCE,
    [string] $Company  = $env:LW_COMPANY,
    [int]    $TableNo  = $env:LW_DOC_TABLE_NO,
    [int]    $FieldNo  = $env:LW_DOC_FIELD_NO,
    [int]    $PassCodeunitId = 110235,
    [int]    $TaskCodeunitId = 110236,
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
if ($TableNo -le 0) { Fail 'не задана целевая таблица: переменная LW_DOC_TABLE_NO или параметр -TableNo' }
if ($FieldNo -le 0) { Fail 'не задано поле документа: переменная LW_DOC_FIELD_NO или параметр -FieldNo' }

$episode = "[$Company`$LockWatch Episode]"
$context = "[$Company`$LockWatch Context Table]"
$setup   = "[$Company`$LockWatch Setup]"
$state   = "[$Company`$LockWatch Watchdog]"
$service = "MicrosoftDynamicsNavServer`$$Instance"

# Номера заведомо не встречающиеся: прогон пишет в ЖИВУЮ таблицу установки, и столкнуться
# с настоящим документом ему нельзя ни при каких обстоятельствах.
$docA = 'LOCKWATCH-DOC-1'
$docB = 'LOCKWATCH-DOC-2'
# Третий опыт: спор идёт за DOC-3, а виновник держит ещё и DOC-0. Ноль выбран нарочно - по
# ключу он идёт ПЕРВЫМ, и ответ "первая тронутая строка" отличим от ответа "спорная строка".
$docC = 'LOCKWATCH-DOC-3'
$docD = 'LOCKWATCH-DOC-0'

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

# Имя NAV в имя SQL переводит платформа, и правило это нигде не объявлено. Прогон повторяет
# тот же приём, что и сам инструмент: переводит имя не в имя, а в ОБРАЗЕЦ для LIKE, где
# каждый незнаковый символ подходит к любому одному. Совпасть образец обязан ровно один раз.
function Get-SqlPattern([string]$name) {
    $pattern = ''
    foreach ($ch in $name.ToCharArray()) {
        if ([char]::IsLetterOrDigit($ch) -or ($ch -eq ' ')) { $pattern += $ch } else { $pattern += '_' }
    }
    return $pattern
}

$passed = 0; $total = 0; $report = @()
function Check([string]$what, [bool]$ok, [string]$detail) {
    $script:total++
    if ($ok) { $script:passed++; $verdict = 'пройдено' } else { $verdict = 'ПРОВАЛ  ' }
    $script:report += "$verdict $what"
    $script:report += "         $detail"
}

$blocker = $null; $waiter = $null; $sqlTable = ''; $sqlTableName = ''; $docColumn = ''
function Start-Sqlcmd([string]$name, [string]$sql) {
    # Запрос уезжает ФАЙЛОМ, а не параметром -Q. Start-Process склеивает элементы
    # -ArgumentList пробелом и кавычек вокруг них не ставит: запрос с пробелами рассыпается
    # на аргументы, sqlcmd молча выходит с ошибкой, а выглядит это как "блокировка не
    # случилась". В имени таблицы NAV к тому же стоит доллар.
    $file = Join-Path $outDir $name
    [IO.File]::WriteAllText($file, (($sql -replace "`r`n", "`n") -replace "`n", "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
    Start-Process -FilePath 'sqlcmd' -PassThru -WindowStyle Hidden -ArgumentList @(
        '-S', $Server, '-d', $Database, '-E', '-b', '-l', '30', '-i', $file
    )
}
function Stop-Sqlcmd($process) {
    # Снятие процесса рвёт соединение, а разорванное соединение сервер откатывает сам.
    if ($process -and -not $process.HasExited) { $process.Kill(); $process.WaitForExit(10000) | Out-Null }
}

# Модуль NAV живёт только в Windows PowerShell 5.1, поэтому и ожидание готовности, и вызовы
# идут через него. Готовность спрашивается ДО опыта: служба поднимается минутами, а
# блокировка столько не держится.
$probeFile   = Join-Path $outDir 'wait-nav.ps1'
$passFile    = Join-Path $outDir 'invoke-pass.ps1'
$refreshFile = Join-Path $outDir 'invoke-refresh.ps1'
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
Write-Ps51 $refreshFile @"
`$ErrorActionPreference = 'Stop'
$navImport
Invoke-NAVCodeunit -ServerInstance $Instance -CompanyName '$Company' -CodeunitId $TaskCodeunitId -MethodName RefreshContextNames -ErrorAction Stop
"@
$ps51 = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
function Invoke-Ps51([string]$file, [string]$why) {
    $log = & $ps51 -NoProfile -ExecutionPolicy Bypass -File $file 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { Fail "$why не отработал:`n$log" }
}

# Значения собираются ПО ТИПАМ, и ни одно из них не литерал со скобками: SPACE(0) вместо
# пустой строки и CONVERT(datetime,0) вместо даты. Так текст запроса обходится без вложенных
# кавычек, а вложенные кавычки в динамическом SQL - самое дорогое место из всех.
$zeroByType = @'
CASE WHEN t.name IN (N'nvarchar',N'varchar',N'char',N'nchar',N'text',N'ntext',N'xml') THEN N'SPACE(0)'
     WHEN t.name IN (N'datetime',N'datetime2',N'smalldatetime',N'date',N'time',N'datetimeoffset') THEN N'CONVERT(datetime,0)'
     WHEN t.name = N'uniqueidentifier' THEN N'CONVERT(uniqueidentifier,0x00000000000000000000000000000000)'
     WHEN t.name IN (N'binary',N'varbinary',N'image') THEN N'0x'
     ELSE N'0' END
'@

function New-TargetRow([string]$docNo) {
    # Строка собирается динамически по списку столбцов. Перечислить их руками нельзя: их
    # двести, и список у каждой установки свой.
    $sql = @'
DECLARE @t sysname = N'{T}', @col sysname = N'{C}', @doc nvarchar(20) = N'{D}';
DECLARE @cols nvarchar(max) = N'', @vals nvarchar(max) = N'', @sql nvarchar(max);
SELECT @cols = @cols + CASE WHEN @cols = N'' THEN N'' ELSE N',' END + QUOTENAME(c.name),
       @vals = @vals + CASE WHEN @vals = N'' THEN N'' ELSE N',' END +
         CASE WHEN c.name = @col THEN N'@doc' ELSE {Z} END
FROM sys.columns c JOIN sys.types t ON t.user_type_id = c.user_type_id
WHERE c.object_id = OBJECT_ID(QUOTENAME(@t)) AND c.is_computed = 0 AND c.is_identity = 0
  AND t.name <> N'timestamp';
SET @sql = N'INSERT INTO ' + QUOTENAME(@t) + N' (' + @cols + N') VALUES (' + @vals + N');';
EXEC sp_executesql @sql, N'@doc nvarchar(20)', @doc = @doc;
'@
    $sql = $sql.Replace('{T}', $sqlTableName).Replace('{C}', $docColumn).Replace('{D}', $docNo).Replace('{Z}', $zeroByType)
    Invoke-Sql $sql | Out-Null
}

function Get-RowHash([string]$docNo) {
    # Хэш ключа берётся с КЛАСТЕРНОГО индекса: на нём и садится блокировка строки, и на
    # другом индексе у той же строки хэш другой. Скобки снимаются в SQL: ответ вида
    # (0e2051c31040) начинается со скобки, а с неё же начинаются служебные строки sqlcmd,
    # и общий отсев съел бы значение вместе с ними.
    return (Scalar "SELECT TOP 1 REPLACE(REPLACE(CONVERT(varchar(64),%%lockres%%),'(',''),')','') FROM $sqlTable WITH (INDEX(0), NOLOCK) WHERE [$docColumn] = N'$docNo';")
}

function Get-KeyPredicate([string]$docNo) {
    # Блокировка ставится по ПЕРВИЧНОМУ КЛЮЧУ, а не по полю документа: поле документа
    # может быть неиндексированным, и запрос по нему взял бы блокировки на всю таблицу.
    $sql = @'
DECLARE @t sysname = N'{T}', @col sysname = N'{C}', @doc nvarchar(20) = N'{D}';
DECLARE @where nvarchar(max) = N'';
SELECT @where = @where + CASE WHEN @where = N'' THEN N'' ELSE N' AND ' END + QUOTENAME(c.name) + N' = ' +
         CASE WHEN c.name = @col THEN N'N' + QUOTENAME(@doc, '''') ELSE {Z} END
FROM sys.index_columns ic
JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
JOIN sys.types t ON t.user_type_id = c.user_type_id
WHERE ic.object_id = OBJECT_ID(QUOTENAME(@t)) AND ic.index_id = 1 AND ic.is_included_column = 0;
SELECT @where;
'@
    $sql = $sql.Replace('{T}', $sqlTableName).Replace('{C}', $docColumn).Replace('{D}', $docNo).Replace('{Z}', $zeroByType)
    return (Scalar $sql)
}

function Wait-Gone([int]$spid) {
    $deadline = (Get-Date).AddSeconds(20)
    while ((Get-Date) -lt $deadline) {
        $still = Scalar "SELECT TOP 1 CONVERT(varchar(11),session_id) FROM sys.dm_os_waiting_tasks WHERE wait_type LIKE 'LCK[_]%' AND session_id = $spid;"
        if (-not $still) { return }
        Start-Sleep -Milliseconds 500
    }
}

function Invoke-Experiment([string]$docNo, [string]$alsoHeld = '') {
    New-TargetRow $docNo
    $second = ''
    if ($alsoHeld) {
        New-TargetRow $alsoHeld
        # Роли назначаются ПО ХЭШУ, а не по порядку в вызове: спорной становится строка с
        # большим хэшом, потому что ответ "первая из тронутых" берётся из набора,
        # упорядоченного по хэшу, и указывает на меньшую.
        $mine  = Get-RowHash $docNo
        $other = Get-RowHash $alsoHeld
        if (-not $mine -or -not $other) { Fail 'хэш подложенной строки не прочитался - опыт не состоялся' }
        if ([string]::CompareOrdinal($mine, $other) -lt 0) {
            $swap = $docNo; $docNo = $alsoHeld; $alsoHeld = $swap
            $swap = $mine;  $mine = $other;     $other = $swap
        }
        Write-Host "  спор за $docNo $mine, тронута ещё $alsoHeld $other"
    }
    $script:contended = $docNo
    $script:alsoTouched = $alsoHeld
    $where = Get-KeyPredicate $docNo
    if (-not $where) { Fail 'первичный ключ целевой таблицы не определён - блокировку ставить не по чему' }
    $held = $where
    if ($alsoHeld) {
        $second = Get-KeyPredicate $alsoHeld
        if (-not $second) { Fail 'вторую строку опыта не адресовать по ключу' }
        $held = "($where) OR ($second)"
    }

    # Держатель НИЧЕГО НЕ МЕНЯЕТ: UPDLOCK на строке даёт ту же блокировку рода KEY, что и
    # запись, но не трогает данные установки. Опыт, правящий чужую таблицу, стоил бы дороже
    # того, что он доказывает.
    # HOLDLOCK здесь был бы подлогом: он превращает блокировку в ДИАПАЗОННУЮ, а диапазонную
    # берут на границе между строками, и у неё нет строки вовсе. NAV работает на уровне
    # read committed и диапазонных блокировок не берёт - опыт обязан повторять NAV.
    # У держателя TOP 1 нет нарочно: ему надо взять ВСЕ строки, какие названы, - иначе
    # третий опыт выродился бы в первый. Ждущий спорит ровно за одну.
    $hold = "SET LOCK_TIMEOUT -1`nBEGIN TRAN`nSELECT 1 FROM $sqlTable WITH (UPDLOCK, ROWLOCK) WHERE $held`nWAITFOR DELAY '00:05:00'`nROLLBACK`n"
    $want = "SET LOCK_TIMEOUT -1`nBEGIN TRAN`nSELECT TOP 1 1 FROM $sqlTable WITH (UPDLOCK, ROWLOCK) WHERE $where`nROLLBACK`n"
    $script:blocker = Start-Sqlcmd 'doc-hold.sql' $hold
    Start-Sleep -Seconds 2
    $script:waiter = Start-Sqlcmd 'doc-want.sql' $want

    # Ждём, пока ожидание ПОЯВИТСЯ в очереди сервера. Иначе провал проверки означал бы
    # "опыт не удался", а выглядел бы как "инструмент не увидел блокировку" - самая дорогая
    # подмена, какая бывает в прогоне.
    $waitRow = ''
    $deadline = (Get-Date).AddSeconds(40)
    while ((Get-Date) -lt $deadline) {
        $waitRow = Scalar @"
SELECT TOP 1 CONVERT(varchar(11),wt.session_id) + '|' + CONVERT(varchar(11),wt.blocking_session_id)
FROM sys.dm_os_waiting_tasks wt
JOIN sys.dm_exec_sessions s ON s.session_id = wt.session_id
WHERE wt.wait_type LIKE 'LCK[_]%' AND s.host_process_id = $($script:waiter.Id);
"@
        if ($waitRow) { break }
        Start-Sleep -Milliseconds 500
    }
    if (-not $waitRow) { Fail 'ожидание в очереди сервера так и не появилось - опыт не удался, инструмент тут ни при чём' }
    $waiterSpid = [int]($waitRow -split '\|')[0]
    Write-Host "  документ $docNo - жертва $waiterSpid ждёт виновника $(($waitRow -split '\|')[1])"
    Start-Sleep -Seconds 2

    Invoke-Ps51 $passFile "проход по документу $docNo"

    $row = Scalar @"
SELECT TOP 1 [NAV Table Name] + '|' + [Document No_] + '|' + CONVERT(varchar(11),[Document Source]) + '|' +
  [User Name] + '|' + CONVERT(varchar(11),[User Source]) + '|' + [No Document Reason] + '|' +
  CONVERT(varchar(11),(SELECT COUNT(*) FROM $episode))
FROM $episode ORDER BY [Entry No_] DESC;
"@
    Stop-Sqlcmd $script:blocker
    Stop-Sqlcmd $script:waiter
    $script:blocker = $null; $script:waiter = $null
    Wait-Gone $waiterSpid
    if ($second) {
        Invoke-Sql "DELETE FROM $sqlTable WHERE ($where) OR ($second);" | Out-Null
    } else {
        Invoke-Sql "DELETE FROM $sqlTable WHERE $where;" | Out-Null
    }
    Invoke-Sql "DELETE FROM $episode;" | Out-Null
    if (-not $row) { return @() }
    return @(($row -split '\|') | ForEach-Object { $_.Trim() })
}

try {
    Write-Host 'Подготовка стенда'
    if ((Get-Service $service).Status -ne 'Running') { Start-Service $service }
    # Сбор взаимоблокировок на время опыта выключается. Он берёт графы из КОЛЬЦЕВОГО
    # БУФЕРА сервера, а туда они попадают от кого угодно и когда угодно - хоть от прошлого
    # прогона, хоть от чужой работы на той же базе. Строка в журнале получилась бы законной,
    # но проверка "эпизод заведён ровно один" считает строки, и опыт судил бы инструмент по
    # чужим кругам. Две дороги - два прогона, и каждый отвечает только за свою.
    Invoke-Sql "UPDATE $setup SET [SQL Server] = N'$Server', [Deadlocks Enabled] = 0; UPDATE $state SET [Watchdog Message] = N'';" | Out-Null
    Invoke-Sql "DELETE FROM $episode;" | Out-Null

    # Строка контекста заводится ОДНИМИ НОМЕРАМИ - имён здесь нет вовсе. Имена подставит сам
    # NAV, и это не удобство, а проверка: так же их узнаёт и человек, вводящий номер руками.
    # Правка мимо NAV в кэш работающей службы не доходит, поэтому строка пишется ДО
    # перезапуска.
    Invoke-Sql "DELETE FROM $context WHERE [Table No_] = $TableNo;" | Out-Null
    Invoke-Sql @"
INSERT INTO $context ([Table No_],[Table Name],[Document Field No_],[Document Field Name],[Document Caption],[Enabled])
VALUES ($TableNo,N'',$FieldNo,N'',N'',1);
"@ | Out-Null

    Write-Host "  перезапускаю службу $Instance и жду ответа порта управления"
    Restart-Service $service -Force
    & $ps51 -NoProfile -ExecutionPolicy Bypass -File $probeFile | Out-Null
    if ($LASTEXITCODE -ne 0) { Fail "экземпляр $Instance не ответил по порту управления" }

    Invoke-Ps51 $refreshFile 'перечитывание имён'
    $names = Scalar "SELECT TOP 1 [Table Name] + '|' + [Document Field Name] FROM $context WHERE [Table No_] = $TableNo;"
    $navTable = ($names -split '\|')[0].Trim()
    $navField = ($names -split '\|')[1].Trim()
    Check 'NAV сам назвал таблицу и поле по их номерам' (($navTable -ne '') -and ($navField -ne '')) `
        "таблица [$navTable], поле [$navField]"
    if (($navTable -eq '') -or ($navField -eq '')) { Fail 'без имён дальше проверять нечего' }

    # Имя таблицы SQL ищется тем же образцом: правило замены знаков у платформы одно и то же
    # и для таблиц, и для столбцов, и повторять его по памяти нельзя ни там, ни там.
    $tablePattern = (Get-SqlPattern $Company) + '$' + (Get-SqlPattern $navTable)
    $tables = Invoke-Sql "SELECT name FROM sys.tables WHERE name LIKE N'$tablePattern';"
    Check 'имя таблицы из настройки нашлось в SQL, и ровно одно' ($tables.Count -eq 1) `
        "образец [$tablePattern], совпадений $($tables.Count)"
    if ($tables.Count -ne 1) { Fail 'по образцу имени таблицы ответ неоднозначен - дальше идти нельзя' }
    $sqlTableName = $tables[0].Trim()
    $sqlTable = "[$sqlTableName]"

    $identityInKey = Scalar @"
SELECT CONVERT(varchar(11),COUNT(*)) FROM sys.index_columns ic
JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
WHERE ic.object_id = OBJECT_ID(N'$sqlTable') AND ic.index_id = 1 AND ic.is_included_column = 0
  AND c.is_identity = 1;
"@
    # Значение столбца IDENTITY выбирает сервер, а не прогон. Стой такой столбец в ключе -
    # предикат, собранный из нулей, указал бы на ЧУЖУЮ строку, и опыт молча сменил бы цель.
    Check 'в первичном ключе цели нет столбца с автономером' ($identityInKey -eq '0') `
        "столбцов IDENTITY в ключе $identityInKey"
    if ($identityInKey -ne '0') { Fail 'ключ цели содержит автономер - строку для опыта не адресовать' }

    $columnPattern = Get-SqlPattern $navField
    $columns = Invoke-Sql "SELECT c.name FROM sys.columns c WHERE c.object_id = OBJECT_ID(N'$sqlTable') AND c.name LIKE N'$columnPattern';"
    Check 'образец имени столбца подходит ровно к одному столбцу' ($columns.Count -eq 1) `
        "образец [$columnPattern], совпадений $($columns.Count)"
    if ($columns.Count -ne 1) { Fail 'по образцу имени столбца ответ неоднозначен - обратный поиск обязан молчать' }
    $docColumn = $columns[0].Trim()
    Write-Host "  цель: $sqlTable, столбец [$docColumn]"

    Write-Host 'Опыт первый'
    $f = Invoke-Experiment $docA
    Check 'эпизод заведён ровно один' (($f.Count -ge 7) -and ($f[6] -eq '1')) `
        "строк в журнале $(if ($f.Count -ge 7) { $f[6] } else { 0 })"
    if ($f.Count -lt 7) { Fail 'в журнале пусто - дальше проверять нечего' }
    Check 'таблица в эпизоде - та самая, чью строку не поделили' ($f[0] -eq $navTable) `
        "в журнале [$($f[0])] при ожидаемой [$navTable]"
    Check 'документ назван, и он тот самый' ($f[1] -eq $docA) `
        "документ [$($f[1])] при ожидаемом [$docA], причина [$($f[5])]"
    Check 'источник назван - по хэшу блокировки' ($f[2] -eq '1') `
        "откуда $($f[2]) при ожидаемом 1 (по хэшу блокировки)"
    # Дорога по хэшу отвечает про СТРОКУ, а не про человека. Выдумывать учётную запись там,
    # где её никто не называл, - худшее, что может сделать журнал.
    Check 'по хэшу блокировки учётная запись не выдумывается' (($f[3] -eq '') -and ($f[4] -eq '0')) `
        "учётная запись [$($f[3])], откуда $($f[4]) при ожидаемом 0 (нет)"

    Write-Host 'Опыт второй, с другим номером документа'
    $g = Invoke-Experiment $docB
    # Проверка, печатающая заранее известное число, прошла бы и на выключенном разборе.
    # Второй номер отличается от первого, и ответ обязан отличаться вместе с ним.
    Check 'ответ следует за данными, а не за кодом' (($g.Count -ge 3) -and ($g[1] -eq $docB) -and ($g[1] -ne $f[1])) `
        "второй опыт назвал [$(if ($g.Count -ge 2) { $g[1] } else { '' })] при первом [$($f[1])]"

    Write-Host 'Опыт третий, виновник держит две строки'
    $h = Invoke-Experiment $docC $docD
    # Хэш спорной строки лежит в невыполненной просьбе ЖЕРТВЫ. Со стороны виновника их
    # столько, сколько строк он тронул, и выбранная из них назвала бы чужой документ.
    Check 'назван документ спорной строки, а не любой из тронутых виновником' `
        (($h.Count -ge 3) -and ($h[1] -eq $contended)) `
        "назван [$(if ($h.Count -ge 2) { $h[1] } else { '' })] при спорном [$contended] и второй тронутой [$alsoTouched]"
}
finally {
    Stop-Sqlcmd $blocker
    Stop-Sqlcmd $waiter
    # Убираем за собой ОБЕ подложенные строки и строку настройки. Чужая таблица обязана
    # остаться ровно такой, какой была: отбор по номеру документа, и никаких DELETE без него.
    # Признак возвращается в исходное - таким он заводится при создании настройки.
    $cleanup = "DELETE FROM $context WHERE [Table No_] = $TableNo; UPDATE $setup SET [Deadlocks Enabled] = 1;"
    if ($sqlTable -and $docColumn) {
        $cleanup += " DELETE FROM $sqlTable WHERE [$docColumn] IN (N'$docA',N'$docB',N'$docC',N'$docD');"
    }
    if (-not $KeepJournal) { $cleanup += " DELETE FROM $episode;" }
    & sqlcmd -S $Server -d $Database -E -l 30 -h -1 -Q $cleanup 2>&1 | Out-Null
    if ($StopInstance) { Stop-Service $service -Force }
}

Write-Host ''
Write-Host "пройдено $passed из $total"
Write-Host ''
$report | ForEach-Object { Write-Host $_ }
if ($passed -lt $total) { Fail 'дорога к документу на настоящей таблице не пройдена' }
Write-Host 'Готово: обратный поиск дошёл до документа в таблице установки' -ForegroundColor Green
