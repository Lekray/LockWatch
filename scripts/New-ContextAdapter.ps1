#requires -Version 7
<#
.SYNOPSIS
    Собирает переходник-подписчик под таблицу контекста установки по образцу Codeunit 110237.

.DESCRIPTION
    Номер таблицы у подписки `[EventSubscriber(Table,N,...)]` - КОНСТАНТА времени
    компиляции: настройкой он не задаётся, и одним объектом на все таблицы обойтись нельзя.
    Значит, на каждую таблицу контекста нужен свой объект, и собирать его приходится
    подстановкой.

    Руками это делать нельзя, и вот почему. Мест для правки пять - три подписки, тип
    записи в четырёх сигнатурах, номер таблицы в DATABASE::, имя поля в Rec. - и
    промахнуться в них можно МОЛЧА: подписка на чужой номер таблицы компилируется без
    единого замечания и просто никогда не срабатывает. Колонка документа остаётся пустой,
    а пустая колонка читается как "спорили не за документы".

    Собранный объект кладётся в out/ и в git не попадает: номер таблицы заказчика - ровно
    то, чего в публичном репозитории быть не должно.

    Имена таблицы и поля берутся из строки таблицы контекста - их туда кладёт сам NAV
    кнопкой «Перечитать имена», - либо задаются параметрами. Выдумывать их скрипт не
    вправе: имя, разошедшееся с тем, что знает NAV, даёт объект, который не компилируется,
    и это ещё лучший исход.

.EXAMPLE
    pwsh scripts/New-ContextAdapter.ps1 -TableNo 37 -ObjectNo 110240

.EXAMPLE
    pwsh scripts/New-ContextAdapter.ps1 -TableNo 37 -ObjectNo 110240 -TableName 'Sales Line' -FieldName 'Document No.'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [int] $TableNo,
    [Parameter(Mandatory)] [int] $ObjectNo,
    [string] $TableName,
    [string] $FieldName,
    [string] $Server   = 'localhost',
    [string] $Database = $env:LW_DATABASE,
    [string] $Company  = $env:LW_COMPANY,
    [string] $OutDir
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if (-not $OutDir) { $OutDir = Join-Path $root 'out' }
$sample = Join-Path $root 'objects\c110237_LockWatch_Context_Adapter.txt'

function Fail([string]$message) { Write-Host "ОТКАЗ: $message" -ForegroundColor Red; exit 1 }

if (-not (Test-Path $sample)) { Fail "нет образца: $sample" }
if ($ObjectNo -eq 110237) { Fail 'номер 110237 занят образцом - у собранного объекта должен быть свой' }
if ($ObjectNo -le 0) { Fail 'номер объекта должен быть положительным' }

# Имена спрашиваем у строки таблицы контекста - там их заполнил сам NAV. Своей выдумке
# здесь не место: имя, разошедшееся с тем, что знает платформа, даст объект, который не
# соберётся, и это ещё лучший исход.
if ((-not $TableName) -or (-not $FieldName)) {
    if (-not $Database) { Fail 'не задано имя базы: переменная LW_DATABASE или параметр -Database' }
    if (-not $Company)  { Fail 'не задана компания: переменная LW_COMPANY или параметр -Company' }
    $context = "[$Company`$LockWatch Context Table]"
    $row = & sqlcmd -S $Server -d $Database -E -b -l 30 -h -1 -W -Q `
        "SET NOCOUNT ON; SELECT [Table Name] + '|' + [Document Field Name] FROM $context WHERE [Table No_] = $TableNo;" 2>&1
    if ($LASTEXITCODE -ne 0) { Fail "не удалось прочитать строку таблицы контекста:`n$row" }
    $line = ($row | Where-Object { $_ -match '\|' } | Select-Object -First 1)
    if (-not $line) {
        Fail @"
строки таблицы контекста для таблицы $TableNo нет, а имена взять больше неоткуда.
Заведите её на странице «Таблицы контекста», нажмите «Перечитать имена» - или задайте
имена параметрами -TableName и -FieldName.
"@
    }
    $parts = ($line -split '\|') | ForEach-Object { $_.Trim() }
    if (-not $TableName) { $TableName = $parts[0] }
    if (-not $FieldName) { $FieldName = $parts[1] }
}

if (-not $TableName) { Fail 'имя таблицы пусто: подставлять DATABASE::"" нельзя' }
if (-not $FieldName) { Fail 'имя поля документа пусто: подставлять Rec."" нельзя' }
if ($TableName -match '"') { Fail "в имени таблицы есть кавычка: [$TableName]" }
if ($FieldName -match '"') { Fail "в имени поля есть кавычка: [$FieldName]" }

# Имя объекта - не длиннее тридцати знаков, иначе C/SIDE откажет при импорте.
$objectName = "LockWatch Adapter $TableNo"
if ($objectName.Length -gt 30) { Fail "имя объекта длиннее тридцати знаков: [$objectName]" }

$text = [IO.File]::ReadAllText($sample, [Text.UTF8Encoding]::new($false))

function Swap([string]$body, [string]$from, [string]$to, [int]$expected) {
    # Каждая замена сверяется по числу совпадений. Образец правят, и правка, тихо
    # разошедшаяся с этим скриптом, дала бы объект, который компилируется и не работает, -
    # ровно та беда, ради которой скрипт и написан.
    $count = ([regex]::Matches($body, [regex]::Escape($from))).Count
    if ($count -ne $expected) {
        Fail "образец разошёлся со сборщиком: [$from] встречается $count раз при ожидаемых $expected"
    }
    return $body.Replace($from, $to)
}

# --- шапка объекта -----------------------------------------------------------------
$text = Swap $text 'OBJECT Codeunit 110237 LockWatch Context Adapter' "OBJECT Codeunit $ObjectNo $objectName" 1
$text = Swap $text 'CODEUNIT::"LockWatch Context Adapter"' "CODEUNIT::`"$objectName`"" 2

# --- подписки и тип записи ---------------------------------------------------------
$text = Swap $text '[EventSubscriber(Table,37,' "[EventSubscriber(Table,$TableNo," 3
$text = Swap $text 'Record 37' "Record $TableNo" 7

# --- номер таблицы и поле документа ------------------------------------------------
$text = Swap $text 'EXIT(DATABASE::"Sales Line");' "EXIT(DATABASE::`"$TableName`");" 1
$text = Swap $text 'EXIT(Rec."Document No.");' "EXIT(Rec.`"$FieldName`");" 1

# --- блок переменных ---------------------------------------------------------------
$varsFrom = @'
      NoMarkErr@1000000001 : TextConst 'ENU=The adapter did not put a mark down. Without it the document column stays empty, and an empty column reads as no locks by document.;RUS=Переходник отметку не поставил. Без неё колонка документа остаётся пустой, а пустая колонка читается как "блокировок по документам не было".';
      WrongDocErr@1000000002 : TextConst 'ENU=The mark holds the document %1 while %2 was written.;RUS=В отметке документ %1, а записан был %2.';
'@
$varsTo = @'
      NoContextRowErr@1000000005 : TextConst 'ENU=There is no context table row for table %1. Without it the adapter exits at the first line and marks nothing.;RUS=Строки таблицы контекста для таблицы %1 нет. Без неё переходник выходит на первой же строке и не отмечает ничего.';
      DisabledErr@1000000006 : TextConst 'ENU=The context table row for table %1 is switched off. The adapter is deployed and silent, which is exactly what the switch is for - but then the document column will stay empty.;RUS=Строка таблицы контекста для таблицы %1 выключена. Переходник выложен и молчит - для того выключатель и заведён, - но колонка документа при этом останется пустой.';
'@
$text = Swap $text $varsFrom $varsTo 1

$okFrom = "      OkMsg@1000000003 : TextConst 'ENU=passed 2 of 2 - the platform knows the subscription, and the adapter marks the session with the document %1;RUS=пройдено 2 из 2 - платформа знает подписку, и переходник отмечает сеанс документом %1';"
$okTo = "      OkMsg@1000000003 : TextConst 'ENU=passed 3 of 3 - the platform knows the subscription on table %1, the context row is on, and the subscription has fired %2 times since the service started;RUS=пройдено 3 из 3 - платформа знает подписку на таблицу %1, строка контекста включена, вызовов подписки с момента старта службы %2';"
$text = Swap $text $okFrom $okTo 1

# --- обкатка: записью в чужую таблицу её вести нельзя -------------------------------
$selfStart = $text.IndexOf("    [External]`r`n    PROCEDURE SelfTest@7();")
$selfEnd = $text.IndexOf("    BEGIN`r`n    {")
if (($selfStart -lt 0) -or ($selfEnd -lt 0) -or ($selfEnd -le $selfStart)) {
    Fail 'в образце не нашлась обкатка или заключительный комментарий - образец разошёлся со сборщиком'
}
$selfTest = @'
    [External]
    PROCEDURE SelfTest@7();
    VAR
      ContextTable@1000000000 : Record 110232;
      Calls@1000000001 : Integer;
    BEGIN
      // Вести обкатку записью в чужую таблицу нельзя: первичный ключ у неё свой, а
      // подложенная строка - это документ из ниоткуда в учёте заказчика. Поэтому все три
      // проверки спрашивают ПЛАТФОРМУ, а не данные.
      //
      // Третья из них - счётчик вызовов. Ноль на живой таблице значит не "тихо", а "не
      // туда": объект собран под другой номер. Узнать это иначе нельзя - номера таблицы
      // платформа в списке подписок не держит вовсе.
      IF NOT SubscriptionActive THEN
        ERROR(NotSubscribedErr,TableNo);
      IF NOT ContextTable.GET(TableNo) THEN
        ERROR(NoContextRowErr,TableNo);
      IF NOT ContextTable.Enabled THEN
        ERROR(DisabledErr,TableNo);
      Calls := SubscriptionCalls;
      MESSAGE(OkMsg,TableNo,Calls);
    END;

'@
$text = $text.Substring(0, $selfStart) + $selfTest + $text.Substring($selfEnd)

# --- заключительный комментарий ----------------------------------------------------
$noteFrom = @'
      Переходник-подписчик: ОБРАЗЕЦ, а не готовый объект установки.
'@
$noteTo = @"
      Переходник-подписчик под таблицу $TableNo. Объект СОБРАН подстановкой из образца
      (Codeunit 110237) скриптом scripts/New-ContextAdapter.ps1 - правкой рук в нём нет.
      Пересобирать его надо тем же скриптом: мест для правки пять, и промахнуться в них
      можно молча.
"@
$text = Swap $text $noteFrom $noteTo 1

# Кусок образца про "копируют и меняют" в собранном объекте лишний: он уже собран.
$copyFrom = @'
      Подписка стоит на штатной Table 37 "Sales Line" нарочно - репозиторий считаем
      публичным, и номеров доработанных объектов заказчика в коде быть не может. На
      установке объект под целевую таблицу СОБИРАЕТСЯ ПОДСТАНОВКОЙ, а не правкой руками:
      `pwsh scripts/New-ContextAdapter.ps1 -TableNo N -ObjectNo M`. Мест для правки пять, и
      промахнуться в них можно молча - подписка на чужой номер таблицы компилируется и
      просто никогда не срабатывает. Копий столько, сколько таблиц контекста: номер таблицы
      в подписке - константа времени компиляции, и одним объектом на все таблицы обойтись
      нельзя (FINDINGS, раздел 10).
'@
$copyTo = @"
      Таблица - $TableNo [$TableName], поле документа - [$FieldName]. Копий столько,
      сколько таблиц контекста: номер таблицы в подписке - константа времени компиляции,
      и одним объектом на все таблицы обойтись нельзя (FINDINGS, раздел 10).
"@
$text = Swap $text $copyFrom $copyTo 1

if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir | Out-Null }
$outFile = Join-Path $OutDir "c${ObjectNo}_LockWatch_Adapter_$TableNo.txt"
# Объект C/SIDE: UTF-8 БЕЗ BOM и CRLF. Иначе импорт ломается на кириллице молча.
$text = $text -replace "`r`n", "`n" -replace "`n", "`r`n"
[IO.File]::WriteAllText($outFile, $text, [Text.UTF8Encoding]::new($false))

Write-Host "Собрано: $outFile" -ForegroundColor Green
Write-Host "  объект   Codeunit $ObjectNo [$objectName]"
Write-Host "  таблица  $TableNo [$TableName]"
Write-Host "  поле     [$FieldName]"
Write-Host ''
Write-Host 'Дальше - три шага, и ни один из них скрипт за вас не делает:'
Write-Host '  1. импортировать объект и СКОМПИЛИРОВАТЬ его;'
Write-Host '  2. завести строку на странице «Таблицы контекста» и включить её;'
Write-Host "  3. запустить обкатку самого объекта (SelfTest) - она скажет, знает ли"
Write-Host '     платформа подписку и сколько раз та сработала.'
