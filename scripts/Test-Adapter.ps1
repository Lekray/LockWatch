#requires -Version 7
<#
.SYNOPSIS
    Во что обходится своя подписка на каждой записи - и знает ли платформа собранный
    переходник. Три варианта цены и сборщик, проверенный на настоящей таблице установки.

.DESCRIPTION
    Вопрос «ставить ли свою подписку на таблицу, куда пишут постоянно» решается числом, а
    не рассуждением. Числа три, и меньше нельзя: два без базового - это не замер.

      1. подписчика нет вовсе (объект удалён из базы);
      2. подписчик есть, строка таблицы контекста выключена - он выходит на первой строке;
      3. подписчик есть и работает - ставит отметку внутри той же транзакции.

    Улика того, что варианты и вправду разные, - поле marked в ответе мерного объекта.
    Без него прогон, в котором подписка молча не сработала, дал бы три одинаковых числа
    и был бы объявлен успехом.

    Замер идёт на штатной Table 37. На целевой таблице установки уже стоят чужие подписки,
    и вставка в неё меряла бы ИХ работу, а не нашу; своя подписка стоит одинаково вне
    зависимости от того, сколько соседей у неё в списке.

    Отдельно проверяется сборщик переходников: объект под настоящую таблицу установки
    собирается, выкладывается, компилируется и сам себя спрашивает у платформы - знает ли
    она его подписку. После проверки объект из базы удаляется: оставлять на стенде
    подписчика на чужой таблице прогон не вправе.

    Строки контекста, заведённые замеру, возвращаются в ТО состояние, в каком прогон их
    застал: строка, снесённая после себя, выключила бы установке объявленную таблицу
    документа - а заметно это стало бы только по пустой колонке в журнале.

    Сломано нарочно 11.09.2026: у переходника убрана проверка галки в строке контекста.
    На прежнем устройстве прогона это не изменило НИЧЕГО - 5 из 5, - потому что вариант,
    названный "выключен", строки контекста не имел вовсе: переходник выходил на GET, до
    галки не доходя. Строка заводится теперь во втором варианте сразу со снятой галкой, и
    третий отличается от второго ровно ею; с той же поломкой прогон даёт 4 из 5, красная -
    "выключен 1".

.EXAMPLE
    pwsh scripts/Test-Adapter.ps1
#>
[CmdletBinding()]
param(
    [string] $Server   = 'localhost',
    [string] $Database = $env:LW_DATABASE,
    [string] $Instance = $env:LW_INSTANCE,
    [string] $Company  = $env:LW_COMPANY,
    [int]    $TableNo  = $env:LW_DOC_TABLE_NO,
    [int]    $FieldNo  = $env:LW_DOC_FIELD_NO,
    [int]    $AdapterObjectNo = 110250,
    [int]    $SampleAdapterId = 110237,
    [int]    $BenchCodeunitId = 110239,
    [int]    $TaskCodeunitId  = 110236,
    [int]    $MgmtPort = 7145,
    [int]    $TimeoutMinutes = 3,
    [switch] $StopInstance
)

$ErrorActionPreference = 'Stop'
$root   = Split-Path -Parent $PSScriptRoot
$outDir = Join-Path $root 'out'
$finsql = 'C:\Program Files (x86)\Microsoft Dynamics NAV\110\RoleTailored Client\finsql.exe'
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir | Out-Null }

function Fail([string]$message) { Write-Host "ОТКАЗ: $message" -ForegroundColor Red; exit 1 }
function Warn-Cleanup([string]$message) { Write-Host "ВНИМАНИЕ: $message" -ForegroundColor Red }
function Refuse([string]$message, [bool]$soft) {
    # Мягкий отказ - предупреждение вместо завершения процесса. Он нужен УБОРКЕ: Fail делает
    # exit, а exit прекращает процесс сразу и до конца блока finally - catch его не ловит
    # вовсе, и слова уборки не печатались бы никогда.
    if ($soft) { Warn-Cleanup $message; return $false }
    Fail $message
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
if ($TableNo -le 0) { Fail 'не задана целевая таблица: переменная LW_DOC_TABLE_NO или параметр -TableNo' }
if ($FieldNo -le 0) { Fail 'не задано поле документа: переменная LW_DOC_FIELD_NO или параметр -FieldNo' }

$context = "[$Company`$LockWatch Context Table]"
$mark    = "[$Company`$LockWatch Context Mark]"
$service = "MicrosoftDynamicsNavServer`$$Instance"
$sampleTableNo = 37

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

function Invoke-Finsql([string]$argLine, [string]$logName, [switch]$Soft) {
    $log = Join-Path $outDir $logName
    if (Test-Path $log) { Remove-Item $log -Force }
    $navArgs = "ServerName=$Server,Database=$Database,NTAuthentication=1,LogFile=`"$log`""
    $process = Start-Process -FilePath $finsql -PassThru -NoNewWindow -ArgumentList "$argLine,$navArgs"
    if (-not $process.WaitForExit($TimeoutMinutes * 60000)) {
        $process.Kill()
        return (Refuse "finsql завис дольше $TimeoutMinutes мин и снят" $Soft)
    }
    if (Test-Path $log) {
        $text = ([System.Text.Encoding]::GetEncoding(866).GetString([IO.File]::ReadAllBytes($log))).Trim()
        if ($text) { return (Refuse "finsql ($logName):`n$text" $Soft) }
    }
    return $true
}

function Import-Object([string]$sourceFile, [string]$tag) {
    # Импорт в C/SIDE идёт в cp866: cp1251 и UTF-8 ломают кириллицу молча.
    $text = [IO.File]::ReadAllText($sourceFile, [Text.UTF8Encoding]::new($false))
    $text = ($text -replace "`r`n", "`n") -replace "`n", "`r`n"
    $cp866 = [System.Text.Encoding]::GetEncoding(866)
    if ($cp866.GetString($cp866.GetBytes($text)) -ne $text) { Fail "cp866 теряет символы в $sourceFile" }
    $pack = Join-Path $outDir "$tag.cp866.txt"
    [IO.File]::WriteAllBytes($pack, $cp866.GetBytes($text))
    # Свой ответ (истина) глушится: он нужен уборке, а в прогоне это был бы лишний шум.
    Invoke-Finsql "Command=ImportObjects,File=`"$pack`",ImportAction=overwrite,SynchronizeSchemaChanges=Force,NavServerName=$Server,NavServerInstance=$Instance,NavServerManagementPort=$MgmtPort" "import-$tag.log" | Out-Null
}

function Compile-Codeunit([int]$id, [string]$tag) {
    Invoke-Finsql "Command=CompileObjects,Filter=`"Type=Codeunit;ID=$id`",SynchronizeSchemaChanges=Force,NavServerName=$Server,NavServerInstance=$Instance,NavServerManagementPort=$MgmtPort" "compile-$tag.log" | Out-Null
}

function Delete-Codeunit([int]$id, [string]$tag, [switch]$Soft) {
    # Ответ вызова возвращается, а не глушится: уборке он и нужен - она говорит, что снялось.
    return (Invoke-Finsql "Command=DeleteObjects,Filter=`"Type=Codeunit;ID=$id`"" "delete-$tag.log" -Soft:$Soft)
}

# Модуль NAV живёт только в Windows PowerShell 5.1, поэтому и ожидание готовности, и сами
# вызовы идут через него.
$ps51 = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$navImport = "Import-Module 'C:\Program Files\Microsoft Dynamics NAV\110\Service\NavAdminTool.ps1' -DisableNameChecking -WarningAction SilentlyContinue | Out-Null"
function Write-Ps51([string]$path, [string]$body) {
    [IO.File]::WriteAllText($path, (($body -replace "`r`n", "`n") -replace "`n", "`r`n"), (New-Object System.Text.UTF8Encoding($true)))
}
$probeFile = Join-Path $outDir 'wait-nav-adapter.ps1'
Write-Ps51 $probeFile @"
$navImport
`$deadline = (Get-Date).AddMinutes(6)
while ((Get-Date) -lt `$deadline) {
    try { Get-NAVServerSession -ServerInstance $Instance -ErrorAction Stop | Out-Null; exit 0 } catch { Start-Sleep -Seconds 5 }
}
exit 1
"@

function Restart-Nav([string]$why, [switch]$Soft) {
    Write-Host "  перезапускаю службу $Instance ($why)"
    Restart-Service $service -Force
    & $ps51 -NoProfile -ExecutionPolicy Bypass -File $probeFile | Out-Null
    if ($LASTEXITCODE -ne 0) { return (Refuse "экземпляр $Instance не ответил по порту управления" $Soft) }
    return $true
}

function Invoke-Codeunit([int]$id, [string]$method, [string]$why) {
    $runFile = Join-Path $outDir "invoke-$id-$method.ps1"
    Write-Ps51 $runFile @"
`$ErrorActionPreference = 'Stop'
$navImport
Invoke-NAVCodeunit -ServerInstance $Instance -CompanyName '$Company' -CodeunitId $id -MethodName $method -ErrorAction Stop
"@
    $log = & $ps51 -NoProfile -ExecutionPolicy Bypass -File $runFile 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { Fail "$why не отработал:`n$log" }
    return $log
}

# Ответ мерного объекта нарочно одинаков на обоих языках - разбирать его прогону, а не
# читать человеку, и зависеть от языка службы разбор не должен.
function MeasureRepeats {
    # Сколько раз мерить каждый вариант. Три, и берётся ЛУЧШЕЕ из трёх - об этом ниже.
    # Больше трёх окупается плохо: замер длится секунды, а вариантов три, и каждый ещё и
    # разогревается.
    return 3
}

function Read-Bench([string]$why) {
    # Одного прогона довольно: здесь спрашивается не цена, а ОТМЕТКА - ставится она или
    # нет. Разогрев и лучшее из трёх нужны числу в микросекундах, а не единице с нулём.
    $log = Invoke-Codeunit $BenchCodeunitId 'Bench' $why
    if ($log -notmatch 'ADAPTERBENCH ms (\d+) rows (\d+) us (\d+) marked (\d+)') {
        Fail "мерный объект не отчитался ($why):`n$log"
    }
    return [pscustomobject]@{ Ms = [int]$Matches[1]; Rows = [int]$Matches[2]; Us = [int]$Matches[3]; Marked = [int]$Matches[4] }
}

function Measure-Mode([string]$why) {
    # Первый прогон после перезапуска меряет не подписку, а РАЗОГРЕВ службы: NAV собирает
    # business assemblies и наполняет кэш метаданных, и это сотни миллисекунд на ровном
    # месте. Измерено на себе: без разогрева вариант с выключенной подпиской вышел быстрее
    # варианта без подписки вовсе - то есть замер мерил не то. Поэтому первый прогон
    # разогревочный, а числом становится следующий.
    #
    # Числом становится ЛУЧШЕЕ из нескольких, а не последнее. Довод не в красоте: варианты
    # меряются минутами врозь, с перезапуском службы между ними, и фон достаётся им
    # неравномерно. Ловилось 08.09.2026 в общей смете: базовый вариант успел пройти по
    # тихой машине (608 мкс), а вариант с подпиской попал под чужую нагрузку (1464), и
    # отношение вышло 2,4 при потолке 2 - на стенде, где оно годами держалось около 1,2.
    # Одиночный прогон тут же дал 817 и 894, то есть 1,09.
    #
    # Лучшее из трёх - не поблажка: шум умеет только ПРИБАВЛЯТЬ, и самый быстрый из
    # замеров ближе всех к настоящей цене. Поблажкой был бы поднятый потолок, а он остался
    # прежним.
    Invoke-Codeunit $BenchCodeunitId 'Bench' "$why (разогрев)" | Out-Null
    $best = $null
    for ($try = 1; $try -le (MeasureRepeats); $try++) {
        $log = Invoke-Codeunit $BenchCodeunitId 'Bench' $why
        if ($log -notmatch 'ADAPTERBENCH ms (\d+) rows (\d+) us (\d+) marked (\d+)') {
            Fail "мерный объект не отчитался ($why):`n$log"
        }
        $one = [pscustomobject]@{ Ms = [int]$Matches[1]; Rows = [int]$Matches[2]; Us = [int]$Matches[3]; Marked = [int]$Matches[4] }
        if (-not $best -or ($one.Us -lt $best.Us)) { $best = $one }
    }
    return $best
}

$generated = $null
# Что стоит в базе ДО прогона. Строки контекста на время замера переписываются, и вернуть
# их прежнее состояние можно, только зная, каким оно было: помнится ПРИЗНАК (была ли
# строка) и её галка. Содержимое строки прогон не выдумывает - имена в неё кладёт сам NAV.
$rowsWas = @{}
try {
    Write-Host 'Подготовка стенда'
    if ((Get-Service $service).Status -ne 'Running') { Start-Service $service }
    foreach ($no in @($sampleTableNo, $TableNo)) {
        $exists = [int](Scalar "SELECT COUNT(*) FROM $context WHERE [Table No_] = $no;")
        $enabled = if ($exists -gt 0) { Scalar "SELECT CONVERT(varchar(2),[Enabled]) FROM $context WHERE [Table No_] = $no;" } else { '' }
        $rowsWas[$no] = @{ Exists = $exists; Enabled = $enabled }
    }
    Invoke-Sql "DELETE FROM $context WHERE [Table No_] IN ($sampleTableNo,$TableNo);" | Out-Null
    Invoke-Sql "DELETE FROM $mark;" | Out-Null

    # ---------- вариант 1: подписчика нет вовсе ----------
    Write-Host 'Вариант первый: подписчика нет'
    Delete-Codeunit $SampleAdapterId 'adapter' | Out-Null
    Restart-Nav 'подписчик удалён' | Out-Null
    $noAdapter = Measure-Mode 'замер без подписчика'
    Write-Host "  $($noAdapter.Ms) мс на $($noAdapter.Rows) строк, $($noAdapter.Us) мкс на строку, отметка $($noAdapter.Marked)"

    # ---------- вариант 2: подписчик есть, но выключен ----------
    #
    # Строка контекста заводится ЗДЕСЬ и сразу со снятой галкой. Раньше её здесь не было
    # вовсе, и вариант назывался "выключен", а мерил "строки нет": переходник выходил на
    # ContextTable.GET, до галки не доходя. Обещание "снятая галка выключает переходник"
    # не проверялось тогда ничем - доказано поломкой 11.09.2026: убрали у переходника
    # проверку галки целиком, и прогон остался зелёным, 5 из 5.
    Write-Host 'Вариант второй: подписчик есть, строка контекста выключена'
    Import-Object (Join-Path $root 'objects\c110237_LockWatch_Context_Adapter.txt') 'sample-adapter'
    Compile-Codeunit $SampleAdapterId 'sample-adapter'
    Invoke-Sql @"
DELETE FROM $context WHERE [Table No_] = $sampleTableNo;
INSERT INTO $context ([Table No_],[Table Name],[Document Field No_],[Document Field Name],[Document Caption],[Enabled])
VALUES ($sampleTableNo,N'Sales Line',3,N'Document No.',N'Строка продажи',0);
"@ | Out-Null
    Restart-Nav 'подписчик вернулся, галка снята' | Out-Null
    $offAdapter = Measure-Mode 'замер с выключенной подпиской'
    Write-Host "  $($offAdapter.Ms) мс на $($offAdapter.Rows) строк, $($offAdapter.Us) мкс на строку, отметка $($offAdapter.Marked)"

    # ---------- вариант 3: подписчик работает ----------
    # Разница между вторым вариантом и третьим теперь РОВНО В ГАЛКЕ: строка одна и та же,
    # переходник один и тот же, меняется одно поле. Так и спрашивается обещание.
    Write-Host 'Вариант третий: подписчик работает'
    Invoke-Sql "UPDATE $context SET [Enabled] = 1 WHERE [Table No_] = $sampleTableNo;" | Out-Null
    Restart-Nav 'галка поставлена' | Out-Null
    $onAdapter = Measure-Mode 'замер с включённой подпиской'
    Write-Host "  $($onAdapter.Ms) мс на $($onAdapter.Rows) строк, $($onAdapter.Us) мкс на строку, отметка $($onAdapter.Marked)"

    # Три варианта отличаются ровно тем, чем названы: подписчика нет / есть, но галка
    # снята / есть и галка стоит. Отметка обязана появиться только в третьем.
    Check 'нет подписчика - нет отметки; снятая галка - тоже нет; и только галка её даёт' `
        (($noAdapter.Marked -eq 0) -and ($offAdapter.Marked -eq 0) -and ($onAdapter.Marked -eq 1)) `
        "отметка: без подписчика $($noAdapter.Marked), выключен $($offAdapter.Marked), включён $($onAdapter.Marked)"

    # ---------- вариант 4: галка щёлкается из сессии NAV, без перезапуска ----------
    #
    # Три варианта выше меняли галку через SQL и КАЖДЫЙ раз перезапускали службу. Перезапуск
    # в обещании не назван: обещано "выключить переходник, не выкладывая объектов, - в один
    # щелчок". Щелчок - это запись из сессии NAV, и подействовать он обязан в других сессиях
    # сразу. Правка через SQL до них и не дошла бы вовсе (FINDINGS, раздел 67), так что
    # проверить обещание можно только записью, а не UPDATE.
    Write-Host 'Вариант четвёртый: галка щёлкается из сессии NAV, службу не трогаем'
    Invoke-Codeunit $BenchCodeunitId 'ContextOff' 'снятие галки из сессии NAV' | Out-Null
    $afterOff = Read-Bench 'отметка после снятия галки'
    Invoke-Codeunit $BenchCodeunitId 'ContextOn' 'возврат галки из сессии NAV' | Out-Null
    $afterOn = Read-Bench 'отметка после возврата галки'
    # Обе половины разом: переходник, который перестал отмечать НАВСЕГДА, зелен по первой,
    # а не заметивший снятия - по второй.
    Check 'галка, щёлкнутая из сессии NAV, действует в других сессиях сразу' `
        (($afterOff.Marked -eq 0) -and ($afterOn.Marked -eq 1)) `
        "отметка: после снятия $($afterOff.Marked), после возврата $($afterOn.Marked)"

    # Потолок объявленный, и довод у него простой: подписчик, удваивающий цену КАЖДОЙ
    # записи на горячей таблице, не выкладывается ни при каких обещаниях пользы.
    #
    # Приговор по ОДНОМУ замеру тут не выносится. Варианты меряются минутами врозь, с
    # перезапуском службы между ними, и всплеск фона длиной в десятки секунд накрывает все
    # три повтора дорогого варианта разом - лучшее из трёх спасает от дрожания, но не от
    # такого. Замеры одного и того же подписчика:
    #
    #   смета  08.09.2026   608 -> 1464   отношение 2,4    одиночный тут же 817 -> 894 (1,09)
    #   смета  09.09.2026   657 -> 960    отношение 1,46
    #   смета  09.09.2026   618 -> 1447   отношение 2,34   одиночный тут же 1082 -> 1526 (1,41)
    #
    # Оба выхода за потолок случились ТОЛЬКО в смете, и в последнем дешёвые варианты были
    # самыми быстрыми из всех (618 и 638) - то есть машина была не медленной, всплеск накрыл
    # именно дорогой вариант. Поэтому перед приговором дорогой вариант перемеряется, и в
    # дело идёт лучший из двух. Это та же мерка, что и внутри варианта: шум умеет только
    # ПРИБАВЛЯТЬ, и самый быстрый замер ближе всех к настоящей цене. Поблажкой был бы
    # поднятый потолок - он остался прежним, и подписчик, дорогой на самом деле, не
    # подешевеет от повтора.
    $onBest = $onAdapter
    $retryNote = ''
    if ($onAdapter.Us -gt (2 * $noAdapter.Us)) {
        Write-Host 'Потолок перейдён - перемеряю дорогой вариант, прежде чем судить'
        Restart-Nav 'повторный замер с включённой подпиской' | Out-Null
        $again = Measure-Mode 'повторный замер с включённой подпиской'
        Write-Host "  $($again.Ms) мс на $($again.Rows) строк, $($again.Us) мкс на строку, отметка $($again.Marked)"
        $retryNote = ", повтор $($again.Us) мкс"
        if (($again.Marked -eq 1) -and ($again.Us -lt $onBest.Us)) { $onBest = $again }
    }
    Check 'включённая подписка не удваивает цену записи' `
        ($onBest.Us -le (2 * $noAdapter.Us)) `
        "без подписчика $($noAdapter.Us) мкс, включён $($onBest.Us) мкс при потолке $(2 * $noAdapter.Us)$retryNote"

    # ---------- сборщик переходника под настоящую таблицу ----------
    Write-Host 'Сборщик: переходник под таблицу установки'
    # Имена вставляются ПУСТЫМИ, а не пропускаются: NAV не заводит DEFAULT ни на одном
    # столбце, и все они NOT NULL. Пропущенный столбец - это отказ сервера, а не пустое поле.
    Invoke-Sql @"
INSERT INTO $context ([Table No_],[Table Name],[Document Field No_],[Document Field Name],[Document Caption],[Enabled])
VALUES ($TableNo,N'',$FieldNo,N'',N'',0);
"@ | Out-Null
    Invoke-Codeunit $TaskCodeunitId 'RefreshContextNames' 'перечитывание имён' | Out-Null
    $names = Scalar "SELECT [Table Name] + '|' + [Document Field Name] FROM $context WHERE [Table No_] = $TableNo;"
    $nm = ($names -split '\|') | ForEach-Object { $_.Trim() }
    Check 'NAV сам назвал таблицу и поле, и сборщику есть что подставлять' `
        (($nm.Count -eq 2) -and ($nm[0] -ne '') -and ($nm[1] -ne '')) `
        "таблица [$($nm[0])], поле [$($nm[1])]"

    $generated = Join-Path $outDir "c${AdapterObjectNo}_LockWatch_Adapter_$TableNo.txt"
    if (Test-Path $generated) { Remove-Item $generated -Force }
    & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'New-ContextAdapter.ps1') `
        -TableNo $TableNo -ObjectNo $AdapterObjectNo -Server $Server -Database $Database -Company $Company | Out-Null
    if ($LASTEXITCODE -ne 0) { Fail 'сборщик переходника отказал' }
    Check 'переходник собран, и в нём стоит номер целевой таблицы' `
        ((Test-Path $generated) -and (([IO.File]::ReadAllText($generated)) -match "\[EventSubscriber\(Table,$TableNo,")) `
        "файл $(Split-Path -Leaf $generated)"

    Import-Object $generated 'made-adapter'
    Compile-Codeunit $AdapterObjectNo 'made-adapter'
    Invoke-Sql "UPDATE $context SET [Enabled] = 1 WHERE [Table No_] = $TableNo;" | Out-Null
    Restart-Nav 'собранный переходник выложен' | Out-Null
    $selfTest = Invoke-Codeunit $AdapterObjectNo 'SelfTest' 'обкатка собранного переходника'
    Check 'платформа знает подписку собранного переходника' `
        ($selfTest -match 'passed 3 of 3|пройдено 3 из 3') `
        (($selfTest -split "`n" | Where-Object { $_ -match 'passed|пройдено|ERROR|Ошибка' } | Select-Object -First 1) -replace '\s+', ' ')

    # Обкатка образца переехала сюда из сборки: в пакет образец не едет, и на стенде он
    # стоит только здесь - этот прогон его и выкладывает. Спрашивает она то, чего не
    # спрашивает замер: знает ли платформа подписку и лёг ли в отметку ТОТ САМЫЙ документ,
    # который записан. Замер считает отметки, а не сверяет их содержимое.
    $sampleSelf = Invoke-Codeunit $SampleAdapterId 'SelfTest' 'обкатка образца'
    Check 'образец сам прошёл по мосту: подписка жива, и в отметке тот документ, что записан' `
        ($sampleSelf -match 'passed 2 of 2|пройдено 2 из 2') `
        (($sampleSelf -split "`n" | Where-Object { $_ -match 'passed|пройдено|ERROR|Ошибка' } | Select-Object -First 1) -replace '\s+', ' ')

    $report += ''
    $report += "цена подписки на 2000 записей: без подписчика $($noAdapter.Us) мкс на строку, " +
               "выключен $($offAdapter.Us), включён $($onAdapter.Us)"
}
finally {
    Write-Host 'Убираю за собой'
    # Порядок уборки - от ЦЕНЫ ОШИБКИ. Первыми возвращаются строки контекста: прогон правит
    # ЧУЖУЮ настройку, и установленный переходник без своей строки молча перестаёт отмечать
    # документ. Только потом идёт то, что может отказать, - снятие кодюнитов и перезапуск
    # службы: Fail делает exit, а exit прекращает процесс сразу и до конца finally, и прежний
    # порядок оставлял строки неубранными ровно тогда, когда уборка и нужна была.
    $restore = "DELETE FROM $mark;"
    if ($rowsWas.Count -eq 0) {
        Warn-Cleanup 'прежнее состояние строк контекста прочитать не удалось - убираю строки целиком'
        $restore += " DELETE FROM $context WHERE [Table No_] IN ($sampleTableNo,$TableNo);"
    } else {
        foreach ($no in @($sampleTableNo, $TableNo)) {
            $was = $rowsWas[$no]
            if ($was.Exists -eq 0) { $restore += " DELETE FROM $context WHERE [Table No_] = $no;" }
            elseif ($was.Enabled -match '^[01]$') { $restore += " UPDATE $context SET [Enabled] = $($was.Enabled) WHERE [Table No_] = $no;" }
        }
    }
    Invoke-CleanupSql $restore 'уборка за прогоном'

    # Собранный переходник со стенда снимается ОБЯЗАТЕЛЬНО: оставить на чужой таблице
    # подписчика, о котором никто не просил, прогон не вправе. Отказ в этом хвосте виден
    # предупреждением: чужие данные к нему уже возвращены, и он говорит о другом - о том,
    # что на стенде остался живой подписчик на чужую таблицу.
    if ($generated) {
        try { Delete-Codeunit $AdapterObjectNo 'made-adapter-drop' -Soft | Out-Null }
        catch { Warn-Cleanup "собранный переходник $AdapterObjectNo снять не удалось: $($_.Exception.Message)" }
        if (Test-Path $generated) { Remove-Item $generated -Force }
    }
    # Образец со стенда СНИМАЕТСЯ, а не возвращается на место. В пакет он не едет, значит
    # после выкладки его на стенде нет, и оставить его здесь значило бы развести стенд с
    # установкой - ровно той разницей, которую прогон и обязан не допускать.
    try { Delete-Codeunit $SampleAdapterId 'sample-adapter-drop' -Soft | Out-Null }
    catch { Warn-Cleanup "образец $SampleAdapterId снять не удалось: $($_.Exception.Message)" }
    try { Restart-Nav 'стенд возвращён в исходное' -Soft | Out-Null }
    catch { Warn-Cleanup "служба $Instance не перезапустилась: $($_.Exception.Message)" }
    if ($StopInstance) { Stop-Service $service -Force }
}

Write-Host ''
Write-Host "пройдено $passed из $total"
Write-Host ''
$report | ForEach-Object { Write-Host $_ }
if ($passed -lt $total) { Fail 'переходник проверку не прошёл' }
Write-Host 'Готово: цена подписки названа числом, а собранный переходник платформе известен' -ForegroundColor Green
