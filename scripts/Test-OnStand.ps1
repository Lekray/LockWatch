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
    [int]    $PermissionsCodeunitId = 110247,
    [int]    $SetupTableId    = 110230,
    [int]    $SetupPageId     = 110230,
    # Диапазон, занятый инструментом целиком. Всё, что вне его, - чужое, и о чужом надо
    # сказать вслух: репозиторий служит материалом для согласования установки.
    [int]    $OurFirstObject  = 110230,
    [int]    $OurLastObject   = 110249,
    # Номер таблицы документа - такая же конкретика установки, как имя базы, и берётся он
    # оттуда же. Номер ПОЛЯ рядом не проверяется нарочно: это однозначное число, и искать
    # его по репозиторию значило бы находить его всюду.
    [string] $DocTableNo      = $env:LW_DOC_TABLE_NO,
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
# потерянные параметры службы, а на деле - гонка со стартом.
#
# Здесь стояло "и на прогретой службе она не воспроизводится вовсе". Это оказалось сказано
# шире, чем измерено: 13.09.2026 такой отказ случился на службе, поднятой минутами раньше,
# и не повторился ни в одном из пяти следующих заходов. Две догадки проверены и сняты -
# перезапуск с немедленной сборкой прошёл, сборка под исключительным замком на таблице
# инструмента прошла тоже. Причина осталась неизвестной, и потому отказ теперь говорит
# читателю, что именно ему передали (FINDINGS, раздел 79).
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
#
# Сами координаты, однако, не обязательны: среда находит запущенный экземпляр и сама
# (замерено 13.09.2026 - с погашенными координатами сборка прошла целиком). Передаются они
# затем, что находить среда будет ОДИН экземпляр, а их на машине бывает несколько, и молча
# синхронизировать схему не с тем - хуже отказа.
$hasTables = @($files | Where-Object { $_.Name.Substring(0,1) -eq 't' }).Count -gt 0
$navServerArgs = ''
if ($hasTables) {
    Ensure-Instance 'в пакете есть таблицы'
    $navServerArgs = ",NavServerName=$Server,NavServerInstance=$Instance,NavServerManagementPort=$MgmtPort"
}

function Invoke-Sql([string]$query) {
    # -w 500 обязателен: по умолчанию sqlcmd рвёт строку на 80 знаках, и длинное значение
    # приходит ДВУМЯ строками. Проверка, читающая первую, получает обрезок и судит по нему.
    # -b обязателен не меньше: без него sqlcmd возвращает НОЛЬ и на ошибке SQL, проверка
    # кода возврата проходит вхолостую, а запрос не выполнен вовсе.
    $answer = & sqlcmd -S $Server -d $Database -E -b -l 30 -w 500 -W -s '|' -h -1 -Q "SET NOCOUNT ON; $query" 2>&1
    if ($LASTEXITCODE -ne 0) { Fail "SQL не выполнился: $($answer -join ' ')" }
    # Запятая обязательна. Без неё PowerShell разворачивает массив из одной строки в скаляр,
    # и $row[0] берёт ПЕРВЫЙ СИМВОЛ строки: дата превращается в "0", а [int] от символа "2"
    # даёт 50 - его код. Обе подмены выглядят как настоящие числа и врут молча.
    return ,@($answer | Where-Object { $_ -and ($_ -notmatch '^\(') })
}

# Репозиторий считаем ПУБЛИЧНЫМ - это первое правило проекта, и держалось оно на внимании.
# Внимание подвело четырежды: имя компании и номер таблицы документа уехали в FINDINGS
# 09.09.2026 и пролежали там четыре дня, имя той же таблицы - дважды, а имя экземпляра чуть
# не уехало в образец текста внутри самой этой сборки 13.09.2026. Все четыре нашлись глазами
# и все четыре - случайно.
#
# Искать умеет только тот, кто имена знает, а знать их репозиторию нельзя. Берутся они ОТТУДА
# ЖЕ, откуда их берёт вся работа: три - из переменных окружения, а имя таблицы документа
# спрашивается У БАЗЫ по её номеру, ровно как спрашивает его сам инструмент. Вести список
# имён руками было бы четвёртой такой же бедой (разделы 76-78).
#
# В git не попадает ни одно из них: отказ печатает файл, строку и ЧТО это за имя, а самого
# имени не показывает.
$secretNames = [ordered]@{ 'имя базы' = $Database; 'имя экземпляра' = $Instance
                           'имя компании' = $Company; 'номер таблицы документа' = $DocTableNo }
foreach ($what in @($secretNames.Keys)) {
    if (-not $secretNames[$what]) { Fail "$what не задано - проверить репозиторий на утечку им нечем" }
}
# Имя поля рядом не спрашивается: у целевой таблицы это "No.", и такое имя нашлось бы всюду.
$docRows = Invoke-Sql "SELECT [Name] FROM [Object] WHERE [Type] = 1 AND [ID] = $DocTableNo;"
if ($docRows.Count -eq 0) { Fail 'таблицы с номером из настройки стенда в базе нет - проверить утечку её имени нечем' }
$secretNames['имя таблицы документа'] = $docRows[0].Trim()

$leaks = @()
foreach ($rel in (& git -C $root ls-files)) {
    $full = Join-Path $root $rel
    if (-not (Test-Path $full)) { continue }
    $lines = [IO.File]::ReadAllLines($full)
    for ($i = 0; $i -lt $lines.Count; $i++) {
        foreach ($what in @($secretNames.Keys)) {
            # Границы по обе стороны: имя компании бывает началом имени базы, и без границ
            # оно находилось бы внутри неё в каждой строке запроса.
            if ($lines[$i] -match ('(?<![A-Za-z0-9_])' + [regex]::Escape($secretNames[$what]) + '(?![A-Za-z0-9_])')) {
                $leaks += "$rel : строка $($i + 1) - это $what"
            }
        }
    }
}
if ($leaks) {
    Fail ("в git уехало имя конкретной установки, а репозиторий считается ПУБЛИЧНЫМ:`n  " +
          (($leaks | Sort-Object -Unique) -join "`n  "))
}

# «Кодировки - здесь ломается чаще всего» стоит в правилах проекта заголовком, и там же
# сказано, чем ловить: счётом байтов 13 и 10 после каждой пакетной правки. Считал их
# человек - руками и помня, что надо. Ни один прогон в файл не заглядывал ни разу, а
# `sed -i` из git bash снимает CR со всего файла молча.
#
# Замер 14.09.2026, четыре клетки на одном и том же тексте с кириллицей:
#   pwsh 7 читает и с BOM, и без - работает одинаково;
#   Windows PowerShell 5.1 БЕЗ BOM читает файл как ANSI, и кириллица ломает РАЗБОР:
#     «Unexpected token '»РѕРІРѕ'», скрипт не начинает исполняться вовсе;
#   а объяви файл #requires -Version 7 - 5.1 откажет ЧЕСТНО, словами про версию, и с BOM,
#     и без него.
# Отсюда правило, которое можно проверить: скрипту, объявившему семёрку, BOM безразличен,
# всякому другому - обязателен.
#
# Объекту BOM запрещён по своей причине, и причина эта не в пакете: .NET снимает BOM при
# чтении (замерено там же), так что сборка его не увидит вовсе. Увидит его C/SIDE - если
# объект понесут туда файлом, а не пакетом.
#
# У .sql правило ОБРАТНОЕ объектам, и оно тоже замерено (14.09.2026): sqlcmd читает файл
# без BOM как OEM, и русская шапка отчёта приезжает в консоль мусором - «Р¶РґС‘С‚ spid»
# вместо «ждёт spid». Данные при этом верны, и беда выглядит не порчей файла, а поломкой
# консоли. Скрипт ручного разбора пишет про это в своей же шапке; теперь про это знает и
# сборка.
$encProblems = @()
foreach ($rel in (& git -C $root ls-files '*.ps1' '*.txt' '*.sql')) {
    $full = Join-Path $root $rel
    if (-not (Test-Path $full)) { continue }
    $bytes = [IO.File]::ReadAllBytes($full)
    $hasBom = ($bytes.Length -ge 3) -and ($bytes[0] -eq 0xEF) -and ($bytes[1] -eq 0xBB) -and ($bytes[2] -eq 0xBF)
    $bare = 0
    for ($i = 0; $i -lt $bytes.Length; $i++) {
        if (($bytes[$i] -eq 10) -and (($i -eq 0) -or ($bytes[$i - 1] -ne 13))) { $bare++ }
    }
    if ($bare -gt 0) { $encProblems += "$rel : переводов строки без CR - $bare" }
    # Настоящий ли это UTF-8. Кириллица в cp1251 почти всегда даёт недопустимую
    # последовательность, и подмена кодировки ловится здесь, а не в клиенте - знаками
    # вопроса в сообщении, которые уже не скажут, где их потеряли.
    try { [void]([Text.UTF8Encoding]::new($false, $true)).GetString($bytes) }
    catch { $encProblems += "$rel : это не UTF-8" }
    if ($rel -like '*.sql') {
        if (-not $hasBom) { $encProblems += "$rel : скрипту SQL BOM обязателен - sqlcmd прочтёт его как OEM" }
    } elseif ($rel -like '*.txt') {
        if ($hasBom) { $encProblems += "$rel : объекту BOM запрещён - пакет его снимет, а C/SIDE увидит" }
    } elseif (-not $hasBom) {
        if ([Text.Encoding]::UTF8.GetString($bytes) -notmatch '(?m)^\s*#requires\s+-Version\s+7') {
            $encProblems += "$rel : без #requires -Version 7 скрипту нужен BOM - 5.1 прочтёт его как ANSI"
        }
    }
}
if ($encProblems) {
    Fail ("кодировка файлов разошлась с правилом проекта:`n  " + (($encProblems | Sort-Object) -join "`n  "))
}

# Кириллица в файле .sql держится не на кодировке файла, а на ПАРАМЕТРАХ СОРТИРОВКИ той
# базы, где его запускают: литерал без N разбирается как varchar по сортировке базы, и на
# латинской от него остаются вопросительные знаки. Замер 14.09.2026 на своей базе с
# Latin1_General_CI_AS:
#     PRINT 'без N: отметки контекста нет'   ->  ??? N: ??????? ????????? ???
#     PRINT N'с N:  отметки контекста нет'   ->  с N:  отметки контекста нет
#     CONVERT(varchar(30),  'текст')         ->  (??????? ????????? ???)
#     CONVERT(nvarchar(30), N'текст')        ->  (отметки контекста нет)
# Стенд идёт с Cyrillic_General_100_CS_AS, и на нём не видно ровно ничего. А скрипт ручного
# разбора уезжает на ЧУЖУЮ базу, сортировку которой мы не выбираем, и там от объяснений
# остались бы знаки вопроса - то есть хуже, чем молчание: молчание хоть не врёт про порчу.
#
# Отсюда два правила, и оба проверяемы: кириллица в литерале - только с N, текст - только
# nvarchar (имя таблицы NAV и имя компании в чужой базе бывают кириллическими). Разбор
# посимвольный, а не образцом: «--» внутри литерала комментарием не является, кавычка
# внутри комментария литерала не открывает, и образец ошибся бы на этом молча.
function Read-SqlText([string]$text) {
    $code = [Text.StringBuilder]::new()
    $literals = @()
    $i = 0; $n = $text.Length
    while ($i -lt $n) {
        $c = $text[$i]
        if (($c -eq '-') -and ($i + 1 -lt $n) -and ($text[$i + 1] -eq '-')) {
            while (($i -lt $n) -and ($text[$i] -ne "`n")) { $i++ }
        } elseif (($c -eq '/') -and ($i + 1 -lt $n) -and ($text[$i + 1] -eq '*')) {
            $i += 2
            while (($i + 1 -lt $n) -and -not (($text[$i] -eq '*') -and ($text[$i + 1] -eq '/'))) { $i++ }
            $i += 2
        } elseif ($c -eq "'") {
            $start = $i
            $i++
            while ($i -lt $n) {
                if ($text[$i] -eq "'") {
                    if (($i + 1 -lt $n) -and ($text[$i + 1] -eq "'")) { $i += 2; continue }
                    break
                }
                $i++
            }
            $body = $text.Substring($start + 1, [Math]::Max(0, $i - $start - 1))
            $before = if ($start -gt 0) { "$($text[$start - 1])" } else { '' }
            $literals += [pscustomobject]@{ Text = $body; Prefixed = ($before -match '^[Nn]$') }
            $i++
        } else {
            [void]$code.Append($c)
            $i++
        }
    }
    return [pscustomobject]@{ Code = $code.ToString(); Literals = $literals }
}

$sqlProblems = @()
foreach ($rel in (& git -C $root ls-files '*.sql')) {
    $full = Join-Path $root $rel
    if (-not (Test-Path $full)) { continue }
    $parsed = Read-SqlText ([IO.File]::ReadAllText($full))
    foreach ($lit in $parsed.Literals) {
        if (($lit.Text -match '[А-Яа-яЁё]') -and (-not $lit.Prefixed)) {
            $shown = if ($lit.Text.Length -gt 40) { $lit.Text.Substring(0, 40) + '...' } else { $lit.Text }
            $sqlProblems += "$rel : кириллица в литерале без N - «$shown»"
        }
    }
    $bare = [regex]::Matches($parsed.Code, '(?<![n\w])varchar\s*\(')
    if ($bare.Count -gt 0) {
        $sqlProblems += "$rel : varchar встречается $($bare.Count) раз - на базе с латинской сортировкой кириллица в нём станет знаками вопроса"
    }
}
if ($sqlProblems) {
    Fail ("текст .sql зависит от сортировки чужой базы:`n  " + (($sqlProblems | Sort-Object) -join "`n  "))
}

# Подписчик - единственный наш объект, исполняющийся В ЧУЖОМ СЕАНСЕ: платформа зовёт его
# внутри транзакции того, кто пишет строку документа. Права на запись отметки проверяются
# поэтому у ТОГО человека, а не у нас, и отказ прилетает ВНУТРЬ его транзакции - проведение
# падает. На стенде этого не увидеть ничем: там всё ходит под SUPER, а на бою пользователи
# не SUPER почти никогда.
#
# Свойство Permissions эту беду НЕ закрывает - замерено лестницей из восьми ступеней
# (docs/FINDINGS.md, раздел 92): работают только ПРЯМЫЕ права пользователя на обе наши
# таблицы, и о них сказано в порядке установки, где им и место. Но снятие свойства делает
# хуже: без него не проходит даже чтение строки контекста (ступень 6). Поэтому свойство
# остаётся и сверяется здесь - снять его легко и незаметно.
#
# Обещать сторожу больше, чем он даёт, нельзя: сторож, на которого надеются зря, опаснее
# отсутствующего. Потому и слова его - про объявленные права, а не про «чужой сеанс».
#
# Номера таблиц берутся ИЗ ПАКЕТА по именам, а не пишутся числом: перенумеруй объект - и
# сторож, знающий число, промолчал бы (то же правило, что в разделе 81).
function Get-ObjectNo([string]$name) {
    foreach ($rel in (& git -C $root ls-files 'objects/*.txt')) {
        $full = Join-Path $root $rel
        if (-not (Test-Path $full)) { continue }
        $m = [regex]::Match([IO.File]::ReadAllText($full), "(?m)^OBJECT\s+Table\s+(\d+)\s+$([regex]::Escape($name))\s*$")
        if ($m.Success) { return [int]$m.Groups[1].Value }
    }
    return 0
}
$markNo = Get-ObjectNo 'LockWatch Context Mark'
$ctxNo  = Get-ObjectNo 'LockWatch Context Table'
$permProblems = @()
if (($markNo -eq 0) -or ($ctxNo -eq 0)) {
    $permProblems += "таблицы отметок и контекста не нашлись в пакете по именам ($markNo, $ctxNo)"
} else {
    foreach ($rel in (& git -C $root ls-files 'objects/c*.txt')) {
        $full = Join-Path $root $rel
        if (-not (Test-Path $full)) { continue }
        $text = [IO.File]::ReadAllText($full)
        if ($text -notmatch '\[EventSubscriber\(') { continue }
        # Свойство C/SIDE переносит по строкам, поэтому оно склеивается в одну.
        $props = ([regex]::Match($text, '(?s)Permissions=(.*?);')).Groups[1].Value -replace '\s', ''
        foreach ($need in @(@{ No = $markNo; Rights = 'rimd'; What = 'таблицу отметок' },
                            @{ No = $ctxNo;  Rights = 'rim';  What = 'строку контекста' })) {
            $m = [regex]::Match($props, "TableData$($need.No)=([rimd]+)")
            if (-not $m.Success) {
                $permProblems += "$rel : подписчик не объявляет прав на $($need.What) ($($need.No)) - без них не проходит даже чтение (раздел 92)"
            } else {
                $missing = ($need.Rights.ToCharArray() | Where-Object { $m.Groups[1].Value -notmatch $_ }) -join ''
                if ($missing) {
                    $permProblems += "$rel : у прав на $($need.What) ($($need.No)) не хватает букв «$missing» - объявлено «$($m.Groups[1].Value)»"
                }
            }
        }
    }
}
if ($permProblems) {
    Fail ("подписчик не объявил прав на свои таблицы:`n  " + (($permProblems | Sort-Object) -join "`n  "))
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
        if ($text) { Fail "finsql ($logName):`n$text$(Coordinates-Note $text)" }
    }
}

function Coordinates-Note([string]$text) {
    # Отказ синхронизации схемы печатает координаты службы ПУСТЫМИ - "Server Name: Server
    # Instance: Management Port: 0" - и первым же пунктом советует проверить, запущен ли
    # сервер. Читается это как "потеряны параметры службы", и искать идут в конфигурацию,
    # где искать нечего: координаты переданы, а служба отвечает.
    #
    # Приписка не гадает о причине - причина неизвестна, - а называет ТОЛЬКО то, что сборка
    # знает наверняка: что она передала и чего НЕ проверяла. Отказ, называющий виноватого
    # наугад, посылает искать туда, куда послал (раздел 63).
    # Признак берётся ТОЧНЫЙ: два пустых поля подряд. Отказ по неверному номеру порта тоже
    # называет порт, но координаты в нём ЗАПОЛНЕНЫ, и приписка про ненайденный экземпляр
    # была бы там прямой неправдой.
    if ($text -notmatch 'Server Name:\s*Server Instance:') { return '' }
    $passed = if ($navServerArgs) { "сервер [$Server], экземпляр [$Instance], порт управления $MgmtPort" }
              else { 'ничего - в пакете нет таблиц' }
    return "`n`nПустые координаты выше - это то, что среда РАЗРЕШИЛА, а не то, что ей дали: передано " +
           "$passed.`n" +
           "В номере порта дело быть не может: неверный номер даёт ДРУГОЙ отказ, и координаты он " +
           "называет (замерено на порте 9999). Пустые же значат, что экземпляр не нашёлся вовсе.`n" +
           "Больше сборке сказать нечего, и гадать она не станет: такой отказ случился однажды на давно " +
           "поднятой службе и не повторился ни разу в семи следующих заходах, а перезапуск с немедленной " +
           "сборкой и сборка под исключительным замком на таблице инструмента прошли обе. Повторите " +
           "сборку (FINDINGS, раздел 79)."
}

# Приписка - чистая функция над текстом, и проверяется она без базы, тут же. Образцы
# настоящие, снятые со стенда 13.09.2026: первый - тот самый отказ, где координаты ПУСТЫ,
# второй - отказ по неверному номеру порта, где они названы. Отказ этот сам по себе не
# воспроизводится ничем (раздел 79), и другой дороги проверить приписку нет вовсе.
#
# Различать эти два обязательно: соврав на втором, приписка объявила бы ненайденным
# экземпляр, который нашёлся, - и увела бы читателя от верного номера порта.
$sampleLost = 'The table changes were saved, but they contain schema changes that cannot be ' +
              'synchronized to the database with the Microsoft Dynamics NAV Server instance.' +
              'Contact your system administrator with the following information:' +
              'Server Name: Server Instance: Management Port: 0 -- Object: Table 110230'
$samplePort = "Не удаётся обработать изменения таблицы`r`nИмя сервера: localhost`r`n" +
              "Экземпляр сервера: DynamicsNAV110`r`nПорт управления: 9999"
if (-not (Coordinates-Note $sampleLost)) {
    Fail 'приписка молчит на отказе с ПУСТЫМИ координатами - читателя оставят наедине с чужими словами'
}
if (Coordinates-Note $samplePort) {
    Fail 'приписка срабатывает на отказе с НАЗВАННЫМИ координатами - она объявила бы ненайденным найденный экземпляр'
}

Write-Host 'Сборка пакета'
# Перевод строки в конце КАЖДОГО объекта, а не как выйдет. Шесть файлов из тридцати пяти
# заканчивались без него, и в пакете выходило "}OBJECT Codeunit ..." одной строкой: C/SIDE
# такое принимает, а всякий разбор по строкам - и наши же проверки пакета - теряет на
# склейке заголовок. Пять заголовков из тридцати пяти не виделись вовсе (12.09.2026).
$monolith = (($files | ForEach-Object {
    $body = [IO.File]::ReadAllText($_.FullName)
    if ($body -notmatch "(\r?\n)$") { $body += "`r`n" }
    $body
}) -join '')
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

# Точка с запятой и знак равенства ВНУТРИ многоязычного текста ломают импорт, и отказ
# указывает не на причину: "'' is not an option" либо "You cannot enter ... in ToolTipML",
# и номер строки. Ловилось трижды, каждый раз стоило по прогону, поэтому проверка стоит
# здесь - ДО finsql, а не после.
#
# Разбор простой: содержимое ML-литерала в квадратных скобках и текста TextConst в
# кавычках, а внутри - каждая точка с запятой обязана быть РАЗДЕЛИТЕЛЕМ ЯЗЫКОВ, то есть за
# ней должен стоять трёхбуквенный код и знак равенства. Всё прочее - беда.
$mlProblems = @()
$mlLiterals = @()
foreach ($m in [regex]::Matches($monolith, '(?s)(?:Caption|ToolTip|OptionCaption|Description|Instruction)ML=\[(.*?)\]')) {
    $mlLiterals += $m.Groups[1].Value
}
foreach ($m in [regex]::Matches($monolith, "TextConst '([^']*)'")) {
    $mlLiterals += $m.Groups[1].Value
}
foreach ($literal in $mlLiterals) {
    if ($literal -notmatch '^\s*[A-Z]{3}=') { continue }
    foreach ($hit in [regex]::Matches($literal, ';')) {
        if ($hit.Index -eq $literal.Length - 1) { continue }
        $tail = $literal.Substring($hit.Index + 1)
        if ($tail -notmatch '^\s*[A-Z]{3}=') {
            $near = $literal.Substring([Math]::Max(0, $hit.Index - 60), [Math]::Min(80, $literal.Length - [Math]::Max(0, $hit.Index - 60)))
            $mlProblems += "точка с запятой не разделяет языки: ...$near"
        }
    }
    $equals = ([regex]::Matches($literal, '=')).Count
    $codes = ([regex]::Matches($literal, '(?:^|;)\s*[A-Z]{3}=')).Count
    if ($equals -ne $codes) {
        $mlProblems += "знак равенства внутри текста ($equals при $codes языках): $($literal.Substring(0, [Math]::Min(120, $literal.Length)))"
    }
}
if ($mlProblems) { Fail ("многоязычный текст не переживёт импорт:`n" + (($mlProblems | Select-Object -Unique | Select-Object -First 5) -join "`n")) }

# Два [External] подряд C/SIDE проглатывает молча, и так же молча теряет атрибут функция,
# у которой его увели вставкой НАД строкой PROCEDURE. Беда не смертельная - звать функцию
# без атрибута всё равно можно, - но правка при этом делает не то, что написано, а поймать
# это глазом нельзя: в отчёте не меняется ничто. Ловилось дважды, 11 и 12.09.2026.
$doubles = ([regex]::Matches($monolith, '\[External\]\s*\r?\n\s*\[External\]')).Count
if ($doubles -gt 0) {
    Fail "атрибут [External] стоит дважды подряд ($doubles раз): вставка легла над чужой функцией и увела её атрибут"
}

# Номер локальной переменной у C/SIDE ОБЩИЙ на блок: параметры и раздел VAR вместе. Два
# имени с одним номером компилятор не принимает - "The local variable ID 1000000069 is used
# by both local variable CovEpBefore and local variable BenchDropped" - и говорит он это
# импортом, то есть через двенадцать минут сборки, и откатывает всю пачку. Стоило одного
# прогона 13.09.2026, когда новая переменная мерного объекта взяла занятый номер.
#
# Блок кончается на BEGIN, а начинается либо заголовком функции, либо разделом CODE:
# объектные переменные живут в своём пространстве, и совпадение в нём так же смертельно.
$idProblems = @()
$idBlock = ''; $idSeen = @{}
foreach ($line in ($monolith -split "`r`n")) {
    if ($line -match '^\s*(?:LOCAL\s+)?(?:PROCEDURE|EVENT)\s+([A-Za-z0-9_"]+)@') { $idBlock = $Matches[1]; $idSeen = @{} }
    elseif ($line -match '^\s*CODE\s*$') { $idBlock = 'объектные переменные'; $idSeen = @{} }
    elseif ($line -match '^\s*([A-Za-z0-9_]+)=VAR\s*$') { $idBlock = $Matches[1]; $idSeen = @{} }
    if ($idBlock -eq '') { continue }
    if (($line -match '^\s*BEGIN\s*$') -or ($line -match '=BEGIN\s*$')) { $idBlock = ''; continue }
    foreach ($hit in [regex]::Matches($line, '([A-Za-z0-9_"]+)@(\d{6,})')) {
        # Имя самой функции несёт номер из ДРУГОГО пространства, и сравнивать его с
        # переменными нельзя. Ловится оно по совпадению с именем блока.
        $name = $hit.Groups[1].Value
        $id = $hit.Groups[2].Value
        if ($name -eq $idBlock) { continue }
        if ($idSeen.ContainsKey($id) -and ($idSeen[$id] -ne $name)) {
            $idProblems += "$idBlock - номер $id у '$($idSeen[$id])' и у '$name'"
        }
        $idSeen[$id] = $name
    }
}
if ($idProblems) {
    Fail ("номер локальной переменной занят дважды - импорт откажет и откатит пакет:`n" +
          (($idProblems | Select-Object -Unique | Select-Object -First 5) -join "`n"))
}

# Пятый признак, и найден он пять раз подряд - разделы 54, 61, 62, 63, 64: мерный прогон
# зовёт чистую функцию САМ, передаёт ей то, чего живая дорога не передаёт, и остаётся
# зелёным. В разделе 64 это стоило целого класса эпизодов: живая дорога звала EpisodeClass
# с нулём на месте признака, мерный прогон - с двойкой, и проверка мерила свободу, которой
# у продукта не было ни дня.
#
# Ловится это точным совпадением, а не подозрением: ВСЕ боевые вызовы функции пришпилили
# один и тот же довод к постоянной, а мерный объект подставил на то же место другое.
# Законная постоянная так не выглядит: у неё либо есть боевой вызов с переменной (как у
# SetDocument, где вторая дорога зовёт с именами), либо мерный объект согласен с боевым.
function Split-CalArgs([string]$src, [int]$openAt) {
    # Накопитель зовётся $list, а не $args: $args у PowerShell свой, встроенный, и внутри
    # функции присваивание ему - не ошибка разбора, а тихая подмена.
    $depth = 0; $list = @(); $cur = ''; $i = $openAt; $inStr = $false
    while ($i -lt $src.Length) {
        $ch = $src[$i]
        if ($inStr) { $cur += $ch; if ($ch -eq "'") { $inStr = $false } }
        elseif ($ch -eq "'") { $inStr = $true; $cur += $ch }
        elseif ($ch -eq '(') { $depth++; if ($depth -gt 1) { $cur += $ch } }
        elseif ($ch -eq ')') { $depth--; if ($depth -eq 0) { return ,($list + $cur) }; $cur += $ch }
        elseif (($ch -eq ',') -and ($depth -eq 1)) { $list += $cur; $cur = '' }
        else { if ($depth -ge 1) { $cur += $ch } }
        $i++
    }
    # Скобка не закрылась - разбирать нечего. Молчание тут честнее догадки: сборка не
    # обязана понимать C/AL целиком, она обязана не врать.
    return ,@()
}
# Чистые кодюниты, которые меряются без базы, и мерные объекты, которые их меряют.
# Ключ объекта - РОД И НОМЕР, а не номер: таблица 110230, кодюнит 110230 и страница 110230
# живут рядом, и по одному номеру кодюнит разбора подменялся таблицей настройки.
$pureCodeunits = @(110230, 110232)
# 110243 держит замок от имени названного пользователя и живёт одними прогонами - в этом
# списке он потому же, почему и остальные: мерный объект не делает функцию живой.
$benchCodeunits = @(110231, 110233, 110239, 110242, 110243)
$heads = [regex]::Matches($monolith, '(?m)^OBJECT\s+(\w+)\s+(\d+)\s+(.+?)\s*$')
if ($heads.Count -ne $files.Count) {
    Fail "заголовков объектов в пакете $($heads.Count) при $($files.Count) файлах - разбор пакета не полон"
}
$parts = @()
for ($i = 0; $i -lt $heads.Count; $i++) {
    $to = if ($i + 1 -lt $heads.Count) { $heads[$i + 1].Index } else { $monolith.Length }
    $parts += [pscustomobject]@{
        Kind = $heads[$i].Groups[1].Value; No = [int]$heads[$i].Groups[2].Value
        Name = $heads[$i].Groups[3].Value
        Body = $monolith.Substring($heads[$i].Index, $to - $heads[$i].Index)
    }
}

# Образец подписчика в ПАКЕТ НЕ ЕДЕТ, и правило это ВЫВОДИТСЯ, а не пишется номером.
# Номер таблицы у подписки - константа времени компиляции, поэтому всякий подписчик,
# лежащий в git, по определению образец: на бою на его месте стоит объект, СОБРАННЫЙ под
# таблицу установки (scripts/New-ContextAdapter.ps1). Заведётся второй образец - отсеется
# сам, и списка править не придётся.
#
# Везти его было бы не мелочью. Это живой подписчик на ШТАТНОЙ таблице NAV: он срабатывает
# на каждой её записи ни за чем (раздел 23 - надбавка от двух процентов до двенадцати даже
# при выключенной строке контекста), а его обкатка в эту таблицу ПИШЕТ. На стенде ему
# место, на бою - нет.
#
# Проверки выше смотрят на ВСЕ объекты папки, включая образец: он настоящий C/AL, и
# сортировка, кодировки, номера переменных и объявленные права нужны ему не меньше. Отсев
# касается только того, что повезём.
$shipFiles = @(); $shipParts = @(); $sampleParts = @()
for ($i = 0; $i -lt $parts.Count; $i++) {
    if ($parts[$i].Body -match '\[EventSubscriber\(') { $sampleParts += $parts[$i] }
    else { $shipParts += $parts[$i]; $shipFiles += $files[$i] }
}
if ($sampleParts.Count -ne 1) {
    Fail ("образцов подписчика в objects/ $($sampleParts.Count) при одном ожидаемом - " +
          'сборщик переходника берёт образец единственным, и выбирать ему не из чего')
}
$pinProblems = @()
foreach ($pureNo in $pureCodeunits) {
    $pure = $parts | Where-Object { ($_.Kind -eq 'Codeunit') -and ($_.No -eq $pureNo) }
    if (-not $pure) { continue }
    $names = @()
    foreach ($m in [regex]::Matches($pure.Body, '(?m)^\s*PROCEDURE\s+([A-Za-z0-9_]+)@\d+')) { $names += $m.Groups[1].Value }
    $names = @($names | Sort-Object -Unique)
    # Доводы по местам: отдельно боевые, отдельно мерные.
    $seen = @{}
    foreach ($p in $parts) {
        if (($p.Kind -eq 'Codeunit') -and ($p.No -eq $pureNo)) { continue }
        $vars = @()
        foreach ($m in [regex]::Matches($p.Body, "(?m)^\s*([A-Za-z0-9_]+)@\d+\s*:\s*Codeunit\s+$pureNo\s*;")) { $vars += $m.Groups[1].Value }
        if ($vars.Count -eq 0) { continue }
        $isBench = ($p.Kind -eq 'Codeunit') -and ($benchCodeunits -contains $p.No)
        foreach ($v in ($vars | Sort-Object -Unique)) {
            foreach ($name in $names) {
                foreach ($call in [regex]::Matches($p.Body, "$v\.$name\(")) {
                    $list = Split-CalArgs $p.Body ($call.Index + $call.Length - 1)
                    for ($i = 0; $i -lt $list.Count; $i++) {
                        $a = ($list[$i] -replace '\s+', ' ').Trim()
                        $key = "$name|$($i + 1)"
                        if (-not $seen.ContainsKey($key)) { $seen[$key] = @{ Prod = @(); Bench = @() } }
                        if ($isBench) { $seen[$key].Bench += $a } else { $seen[$key].Prod += $a }
                    }
                }
            }
        }
    }
    foreach ($key in $seen.Keys) {
        $prod = @($seen[$key].Prod); $bench = @($seen[$key].Bench)
        if (($prod.Count -eq 0) -or ($bench.Count -eq 0)) { continue }
        $pinned = @($prod | Sort-Object -Unique)
        if ($pinned.Count -ne 1) { continue }
        if ($pinned[0] -notmatch "^(-?\d+|TRUE|FALSE|''|'[^']*')$") { continue }
        $others = @($bench | Where-Object { $_ -ne $pinned[0] })
        if ($others.Count -eq 0) { continue }
        # Имя $k, а не $parts: под $parts лежит список объектов пакета, и перезапись его
        # тихо выкидывала из проверки второй чистый кодюнит целиком.
        $k = $key -split '\|'
        $pinProblems += ("$($k[0]), довод $($k[1]): в бою всегда [$($pinned[0])], " +
                         "а мерный объект подставляет [$(($others | Sort-Object -Unique) -join '], [')]")
    }

    # Вторая половина того же признака: функцию зовёт ТОЛЬКО мерный объект. Разделы 54, 61,
    # 62 и 63 - четыре раза подряд вызов пропадал из продукта или не появлялся вовсе, а
    # мерный прогон оставался зелёным весь: он зовёт функцию сам.
    #
    # Своя же ссылка внутри объекта считается за участие: функция, работающая на соседнюю,
    # доходит до боя через неё. Ищем поэтому те, кого не зовёт НИКТО, кроме мерных.
    foreach ($name in $names) {
        $prodCalls = 0; $benchCalls = 0
        foreach ($p in $parts) {
            if (($p.Kind -eq 'Codeunit') -and ($p.No -eq $pureNo)) { continue }
            $vars = @()
            foreach ($m in [regex]::Matches($p.Body, "(?m)^\s*([A-Za-z0-9_]+)@\d+\s*:\s*Codeunit\s+$pureNo\s*;")) { $vars += $m.Groups[1].Value }
            foreach ($v in ($vars | Sort-Object -Unique)) {
                $hits = ([regex]::Matches($p.Body, "$v\.$name\b")).Count
                if ($hits -eq 0) { continue }
                if (($p.Kind -eq 'Codeunit') -and ($benchCodeunits -contains $p.No)) { $benchCalls += $hits } else { $prodCalls += $hits }
            }
        }
        if (($prodCalls -gt 0) -or ($benchCalls -eq 0)) { continue }
        $selfCalls = ([regex]::Matches($pure.Body, "(?<![.A-Za-z0-9_])$name(?![A-Za-z0-9_@])")).Count
        if ($selfCalls -gt 0) { continue }
        $pinProblems += "$name : зовут только мерные объекты ($benchCalls раз), живая дорога - ни разу"
    }
}
if ($pinProblems) {
    Fail ("мерка меряет то, чего продукт не делает:`n  " + (($pinProblems | Sort-Object) -join "`n  "))
}

# Тот же вопрос с другого конца, и он проще: а ЗОВЁТ ли эту функцию хоть кто-нибудь на
# живой дороге? Разделы 54 и 61-65 ловили мерку, которая меряет не то; здесь ловится
# продукт, до которого не дойти. Найдено этим 12.09.2026 сразу двое: срез тревог по сроку,
# которого не звал ни один проход, и показ блокировок платформы, написанный ровно для того
# мига, когда имя не назвалось, - и не выведенный ни на одну страницу.
#
# Считается достижимостью от корней, а корня три:
#   - тело объекта вне функций: триггеры страницы, полей и OnRun зовёт платформа;
#   - функция с атрибутом [EventSubscriber]: её зовёт платформа же, по событию;
#   - имя, названное в INSTALL.md кодом - в обратных кавычках или после -MethodName:
#     такую функцию зовёт человек командой, и других внешних входов у инструмента нет.
# Мерные объекты корнями не считаются вовсе: в том и беда, что мерка держит функцию живой
# на вид. Зато считается своя же ссылка внутри объекта - функция, работающая на соседнюю,
# доходит до боя через неё.
$mould = Join-Path $root 'scripts\New-ContextAdapter.ps1'
if (-not (Test-Path $mould)) { Fail 'сборщика переходника нет на месте - правило о нём протухло' }
# Переходник в objects/ - ОБРАЗЕЦ: живой его вид собирает подстановкой этот скрипт, и
# обкатку он подменяет целиком. Значит и вызовы его функций надо искать там же.
$mouldText = [IO.File]::ReadAllText($mould)
$installDoc = [IO.File]::ReadAllText((Join-Path $root 'docs\INSTALL.md'))
$docNames = @()
foreach ($m in [regex]::Matches($installDoc, '`([A-Za-z][A-Za-z0-9_]*)`')) { $docNames += $m.Groups[1].Value }
foreach ($m in [regex]::Matches($installDoc, 'MethodName\s+([A-Za-z0-9_]+)')) { $docNames += $m.Groups[1].Value }
$docNames = @($docNames | Sort-Object -Unique)

$objOf = @{}
foreach ($p in $parts) { $objOf["$($p.Kind)|$($p.Name)"] = $p }
$regionsOf = @{}; $varsOf = @{}; $funcsOf = @{}
foreach ($p in $parts) {
    $key = "$($p.Kind)|$($p.No)"
    $ms = [regex]::Matches($p.Body, '(?m)^\s*(?:LOCAL\s+)?PROCEDURE\s+([A-Za-z0-9_]+)@\d+')
    $regions = @()
    $firstAt = if ($ms.Count -gt 0) { $ms[0].Index } else { $p.Body.Length }
    $regions += [pscustomobject]@{ Func = '(тело)'; Text = $p.Body.Substring(0, $firstAt) }
    for ($i = 0; $i -lt $ms.Count; $i++) {
        $to = if ($i + 1 -lt $ms.Count) { $ms[$i + 1].Index } else { $p.Body.Length }
        $regions += [pscustomobject]@{ Func = $ms[$i].Groups[1].Value; Text = $p.Body.Substring($ms[$i].Index, $to - $ms[$i].Index) }
    }
    $regionsOf[$key] = $regions
    $funcsOf[$key] = @($regions | Where-Object { $_.Func -ne '(тело)' } | ForEach-Object { $_.Func })
    $map = @{}
    # Record в объявлении - это Table в заголовке объекта. Без перевода ни одна табличная
    # функция не находит хозяина, и все таблицы выглядят мёртвыми целиком.
    foreach ($m in [regex]::Matches($p.Body, '(?m)([A-Za-z0-9_]+)@\d+\s*:\s*(?:VAR\s+)?(?:TEMPORARY\s+)?(Codeunit|Record|Page|Report|Query|XMLport)\s+(\d+)')) {
        $kind = $m.Groups[2].Value
        if ($kind -eq 'Record') { $kind = 'Table' }
        $map[$m.Groups[1].Value] = "$kind|$([int]$m.Groups[3].Value)"
    }
    $varsOf[$key] = $map
}
# Вызов ищется по ИМЕНИ функции, а не по скобке: в C/AL функция без доводов зовётся без
# скобок вовсе - "RunPass;", а не "RunPass()". Разбор по "имя(" теряет почти все вызовы и
# объявляет мёртвым весь инструмент.
$edges = @{}
foreach ($p in $parts) {
    $key = "$($p.Kind)|$($p.No)"
    foreach ($r in $regionsOf[$key]) {
        $from = "$key|$($r.Func)"
        if (-not $edges.ContainsKey($from)) { $edges[$from] = @{} }
        # Имя действия - не вызов. Кнопка зовётся Name=PurgeShown, и эта строка держала функцию
        # живой даже тогда, когда из OnAction вызов вынут вовсе: первая же поломка это и показала.
        # Свойства, чьё значение - голое имя, а не код, из разбора выкидываются целиком.
        $text = $r.Text -replace '(?m)^[ ]*(?:Name|Image|PromotedCategory|ApplicationArea|ActionContainerType|GroupType|ContainerType|PageType)[ ]*=.*', ''
        if (($p.Kind -eq 'Codeunit') -and ($p.No -eq $AdapterCodeunitId) -and ($r.Func -eq '(тело)')) { $text += $mouldText }
        foreach ($v in $varsOf[$key].Keys) {
            $target = $varsOf[$key][$v]
            if (-not $funcsOf.ContainsKey($target)) { continue }
            foreach ($fn in $funcsOf[$target]) {
                if ([regex]::IsMatch($text, "(?<![A-Za-z0-9_])$v\.$fn(?![A-Za-z0-9_@])")) { $edges[$from]["$target|$fn"] = $true }
            }
        }
        foreach ($fn in $funcsOf[$key]) {
            if ($fn -eq $r.Func) { continue }
            if ([regex]::IsMatch($text, "(?<![.A-Za-z0-9_])$fn(?![A-Za-z0-9_@])")) { $edges[$from]["$key|$fn"] = $true }
        }
        foreach ($m in [regex]::Matches($text, '(CODEUNIT|PAGE|REPORT)::"([^"]+)"')) {
            $kind = switch ($m.Groups[1].Value) { 'CODEUNIT' { 'Codeunit' } 'PAGE' { 'Page' } 'REPORT' { 'Report' } }
            $other = $objOf["$kind|$($m.Groups[2].Value)"]
            if ($other) { $edges[$from]["$($other.Kind)|$($other.No)|(тело)"] = $true }
        }
    }
}
$roots = @()
foreach ($p in $parts) {
    $key = "$($p.Kind)|$($p.No)"
    if (($p.Kind -eq 'Codeunit') -and ($benchCodeunits -contains $p.No)) { continue }
    $roots += "$key|(тело)"
    foreach ($m in [regex]::Matches($p.Body, '(?m)^\s*\[EventSubscriber\([^\r\n]*\)\]\s*\r?\n\s*(?:LOCAL\s+)?PROCEDURE\s+([A-Za-z0-9_]+)@')) {
        $roots += "$key|$($m.Groups[1].Value)"
    }
    foreach ($fn in $funcsOf[$key]) {
        if ($docNames -contains $fn) { $roots += "$key|$fn" }
    }
}
$reached = @{}; $stack = [Collections.Stack]::new()
foreach ($r in $roots) { $stack.Push($r) }
while ($stack.Count -gt 0) {
    $node = $stack.Pop()
    if ($reached.ContainsKey($node)) { continue }
    $reached[$node] = $true
    if ($edges.ContainsKey($node)) { foreach ($t in $edges[$node].Keys) { $stack.Push($t) } }
}
$unreachable = @()
foreach ($p in $parts) {
    $key = "$($p.Kind)|$($p.No)"
    if (($p.Kind -eq 'Codeunit') -and ($benchCodeunits -contains $p.No)) { continue }
    foreach ($fn in $funcsOf[$key]) {
        if (-not $reached.ContainsKey("$key|$fn")) { $unreachable += "$($p.Kind) $($p.No) $($p.Name) :: $fn" }
    }
}
if ($unreachable) {
    Fail ("до боевой функции не доходит живая дорога:`n  " + (($unreachable | Sort-Object) -join "`n  "))
}

# Надпись поля живёт в ДВУХ местах, и человек видит ту, что на странице: свой CaptionML у
# контрола перекрывает надпись поля таблицы. Замер 13.09.2026: у потолка строк в журнале они
# разные - страница говорит «Потолок строк в журнале», таблица «Сколько строк в журнале,
# прежде чем старые уедут в историю». Проверка, читавшая таблицу, заставила переименовать в
# порядке установки ровно то место, которое было верным.
$setupPart = $parts | Where-Object { ($_.Kind -eq 'Table') -and ($_.No -eq $SetupTableId) }
if (-not $setupPart) { Fail "в пакете нет таблицы настройки $SetupTableId - правило о надписях протухло" }
$setupPage = $parts | Where-Object { ($_.Kind -eq 'Page') -and ($_.No -eq $SetupPageId) }
if (-not $setupPage) { Fail "в пакете нет страницы настройки $SetupPageId - правило о надписях протухло" }

$tableCaption = @{}; $isFlowField = @{}
foreach ($m in [regex]::Matches($setupPart.Body,
        '(?s)(?m)^\s*\{\s*\d+\s*;\s*;([^;]+?)\s*;\s*[\w\[\]]+\s*;(.*?)(?=(?:\r?\n\s*\{\s*\d+\s*;)|(?:\r?\n\s*\}))')) {
    $field = $m.Groups[1].Value.Trim()
    $rus = [regex]::Match($m.Groups[2].Value, '(?s)CaptionML=\[ENU=.*?;\s*RUS=(.*?)\]')
    if ($rus.Success) { $tableCaption[$field] = ($rus.Groups[1].Value -replace '\s+', ' ').Trim() }
    $isFlowField[$field] = ($m.Groups[2].Value -match 'FieldClass=FlowField')
}
$pageCaption = @{}; $pageEditable = @{}
foreach ($m in [regex]::Matches($setupPage.Body,
        '(?s)\{\s*\d+\s*;\s*\d*\s*;Field\s*;(.*?)SourceExpr=("[^"]+"|[A-Za-z][A-Za-z0-9_]*)\s*\}')) {
    $src = $m.Groups[2].Value.Trim('"')
    $rus = [regex]::Match($m.Groups[1].Value, '(?s)CaptionML=\[ENU=.*?;\s*RUS=(.*?)\]')
    if ($rus.Success) { $pageCaption[$src] = ($rus.Groups[1].Value -replace '\s+', ' ').Trim() }
    $pageEditable[$src] = ($m.Groups[1].Value -notmatch 'Editable=FALSE')
}
# Видимая надпись: страница перекрывает таблицу. Порядок тут и есть всё правило.
function Shown-Caption([string]$field) {
    if ($pageCaption.ContainsKey($field)) { return $pageCaption[$field] }
    if ($tableCaption.ContainsKey($field)) { return $tableCaption[$field] }
    return ''
}
function Doc-Section([string]$head) {
    $s = [regex]::Match($installDoc, '(?s)' + [regex]::Escape($head) + '(.*?)(?:\r?\n## |\z)').Groups[1].Value
    if (-not $s) { Fail "в docs/INSTALL.md нет раздела $head - правило о нём протухло" }
    return ($s -replace '\s+', ' ')
}

# Первое: заводское значение срабатывает РОВНО ОДИН раз - когда строка настройки заводится.
# Выкладка поверх работающей установки её не заводит: столбец добавляет SQL, а умолчания
# живут в коде, и поле, появившееся позже прежней сборки, ложится в существующую строку
# нулём. Для половины полей ноль означает прежнее поведение, для другой - молча выключенную
# возможность: тревогу, охват, взаимоблокировки. Сказать об этом обязан порядок установки.
$initBlock = [regex]::Match($setupPart.Body, '(?s)INIT;(.*?)INSERT;').Groups[1].Value
if (-not $initBlock) { Fail "в таблице настройки $SetupTableId нет блока заведения строки - проверять нечего" }
$upgradeFlat = Doc-Section '## Обновление поверх прежней выкладки'
$unsaid = @()
foreach ($m in [regex]::Matches($initBlock, '(?m)^\s*("[^"]+"|[A-Za-z][A-Za-z0-9_]*)\s*:=\s*(.+?);')) {
    $field = $m.Groups[1].Value.Trim('"')
    $value = $m.Groups[2].Value.Trim()
    # Ноль, пустая строка и снятая галка - это и есть то, чем поле придёт на обновлении.
    # Говорить о них нечего: заведение строки кладёт туда то же самое.
    if (($value -eq 'FALSE') -or ($value -eq '0') -or ($value -eq "''")) { continue }
    $caption = Shown-Caption $field
    if (-not $caption) { Fail "у поля настройки [$field] нет русской надписи - назвать его в порядке установки нечем" }
    if ($upgradeFlat -notmatch [regex]::Escape($caption)) { $unsaid += "«$caption» (поле $field)" }
}
if ($unsaid) {
    Fail ("на обновлении поле придёт нулём, а раздел «Обновление поверх прежней выкладки» " +
          "в docs/INSTALL.md о нём молчит - назвать его надо надписью со страницы настройки:`n  " +
          (($unsaid | Sort-Object) -join "`n  "))
}

# Второе: то, что человек может ЗАДАТЬ, обязано быть в перечне настроек. Список этот вёлся
# руками так же, как и список обновления, и отстал так же: замер 13.09.2026 - трёх полей в
# нём не было вовсе, а остальные звались английскими именами, которых на русской странице
# нет. Считается по СТРАНИЦЕ, а не по таблице: настройка - это то, что страница даёт править.
$setupFlat = Doc-Section '## Настройка после выкладки'
$undocumented = @()
foreach ($src in $pageEditable.Keys) {
    if (-not $pageEditable[$src]) { continue }
    if (-not $tableCaption.ContainsKey($src)) { continue }
    if ($isFlowField[$src]) { continue }
    $caption = Shown-Caption $src
    if ($setupFlat -notmatch [regex]::Escape($caption)) { $undocumented += "«$caption» (поле $src)" }
}
if ($undocumented) {
    Fail ("поле настройки правится человеком, а раздел «Настройка после выкладки» " +
          "в docs/INSTALL.md о нём молчит - назвать его надо надписью со страницы настройки:`n  " +
          (($undocumented | Sort-Object) -join "`n  "))
}

# Третье: всё чужое, чего инструмент касается, обязано быть названо. Репозиторий служит
# материалом для согласования установки службой безопасности, и вопрос у неё не "правите ли
# вы чужие объекты" - на него легко ответить "нет", - а "во что вы смотрите". Замер
# 13.09.2026: из одиннадцати чужих имён порядок установки называл ОДНО.
#
# Ищется четырьмя дорогами, потому что сослаться на чужое можно четырьмя способами: объявить
# переменной, назвать через DATABASE::/CODEUNIT::/PAGE::, связать полем через TableRelation и
# позвать посредника платформы. Одной дороги мало: подписка переходника ездит второй, а
# цепочка задач - четвёртой.
$foreignHead = '## Чего инструмент касается за своими пределами'
$foreignFlat = Doc-Section $foreignHead
$foreign = @{}
function Want-Foreign([string]$key, [string]$where) {
    if (-not $foreign.ContainsKey($key)) { $foreign[$key] = @() }
    $foreign[$key] += $where
}
foreach ($p in $parts) {
    foreach ($m in [regex]::Matches($p.Body, '(?m)([A-Za-z0-9_]+)@\d+\s*:\s*(?:VAR\s+)?(?:TEMPORARY\s+)?(Record|Codeunit|Page|Report|Query|XMLport)\s+(\d+)')) {
        $no = [int]$m.Groups[3].Value
        if (($no -ge $OurFirstObject) -and ($no -le $OurLastObject)) { continue }
        $kind = if ($m.Groups[2].Value -eq 'Record') { 'Table' } else { $m.Groups[2].Value }
        Want-Foreign "$kind $no" "$($p.Kind) $($p.No)"
    }
    foreach ($m in [regex]::Matches($p.Body, '(DATABASE|CODEUNIT|PAGE|REPORT)::"([^"]+)"')) {
        if ($m.Groups[2].Value -like 'LockWatch*') { continue }
        Want-Foreign $m.Groups[2].Value "$($p.Kind) $($p.No)"
    }
    foreach ($m in [regex]::Matches($p.Body, 'TableRelation="([^"]+)"')) {
        if ($m.Groups[1].Value -like 'LockWatch*') { continue }
        Want-Foreign $m.Groups[1].Value "$($p.Kind) $($p.No)"
    }
    foreach ($api in @('TASKSCHEDULER', 'STARTSESSION')) {
        if ($p.Body -match "(?<![A-Za-z0-9_])$api(?![A-Za-z0-9_])") { Want-Foreign $api "$($p.Kind) $($p.No)" }
    }
}
$hidden = @()
foreach ($key in $foreign.Keys) {
    if ($foreignFlat -notmatch [regex]::Escape($key)) {
        $hidden += "$key (в $(($foreign[$key] | Sort-Object -Unique) -join ', '))"
    }
}
if ($hidden) {
    Fail ("инструмент касается чужого, а раздел «Чего инструмент касается за своими пределами» " +
          "в docs/INSTALL.md о нём молчит - по этому списку согласуют установку:`n  " +
          (($hidden | Sort-Object) -join "`n  "))
}

# «Что встаёт в базу» - первый раздел, который читают перед установкой, и весь он состоит из
# чисел, посчитанных руками: сколько объектов, каких родов, в каких номерах, сколько строк
# выйдет в dbo.[Object] и какие кодюниты мерные. Пересчитывать их было некому: добавленный
# объект молча оставлял список прежним, и служба безопасности согласовывала бы не то, что
# приедет. Считает теперь сборка, и считает по ТОМУ САМОМУ пакету, который и повезёт
# объекты, - не по папке и не по списку рядом. Образец подписчика в счёт не идёт по той же
# причине: в пакет он не едет, и обещать его установке значит обещать не то.
$kindCount = @{}; $kindFrom = @{}; $kindTo = @{}
foreach ($p in $shipParts) {
    if (-not $kindCount.ContainsKey($p.Kind)) {
        $kindCount[$p.Kind] = 0; $kindFrom[$p.Kind] = $p.No; $kindTo[$p.Kind] = $p.No
    }
    $kindCount[$p.Kind]++
    if ($p.No -lt $kindFrom[$p.Kind]) { $kindFrom[$p.Kind] = $p.No }
    if ($p.No -gt $kindTo[$p.Kind]) { $kindTo[$p.Kind] = $p.No }
}
$listProblems = @()
$namedKinds = @()
foreach ($m in [regex]::Matches($installDoc,
        '(?m)^\|\s*(?<kind>[A-Za-z]+)\s*\|\s*(?<from>\d+)\s*[-\u2013]\s*(?<to>\d+)\s*\|\s*(?<count>\d+)\s*\|')) {
    $kind = $m.Groups['kind'].Value
    if (-not $kindCount.ContainsKey($kind)) {
        $listProblems += "в пакете нет ни одного объекта рода $kind, а раздел «Что встаёт в базу» его называет"
        continue
    }
    $namedKinds += $kind
    $said = "$($m.Groups['from'].Value)-$($m.Groups['to'].Value), $($m.Groups['count'].Value) шт"
    $real = "$($kindFrom[$kind])-$($kindTo[$kind]), $($kindCount[$kind]) шт"
    if ($said -ne $real) { $listProblems += "$kind в docs/INSTALL.md обещан как $said, а в пакете $real" }
}
foreach ($kind in $kindCount.Keys) {
    if ($namedKinds -notcontains $kind) {
        $listProblems += "пакет везёт $($kindCount[$kind]) объектов рода $kind, а раздел «Что встаёт в базу» о них молчит"
    }
}

# Всего объектов и диапазон, который инструмент занимает целиком. Границы диапазона - те же
# параметры, по которым сборка судит о своём и чужом, а не число, переписанное в документ.
$whole = [regex]::Match($installDoc, '(?<n>\d+)\s+объект\w*\s+в диапазоне\s+\*\*(?<from>\d+)\s*[-\u2013]\s*(?<to>\d+)\*\*')
if (-not $whole.Success) {
    $listProblems += 'в docs/INSTALL.md нет строки «N объектов в диапазоне A-B» - правило о ней протухло'
} else {
    if ([int]$whole.Groups['n'].Value -ne $shipParts.Count) {
        $listProblems += "объектов обещано $($whole.Groups['n'].Value), а в пакете $($shipParts.Count)"
    }
    if (([int]$whole.Groups['from'].Value -ne $OurFirstObject) -or ([int]$whole.Groups['to'].Value -ne $OurLastObject)) {
        $listProblems += ("диапазон обещан $($whole.Groups['from'].Value)-$($whole.Groups['to'].Value), " +
                          "а сборка считает своими $OurFirstObject-$OurLastObject")
    }
}

# Строк в dbo.[Object] БОЛЬШЕ, чем объектов: у каждой таблицы там ещё одна, на её данные.
# Число это тоже написано в документе, и выводится оно отсюда же, а не запоминается.
$objRows = [regex]::Match($installDoc, 'В таблице `dbo\.\[Object\]` это \*\*(?<n>\d+) строк\w*\*\*, а не (?<objs>\d+)')
if (-not $objRows.Success) {
    $listProblems += 'в docs/INSTALL.md нет строки о числе строк в dbo.[Object] - правило о ней протухло'
} else {
    $wantRows = $shipParts.Count + $(if ($kindCount.ContainsKey('Table')) { $kindCount['Table'] } else { 0 })
    if ([int]$objRows.Groups['n'].Value -ne $wantRows) {
        $listProblems += "строк в dbo.[Object] обещано $($objRows.Groups['n'].Value), а выйдет $wantRows"
    }
    # Число объектов названо в той же строке второй раз, и разойтись эти два могут порознь.
    if ([int]$objRows.Groups['objs'].Value -ne $shipParts.Count) {
        $listProblems += "там же объектов названо $($objRows.Groups['objs'].Value), а в пакете $($shipParts.Count)"
    }
    # И ТРЕТИЙ раз - в разделе о снятии, где перечислено, что уходит. Живёт оно там своей
    # жизнью, и сверка выше его не видела вовсе: 15.09.2026 оно отстало от пакета на объект
    # и оказалось верным только по совпадению - следующая же правка сделала его верным снова.
    foreach ($m in [regex]::Matches($installDoc, '(?<n>\d+) строк\w* в `dbo\.\[Object\]`')) {
        if ([int]$m.Groups['n'].Value -ne $wantRows) {
            $listProblems += "строк в dbo.[Object] где-то названо $($m.Groups['n'].Value), а выйдет $wantRows"
        }
    }
}

# Команда, названная документом, обязана быть ИСПОЛНИМА. Числа этого раздела сверяются с
# пакетом давно, а команды порядка установки не сверялись ничем: переименованный метод,
# перенумерованный объект, исчезнувший ключ скрипта оставляют документ, который ведёт
# установщика в отказ - и узнаёт об этом он, на чужой базе, а не сборка здесь.
#
# Спрашивается ровно исполнимость, а не смысл: у вызова кодюнита - что такой объект в пакете
# есть и несёт ВНЕШНЮЮ функцию с таким именем (внутреннюю платформа звать не даст); у вызова
# скрипта - что файл на месте и что каждый названный ключ у него объявлен.
$cmdProblems = @()
foreach ($m in [regex]::Matches($installDoc, '-CodeunitId\s+(?<no>\d+)\s+-MethodName\s+(?<name>[A-Za-z0-9_]+)')) {
    $cmdNo = [int]$m.Groups['no'].Value
    $cmdName = $m.Groups['name'].Value
    $cmdPart = $shipParts | Where-Object { ($_.Kind -eq 'Codeunit') -and ($_.No -eq $cmdNo) }
    if (-not $cmdPart) {
        $cmdProblems += "документ зовёт Codeunit $cmdNo, а пакет его не везёт"
        continue
    }
    if ($cmdPart.Body -notmatch "(?m)^\s*\[External\]\s*\r?\n\s*PROCEDURE\s+$cmdName@") {
        $cmdProblems += "документ зовёт $cmdName у Codeunit $cmdNo, а внешней функции с таким именем там нет"
    }
}
# Обратная кавычка в конце строки - перенос команды, и хвост за ней читать нельзя: там уже
# другая строка документа, а не ключи этого вызова.
foreach ($m in [regex]::Matches($installDoc, '(?m)pwsh\s+(?<path>scripts/[A-Za-z0-9_\-]+\.ps1)(?<tail>[^\r\n`]*)')) {
    $cmdRel = $m.Groups['path'].Value -replace '/', '\'
    $cmdFull = Join-Path $root $cmdRel
    if (-not (Test-Path $cmdFull)) {
        $cmdProblems += "документ зовёт $($m.Groups['path'].Value), а такого файла нет"
        continue
    }
    $cmdText = [IO.File]::ReadAllText($cmdFull)
    foreach ($k in [regex]::Matches($m.Groups['tail'].Value, '(?<![A-Za-z0-9])-(?<key>[A-Za-z][A-Za-z0-9]*)')) {
        $key = $k.Groups['key'].Value
        if ($cmdText -notmatch "(?m)^\s*(?:\[[^\]]*\]\s*)*\`$$key\s*(?:=|,|\)|$)") {
            $cmdProblems += "документ зовёт $($m.Groups['path'].Value) с ключом -$key, а такого параметра у него нет"
        }
    }
}
if ($cmdProblems) {
    Fail ("порядок установки зовёт то, чего нет - по нему ставят руками:`n  " +
          (($cmdProblems | Sort-Object -Unique) -join "`n  "))
}

# Списков в разделе два, и у обоих есть в сборке настоящий двойник: мерные кодюниты она
# знает поимённо, объекты показа зовутся словом Demo. Сверяются они целиком - разойтись
# список может в обе стороны, и забытым именем, и лишним, - а номер берётся только из
# обратных кавычек: число из пояснения рядом списком не является.
$toldLists = @(
    @{ Head = '**Мерные кодюниты**'; Want = @($benchCodeunits) }
    @{ Head = '**Кодюниты показа и таблица к ним**'
       Want = @($shipParts | Where-Object { $_.Name -match 'Demo' } | ForEach-Object { $_.No }) }
)
foreach ($told in $toldLists) {
    $saidBody = [regex]::Match($installDoc, '(?s)' + [regex]::Escape($told.Head) + '(.*?)\r?\n\r?\n').Groups[1].Value
    if (-not $saidBody) {
        $listProblems += "в docs/INSTALL.md нет абзаца $($told.Head) - правило о нём протухло"
        continue
    }
    $said = @([regex]::Matches($saidBody, '`(?:Table\s+)?(?<no>\d+)`') |
              ForEach-Object { [int]$_.Groups['no'].Value } | Sort-Object -Unique)
    $want = @($told.Want | Sort-Object -Unique)
    if (($said -join ',') -ne ($want -join ',')) {
        $listProblems += "$($told.Head): в документе $($said -join ', '), а на деле $($want -join ', ')"
    }
}
if ($listProblems) {
    Fail ("раздел «Что встаёт в базу» разошёлся с пакетом - по нему согласуют установку:`n  " +
          (($listProblems | Sort-Object) -join "`n  "))
}
# Число в этом проекте обязано иметь того, кто его меряет. У чисел, которыми документы
# описывают САМИ СЕБЯ - сколько проверок делает прогон, сколько прогонов в смете, - такой
# был всегда: ведомость сметы и сами обкатки. Но списывали их оттуда РУКАМИ, и 13.09.2026
# из шести списанных отстали четыре: мерный прогон журнала (19 вместо 22), проход (26
# вместо 32), сторож (13 вместо 17) и дорога к имени (11 вместо 15). Отстали молча, в том
# самом документе, по которому установку согласуют, и ни один прогон этого не видел.
#
# Проверяются документы ВСЕ, кроме названных здесь: список проверяемого пополнять забыли бы
# (разделы 76-78), а список исключений заметен тем, что растёт. Записи о прошлом - замеры,
# список дел и дневник - отставать обязаны: число в них принадлежит своему дню.
$recordDocs = @('docs/FINDINGS.md', 'docs/NEXT.md', 'docs/JOURNAL.md')

# Пишутся такие числа ЦИФРАМИ. Слово сверить нечем: падежей у него шесть, и разбирать их
# сборке значило бы завести вторую точность рядом с первой. Поэтому число, записанное
# словом, не разбирается, а отвергается.
$numeralWord = '^(один|одна|одну|одного|одной|два|две|двух|двум|двумя|три|тр[ёе]х|тр[ёе]м|' +
               'тремя|четыре|четыр[ёе]х|четырьмя|пять|пяти|пятью|шесть|шести|шестью|семь|' +
               'семи|семью|восемь|восьми|восемью|девять|девяти|девятью|десять|десяти|' +
               'десятью|сорок|сорока|пятьдесят|пятидесяти|девяносто|девяноста|' +
               '(одиннад|двенад|тринад|четырнад|пятнад|шестнад|семнад|восемнад|девятнад|' +
               'двад|трид)цат[ьию])$'

# Ведомость сметы - единственное место, где записано, сколько проверок делает прогон.
# Между строкой прогона и его числом лежат иногда заметки, и они здесь пропускаются: без
# этого разбор потерял бы прогон молча, а молчание тут неотличимо от порядка.
$ledgerText = [IO.File]::ReadAllText((Join-Path $root 'scripts\Test-All.ps1'))
$runChecks = @{}
$runCount = 0
$runTotal = 0
foreach ($m in [regex]::Matches($ledgerText,
        "Name\s*=\s*'(?<n>[^']+)';\s*Script\s*=\s*'(?<s>[^']+)';\s*Extra\s*=\s*@\([^)]*\)(?:\s*#[^\r\n]*)*\s*Checks\s*=\s*(?<c>\d+)")) {
    $script = $m.Groups['s'].Value
    $checks = [int]$m.Groups['c'].Value
    $runCount++
    $runTotal += $checks
    # Один скрипт стоит в ведомости дважды - выкладка и повторная выкладка. Числа у них
    # обязаны совпадать; разойдись они, документу нечего было бы называть.
    if (-not $runChecks.ContainsKey($script)) { $runChecks[$script] = $checks }
    elseif ($runChecks[$script] -ne $checks) { $runChecks[$script] = -1 }
}
# Разбор обязан найти ВСЕ строки ведомости, а не сколько получится: потерянный прогон увёл
# бы итог вниз, и документ с верным числом покраснел бы вместо разбора. Сколько их
# объявлено, считается отдельно и проще - по имени прогона.
$declared = ([regex]::Matches($ledgerText, "Name\s*=\s*'")).Count
if ($runCount -ne $declared) {
    Fail "ведомость сметы разобралась не вся: прогонов объявлено $declared, разобрано $runCount"
}

function Doc-Line([string]$text, [int]$at) {
    return ([regex]::Matches($text.Substring(0, $at), "`n")).Count + 1
}

# Число и слово при нём стоят рядом: пустая строка между ними означала бы, что речь уже
# о другом.
$nearby = '(?:[ \t]+|[ \t]*\r?\n[ \t]*)'
# Связь числа с тем, кто его меряет, рвут пустая строка и начало нового пункта списка.
# Без пункта списка число из соседней строки перечня прицепилось бы к прогону из ПРОШЛОГО
# пункта - и красный цвет назвал бы не ту причину, что хуже отсутствия проверки.
$apart = '\r?\n[ \t]*\r?\n|\r?\n[ \t]*[-*] |\r?\n[ \t]*\d+\. '
$countClaims = @()
$docProblems = @()
foreach ($rel in (& git -C $root ls-files '*.md')) {
    if ($recordDocs -contains $rel) { continue }
    $full = Join-Path $root $rel
    if (-not (Test-Path $full)) { continue }
    $text = [IO.File]::ReadAllText($full)
    # Чужой кодюнит источником не бывает: за себя печатают только свои обкатки, а штатный
    # NAV в примерах называется нарочно - `Codeunit 80 Sales-Post`. Границы свои берутся
    # оттуда же, откуда их берёт вся сборка, а не переписываются числом рядом.
    $sources = @([regex]::Matches($text, '(?<s>Test-[\w-]+\.ps1)|Codeunit\s+(?<cu>\d+)') |
                 Where-Object { (-not $_.Groups['cu'].Success) -or
                                ((([int]$_.Groups['cu'].Value) -ge $OurFirstObject) -and
                                 (([int]$_.Groups['cu'].Value) -le $OurLastObject)) })
    foreach ($claim in [regex]::Matches($text, "(?<num>\d+)$nearby(?<what>провер\w*|прогон\w*)")) {
        $num = [int]$claim.Groups['num'].Value
        $what = $claim.Groups['what'].Value
        $line = Doc-Line $text $claim.Index
        $src = $null
        foreach ($s in $sources) {
            if (($s.Index + $s.Length) -gt $claim.Index) { break }
            $src = $s
        }
        if ($src) {
            $from = $src.Index + $src.Length
            if ($text.Substring($from, $claim.Index - $from) -match $apart) { $src = $null }
        }
        if (-not $src) {
            $docProblems += "$rel : строка $line - число $num $what, а кто его меряет, не назван"
            continue
        }
        if ($src.Groups['cu'].Success) {
            # Сколько проверок делает обкатка, знает только сама обкатка. Сверка отложена
            # до её отчёта - ниже, после прогона.
            $countClaims += @{ Rel = $rel; Line = $line; Num = $num
                               Codeunit = [int]$src.Groups['cu'].Value }
            continue
        }
        $script = $src.Groups['s'].Value
        if ($script -eq 'Test-All.ps1') {
            $want = if ($what.StartsWith('прогон')) { $runCount } else { $runTotal }
        } elseif (-not $runChecks.ContainsKey($script)) {
            $docProblems += "$rel : строка $line - прогона $script в ведомости сметы нет вовсе"
            continue
        } elseif ($runChecks[$script] -lt 0) {
            $docProblems += "$rel : строка $line - $script стоит в ведомости дважды с разными числами"
            continue
        } elseif ($what.StartsWith('прогон')) {
            $docProblems += "$rel : строка $line - счёт прогонов приписан одному прогону $script"
            continue
        } else {
            $want = $runChecks[$script]
        }
        if ($num -ne $want) {
            $docProblems += "$rel : строка $line - сказано $num, а $script делает $want"
        }
    }
    foreach ($worded in [regex]::Matches($text, "(?<w>[А-Яа-яЁё]+)$nearby(?:провер\w*|прогон\w*)")) {
        if ($worded.Groups['w'].Value.ToLower() -match $numeralWord) {
            $docProblems += ("$rel : строка $(Doc-Line $text $worded.Index) - число записано словом " +
                             "«$($worded.Groups['w'].Value)»: сверить его нечем, писать цифрами")
        }
    }
}
if ($docProblems) {
    Fail ("документ обещает не то число, что делает прогон:`n  " +
          (($docProblems | Sort-Object -Unique) -join "`n  "))
}
# Документы указывают человеку на кнопки, поля и страницы ПО ИМЕНИ: «действие „Проверить
# дорогу от платформы“», «галка „Кнопка показа доступна“». Имя на экране - такая же
# величина, как число, и сверял его тот же, кто и числа: никто. 14.09.2026 нашлось
# расхождение - страница зовётся «История эпизодов блокировок», а порядок установки
# посылал на страницу «История эпизодов»: человек искал бы то, чего на экране нет.
#
# Указанием считается имя с БОЛЬШОЙ буквы после указывающего слова - так надписи пишут и
# сами объекты. Со строчной буквы в кавычках стоит описание («отметка „сеанс работает с
# документом“»), и требовать от него надписи нельзя. Правило это не придумано, а выбрано
# по замеру: из двадцати имён с большой буквы восемнадцать нашлись точь-в-точь, а два
# разошедшихся оказались одной и той же бедой.
#
# Надписи берутся из ПАКЕТА, а регистр не сличается: документ вправе начать фразу с той же
# кнопки, не меняя ей имени.
$shownNames = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($m in [regex]::Matches($monolith, '(?s)CaptionML=\[ENU=.*?;\s*RUS=(.*?)\]')) {
    [void]$shownNames.Add((($m.Groups[1].Value -replace '\s+', ' ').Trim()))
}
foreach ($m in [regex]::Matches($monolith, '(?s)OptionCaptionML=\[ENU=.*?;\s*RUS=(.*?)\]')) {
    foreach ($part in (($m.Groups[1].Value -replace '\s+', ' ') -split ',')) {
        if ($part.Trim()) { [void]$shownNames.Add($part.Trim()) }
    }
}
$pointer = 'кнопк\w*|действи\w*|галк\w*|страниц\w*|колонк\w*|пол[еяю]\w*|отметк\w*|вкладк\w*'
$nameProblems = @()
$nameChecked = 0
foreach ($rel in (& git -C $root ls-files '*.md')) {
    if ($recordDocs -contains $rel) { continue }
    $full = Join-Path $root $rel
    if (-not (Test-Path $full)) { continue }
    $text = [IO.File]::ReadAllText($full)
    foreach ($m in [regex]::Matches($text, "(?<word>$pointer)\s+«(?<name>[^»]{2,70})»")) {
        $name = ($m.Groups['name'].Value -replace '\s+', ' ').Trim()
        if ($name -cnotmatch '^[А-ЯЁA-Z]') { continue }
        $nameChecked++
        if (-not $shownNames.Contains($name)) {
            $nameProblems += ("$rel : строка $(Doc-Line $text $m.Index) - $($m.Groups['word'].Value) " +
                              "«$name», а надписи с таким именем в объектах нет")
        }
    }
}
if ($nameProblems) {
    Fail ("документ указывает на то, чего человек на экране не найдёт:`n  " +
          (($nameProblems | Sort-Object) -join "`n  "))
}
# Пакет собирается из ТОГО, ЧТО ЕДЕТ. Тела берутся уже разобранные: каждое кончается
# переводом строки, и склейка возвращает те же байты за вычетом отсеянного.
$shipMonolith = ($shipParts | ForEach-Object { $_.Body }) -join ''
$packUtf = Join-Path $outDir 'LockWatch.txt'
$pack    = Join-Path $outDir 'LockWatch.cp866.txt'
[IO.File]::WriteAllText($packUtf, $shipMonolith, (New-Object System.Text.UTF8Encoding($false)))
[IO.File]::WriteAllBytes($pack, $cp866.GetBytes($shipMonolith))
Write-Host ("  объектов {0}, пакет {1:N0} байт" -f $shipParts.Count, (Get-Item $pack).Length)
foreach ($s in $sampleParts) {
    Write-Host "  образец в пакет не едет: $($s.Kind) $($s.No) $($s.Name)" -ForegroundColor DarkYellow
}

# Состояние ДО: чужой отказ не должен засчитываться нашей выкладке.
$uncompiledBefore = [int]((Invoke-Sql 'SELECT COUNT(*) FROM [dbo].[Object] WHERE [Compiled] = 0;')[0])
Write-Host "  несобранных в базе до выкладки: $uncompiledBefore"

Write-Host 'Импорт и компиляция'
$stamp = Get-Date -Format 'HHmmss'
Invoke-Finsql "Command=ImportObjects,File=`"$pack`",ImportAction=overwrite,SynchronizeSchemaChanges=Force$navServerArgs" "import-$stamp.log"

# MenuSuite - это тип 7, а не 4: четвёркой в NAV нумеровался дataport, которого в 2018
# нет вовсе. Ошибка здесь не роняет выкладку, а МОЛЧА проверяет не тот объект.
$typeNo = @{ 't' = 1; 'c' = 5; 'r' = 3; 'p' = 8; 'x' = 6; 'q' = 9; 'm' = 7 }
$typeNm = @{ 't' = 'Table'; 'c' = 'Codeunit'; 'r' = 'Report'; 'p' = 'Page'; 'x' = 'XMLport'; 'q' = 'Query'; 'm' = 'MenuSuite' }
$declared = foreach ($file in $shipFiles) {
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
Invoke-NAVCodeunit -ServerInstance $Instance -CompanyName '$Company' -CodeunitId $PermissionsCodeunitId -MethodName SelfTest -ErrorAction Stop
"@
# Обкатки образца здесь больше нет, и не потому, что она лишняя: образец в пакет не едет,
# значит на стенде после выкладки его нет вовсе. Выкладывает его теперь один прогон -
# Test-Adapter.ps1, - он же его и спрашивает.
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
# Отложенные числа документов сверяются здесь: сколько проверок делает обкатка, знает
# только её отчёт. Порядок итогов в отчёте - это порядок вызовов в $body, и берётся он из
# самого $body, а не переписывается рядом: переписанный разошёлся бы с ним молча.
if ($countClaims) {
    $suiteIds = @([regex]::Matches($body, '-CodeunitId\s+(\d+)') | ForEach-Object { [int]$_.Groups[1].Value })
    $said = @([regex]::Matches($report, 'passed\s+(\d+)\s+of\s+(\d+)'))
    if ($said.Count -ne $suiteIds.Count) {
        Fail "обкаток запущено $($suiteIds.Count), а итогов в отчёте $($said.Count) - числа документов сверять не с чем"
    }
    $measured = @{}
    for ($i = 0; $i -lt $suiteIds.Count; $i++) { $measured[$suiteIds[$i]] = [int]$said[$i].Groups[2].Value }
    $claimProblems = @()
    foreach ($claim in $countClaims) {
        if (-not $measured.ContainsKey($claim.Codeunit)) {
            $claimProblems += "$($claim.Rel) : строка $($claim.Line) - Codeunit $($claim.Codeunit) обкатки не печатает"
        } elseif ($claim.Num -ne $measured[$claim.Codeunit]) {
            $claimProblems += ("$($claim.Rel) : строка $($claim.Line) - сказано $($claim.Num), " +
                               "а Codeunit $($claim.Codeunit) сделал $($measured[$claim.Codeunit])")
        }
    }
    if ($claimProblems) {
        Fail ("документ обещает не то число, что сделала обкатка:`n  " + ($claimProblems -join "`n  "))
    }
}
Write-Host 'Готово: собрано и обкатано' -ForegroundColor Green
