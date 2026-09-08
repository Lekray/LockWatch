#requires -Version 7
<#
.SYNOPSIS
    Показ на стенде: инструмент ставится в рабочее положение, база получает четыре
    настоящие блокировки, и журнал заполняется у человека на глазах.

.DESCRIPTION
    Это не прогон. Прогон судит сам себя и печатает "пройдено N из M"; показ ничего не
    судит - он устраивает на живой базе то, ради чего инструмент и заведён, и оставляет
    результат на экране клиента.

    Блокировки настоящие, все четыре. Ни одна строка журнала здесь не пишется запросом:
    журнал заполняет сам сторож, проснувшийся по своей же цепочке задач, и ни одного
    ручного прохода показ не делает. Строка, положенная в журнал показом, доказывала бы
    только то, что INSERT работает.

    Четыре сцены отвечают на четыре разных вопроса:

      1. За какой ДОКУМЕНТ идёт спор. Блокировка на таблице документа установки, номер
         достаётся обратным поиском по хэшу ключа - без единой врезки в чужой код.
      2. Кто ЧЕЛОВЕК. Блокировка на штатной таблице, где дорога по хэшу молчит по делу
         (таблица не объявлена таблицей документа), и ответ приходит от отметки контекста,
         которую переходник кладёт в ТОЙ ЖЕ транзакции.
      3. Кто ПОСТРАДАЛ. Трое ждут одного: голова цепочки, число жертв за ней, и ожидание
         дольше порога - тревога наружу.
      4. Взаимоблокировка. Круг двух сеансов, который сервер рвёт сам; журнал записывает
         его из кольцевого буфера.

    Круг устраивается ЗАРАНЕЕ, до первой сцены. Кольцевой буфер сервера инструмент читает
    раз в минуту, и ждать эту минуту в тишине незачем: пока идут остальные сцены, он его
    прочитает.

    В конце показ оставляет ОТКРЫТЫЙ эпизод на несколько минут - чтобы на экране было
    видно не только прошлое, но и настоящее: ожидание растёт с каждым обновлением.

    Что показ меняет на стенде и как это вернуть - ключ -Clean.

.PARAMETER Clean
    Вернуть стенд как было: погасить сторожа, убрать подложенные строки, очистить журнал,
    тревоги и охват, вернуть настройку к заводским значениям и снять пункты меню.

.PARAMETER PlainTable
    Штатная таблица NAV для второй сцены - та, что НЕ объявлена таблицей документа.
    Нужна непустая: показ спорит за её первую строку и ничего в ней не меняет.

.EXAMPLE
    $env:LW_DATABASE = '...'; $env:LW_INSTANCE = '...'; $env:LW_COMPANY = '...'
    $env:LW_DOC_TABLE_NO = 50000; $env:LW_DOC_FIELD_NO = 2
    pwsh scripts/Demo.ps1

.EXAMPLE
    pwsh scripts/Demo.ps1 -Clean
#>
[CmdletBinding()]
param(
    [string] $Server     = 'localhost',
    [string] $Database   = $env:LW_DATABASE,
    [string] $Instance   = $env:LW_INSTANCE,
    [string] $Company    = $env:LW_COMPANY,
    [int]    $TableNo    = $env:LW_DOC_TABLE_NO,
    [int]    $FieldNo    = $env:LW_DOC_FIELD_NO,
    [string] $PlainTable = 'G/L Entry',
    [int]    $EpisodesPageId = 110231,
    [int]    $TaskCodeunitId = 110236,
    [switch] $NoClient,
    [switch] $NoMenu,
    [switch] $Clean
)

$ErrorActionPreference = 'Stop'
$root   = Split-Path -Parent $PSScriptRoot
$outDir = Join-Path $root 'out'
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir | Out-Null }
$liveFile   = Join-Path $outDir 'demo-live.txt'
$targetFile = Join-Path $outDir 'demo-target.txt'

function Fail([string]$message) { Write-Host "ОТКАЗ: $message" -ForegroundColor Red; exit 1 }
function Say([string]$message)  { Write-Host "  $message" }
function Head([string]$message) { Write-Host ''; Write-Host $message -ForegroundColor Cyan }
function Good([string]$message) { Write-Host "  $message" -ForegroundColor Green }
function Warn([string]$message) { Write-Host "  $message" -ForegroundColor Yellow }

if (-not $Database) { Fail 'не задано имя базы: переменная LW_DATABASE или параметр -Database' }
if (-not $Instance) { Fail 'не задан экземпляр службы: переменная LW_INSTANCE' }
if (-not $Company)  { Fail 'не задана компания: переменная LW_COMPANY' }
if ($TableNo -le 0) { Fail 'не задана таблица документа: переменная LW_DOC_TABLE_NO' }
if ($FieldNo -le 0) { Fail 'не задано поле документа: переменная LW_DOC_FIELD_NO' }

$episode  = "[$Company`$LockWatch Episode]"
$setup    = "[$Company`$LockWatch Setup]"
$state    = "[$Company`$LockWatch Watchdog]"
# Строку состояния сторожа заводит первый же проход, но здесь она нужна РАНЬШЕ: отметку
# "прочитано до" надо поставить прежде, чем проход впервые откроет кольцевой буфер, иначе
# в журнал приедут чужие круги. Умолчаний NAV в SQL не создаёт, а столбцы объявляет
# NOT NULL, поэтому строка заводится со всеми столбцами разом.
$stateSeed = @"
IF NOT EXISTS (SELECT 1 FROM $state)
  INSERT INTO $state ([Primary Key],[Deadlocks Read Until],[Deadlocks Read At],[Coverage Since],
                      [Last Pass At],[Last Pass (ms)],[Last Pass Rows],[Last Pass Truncated],[Watchdog Message])
  VALUES (N'',CONVERT(datetime,'17530101'),CONVERT(datetime,'17530101'),CONVERT(datetime,'17530101'),
          CONVERT(datetime,'17530101'),0,0,0,N'');
"@
$context  = "[$Company`$LockWatch Context Table]"
$mark     = "[$Company`$LockWatch Context Mark]"
$alert    = "[$Company`$LockWatch Alert]"
$coverage = "[$Company`$LockWatch Coverage]"
$tasks    = '[dbo].[Scheduled Task]'
$service  = "MicrosoftDynamicsNavServer`$$Instance"

# Номера показа заведомо не встречаются в делах: показ пишет в ЖИВУЮ таблицу установки,
# и столкнуться с настоящим документом ему нельзя ни при каких обстоятельствах.
$docHash  = 'LOCKWATCH-DEMO-1'
$docQueue = 'LOCKWATCH-DEMO-2'
$docLive  = 'LOCKWATCH-DEMO-3'
$docMark  = 'LOCKWATCH-DEMO-4'
$demoLike = 'LOCKWATCH-DEMO-%'

# ---------------------------------------------------------------------------------------
# Величины показа. У каждой имя и довод: число без довода в скрипте показа так же
# необъяснимо, как в коде.
# ---------------------------------------------------------------------------------------

function DemoAlertMs {
    # Десять секунд на время показа при заводских пяти. С заводским порогом тревогой стала
    # бы КАЖДАЯ сцена: держать блокировку меньше пяти секунд нельзя - её не успеет увидеть
    # сам сторож, - и показ выродился бы в сплошную тревогу. С десятью две короткие сцены
    # проходят молча, а очередь из троих поднимает её: видно, что тревога - событие, а не
    # фон.
    return 10000
}
function ShortHoldSeconds {
    # Восемь. Сторож просыпается раз в три секунды, и блокировка обязана пережить ДВА
    # пробуждения: первое заводит эпизод, второе продлевает его - и на экране видно, что
    # строка одна, а не две. Держать меньше значит показывать удачу, а не работу.
    return 8
}
function QueueHoldSeconds {
    # Пятнадцать: дольше порога тревоги с запасом в половину. Порог, пройденный впритык,
    # показывал бы точность часов, а не тревогу.
    return 15
}
function QueueVictims {
    # Трое. Один даёт цепочку глубиной в единицу и о голове не говорит ничего; двое
    # отличают "жертв за головой" от "глубины цепочки"; трое делают это заметным.
    return 3
}
function LiveHoldMinutes {
    # Три минуты живого эпизода в конце: столько нужно, чтобы клиент успел открыться,
    # человек - найти страницу, а эпизод - остаться ОТКРЫТЫМ у него на глазах.
    return 3
}
function CatchSeconds {
    # Минута на ожидание строки в журнале. Сторож ходит раз в три секунды, но первый его
    # проход после завода отложен, а служба на стенде отвечает не мгновенно.
    return 60
}
function CircleAttempts {
    # Три. Одной мало - круг вероятностный; больше трёх значит, что не состоится он и на
    # четвёртой, и молчать об этом нельзя.
    return 3
}
function CircleHold {
    # Десять секунд между первым и вторым захватом. Обе стороны должны успеть взять свою
    # строку до того, как соперник потянется за ней: с короткой паузой одна из них не
    # успевает, и круга не выходит вовсе.
    return '00:00:10'
}
function LockTimeoutNavMs {
    # Предел ожидания блокировки у NAV. Показ им не пользуется, но называет его в отчёте:
    # именно в это окно укладывается эпизод целиком.
    return 10000
}

# ---------------------------------------------------------------------------------------
# Разговор с SQL
# ---------------------------------------------------------------------------------------

function Invoke-Sql([string]$query) {
    # -w 500 обязателен: по умолчанию sqlcmd рвёт строку на 80 знаках, и длинное значение
    # приходит ДВУМЯ строками. -b обязателен не меньше: без него sqlcmd возвращает ноль и
    # на ошибке SQL, а запрос при этом не выполнен вовсе.
    # SET QUOTED_IDENTIFIER ON обязателен третьим: sqlcmd включает его ВЫКЛЮЧЕННЫМ, а без
    # него любой метод типа xml отвечает не пустотой, а отказом 1934 - и выглядит это как
    # «в кольцевом буфере ничего нет».
    $answer = & sqlcmd -S $Server -d $Database -E -b -l 30 -w 500 -W -s '|' -h -1 -Q "SET QUOTED_IDENTIFIER ON; SET NOCOUNT ON; $query" 2>&1
    if ($LASTEXITCODE -ne 0) { Fail "SQL не выполнился: $($answer -join ' ')" }
    return ,@($answer | Where-Object { $_ -and ($_ -notmatch '^\(') })
}
function Scalar([string]$query) {
    $rows = Invoke-Sql $query
    if ($rows.Count -eq 0) { return '' }
    return $rows[0].Trim()
}
function Fields([string]$query) {
    $row = Scalar $query
    if (-not $row) { return @() }
    return @(($row -split '\|') | ForEach-Object { $_.Trim() })
}

$scenePids = @()
function Start-Sqlcmd([string]$name, [string]$sql) {
    # Запрос уезжает ФАЙЛОМ, а не параметром -Q: Start-Process склеивает -ArgumentList
    # пробелом и кавычек вокруг элементов не ставит, а в имени таблицы NAV стоит доллар.
    $file = Join-Path $outDir $name
    [IO.File]::WriteAllText($file, (($sql -replace "`r`n", "`n") -replace "`n", "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
    return Start-Process -FilePath 'sqlcmd' -PassThru -WindowStyle Hidden -ArgumentList @(
        '-S', $Server, '-d', $Database, '-E', '-b', '-l', '30', '-i', $file
    )
}
function Stop-Sqlcmd($process) {
    # Снятие процесса рвёт соединение, а разорванное соединение сервер откатывает сам.
    if ($process -and -not $process.HasExited) { $process.Kill(); $process.WaitForExit(10000) | Out-Null }
}
function Stop-Scene {
    foreach ($p in $script:scenePids) { Stop-Sqlcmd $p }
    $script:scenePids = @()
}
function Stop-Live {
    # Снимать по номеру процесса опасно: номера переиспользуются, и снятый по старому
    # номеру процесс может оказаться чужим. Поэтому имя проверяется до снятия.
    if (-not (Test-Path $liveFile)) { return 0 }
    $killed = 0
    foreach ($line in (Get-Content $liveFile)) {
        if ($line -notmatch '^\d+$') { continue }
        $p = Get-Process -Id ([int]$line) -ErrorAction SilentlyContinue
        if ($p -and ($p.ProcessName -eq 'sqlcmd')) { $p.Kill(); $killed++ }
    }
    Remove-Item $liveFile -ErrorAction SilentlyContinue
    return $killed
}

function Wait-For([scriptblock]$condition, [int]$seconds) {
    # Ждать НАСТУПЛЕНИЯ события, а не спать наугад: сон вслепую делает показ то удачным,
    # то нет в зависимости от того, чем занята машина.
    $deadline = (Get-Date).AddSeconds($seconds)
    while ((Get-Date) -lt $deadline) {
        if (& $condition) { return $true }
        Start-Sleep -Milliseconds 500
    }
    return $false
}

# ---------------------------------------------------------------------------------------
# Разговор с NAV. Модуль живёт только в Windows PowerShell 5.1 - pwsh 7 падает на RealProxy.
# ---------------------------------------------------------------------------------------

$ps51 = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$navImport = "Import-Module 'C:\Program Files\Microsoft Dynamics NAV\110\Service\NavAdminTool.ps1' -DisableNameChecking -WarningAction SilentlyContinue | Out-Null"
function Write-Ps51([string]$path, [string]$body) {
    # Windows PowerShell 5.1 читает файл БЕЗ BOM как ANSI и ломается на кириллице в
    # кавычках: часть команд печатается вместо выполнения.
    [IO.File]::WriteAllText($path, (($body -replace "`r`n", "`n") -replace "`n", "`r`n"), (New-Object System.Text.UTF8Encoding($true)))
}
$probeFile = Join-Path $outDir 'demo-wait-nav.ps1'
Write-Ps51 $probeFile @"
$navImport
`$deadline = (Get-Date).AddMinutes(6)
while ((Get-Date) -lt `$deadline) {
    try { Get-NAVServerSession -ServerInstance $Instance -ErrorAction Stop | Out-Null; exit 0 } catch { Start-Sleep -Seconds 5 }
}
exit 1
"@
function Wait-Nav {
    & $ps51 -NoProfile -ExecutionPolicy Bypass -File $probeFile | Out-Null
    if ($LASTEXITCODE -ne 0) { Fail "экземпляр $Instance не ответил по порту управления" }
}
function Invoke-Method([string]$method) {
    $file = Join-Path $outDir "demo-invoke-$method.ps1"
    Write-Ps51 $file @"
`$ErrorActionPreference = 'Stop'
$navImport
Invoke-NAVCodeunit -ServerInstance $Instance -CompanyName '$Company' -CodeunitId $TaskCodeunitId -MethodName $method -ErrorAction Stop
"@
    $log = & $ps51 -NoProfile -ExecutionPolicy Bypass -File $file 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { Fail "$method не отработал:`n$log" }
}

# ---------------------------------------------------------------------------------------
# Имена: номер таблицы NAV -> имя NAV -> имя SQL. Правило замены знаков у платформы нигде
# не объявлено, поэтому имя переводится не в имя, а в ОБРАЗЕЦ, где каждый незнаковый
# символ подходит к любому одному. Совпасть образец обязан ровно один раз.
# ---------------------------------------------------------------------------------------

function Get-SqlPattern([string]$name) {
    $pattern = ''
    foreach ($ch in $name.ToCharArray()) {
        if ([char]::IsLetterOrDigit($ch) -or ($ch -eq ' ')) { $pattern += $ch } else { $pattern += '_' }
    }
    return $pattern
}
function Resolve-SqlTable([string]$navName) {
    $pattern = (Get-SqlPattern $Company) + '$' + (Get-SqlPattern $navName)
    $tables = Invoke-Sql "SELECT name FROM sys.tables WHERE name LIKE N'$pattern';"
    if ($tables.Count -ne 1) { return '' }
    return $tables[0].Trim()
}
function Resolve-SqlColumn([string]$sqlTable, [string]$navField) {
    $pattern = Get-SqlPattern $navField
    $columns = Invoke-Sql "SELECT c.name FROM sys.columns c WHERE c.object_id = OBJECT_ID(N'[$sqlTable]') AND c.name LIKE N'$pattern';"
    if ($columns.Count -ne 1) { return '' }
    return $columns[0].Trim()
}

# Значения собираются ПО ТИПАМ столбцов, а не по умолчаниям: умолчаний NAV в SQL не
# создаёт вовсе, а NOT NULL стоит почти на всём. Ни одно значение не литерал со скобками -
# SPACE(0) вместо пустой строки, - и текст запроса обходится без вложенных кавычек.
$zeroByType = @'
CASE WHEN t.name IN (N'nvarchar',N'varchar',N'char',N'nchar',N'text',N'ntext',N'xml') THEN N'SPACE(0)'
     WHEN t.name IN (N'datetime',N'datetime2',N'smalldatetime',N'date',N'time',N'datetimeoffset') THEN N'CONVERT(datetime,0)'
     WHEN t.name = N'uniqueidentifier' THEN N'CONVERT(uniqueidentifier,0x00000000000000000000000000000000)'
     WHEN t.name IN (N'binary',N'varbinary',N'image') THEN N'0x'
     ELSE N'0' END
'@

function New-DocRow([string]$sqlTable, [string]$docColumn, [string]$docNo) {
    # Строка собирается динамически по списку столбцов: их у таблицы установки две сотни,
    # и список у каждой установки свой. Столбцы IDENTITY в список вставки не берутся -
    # значение им выбирает сервер.
    $sql = @'
DECLARE @t sysname = N'{T}', @col sysname = N'{C}', @doc nvarchar(20) = N'{D}';
DECLARE @cols nvarchar(max) = N'', @vals nvarchar(max) = N'', @sql nvarchar(max);
IF NOT EXISTS (SELECT 1 FROM {Q} WHERE [{C}] = @doc)
BEGIN
  SELECT @cols = @cols + CASE WHEN @cols = N'' THEN N'' ELSE N',' END + QUOTENAME(c.name),
         @vals = @vals + CASE WHEN @vals = N'' THEN N'' ELSE N',' END +
           CASE WHEN c.name = @col THEN N'@doc' ELSE {Z} END
  FROM sys.columns c JOIN sys.types t ON t.user_type_id = c.user_type_id
  WHERE c.object_id = OBJECT_ID(QUOTENAME(@t)) AND c.is_computed = 0 AND c.is_identity = 0
    AND t.name <> N'timestamp';
  SET @sql = N'INSERT INTO ' + QUOTENAME(@t) + N' (' + @cols + N') VALUES (' + @vals + N');';
  EXEC sp_executesql @sql, N'@doc nvarchar(20)', @doc = @doc;
END
'@
    $sql = $sql.Replace('{T}', $sqlTable).Replace('{Q}', "[$sqlTable]").Replace('{C}', $docColumn).Replace('{D}', $docNo).Replace('{Z}', $zeroByType)
    Invoke-Sql $sql | Out-Null
}

function Get-KeyPredicate([string]$sqlTable, [string]$docColumn, [string]$docNo) {
    # Блокировка ставится по ПЕРВИЧНОМУ КЛЮЧУ, а не по полю документа: поле документа может
    # быть неиндексированным, и запрос по нему взял бы блокировки на всю таблицу.
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
    $sql = $sql.Replace('{T}', $sqlTable).Replace('{C}', $docColumn).Replace('{D}', $docNo).Replace('{Z}', $zeroByType)
    return (Scalar $sql)
}

# ---------------------------------------------------------------------------------------
# Чтение журнала для пересказа на экране
# ---------------------------------------------------------------------------------------

$classWords   = "CASE [Class] WHEN 0 THEN 'обычный' WHEN 1 THEN 'эскалация' WHEN 2 THEN 'спящая транзакция' WHEN 3 THEN 'взаимоблокировка' ELSE '?' END"
$outcomeWords = "CASE [Outcome] WHEN 0 THEN 'не определён' WHEN 1 THEN 'дождался' WHEN 2 THEN 'предел ожидания' WHEN 3 THEN 'разорвана сервером' ELSE '?' END"
$docWords     = "CASE [Document Source] WHEN 0 THEN 'нет' WHEN 1 THEN 'по хэшу блокировки' WHEN 2 THEN 'из отметки' WHEN 3 THEN 'дороги разошлись' ELSE '?' END"
$userWords    = "CASE [User Source] WHEN 0 THEN 'нет' WHEN 1 THEN 'из отметки' WHEN 2 THEN 'от платформы' ELSE '?' END"

function Last-Episode {
    # Сценам нужен ИХ эпизод, а не просто последняя строка журнала. Круги приезжают из
    # кольцевого буфера в тот проход, когда сторож до него дошёл, и номер записи у них
    # больше: круг, устроенный в начале показа, приезжал посреди третьей сцены и
    # пересказывался под её заголовком - взаимоблокировка вместо очереди из троих.
    # Поэтому круги здесь отсекаются (у них своя сцена и свой запрос), а открытая строка
    # идёт вперёд закрытой: сцена рассказывает о том, что происходит ПРЯМО СЕЙЧАС.
    return Fields @"
SELECT TOP 1 [NAV Table Name] + '|' + CONVERT(varchar(11),[NAV Key No_]) + '|' + [Held Mode] + '|' +
  [Wait Type] + '|' + $classWords + '|' + $outcomeWords + '|' +
  CONVERT(varchar(11),[Max Wait (ms)]) + '|' +
  CASE WHEN [Document No_] = '' THEN '-' ELSE [Document No_] END + '|' + $docWords + '|' +
  CASE WHEN [User Name] = '' THEN '-' ELSE [User Name] END + '|' + $userWords + '|' +
  CASE WHEN [Advice] = '' THEN '-' ELSE [Advice] END + '|' +
  CASE WHEN [Blocker Login] = '' THEN '-' ELSE [Blocker Login] END + '|' +
  CASE WHEN [Blocker Program] = '' THEN '-' ELSE [Blocker Program] END + '|' +
  CONVERT(varchar(11),[Victim SPID]) + '|' + CONVERT(varchar(11),[Head SPID]) + '|' +
  CONVERT(varchar(11),[Victims Behind Head]) + '|' +
  CASE WHEN [No Document Reason] = '' THEN '-' ELSE [No Document Reason] END + '|' +
  CONVERT(varchar(11),ISNULL(DATALENGTH([Blocker Statement Text]),0)) + '|' +
  CONVERT(varchar(11),ISNULL(DATALENGTH([Victim Statement]),0)) + '|' +
  CONVERT(varchar(11),[Entry No_])
FROM $episode WHERE [Class] <> 3 ORDER BY [Open] DESC, [Entry No_] DESC;
"@
}

function Tell-Episode($f) {
    if ($f.Count -lt 21) { Warn 'в журнале пусто'; return }
    Say "журнал: таблица [$($f[0])], ключ NAV $($f[1]), режим $($f[2]), ожидание $($f[3])"
    Say "        эпизод $($f[4]), исход - $($f[5]), ждали $($f[6]) мс"
    if ($f[7] -ne '-') { Say "        документ $($f[7]) ($($f[8]))" } else { Say "        документ не назван: $($f[17])" }
    if ($f[9] -ne '-') { Say "        учётная запись $($f[9]) ($($f[10]))" }
    # Учётная запись NAV и логин SQL - разные ответы на разные вопросы, и порознь они
    # честнее. Отметку кладёт только сессия NAV; за чужим соединением - утилитой, заданием,
    # чьим-то окном запросов - учётной записи NAV нет и быть не может, зато сервер знает о
    # нём логин и программу, и это единственный ответ на "кто", какой вообще возможен.
    if ($f[12] -ne '-') { Say "        держит: логин SQL $($f[12]), программа $($f[13])" }
    Say "        жертва $($f[14]), голова цепочки $($f[15]), за головой жертв: $($f[16])"
    Say "        совет: $($f[11])"
    Say "        оператор виновника $($f[18]) байт, оператор жертвы $($f[19]) байт"
}

# ---------------------------------------------------------------------------------------
# Клиент
# ---------------------------------------------------------------------------------------

function Get-ClientPort {
    $candidates = @(
        "C:\Program Files\Microsoft Dynamics NAV\110\Service\Instances\$Instance\CustomSettings.config",
        "C:\Program Files\Microsoft Dynamics NAV\110\Service\$Instance\CustomSettings.config",
        'C:\Program Files\Microsoft Dynamics NAV\110\Service\CustomSettings.config'
    )
    foreach ($path in $candidates) {
        if (-not (Test-Path $path)) { continue }
        $value = ([xml](Get-Content $path)).appSettings.add |
                 Where-Object { $_.key -eq 'ClientServicesPort' } |
                 Select-Object -First 1 -ExpandProperty value
        if ($value) { return [int]$value }
    }
    return 0
}

function Open-Client([int]$pageId) {
    $exe = 'C:\Program Files (x86)\Microsoft Dynamics NAV\110\RoleTailored Client\Microsoft.Dynamics.Nav.Client.exe'
    if (-not (Test-Path $exe)) { Warn "клиента нет на месте: $exe"; return $false }
    $port = Get-ClientPort
    if ($port -le 0) { Warn 'порт клиентских служб не прочитался - клиент не открываю'; return $false }

    # Отдельный файл настроек ровно под стенд. Иначе клиент показывает модальное
    # "Извещение системы безопасности" - адрес не совпадает с умолчанием, - и окно это
    # легко уезжает за другие: выглядит как зависший клиент.
    $cfgDir  = Join-Path $env:APPDATA 'Microsoft\Microsoft Dynamics NAV\110'
    $cfgPath = Join-Path $cfgDir "ClientUserSettings-$Instance.config"
    if (-not (Test-Path $cfgDir)) { New-Item -ItemType Directory -Force -Path $cfgDir | Out-Null }
    $cfg = @"
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <appSettings>
    <add key="Server" value="$Server" />
    <add key="ClientServicesPort" value="$port" />
    <add key="ServerInstance" value="$Instance" />
    <add key="TenantId" value="" />
    <add key="ClientServicesCredentialType" value="Windows" />
    <add key="ClientServicesProtectionLevel" value="EncryptAndSign" />
    <add key="ServicePrincipalNameRequired" value="False" />
    <add key="AllowNtlm" value="true" />
    <add key="UrlHistory" value="$Server`:$port/$Instance" />
    <add key="UnknownSpnHint" value="(net.tcp://$Server`:$port/$Instance/Service)=NoSpn;" />
  </appSettings>
</configuration>
"@
    [IO.File]::WriteAllText($cfgPath, $cfg, (New-Object Text.UTF8Encoding($false)))

    $url = 'dynamicsnav://{0}:{1}/{2}/{3}/runpage?page={4}' -f $Server, $port, $Instance, [uri]::EscapeDataString($Company), $pageId
    # Путь к настройкам содержит пробелы - без кавычек клиент молча падает на разборе.
    Start-Process -FilePath $exe -ArgumentList @('-settings:"' + $cfgPath + '"', $url) | Out-Null
    Say "клиент запущен: страница $pageId, компания $Company, порт $port"
    Say 'первый вход после старта службы молча собирает business assemblies - это не зависание'
    return $true
}

# ---------------------------------------------------------------------------------------
# Уборка
# ---------------------------------------------------------------------------------------

if ($Clean) {
    Head 'Возвращаю стенд как было'
    $killed = Stop-Live
    if ($killed -gt 0) { Say "снял держателей живого эпизода: $killed" }

    if ((Get-Service $service).Status -eq 'Running') {
        Invoke-Method 'StopWatch'
        Say 'сторож остановлен'
    } else {
        Warn 'служба остановлена - сторожа гашу строкой настройки, задачу снимаю запросом'
    }

    $sqlTable = ''; $docColumn = ''
    if (Test-Path $targetFile) {
        $saved = @(Get-Content $targetFile)
        if ($saved.Count -ge 2) { $sqlTable = $saved[0].Trim(); $docColumn = $saved[1].Trim() }
    }
    if ($sqlTable -and $docColumn) {
        $left = Scalar "SELECT COUNT(*) FROM [$sqlTable] WHERE [$docColumn] LIKE N'$demoLike';"
        Invoke-Sql "DELETE FROM [$sqlTable] WHERE [$docColumn] LIKE N'$demoLike';" | Out-Null
        Say "убрал подложенные строки из [$sqlTable]: $left"
    } else {
        Warn "цель показа не записана ($targetFile) - подложенные строки не трогаю"
    }

    Invoke-Sql @"
DELETE FROM $episode;
DELETE FROM $alert;
DELETE FROM $coverage;
DELETE FROM $mark WHERE [Server Instance Id] < 0;
DELETE FROM $context WHERE [Table No_] = $TableNo;
DELETE FROM $tasks WHERE [Run Codeunit] = $TaskCodeunitId;
UPDATE $setup SET [Enabled] = 0, [Collect Statement Values] = 0, [Alert Threshold (ms)] = 5000,
                  [Alert Channel] = 1;
DELETE FROM $state;
"@ | Out-Null
    Say 'журнал, тревоги, охват, отметки и строка контекста очищены; настройка - заводская'

    if (-not $NoMenu) {
        $merge = Join-Path $PSScriptRoot 'Merge-MenuSuite.ps1'
        if (Test-Path $merge) {
            & pwsh -NoProfile -File $merge -Server $Server -Database $Database -Remove -Import | Out-Null
            if ($LASTEXITCODE -eq 0) { Say 'пункты меню сняты' } else { Warn 'меню снять не удалось - смотрите out/' }
        }
    }
    # Служба держит настройку в кэше, и правка мимо NAV до сессии не дойдёт: без
    # перезапуска инструмент в клиенте остался бы в том виде, в каком его застал показ.
    if ((Get-Service $service).Status -eq 'Running') {
        Say 'перезапускаю службу - иначе кэш вернёт настройку показа'
        Restart-Service $service -Force
    }
    Write-Host ''
    Good 'Стенд возвращён: сторожа нет, журнал пуст, настройка заводская'
    exit 0
}

# ---------------------------------------------------------------------------------------
# Показ
# ---------------------------------------------------------------------------------------

$startedAt = Get-Date
try {
    Head 'Готовлю стенд'
    if ((Get-Service $service).Status -ne 'Running') {
        Say "поднимаю службу $Instance"
        Start-Service $service
    }
    $objects = [int](Scalar "SELECT COUNT(*) FROM dbo.[Object] WHERE [ID] BETWEEN 110230 AND 110249 AND [Type] <> 0;")
    if ($objects -eq 0) { Fail 'объектов инструмента в базе нет - сначала выкладка: pwsh scripts/Test-OnStand.ps1 -Run' }
    Say "объектов инструмента в базе: $objects"

    # Правка настройки мимо NAV в кэш работающей службы не доходит, поэтому всё, что
    # инструмент должен УВИДЕТЬ, пишется ДО перезапуска. Это касается и строки контекста:
    # список таблиц документа служба тоже держит в кэше.
    Invoke-Sql @"
UPDATE $setup SET [SQL Server] = N'$Server',
                  [Collect Statement Values] = 1, [Deadlocks Enabled] = 1,
                  [Coverage Enabled] = 1, [Alert Channel] = 2,
                  [Alert Threshold (ms)] = $(DemoAlertMs);
$stateSeed
UPDATE $state SET [Watchdog Message] = N'', [Deadlocks Read Until] = GETDATE();
DELETE FROM $episode;
DELETE FROM $alert;
DELETE FROM $coverage;
DELETE FROM $mark WHERE [Server Instance Id] < 0;
DELETE FROM $context WHERE [Table No_] = $TableNo;
INSERT INTO $context ([Table No_],[Table Name],[Document Field No_],[Document Field Name],[Document Caption],[Enabled])
VALUES ($TableNo,N'',$FieldNo,N'',N'',1);
"@ | Out-Null
    Say "таблица документа объявлена номерами: таблица $TableNo, поле $FieldNo - имена спросим у NAV"
    Say "текст запросов на время показа включён, порог тревоги $(DemoAlertMs) мс при заводских 5000"
    # В кольцевом буфере сервера лежат круги от прошлых прогонов и от чужой работы на той
    # же базе. Строки о них были бы законными, но показ обязан показывать СВОЁ: иначе
    # человек смотрит на журнал и не может отличить, что здесь только что случилось.
    Say 'отметка «взаимоблокировки прочитаны до» поставлена на сейчас - чужие круги из буфера не берём'

    Say "перезапускаю службу $Instance и жду ответа порта управления"
    Restart-Service $service -Force
    Wait-Nav

    Invoke-Method 'RefreshContextNames'
    $names = Fields "SELECT TOP 1 [Table Name] + '|' + [Document Field Name] FROM $context WHERE [Table No_] = $TableNo;"
    if (($names.Count -lt 2) -or ($names[0] -eq '')) { Fail "NAV не назвал таблицу $TableNo по номеру - показывать нечего" }
    $navTable = $names[0]; $navField = $names[1]
    Good "NAV назвал их сам: таблица [$navTable], поле [$navField]"

    $sqlTable = Resolve-SqlTable $navTable
    if (-not $sqlTable) { Fail "имя таблицы [$navTable] в SQL однозначно не нашлось" }
    $docColumn = Resolve-SqlColumn $sqlTable $navField
    if (-not $docColumn) { Fail "имя столбца [$navField] в SQL однозначно не нашлось" }
    [IO.File]::WriteAllText($targetFile, "$sqlTable`r`n$docColumn`r`n", (New-Object System.Text.UTF8Encoding($false)))
    Say "в SQL это [$sqlTable], столбец [$docColumn]"

    foreach ($doc in @($docHash, $docQueue, $docLive)) { New-DocRow $sqlTable $docColumn $doc }
    Say "подложены строки показа: $docHash, $docQueue, $docLive (уберёт ключ -Clean)"

    if (-not $NoMenu) {
        Head 'Врезаю пункты в меню установки'
        $merge = Join-Path $PSScriptRoot 'Merge-MenuSuite.ps1'
        & pwsh -NoProfile -File $merge -Server $Server -Database $Database -Import | Out-Null
        if ($LASTEXITCODE -eq 0) { Good 'меню слито: оригинал сохранён в out/menusuite-1090-original.txt' }
        else { Warn 'слить меню не удалось - страницы открываются и без него' }
    }

    if (-not $NoClient) {
        Head 'Открываю клиент на журнале эпизодов'
        Open-Client $EpisodesPageId | Out-Null
    }

    Head 'Завожу сторожа'
    # Гасим то, что могло остаться от прошлого показа, И ДОЖИДАЕМСЯ тишины: задача, уже
    # исполняющаяся, строки в таблице не имеет, и её проход всё равно случится.
    Invoke-Method 'StopWatch'
    Wait-For { ([int](Scalar "SELECT COUNT(*) FROM $tasks WHERE [Run Codeunit] = $TaskCodeunitId AND [Company] = N'$Company';")) -eq 0 } 30 | Out-Null
    $before = Scalar "SELECT ISNULL(CONVERT(varchar(30),[Last Pass At],121),'') FROM $state;"
    Invoke-Method 'StartWatch'
    if (-not (Wait-For { (Scalar "SELECT ISNULL(CONVERT(varchar(30),[Last Pass At],121),'') FROM $state;") -ne $before } (CatchSeconds))) {
        Fail 'сторож не проснулся ни разу - показывать нечего'
    }
    $period = Scalar "SELECT CONVERT(varchar(11),[Poll Period (ms)]) FROM $setup;"
    Good "сторож пошёл сам, период опроса $period мс при пределе ожидания NAV $(LockTimeoutNavMs) мс"
    Say 'дальше показ не делает НИ ОДНОГО ручного прохода: журнал заполняет сторож'

    # -----------------------------------------------------------------------------------
    # Учётная запись, которую положил бы переходник: у отметки в поле [User Id] лежит
    # USERID сессии NAV, а не логин SQL - это разные вещи, и путать их нельзя.
    $demoUser = "$env:USERDOMAIN\$env:USERNAME"

    Head 'Круг (устраиваю заранее)'
    Say 'кольцевой буфер сервера инструмент читает раз в минуту - ждать её в тишине незачем'
    Invoke-Sql @"
DELETE FROM $mark WHERE [Server Instance Id] IN (-11,-12);
INSERT INTO $mark ([Server Instance Id],[Session Id],[User Id],[Company Name],[Table No_],[Document No_],[Marked At])
VALUES (-11,-11,N'DEMO',N'$Company',0,N'CIRCLE-A',GETDATE()),
       (-12,-12,N'DEMO',N'$Company',0,N'CIRCLE-B',GETDATE());
"@ | Out-Null
    $circleMade = $false
    for ($attempt = 1; $attempt -le (CircleAttempts); $attempt++) {
        # Круг - опыт ВЕРОЯТНОСТНЫЙ, и это его свойство, а не недоделка: обе стороны
        # обязаны взять свою строку раньше, чем соперник потянется за ней. Приоритеты
        # назначены нарочно - жертвой сервер выберет ту, что с LOW, и исход предсказуем.
        $a = "SET DEADLOCK_PRIORITY LOW`nBEGIN TRAN`nUPDATE $mark SET [Document No_]=N'CIRCLE-A' WHERE [Server Instance Id]=-11`nWAITFOR DELAY '$(CircleHold)'`nUPDATE $mark SET [Document No_]=N'CIRCLE-A' WHERE [Server Instance Id]=-12`nCOMMIT`n"
        $b = "SET DEADLOCK_PRIORITY HIGH`nBEGIN TRAN`nUPDATE $mark SET [Document No_]=N'CIRCLE-B' WHERE [Server Instance Id]=-12`nWAITFOR DELAY '$(CircleHold)'`nUPDATE $mark SET [Document No_]=N'CIRCLE-B' WHERE [Server Instance Id]=-11`nCOMMIT`n"
        $pa = Start-Sqlcmd 'demo-circle-a.sql' $a
        $pb = Start-Sqlcmd 'demo-circle-b.sql' $b
        $script:scenePids += @($pa, $pb)
        $pa.WaitForExit(60000) | Out-Null
        $pb.WaitForExit(60000) | Out-Null
        Stop-Scene
        $graph = [int](Scalar @"
SELECT COUNT(*) FROM (
  SELECT CONVERT(xml,target_data) AS td FROM sys.dm_xe_session_targets t
  JOIN sys.dm_xe_sessions s ON s.address = t.event_session_address
  WHERE s.name = N'system_health' AND t.target_name = N'ring_buffer') r
CROSS APPLY r.td.nodes('RingBufferTarget/event[@name=''xml_deadlock_report'']') AS x(e)
WHERE x.e.value('(@timestamp)[1]','datetime') > DATEADD(minute,-2,GETUTCDATE());
"@)
        if ($graph -gt 0) { $circleMade = $true; Good "круг состоялся с попытки $attempt - сервер разорвал его сам"; break }
        Warn "попытка ${attempt}: круга не вышло, обе стороны успели разойтись"
    }
    if (-not $circleMade) { Warn 'круга не вышло за все попытки - взаимоблокировку в этом показе не увидим' }

    # -----------------------------------------------------------------------------------
    Head 'Сцена 1. За какой документ идёт спор - и кто его держит'
    Say "виновник держит строку документа $docHash, жертва тянется за той же строкой"
    Say 'виновник оставляет и отметку контекста - ровно так, как её оставляет переходник'
    Say 'обе дороги отвечают: документ приходит по хэшу спорной строки, человек - из отметки'
    $where = Get-KeyPredicate $sqlTable $docColumn $docHash
    if (-not $where) { Fail 'первичный ключ таблицы документа не определён' }
    Invoke-Sql @"
DELETE FROM $mark WHERE [Server Instance Id] = -1;
INSERT INTO $mark ([Server Instance Id],[Session Id],[User Id],[Company Name],[Table No_],[Document No_],[Marked At])
VALUES (-1,-1,N'$demoUser',N'$Company',$TableNo,N'$docHash',GETDATE());
"@ | Out-Null
    # В таблице УСТАНОВКИ держатель ничего не меняет: UPDLOCK даёт ту же блокировку рода
    # KEY, что и запись, но данных не трогает. Правится только своя строка отметки - её и
    # правит переходник, в той же транзакции, чем и держит на ней блокировку.
    $hold = "SET LOCK_TIMEOUT -1`nBEGIN TRAN`nUPDATE $mark SET [Document No_]=N'$docHash' WHERE [Server Instance Id]=-1`nSELECT 1 FROM [$sqlTable] WITH (UPDLOCK, ROWLOCK) WHERE $where`nWAITFOR DELAY '00:05:00'`nROLLBACK`n"
    $want = "SET LOCK_TIMEOUT -1`nBEGIN TRAN`nSELECT TOP 1 1 FROM [$sqlTable] WITH (UPDLOCK, ROWLOCK) WHERE $where`nROLLBACK`n"
    $blocker = Start-Sqlcmd 'demo-doc-hold.sql' $hold
    $script:scenePids += $blocker
    Start-Sleep -Seconds 2
    $waiter = Start-Sqlcmd 'demo-doc-want.sql' $want
    $script:scenePids += $waiter
    if (-not (Wait-For { ([int](Scalar "SELECT COUNT(*) FROM $episode WHERE [Open] = 1;")) -gt 0 } (CatchSeconds))) {
        Fail 'сторож блокировку не увидел - показывать нечего'
    }
    Good 'эпизод открыт сторожем, без единого нажатия'
    Start-Sleep -Seconds (ShortHoldSeconds)
    Tell-Episode (Last-Episode)
    Stop-Scene
    if (Wait-For { ([int](Scalar "SELECT COUNT(*) FROM $episode WHERE [Open] = 0;")) -gt 0 } (CatchSeconds)) {
        Good 'блокировка отпущена - эпизод закрылся сам'
    }

    # -----------------------------------------------------------------------------------
    Head 'Сцена 2. Кто человек'
    $plainTableSql = Resolve-SqlTable $PlainTable
    $plainRows = 0
    if ($plainTableSql) { $plainRows = [int](Scalar "SELECT COUNT(*) FROM (SELECT TOP 1 1 AS x FROM [$plainTableSql] WITH (NOLOCK)) c;") }
    if (-not $plainTableSql -or ($plainRows -eq 0)) {
        Warn "штатная таблица [$PlainTable] не найдена или пуста - сцену пропускаю"
    } else {
        Say "спор идёт за строку штатной таблицы [$plainTableSql] - она таблицей документа НЕ объявлена"
        Say 'дорога по хэшу здесь молчит по делу, и отвечает отметка контекста'
        Say "отметку кладёт переходник в той же транзакции; на стенде её кладёт показ - подписчика на чужую таблицу мы не оставляем"
        Invoke-Sql @"
DELETE FROM $mark WHERE [Server Instance Id] = -1;
INSERT INTO $mark ([Server Instance Id],[Session Id],[User Id],[Company Name],[Table No_],[Document No_],[Marked At])
VALUES (-1,-1,N'$demoUser',N'$Company',$TableNo,N'$docMark',GETDATE());
"@ | Out-Null
        # Отметка правится В ТОЙ ЖЕ транзакции, что и захват чужой строки: инструмент
        # находит её не по времени, а по монопольной блокировке той же транзакции.
        $hold = "SET LOCK_TIMEOUT -1`nBEGIN TRAN`nUPDATE $mark SET [Document No_]=N'$docMark' WHERE [Server Instance Id]=-1`nSELECT TOP 1 1 FROM [$plainTableSql] WITH (UPDLOCK, ROWLOCK, INDEX(0))`nWAITFOR DELAY '00:05:00'`nROLLBACK`n"
        $want = "SET LOCK_TIMEOUT -1`nBEGIN TRAN`nSELECT TOP 1 1 FROM [$plainTableSql] WITH (UPDLOCK, ROWLOCK, INDEX(0))`nROLLBACK`n"
        $blocker = Start-Sqlcmd 'demo-user-hold.sql' $hold
        $script:scenePids += $blocker
        Start-Sleep -Seconds 2
        $waiter = Start-Sqlcmd 'demo-user-want.sql' $want
        $script:scenePids += $waiter
        if (Wait-For { ([int](Scalar "SELECT COUNT(*) FROM $episode WHERE [Open] = 1;")) -gt 0 } (CatchSeconds)) {
            Good 'эпизод открыт'
            Start-Sleep -Seconds (ShortHoldSeconds)
            Tell-Episode (Last-Episode)
        } else { Warn 'сторож эту блокировку не увидел' }
        Stop-Scene
        Wait-For { ([int](Scalar "SELECT COUNT(*) FROM $episode WHERE [Open] = 1;")) -eq 0 } (CatchSeconds) | Out-Null
    }

    # -----------------------------------------------------------------------------------
    Head 'Сцена 3. Кто пострадал, и когда это уже тревога'
    Say "виновник держит строку $docQueue, за ней встают $(QueueVictims) жертвы"
    $where = Get-KeyPredicate $sqlTable $docColumn $docQueue
    $hold = "SET LOCK_TIMEOUT -1`nBEGIN TRAN`nSELECT 1 FROM [$sqlTable] WITH (UPDLOCK, ROWLOCK) WHERE $where`nWAITFOR DELAY '00:05:00'`nROLLBACK`n"
    $want = "SET LOCK_TIMEOUT -1`nBEGIN TRAN`nSELECT TOP 1 1 FROM [$sqlTable] WITH (UPDLOCK, ROWLOCK) WHERE $where`nROLLBACK`n"
    $blocker = Start-Sqlcmd 'demo-queue-hold.sql' $hold
    $script:scenePids += $blocker
    Start-Sleep -Seconds 2
    for ($i = 1; $i -le (QueueVictims); $i++) {
        $script:scenePids += Start-Sqlcmd "demo-queue-want-$i.sql" $want
        Start-Sleep -Milliseconds 300
    }
    if (Wait-For { ([int](Scalar "SELECT COUNT(*) FROM $episode WHERE [Open] = 1;")) -ge (QueueVictims) } (CatchSeconds)) {
        Good "в очереди $(QueueVictims) жертвы, голова у всех одна"
    } else { Warn 'очередь целиком в журнал не попала' }
    Say "держу дольше порога тревоги - $(QueueHoldSeconds) с при пороге $(DemoAlertMs) мс"
    Start-Sleep -Seconds (QueueHoldSeconds)
    Tell-Episode (Last-Episode)
    $alerts = Fields @"
SELECT TOP 1 CONVERT(varchar(11),[Head SPID]) + '|' + [NAV Table Name] + '|' +
  CONVERT(varchar(11),[Episodes]) + '|' + CONVERT(varchar(11),[Max Wait (ms)]) + '|' +
  CONVERT(varchar(11),[Threshold (ms)]) + '|' +
  CASE [Channel] WHEN 0 THEN 'только журнал' ELSE 'журнал событий Windows' END + '|' +
  CASE WHEN [Channel Note] = '' THEN '-' ELSE [Channel Note] END
FROM $alert ORDER BY [Entry No_] DESC;
"@
    if ($alerts.Count -ge 7) {
        Good "тревога поднята: голова $($alerts[0]), таблица [$($alerts[1])], эпизодов под ней $($alerts[2])"
        Say "        ждали $($alerts[3]) мс при пороге $($alerts[4]) мс, канал - $($alerts[5])"
        Say "        наружу: $($alerts[6])"
    } else { Warn 'тревоги в журнале тревог нет' }
    Stop-Scene
    Wait-For { ([int](Scalar "SELECT COUNT(*) FROM $episode WHERE [Open] = 1;")) -eq 0 } (CatchSeconds) | Out-Null

    # -----------------------------------------------------------------------------------
    Head 'Сцена 4. Взаимоблокировка'
    if ($circleMade) {
        Say 'круг был устроен в начале показа - смотрим, прочитал ли сторож буфер'
        if (Wait-For { ([int](Scalar "SELECT COUNT(*) FROM $episode WHERE [Class] = 3;")) -gt 0 } 90) {
            $dead = Fields @"
SELECT TOP 1 [NAV Table Name] + '|' + [Deadlock Id] + '|' + $outcomeWords + '|' +
  CONVERT(varchar(11),[Victim SPID]) + '|' + CONVERT(varchar(11),[Blocker SPID]) + '|' +
  CASE WHEN [Blocker Statement] = '' THEN '-'
       ELSE REPLACE(REPLACE([Blocker Statement],CHAR(13),' '),CHAR(10),' ') END + '|' +
  CONVERT(varchar(11),ISNULL(DATALENGTH([Blocker Statement Text]),0))
FROM $episode WHERE [Class] = 3 ORDER BY [Entry No_] DESC;
"@
            Good 'взаимоблокировка записана из кольцевого буфера'
            Say "        таблица [$($dead[0])], круг $($dead[1]), исход - $($dead[2])"
            Say "        жертва $($dead[3]), виновник $($dead[4])"
            Say "        оператор: $($dead[5])"
            Say "        полный текст в блобе: $($dead[6]) байт"
        } else { Warn 'сторож ещё не прочитал буфер - строка появится сама в течение минуты' }
    } else {
        Warn 'круга не вышло - этой сцены в журнале не будет'
    }

    # -----------------------------------------------------------------------------------
    Head 'Сцена 5. Исход, который инструмент готов назвать'
    Say 'до сих пор жертвами были соединения sqlcmd, и исход у всех - «не определён»'
    Say 'это не осторожность на словах: предел в 10 000 мс - предел NAV, а чужое соединение'
    Say 'ждёт сколько угодно, и приписывать ему исход не по чему'
    Say 'теперь жертва - настоящая сессия NAV, и исход становится вопросом арифметики'
    Invoke-Sql @"
DELETE FROM $mark WHERE [Server Instance Id] = -1;
INSERT INTO $mark ([Server Instance Id],[Session Id],[User Id],[Company Name],[Table No_],[Document No_],[Marked At])
VALUES (-1,-1,N'$demoUser',N'$Company',$TableNo,N'$docMark',GETDATE());
"@ | Out-Null
    $hold = "SET LOCK_TIMEOUT -1`nBEGIN TRAN`nUPDATE $mark SET [Document No_]=N'HELD-BY-SQL' WHERE [Server Instance Id]=-1`nWAITFOR DELAY '00:01:00'`nROLLBACK`n"
    $blocker = Start-Sqlcmd 'demo-nav-hold.sql' $hold
    $script:scenePids += $blocker
    Start-Sleep -Seconds 2

    # Жертвой становится Codeunit 110242: он берёт LOCKTABLE на ту же строку отметки из
    # сессии NAV и встаёт в очередь по-настоящему. Ждать его окончания нельзя - взяв
    # блокировку, он держит её минуту, и это его мерная задержка, а не наша.
    $holdFile = Join-Path $outDir 'demo-nav-victim.ps1'
    Write-Ps51 $holdFile @"
`$ErrorActionPreference = 'Stop'
$navImport
Invoke-NAVCodeunit -ServerInstance $Instance -CompanyName '$Company' -CodeunitId 110242 -MethodName Hold -ErrorAction Stop
"@
    $navVictim = Start-Process -FilePath $ps51 -PassThru -WindowStyle Hidden -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $holdFile)
    Say 'сессия NAV встала в очередь за той же строкой'

    # Отпускать надо БЫСТРО. У NAV предел ожидания 10 000 мс: промедлив, показ получил бы
    # честный, но другой исход - "предел ожидания", - и в том и в другом случае врать
    # инструменту не о чем.
    $sawNav = Wait-For { ([int](Scalar "SELECT COUNT(*) FROM $episode WHERE [Victim Is NAV] = 1 AND [Open] = 1;")) -gt 0 } 90
    if ($sawNav) {
        Good 'сторож увидел жертву и узнал в ней сессию NAV'
        Stop-Sqlcmd $blocker
        Say 'блокировка отпущена - жертва получает строку'
        Wait-For { ([int](Scalar "SELECT COUNT(*) FROM $episode WHERE [Victim Is NAV] = 1 AND [Open] = 0;")) -gt 0 } (CatchSeconds) | Out-Null
        $nav = Fields @"
SELECT TOP 1 CONVERT(varchar(11),[Max Wait (ms)]) + '|' + $outcomeWords + '|' +
  CASE WHEN [Victim Host] = '' THEN '-' ELSE [Victim Host] END + '|' +
  CONVERT(varchar(11),[Victim Process Id]) + '|' +
  CASE WHEN [Document No_] = '' THEN '-' ELSE [Document No_] END + '|' +
  CASE WHEN [User Name] = '' THEN '-' ELSE [User Name] END
FROM $episode WHERE [Victim Is NAV] = 1 ORDER BY [Entry No_] DESC;
"@
        if ($nav.Count -ge 6) {
            Good "исход назван: $($nav[1]), ждали $($nav[0]) мс при пределе $(LockTimeoutNavMs) мс"
            Say "        жертва: узел $($nav[2]), процесс $($nav[3])"
            Say "        документ $($nav[4]), учётная запись $($nav[5])"
        }
    } else {
        Warn 'сессия NAV в очередь не встала - сцену пропускаю'
        Stop-Sqlcmd $blocker
    }
    Say 'сессия NAV держит строку отметки ещё около минуты - это её мерная задержка'

    # -----------------------------------------------------------------------------------
    Head 'Живой эпизод'
    Say "оставляю блокировку на $(LiveHoldMinutes) мин: на экране будет ОТКРЫТЫЙ эпизод"
    $where = Get-KeyPredicate $sqlTable $docColumn $docLive
    $liveHold = "SET LOCK_TIMEOUT -1`nBEGIN TRAN`nSELECT 1 FROM [$sqlTable] WITH (UPDLOCK, ROWLOCK) WHERE $where`nWAITFOR DELAY '00:0$(LiveHoldMinutes):00'`nROLLBACK`n"
    $liveWant = "SET LOCK_TIMEOUT -1`nBEGIN TRAN`nSELECT TOP 1 1 FROM [$sqlTable] WITH (UPDLOCK, ROWLOCK) WHERE $where`nROLLBACK`n"
    $liveA = Start-Sqlcmd 'demo-live-hold.sql' $liveHold
    Start-Sleep -Seconds 2
    $liveB = Start-Sqlcmd 'demo-live-want.sql' $liveWant
    [IO.File]::WriteAllText($liveFile, "$($liveA.Id)`r`n$($liveB.Id)`r`n", (New-Object System.Text.UTF8Encoding($false)))
    if (Wait-For { ([int](Scalar "SELECT COUNT(*) FROM $episode WHERE [Open] = 1;")) -gt 0 } (CatchSeconds)) {
        Good 'эпизод открыт и растёт - обновляйте страницу (F5), ожидание прибавляется'
    } else { Warn 'живой эпизод в журнал не попал' }
}
finally {
    Stop-Scene
}

# ---------------------------------------------------------------------------------------
# Что получилось
# ---------------------------------------------------------------------------------------

$total   = [int](Scalar "SELECT COUNT(*) FROM $episode;")
$open    = [int](Scalar "SELECT COUNT(*) FROM $episode WHERE [Open] = 1;")
$alerted = [int](Scalar "SELECT COUNT(*) FROM $alert;")
$covered = [int](Scalar "SELECT COUNT(*) FROM $coverage;")
$minutes = [math]::Round(((Get-Date) - $startedAt).TotalMinutes, 1)

Write-Host ''
Write-Host 'ЖУРНАЛ ЭПИЗОДОВ' -ForegroundColor Cyan
Write-Host ''
Write-Host ('{0,-4} {1,-9} {2,-24} {3,-4} {4,-18} {5,-19} {6,8} {7,-18} {8}' -f `
    '№', 'начало', 'таблица', 'ключ', 'эпизод', 'исход', 'ждали', 'документ', 'кто')
$lines = Invoke-Sql @"
SELECT CONVERT(varchar(11),[Entry No_]) + '|' + CONVERT(varchar(8),[Started At],108) + '|' +
  LEFT([NAV Table Name],24) + '|' + CONVERT(varchar(11),[NAV Key No_]) + '|' +
  $classWords + '|' + $outcomeWords + '|' + CONVERT(varchar(11),[Max Wait (ms)]) + '|' +
  CASE WHEN [Document No_] = '' THEN '-' ELSE [Document No_] END + '|' +
  CASE WHEN [User Name] <> '' THEN [User Name]
       WHEN [Blocker Login] <> '' THEN [Blocker Login]
       ELSE '-' END
FROM $episode ORDER BY [Entry No_];
"@
foreach ($line in $lines) {
    $f = ($line -split '\|') | ForEach-Object { $_.Trim() }
    if ($f.Count -lt 9) { continue }
    Write-Host ('{0,-4} {1,-9} {2,-24} {3,-4} {4,-18} {5,-19} {6,8} {7,-18} {8}' -f `
        $f[0], $f[1], $f[2], $f[3], $f[4], $f[5], $f[6], $f[7], $f[8])
}

Write-Host ''
Write-Host "Эпизодов $total, из них открытых $open. Тревог $alerted. Строк охвата $covered. Показ занял $minutes мин." -ForegroundColor Green
Write-Host ''
Write-Host 'ЧТО СМОТРЕТЬ В КЛИЕНТЕ' -ForegroundColor Cyan
Write-Host "  Эпизоды блокировок (страница $EpisodesPageId) - клиент открыт на ней. F5 обновляет."
Write-Host '  Кнопки над списком: «Запрос виновника» и «Запрос жертвы» - целиком, с прокруткой.'
Write-Host '  «Свод» - на что уходит ожидание по таблицам и ключам; «Охват» - накопительный итог;'
Write-Host '  «Тревоги» - что ушло наружу; «Настройка» - период опроса, порог, каналы.'
if (-not $NoMenu) {
    Write-Host '  В навигации: Разделы (Departments) -> LockWatch -> Блокировки.'
}
Write-Host ''
Write-Host "  Живой эпизод открыт ещё около $(LiveHoldMinutes) мин и закроется сам."
Write-Host '  Вернуть стенд как было: pwsh scripts/Demo.ps1 -Clean'
