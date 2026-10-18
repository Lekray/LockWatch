#requires -Version 7
<#
.SYNOPSIS
    Новая дорога к имени: учётная запись виновника берётся из ЕГО ЖЕ строки, а не из отметки.

.DESCRIPTION
    Отметку контекста кладёт подписчик, и она работает даром - но только там, куда его
    поставили, и только пока виновник пишет в ТУ таблицу. Строка, которую виновник уже
    вставил, лежит в базе и без всякой подписки: в её полях бывает связь на пользователя
    (Field.RelationTableNo = User), и значение такого поля - учётная запись того, кто его
    положил. Транзакция ещё не зафиксирована, поэтому читается строка грязным чтением.

    Прогон сводит обе стороны спора так, чтобы дорог к имени осталась РОВНО ОДНА:

      держатель (сессия NAV) кладёт строку G/L Register со своей учётной записью и берёт
      замок на строке G/L Account  ->  жертва кладёт свою строку с ПОДМЕННЫМ именем и
      встаёт в очередь за той же строкой  ->  проходы идут, пока держатель держит  ->
      в журнале обязан появиться эпизод: имя - учётная запись держателя, источник - 3.

    Подменное имя жертвы ('LOCKWATCH-VICTIM') стоит здесь не для красоты: если дорога
    возьмёт строку жертвы, проверка назовёт подмену, а не совпадение. Обе стороны опыта
    идут под ОДНОЙ учётной записью стенда, и по одному лишь имени виновника от жертвы не
    отличить - отличает её именно подменное значение.

    Дорога отметки на время опыта молчит: все строки таблицы контекста гасятся, отметки
    чистятся. Иначе имя могло бы прийти старой дорогой, и прогон хвалил бы не тот код.

    Выключатель «Имена по строкам виновника» проверяется оба раза: включён - имя обязано
    прийти по строке; выключен - эпизод заводится, а имени нет вовсе.

    Проходы взводятся ЗАРАНЕЕ, до жертвы: вызов через Windows PowerShell 5.1 стартует
    дольше предела ожидания блокировки у NAV (10 000 мс), и проход, запущенный по факту
    очереди, опоздал бы к её концу. Взведённый процесс ждёт файла-сигнала, а сигнал
    ставится в тот миг, когда очередь УЖЕ видна серверу.

    Опыт возвращает за собой всё: строки-мишени не остаются (оба кодюнита кончаются
    ERROR, то есть откатом), настройка и строки контекста возвращаются найденными,
    эпизоды прогона удаляются по номеру записи, снятому ДО опыта.

.EXAMPLE
    pwsh scripts/Test-CulpritRow.ps1
#>
[CmdletBinding()]
param(
    [string] $Server   = 'localhost',
    [string] $Database = $env:LW_DATABASE,
    [string] $Instance = $env:LW_INSTANCE,
    [string] $Company  = $env:LW_COMPANY,
    [int]    $PassCodeunitId  = 110235,
    [int]    $BenchCodeunitId = 110242
)

$ErrorActionPreference = 'Stop'
$root   = Split-Path -Parent $PSScriptRoot
$outDir = Join-Path $root 'out'
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir | Out-Null }

function Fail([string]$message) { Write-Host "ОТКАЗ: $message" -ForegroundColor Red; exit 1 }
function Warn-Cleanup([string]$message) { Write-Host "ВНИМАНИЕ: $message" -ForegroundColor Red }
function Refuse([string]$message, [bool]$soft) {
    # Мягкий отказ - предупреждение вместо завершения процесса. Он нужен УБОРКЕ: Fail делает
    # exit, а exit прекращает процесс сразу и до конца блока finally - catch его не ловит
    # вовсе, и предупреждение о невозврате настройки было бы мёртвым кодом.
    if ($soft) { Warn-Cleanup $message; return $false }
    Fail $message
}
function Stop-Scenario([string]$message) {
    # Сорванный опыт - не провал проверки, а повод прекратить его: продолжать, когда
    # держатель не взял замок, значило бы судить о дороге по состоянию, которого не было.
    # Бросается исключение, а не Fail: exit не даёт выполниться finally, и уборка не прошла бы.
    throw [System.InvalidOperationException]::new($message)
}
function Invoke-CleanupSql([string]$query, [string]$why) {
    # -b обязателен: без него sqlcmd отдаёт НОЛЬ и на ошибке SQL, и уборка, не выполнившаяся
    # вовсе, выглядела бы сделанной. Отказ уборки прогон не роняет - о нём говорят словами.
    $answer = & sqlcmd -S $Server -d $Database -E -b -l 30 -h -1 -Q $query 2>&1
    if ($LASTEXITCODE -ne 0) { Warn-Cleanup "$why не убралось: $(($answer -join ' ') -replace '\s+', ' ')" }
}
if (-not $Database) { Fail 'не задано имя базы: переменная LW_DATABASE или параметр -Database' }
if (-not $Instance) { Fail 'не задан экземпляр службы: переменная LW_INSTANCE' }
if (-not $Company)  { Fail 'не задана компания: переменная LW_COMPANY' }

$episode = "[$Company`$LockWatch Episode]"
$context = "[$Company`$LockWatch Context Table]"
$mark    = "[$Company`$LockWatch Context Mark]"
# Настройка одна на базу, и приставки компании в её SQL-имени нет.
$setup   = '[LockWatch Setup]'
$service = "MicrosoftDynamicsNavServer`$$Instance"
# Штатные таблицы NAV, на которых стоит опыт. Имена собраны правилом платформы: косая
# черта становится подчёркиванием, компания - приставкой через `$`.
$glReg   = "[$Company`$G_L Register]"
$glAcc   = "[$Company`$G_L Account]"
# Значения, которые кладут кодюниты-держатели. Здесь они повторены затем, что прогон
# обязан подложить и убрать ровно то, что положит стенд, - разойдись они, уборка искала
# бы не те строки и молчала бы об оставленных.
$holdNo     = '2000000001'
$waitNo     = '2000000002'
$victimUser = 'LOCKWATCH-VICTIM'

$passed = 0; $total = 0; $report = @()
function Check([string]$what, [bool]$ok, [string]$detail) {
    $script:total++
    if ($ok) { $script:passed++; $verdict = 'пройдено' } else { $verdict = 'ПРОВАЛ  ' }
    $script:report += "$verdict $what"
    $script:report += "         $detail"
}

function Invoke-Sql([string]$query) {
    $answer = & sqlcmd -S $Server -d $Database -E -b -l 30 -w 500 -W -s '|' -h -1 -Q "SET NOCOUNT ON; $query" 2>&1
    if ($LASTEXITCODE -ne 0) { Fail "SQL не выполнился: $($answer -join ' ')" }
    return ,@($answer | Where-Object { $_ -and ($_ -notmatch '^\(') })
}
function Scalar([string]$query) { $rows = Invoke-Sql $query; if ($rows.Count -eq 0) { return '' }; return "$($rows[0])".Trim() }

$ps51 = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$navImport = "Import-Module 'C:\Program Files\Microsoft Dynamics NAV\110\Service\NavAdminTool.ps1' -DisableNameChecking -WarningAction SilentlyContinue | Out-Null"
function Write-Ps51([string]$path, [string]$body) {
    # Windows PowerShell 5.1 читает файл без BOM как ANSI, и кириллица ломает РАЗБОР.
    [IO.File]::WriteAllText($path, (($body -replace "`r`n", "`n") -replace "`n", "`r`n"), (New-Object System.Text.UTF8Encoding($true)))
}
$probeFile = Join-Path $outDir 'wait-nav-culprit.ps1'
Write-Ps51 $probeFile @"
$navImport
`$deadline = (Get-Date).AddMinutes(6)
while ((Get-Date) -lt `$deadline) {
    try { Get-NAVServerSession -ServerInstance $Instance -ErrorAction Stop | Out-Null; exit 0 } catch { Start-Sleep -Seconds 5 }
}
exit 1
"@
function Restart-Nav([string]$why, [switch]$Soft) {
    # Настройку и строки контекста прогон правит мимо NAV, а служба держит их в кэше:
    # без перезапуска проход читал бы прежние значения и опыт мерил бы не тот код.
    Write-Host "  перезапускаю службу $Instance ($why)"
    Restart-Service $service -Force
    & $ps51 -NoProfile -ExecutionPolicy Bypass -File $probeFile | Out-Null
    if ($LASTEXITCODE -ne 0) { return (Refuse "экземпляр $Instance не ответил по порту управления" ([bool]$Soft)) }
    return $true
}
function Read-Shared([string]$path) {
    # Файл пишет ДРУГОЙ процесс, и открывать его надо с общим доступом: обычное чтение
    # спорит с пишущим и падает отказом в самый неудобный миг - посреди чужого опыта.
    if (-not (Test-Path $path)) { return '' }
    try {
        $fs = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        try { return (New-Object IO.StreamReader($fs)).ReadToEnd() } finally { $fs.Dispose() }
    } catch { return '' }
}
function Invoke-Codeunit([int]$id, [string]$method, [string]$why) {
    $runFile = Join-Path $outDir "culprit-invoke-$id-$method.ps1"
    Write-Ps51 $runFile @"
`$ErrorActionPreference = 'Stop'
$navImport
Invoke-NAVCodeunit -ServerInstance $Instance -CompanyName '$Company' -CodeunitId $id -MethodName $method -ErrorAction Stop
"@
    $log = & $ps51 -NoProfile -ExecutionPolicy Bypass -File $runFile 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { Stop-Scenario "$why не отработал:`n$log" }
    return $log
}
function Start-NavCall([int]$id, [string]$method, [string]$tag) {
    # Держатель и жертва уходят В ФОНЕ и своего кода возврата не приносят: оба кончаются
    # ERROR, то есть откатом, и отказ здесь - честный конец опыта, а не беда прогона.
    # Слова их ошибок пишутся в файл UTF-8 изнутри того же процесса: перехваченный вывод
    # консоли несёт кодировку консоли, а учётная запись в нём может быть кириллицей.
    $runFile = Join-Path $outDir "culprit-bg-$tag.ps1"
    $msgFile = Join-Path $outDir "culprit-bg-$tag.msg"
    $outFile = Join-Path $outDir "culprit-bg-$tag.out"
    $errFile = Join-Path $outDir "culprit-bg-$tag.err"
    foreach ($f in @($msgFile, $outFile, $errFile)) { if (Test-Path $f) { Remove-Item $f -Force } }
    Write-Ps51 $runFile @"
`$ErrorActionPreference = 'Stop'
$navImport
`$said = ''
try {
    Invoke-NAVCodeunit -ServerInstance $Instance -CompanyName '$Company' -CodeunitId $id -MethodName $method -ErrorAction Stop | Out-Null
    `$said = 'NOERROR'
} catch {
    `$said = (`$_ | Out-String) + "``n" + `$_.Exception.Message
}
[IO.File]::WriteAllText('$msgFile', `$said, (New-Object System.Text.UTF8Encoding(`$false)))
"@
    $process = Start-Process -FilePath $ps51 -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput $outFile -RedirectStandardError $errFile `
        -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$runFile`""
    return [pscustomobject]@{ Process = $process; Msg = $msgFile; Out = $outFile; Err = $errFile }
}
function Start-ArmedPass([string]$tag) {
    # Проход взводится ДО жертвы и ждёт файла-сигнала. Так платят за старт Windows
    # PowerShell 5.1 не в окне ожидания: пока жертва встаёт в очередь, процесс уже готов.
    $go      = Join-Path $outDir "culprit-go-$tag.txt"
    $runFile = Join-Path $outDir "culprit-pass-$tag.ps1"
    $outFile = Join-Path $outDir "culprit-pass-$tag.out"
    $errFile = Join-Path $outDir "culprit-pass-$tag.err"
    foreach ($f in @($go, $outFile, $errFile)) { if (Test-Path $f) { Remove-Item $f -Force } }
    Write-Ps51 $runFile @"
`$ErrorActionPreference = 'Stop'
$navImport
`$deadline = (Get-Date).AddMinutes(3)
while (-not (Test-Path '$go')) {
    if ((Get-Date) -gt `$deadline) { Write-Output 'NOWAIT'; exit 2 }
    Start-Sleep -Milliseconds 150
}
foreach (`$i in 1..3) {
    try {
        Invoke-NAVCodeunit -ServerInstance $Instance -CompanyName '$Company' -CodeunitId $PassCodeunitId -MethodName 'RunPass' -ErrorAction Stop | Out-Null
        Write-Output "PASS `$i ok"
    } catch { Write-Output ("PASS `$i failed: " + `$_.Exception.Message) }
    if (`$i -lt 3) { Start-Sleep -Seconds 3 }
}
"@
    $process = Start-Process -FilePath $ps51 -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput $outFile -RedirectStandardError $errFile `
        -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$runFile`""
    return [pscustomobject]@{ Process = $process; Go = $go; Out = $outFile; Err = $errFile }
}

# ---------- предусловия: ничего ещё не менялось ----------
if (-not (Scalar "SELECT OBJECT_ID(N'$glReg');")) { Fail "в базе нет таблицы $glReg - опыт подкладывать строки некуда" }
if (-not (Scalar "SELECT OBJECT_ID(N'$glAcc');")) { Fail "в базе нет таблицы $glAcc - спорной строки не будет" }
$stray = [int](Scalar "SELECT COUNT(*) FROM $glReg WHERE [No_] >= $holdNo;")
if ($stray -gt 0) {
    Fail "в $glReg уже есть $stray строк с номером >= $holdNo - прошлый опыт не убрал за собой, разберитесь руками"
}
if ((Get-Service $service -ErrorAction SilentlyContinue) -and (Get-Service $service).Status -ne 'Running') {
    Start-Service $service
}

# Что стоит в базе ДО прогона. Настройка и строки контекста правятся мимо NAV, и
# возвращаются они тем, чем были найдены: погашенная чужая строка контекста осталась бы
# выключенной навсегда, а выключенный сторож - выключенным.
$setupWas = Scalar "SELECT CONVERT(varchar(2),[Enabled]) + '|' + CONVERT(varchar(2),[Names From Culprit Rows]) + '|' + ISNULL([SQL Server],N'') FROM $setup;"
$contextWas = Invoke-Sql "SELECT CONVERT(varchar(11),[Table No_]) + '|' + CONVERT(varchar(2),[Enabled]) FROM $context;"
# -1 - начало журнала ещё не прочитано. Ноль - законное начало: журнал был пуст, и
# эпизоды опыта всё равно обязаны уйти при уборке.
$startNo = -1
$holdProc = $null; $waitProc = $null; $armState = $null
$fatal = $null

function Read-Episode([long]$after) {
    # Свои эпизоды отличаются НОМЕРОМ ЗАПИСИ, а не временем и не сеансом: журнал мог
    # наполняться и до опыта, и разбирать чужие строки прогону не за чем.
    $row = Scalar @"
SELECT TOP 1 [NAV Table Name] + '|' + ISNULL([User Name],N'') + '|' +
  CONVERT(varchar(11),[User Source]) + '|' + ISNULL([Culprit NAV Sessions],N'')
FROM $episode WHERE [Entry No_] > $after AND [NAV Table Name] = N'G_L Account'
ORDER BY [Entry No_] DESC;
"@
    $f = @(($row -split '\|') | ForEach-Object { $_.Trim() })
    while ($f.Count -lt 4) { $f += '' }
    return $f
}

function Invoke-Fixture([string]$tag, [long]$after) {
    # Один опыт целиком: держатель со своей строкой, жертва с подменной, взведённые
    # проходы и чтение того, что осело в журнале.
    $script:armState = Start-ArmedPass $tag
    Write-Host '  держатель пошёл: строка G/L Register со своей учётной записью и замок на строке G/L Account'
    $script:holdProc = Start-NavCall $BenchCodeunitId 'HoldWithUserRow' "hold-$tag"

    # Ждём не времени, а состояния, и состояние это двойное: держатель взял замок на
    # спорной строке G/L Account И держит свой кластерный индекс G/L Register. Одного
    # замка на G/L Account мало - его берёт и любой чужой пост, а транзакция без строки
    # со своей учётной записью дороге нечего показать.
    $holdSpid = 0
    $rowSeen = $false
    $holdLocks = 0
    $deadline = (Get-Date).AddSeconds(60)
    while ((Get-Date) -lt $deadline) {
        $holdSpid = [int](Scalar @"
SELECT TOP 1 CONVERT(varchar(11), l.request_session_id)
FROM sys.dm_tran_locks l
JOIN sys.dm_exec_sessions s ON s.session_id = l.request_session_id
WHERE l.resource_database_id = DB_ID() AND l.request_mode = 'X' AND l.request_status = 'GRANT'
  AND s.program_name LIKE N'Microsoft Dynamics NAV Server%'
  AND EXISTS (SELECT 1 FROM sys.dm_tran_locks r
              WHERE r.request_session_id = l.request_session_id AND r.resource_database_id = DB_ID()
                AND r.resource_type = 'KEY' AND r.request_mode = 'X' AND r.request_status = 'GRANT'
                AND r.resource_associated_entity_id IN
                    (SELECT p2.hobt_id FROM sys.partitions p2
                     WHERE p2.object_id = OBJECT_ID(N'$glReg') AND p2.index_id = 1))
  AND ((l.resource_type = 'OBJECT' AND l.resource_associated_entity_id = OBJECT_ID(N'$glAcc'))
       OR (l.resource_type IN ('KEY','RID','PAGE') AND l.resource_associated_entity_id IN
           (SELECT p.hobt_id FROM sys.partitions p WHERE p.object_id = OBJECT_ID(N'$glAcc'))));
"@)
        if ($holdSpid -gt 0) {
            $rowSeen = [int](Scalar "SELECT COUNT(*) FROM $glReg WITH (NOLOCK) WHERE [No_] = $holdNo;") -gt 0
            $holdLocks = [int](Scalar @"
SELECT COUNT(*) FROM sys.dm_tran_locks l
WHERE l.request_session_id = $holdSpid AND l.resource_type = 'KEY' AND l.request_mode = 'X'
  AND l.request_status = 'GRANT' AND l.resource_database_id = DB_ID()
  AND l.resource_associated_entity_id IN
      (SELECT p.hobt_id FROM sys.partitions p WHERE p.object_id = OBJECT_ID(N'$glReg') AND p.index_id = 1);
"@)
            if (($holdLocks -gt 0) -and $rowSeen) { break }
        }
        if ($script:holdProc.Process.HasExited) { break }
        Start-Sleep -Milliseconds 200
    }

    Write-Host '  жертва пошла: своя строка с ЧУЖИМ именем и очередь за той же строкой G/L Account'
    $script:waitProc = Start-NavCall $BenchCodeunitId 'WaitWithUserRow' "wait-$tag"
    $waitSeen = $false
    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $deadline) {
        if ($holdSpid -gt 0) {
            $waiting = [int](Scalar @"
SELECT COUNT(*) FROM sys.dm_os_waiting_tasks
WHERE wait_type LIKE 'LCK[_]%' AND blocking_session_id = $holdSpid;
"@)
            if ($waiting -gt 0) { $waitSeen = $true; break }
        }
        if ($script:waitProc.Process.HasExited) { break }
        Start-Sleep -Milliseconds 150
    }
    # Сигнал проходам ставится в тот миг, когда очередь УЖЕ видна серверу. Проход,
    # взведённый раньше очереди, открыл бы эпизод пустым и закрыл бы его же.
    if (-not (Test-Path $script:armState.Go)) { New-Item -ItemType File -Path $script:armState.Go | Out-Null }

    # Держатель спит 30 с и кончается откатом; жертва - пределом ожидания NAV. Обе стороны
    # заканчиваются сами, и снимать их силой тут незачем.
    [void]$script:holdProc.Process.WaitForExit(90000)
    [void]$script:waitProc.Process.WaitForExit(90000)
    [void]$script:armState.Process.WaitForExit(180000)

    # Слова ищутся ВО ВСЕХ трёх потоках: текст отказа NAV приходит то в ответ, то в ошибку,
    # и выбирать один из них значило бы гадать, где он окажется на этой платформе.
    $holdSaid = ((Read-Shared $script:holdProc.Msg) + "`n" + (Read-Shared $script:holdProc.Out) + "`n" +
                 (Read-Shared $script:holdProc.Err)) -replace '\s+', ' '
    $waitSaid = ((Read-Shared $script:waitProc.Msg) + "`n" + (Read-Shared $script:waitProc.Out) + "`n" +
                 (Read-Shared $script:waitProc.Err)) -replace '\s+', ' '
    $passSaid = ((Read-Shared $script:armState.Out) + "`n" + (Read-Shared $script:armState.Err)) -replace '\s+', ' '
    $holderUser = ''; $holderSession = 0
    if ($holdSaid -match 'LOCKROWHELD user (\S+) session (\d+)') {
        $holderUser = $Matches[1]; $holderSession = [int]$Matches[2]
    }
    return @{
        HoldSpid = $holdSpid; RowSeen = $rowSeen; HoldLocks = $holdLocks; WaitSeen = $waitSeen
        HolderUser = $holderUser; HolderSession = $holderSession
        VictimTook = ($waitSaid -match 'LOCKROWTOOK')
        HoldSaid = $holdSaid; WaitSaid = $waitSaid; PassSaid = $passSaid
    }
}

try {
    # ---------- 1. условия опыта ----------
    Invoke-Sql @"
UPDATE $setup SET [SQL Server] = N'$Server', [Enabled] = 0, [Names From Culprit Rows] = 1;
DELETE FROM $mark;
UPDATE $context SET [Enabled] = 0;
"@ | Out-Null
    Restart-Nav 'настройка правится мимо NAV, и в кэше службы лежит прежняя' | Out-Null
    # Разогрев: первый вход после перезапуска собирает business assemblies, и проход
    # внутри окна ожидания заплатил бы за это вместо того, чтобы прочитать очередь.
    Invoke-Codeunit $PassCodeunitId 'RunPass' 'разогрев прохода после перезапуска' | Out-Null
    $startNo = [long](Scalar "SELECT ISNULL(MAX([Entry No_]),0) FROM $episode;")

    Write-Host 'Опыт 1: выключатель включён - имя обязано прийти по строке виновника'
    $one = Invoke-Fixture 'one' $startNo
    $e1 = Read-Episode $startNo

    Check 'держатель оставил строку G/L Register со своей учётной записью и держит X-блокировку на её кластерном индексе' `
        (($one.HoldSpid -gt 0) -and $one.RowSeen -and ($one.HoldLocks -gt 0)) `
        ("spid $($one.HoldSpid), X-блокировок на кластерном индексе $($one.HoldLocks), " +
         "строка видна в SQL $($one.RowSeen), держатель сказал [$($one.HoldSaid)]")

    Check 'эпизод по блокировке заведён на G/L Account' `
        (($e1[0] -eq 'G_L Account') -and $one.WaitSeen) `
        ("таблица в журнале [$($e1[0])], очередь видна серверу $($one.WaitSeen), " +
         "жертва сказала [$($one.WaitSaid)]")

    Check 'ПОЛЬЗОВАТЕЛЬ назван, и это учётная запись держателя из его же строки' `
        (($e1[1] -ne '') -and ($e1[1] -eq $one.HolderUser)) `
        "«Пользователь» [$($e1[1])] при учётной записи держателя [$($one.HolderUser)]"

    Check 'откуда имя - по строке виновника' ($e1[2] -eq '3') `
        "«Откуда имя» $($e1[2]) при ожидаемом 3"

    # Дорога вправе взять ЛЮБУЮ подходящую строку транзакции виновника. Строка жертвы
    # лежит рядом и несёт чужое значение - и если дорога взяла её, имя выдаст подмену.
    Check 'взята строка ВИНОВНИКА, а не жертвы: имени-подмены в журнале нет' `
        (($e1[1] -ne '') -and ($e1[1] -ne $victimUser)) `
        "«Пользователь» [$($e1[1])] при подменном значении [$victimUser]"

    $sessions = @((($e1[3]) -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    Check 'сеанс держателя назван рядом с учётной записью' `
        (($one.HolderSession -gt 0) -and ($sessions -contains "$($one.HolderSession)")) `
        "«Сеансы NAV виновника» [$($e1[3])] при сеансе держателя $($one.HolderSession)"

    # ---------- 2. выключатель снят: дороги нет вовсе ----------
    Invoke-Sql "UPDATE $setup SET [Names From Culprit Rows] = 0;" | Out-Null
    Restart-Nav 'выключатель правится мимо NAV, и в кэше службы лежит прежний' | Out-Null
    Invoke-Codeunit $PassCodeunitId 'RunPass' 'разогрев прохода после перезапуска' | Out-Null
    $startNo2 = [long](Scalar "SELECT ISNULL(MAX([Entry No_]),0) FROM $episode;")

    Write-Host 'Опыт 2: выключатель снят - эпизод заводится, а имени нет'
    $two = Invoke-Fixture 'two' $startNo2
    $e2 = Read-Episode $startNo2

    Check 'второй опыт тоже завёл эпизод на G/L Account' `
        (($e2[0] -eq 'G_L Account') -and $two.WaitSeen) `
        ("таблица в журнале [$($e2[0])], очередь видна серверу $($two.WaitSeen), " +
         "жертва сказала [$($two.WaitSaid)]")

    Check 'при снятом выключателе имя не названо вовсе' `
        (($e2[1] -eq '') -and ($e2[2] -eq '0')) `
        "имя [$($e2[1])], «Откуда имя» [$($e2[2])] при ожидаемом пустом имени и 0"
}
catch {
    $fatal = $_.Exception.Message
    Write-Host "ОТКАЗ: $fatal" -ForegroundColor Red
}
finally {
    Write-Host ''
    Write-Host 'Убираю за собой'
    foreach ($call in @($holdProc, $waitProc, $armState)) {
        if (-not $call) { continue }
        $process = $call.Process
        if ($process -and -not $process.HasExited) {
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
            [void]$process.WaitForExit(10000)
        }
    }
    # Снятый клиент ещё не значит снятый замок: служба откатывает транзакцию сеанса
    # не мгновенно, и DELETE ниже встал бы за ней.
    Start-Sleep -Seconds 2

    # Порядок уборки - от цены ошибки: сперва то, что прогон положил в ЧУЖИЕ данные.
    if ($startNo -ge 0) {
        Invoke-CleanupSql "DELETE FROM $episode WHERE [Entry No_] > $startNo;" 'эпизоды прогона'
    }
    # Убираются РОВНО номера опыта, а не всё, что больше них: строка с таким номером,
    # положенная не опытом, тоже попала бы под «больше» и пропала бы молча.
    Invoke-CleanupSql "DELETE FROM $glReg WHERE [No_] IN ($holdNo, $waitNo);" 'строки-мишени G/L Register'

    $cleanup = ''
    if ($setupWas -match '^([01])\|([01])\|(.*)$') {
        $wasEnabled = $Matches[1]; $wasNames = $Matches[2]; $wasServer = $Matches[3]
        $cleanup += " UPDATE $setup SET [Enabled] = $wasEnabled, [Names From Culprit Rows] = $wasNames, [SQL Server] = N'$wasServer';"
    } else {
        $cleanup += " UPDATE $setup SET [Enabled] = 0, [Names From Culprit Rows] = 1;"
        Warn-Cleanup 'прежние значения настройки прочитать не удалось - вернул заводские'
    }
    foreach ($line in $contextWas) {
        $parts = $line -split '\|'
        if (($parts.Count -eq 2) -and ($parts[0] -match '^\d+$') -and ($parts[1] -match '^[01]$')) {
            $cleanup += " UPDATE $context SET [Enabled] = $($parts[1]) WHERE [Table No_] = $($parts[0]);"
        }
    }
    Invoke-CleanupSql $cleanup 'настройка и строки контекста'

    # Настройку вернули мимо NAV, а служба держит в кэше временные значения: без
    # перезапуска установка осталась бы со снятым сторожем до следующего старта.
    try { Restart-Nav 'настройка возвращена, а в кэше службы лежит временная' -Soft | Out-Null }
    catch { Warn-Cleanup "служба $Instance не перезапустилась: $($_.Exception.Message)" }
    Write-Host '  строки убраны, настройка и строки контекста возвращены, эпизоды опыта удалены'
}

Write-Host ''
Write-Host "пройдено $passed из $total"
$report | ForEach-Object { Write-Host $_ }
if ($fatal) { Fail "опыт сорван: $fatal" }
if ($passed -ne $total) { Fail 'дорога к имени по строке виновника не пройдена' }
Write-Host 'Готово: имя приходит из строки виновника, а выключатель его запрещает' -ForegroundColor Green
