#requires -Version 7
<#
.SYNOPSIS
    Врезает пункты LockWatch в существующий MenuSuite установки, не трогая чужие узлы.

.DESCRIPTION
    Своего уровня MenuSuite инструменту не досталось. Лицензия стенда отказала во ВСЕХ
    партнёрских уровнях - 1020, 1040, 1050, 1060, 1070 и 1080, - отвечая одинаково:
    "You do not have permission to create the ... MenuSuite". Остаётся уровень Company
    (1090), а он на установке уже есть и принадлежит заказчику.

    Поэтому объект не выкладывается, а СЛИВАЕТСЯ. Скрипт выгружает существующий MenuSuite
    из базы, дописывает в него узлы из templates/menu-nodes.txt и кладёт результат в out/.
    Выгруженный оригинал сохраняется рядом - это единственный способ вернуть всё как было,
    если слияние не понравится.

    Правится при этом РОВНО ОДИН чужой узел: последнее меню в цепочке верхнего уровня
    получает ссылку на наше меню. Всё остальное дописывается новыми записями. Меньше одного
    чужого узла не выходит: цепочка меню односвязная, и попасть в неё можно только через
    предыдущее звено.

    Слияние идемпотентно: если наши узлы в объекте уже есть, они сначала убираются вместе
    со ссылкой на них, а потом дописываются заново. GUID узлов постоянны нарочно - смена
    их дала бы второй комплект пунктов рядом с первым.

    Импорт слитого объекта скрипт сам НЕ делает: это правка чужого объекта, и решение о
    ней - отдельное. Для импорта есть ключ -Import.

.EXAMPLE
    pwsh scripts/Merge-MenuSuite.ps1

.EXAMPLE
    pwsh scripts/Merge-MenuSuite.ps1 -Import
#>
[CmdletBinding()]
param(
    [string] $Server   = 'localhost',
    [string] $Database = $env:LW_DATABASE,
    [int]    $TargetId = 1090,
    [switch] $Import,
    [switch] $Remove,
    [int]    $TimeoutMinutes = 3
)

$ErrorActionPreference = 'Stop'
$root   = Split-Path -Parent $PSScriptRoot
$outDir = Join-Path $root 'out'
$finsql = 'C:\Program Files (x86)\Microsoft Dynamics NAV\110\RoleTailored Client\finsql.exe'
$nodesFile = Join-Path $root 'templates\menu-nodes.txt'
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir | Out-Null }

function Fail([string]$message) { Write-Host "ОТКАЗ: $message" -ForegroundColor Red; exit 1 }
if (-not $Database) { Fail 'не задано имя базы: переменная LW_DATABASE или параметр -Database' }
if (-not (Test-Path $nodesFile)) { Fail "нет заготовки узлов: $nodesFile" }

$cp866 = [System.Text.Encoding]::GetEncoding(866)
$zeroGuid = '00000000-0000-0000-0000-000000000000'

function Invoke-Finsql([string]$argLine, [string]$logName) {
    $log = Join-Path $outDir $logName
    if (Test-Path $log) { Remove-Item $log -Force }
    $navArgs = "ServerName=$Server,Database=$Database,NTAuthentication=1,LogFile=`"$log`""
    $process = Start-Process -FilePath $finsql -PassThru -NoNewWindow -ArgumentList "$argLine,$navArgs"
    if (-not $process.WaitForExit($TimeoutMinutes * 60000)) {
        $process.Kill()
        Fail "finsql завис дольше $TimeoutMinutes мин и снят"
    }
    if (Test-Path $log) {
        $text = ($cp866.GetString([IO.File]::ReadAllBytes($log))).Trim()
        if ($text) { Fail "finsql ($logName):`n$text" }
    }
}

# ---------- выгрузка оригинала ----------
$originalFile = Join-Path $outDir "menusuite-$TargetId-original.txt"
if (Test-Path $originalFile) { Remove-Item $originalFile -Force }
Invoke-Finsql "Command=ExportObjects,File=`"$originalFile`",Filter=`"Type=MenuSuite;ID=$TargetId`"" "export-menu-$TargetId.log"
if (-not (Test-Path $originalFile)) { Fail "MenuSuite $TargetId из базы не выгрузился" }
$text = $cp866.GetString([IO.File]::ReadAllBytes($originalFile))
if ($text.Trim().Length -eq 0) { Fail "MenuSuite $TargetId пуст - в базе такого объекта нет" }
Write-Host "Выгружен MenuSuite $TargetId, $((Get-Item $originalFile).Length) байт"

# ---------- разбор ----------
$openMarker = "  MENUNODES`r`n  {`r`n"
$open = $text.IndexOf($openMarker)
if ($open -lt 0) { Fail 'в выгруженном объекте нет раздела MENUNODES - формат не тот, слияние не делаем' }
$bodyStart = $open + $openMarker.Length
$close = $text.LastIndexOf("`r`n  }`r`n}")
if ($close -le $bodyStart) { Fail 'в выгруженном объекте не нашёлся конец раздела MENUNODES' }
$head = $text.Substring(0, $bodyStart)
$body = $text.Substring($bodyStart, $close - $bodyStart)
$tail = $text.Substring($close)

# Запись узла начинается со строки вида "    { Тип  ;[{GUID}] ..." и тянется до следующей
# такой же. Разбор по этому признаку, а не по скобкам: внутри записи скобки есть и в
# GUID, и в CaptionML, и считать их - значит ошибиться на первом же многоязычном тексте.
$records = @()
$starts = @()
foreach ($m in [regex]::Matches($body, '(?m)^    \{ ')) { $starts += $m.Index }
if ($starts.Count -eq 0) { Fail 'в разделе MENUNODES не нашлось ни одной записи' }
for ($i = 0; $i -lt $starts.Count; $i++) {
    $from = $starts[$i]
    $to = if ($i + 1 -lt $starts.Count) { $starts[$i + 1] } else { $body.Length }
    $records += $body.Substring($from, $to - $from)
}
Write-Host "  узлов в объекте: $($records.Count)"

function Node-Id([string]$record) {
    $m = [regex]::Match($record, '^\s*\{\s*\S+\s*;\[\{([0-9A-Fa-f-]{36})\}\]')
    if ($m.Success) { return $m.Groups[1].Value.ToUpper() }
    return ''
}
function Node-Kind([string]$record) {
    $m = [regex]::Match($record, '^\s*\{\s*(\S+)\s*;')
    if ($m.Success) { return $m.Groups[1].Value }
    return ''
}
function Prop([string]$record, [string]$name) {
    $m = [regex]::Match($record, "$name=\[\{([0-9A-Fa-f-]{36})\}\]")
    if ($m.Success) { return $m.Groups[1].Value.ToUpper() }
    return ''
}

# ---------- наши узлы ----------
$ourText = [IO.File]::ReadAllText($nodesFile, [Text.UTF8Encoding]::new($false))
$ourText = (($ourText -split "`r?`n") | Where-Object { $_ -notmatch '^\s*#' }) -join "`r`n"
$ourStarts = @()
foreach ($m in [regex]::Matches($ourText, '(?m)^    \{ ')) { $ourStarts += $m.Index }
if ($ourStarts.Count -eq 0) { Fail 'в заготовке узлов не нашлось ни одной записи' }
$ourRecords = @()
for ($i = 0; $i -lt $ourStarts.Count; $i++) {
    $from = $ourStarts[$i]
    $to = if ($i + 1 -lt $ourStarts.Count) { $ourStarts[$i + 1] } else { $ourText.Length }
    $ourRecords += $ourText.Substring($from, $to - $from).TrimEnd() + "`r`n"
}
$ourIds = @($ourRecords | ForEach-Object { Node-Id $_ })
if ($ourIds -contains '') { Fail 'в заготовке узлов есть запись без GUID' }
$ourMenuId = $ourIds[0]
Write-Host "  наших узлов: $($ourRecords.Count), меню [{$ourMenuId}]"

# ---------- убрать прежнюю врезку, если она есть ----------
$hadOurs = $false
$cleaned = @()
foreach ($record in $records) {
    $id = Node-Id $record
    if ($ourIds -contains $id) { $hadOurs = $true; continue }
    if ($record -match [regex]::Escape("NextNodeID=[{$ourMenuId}]")) {
        $hadOurs = $true
        # Ссылка на нас возвращается в НУЛЕВОЙ GUID, а не убирается: так этот узел и
        # выглядел до врезки, и так же выглядят его соседи-хвосты на других уровнях.
        $record = $record.Replace("NextNodeID=[{$ourMenuId}]", "NextNodeID=[{$zeroGuid}]")
    }
    $cleaned += $record
}
if ($hadOurs) { Write-Host '  прежняя врезка найдена и убрана' }
$records = $cleaned

if ($Remove) {
    if (-not $hadOurs) { Write-Host 'Врезки в объекте не было - убирать нечего' }
} else {
    # ---------- найти ХВОСТ цепочки меню верхнего уровня ----------
    # Узла Root в объекте может не быть вовсе, и это не поломка: MenuSuite уровня Company -
    # НАДСТРОЙКА над нижними уровнями, в ней лежит только изменённое и добавленное, а Root
    # живёт на уровне MBS. Измерено на настоящем объекте: 667 узлов, Root среди них нет.
    # Поэтому хвост ищется не обходом от корня, а по признаку: меню верхнего уровня, за
    # которым никого нет.
    $tailMenus = @()
    foreach ($record in $records) {
        if ((Node-Kind $record) -ne 'Menu') { continue }
        if ((Prop $record 'ParentNodeID') -ne $zeroGuid) { continue }
        $next = Prop $record 'NextNodeID'
        if ((-not $next) -or ($next -eq $zeroGuid)) { $tailMenus += $record }
    }
    if ($tailMenus.Count -eq 0) {
        Fail 'меню верхнего уровня без продолжения не нашлось - врезаться не во что, а угадывать тут нельзя'
    }
    if ($tailMenus.Count -gt 1) {
        Fail "меню верхнего уровня без продолжения оказалось $($tailMenus.Count), а должно быть одно - какое из них хвост, скрипт решать не вправе"
    }
    $lastMenuId = Node-Id $tailMenus[0]
    Write-Host "  хвост цепочки меню верхнего уровня [{$lastMenuId}]"

    # ---------- правка РОВНО ОДНОГО чужого узла ----------
    $patched = @()
    $done = $false
    foreach ($record in $records) {
        if ((Node-Id $record) -eq $lastMenuId) {
            if ($record.Contains("NextNodeID=[{$zeroGuid}]")) {
                # Хвост помечен нулевым GUID - его и подменяем. Так цепочка остаётся
                # замкнутой ЯВНО, а не отсутствием свойства, и так же выглядят соседи.
                $record = $record.Replace("NextNodeID=[{$zeroGuid}]", "NextNodeID=[{$ourMenuId}]")
                $done = $true
            } else {
                $indent = ' ' * 64
                $m = [regex]::Match($record, '(?m)^(\s+)\S+=')
                if ($m.Success) { $indent = $m.Groups[1].Value }
                $trimmed = $record.TrimEnd()
                if ($trimmed.EndsWith('}')) {
                    $trimmed = $trimmed.Substring(0, $trimmed.Length - 1).TrimEnd()
                    $record = "$trimmed;`r`n$indent" + "NextNodeID=[{$ourMenuId}] }`r`n"
                    $done = $true
                }
            }
        }
        $patched += $record
    }
    if (-not $done) { Fail 'не удалось дописать ссылку в последнее меню - формат записи не тот' }
    $records = $patched + $ourRecords
}

# Записи склеиваются с переводом строки на конце каждой, а последний перевод снимается:
# в выгрузке последняя запись кончается БЕЗ него, и приписанная следом наша слиплась бы с
# ней в одну строку. Объект при этом импортируется молча и наполовину.
$joined = ($records | ForEach-Object { if ($_.EndsWith("`r`n")) { $_ } else { $_ + "`r`n" } }) -join ''
$merged = $head + $joined.TrimEnd("`r", "`n") + $tail
$mergedFile = Join-Path $outDir "menusuite-$TargetId-merged.txt"
[IO.File]::WriteAllBytes($mergedFile, $cp866.GetBytes($merged))
Write-Host "Слито: $mergedFile" -ForegroundColor Green

if ($Import) {
    Invoke-Finsql "Command=ImportObjects,File=`"$mergedFile`",ImportAction=overwrite" "import-menu-$TargetId.log"
    Invoke-Finsql "Command=CompileObjects,Filter=`"Type=MenuSuite;ID=$TargetId`"" "compile-menu-$TargetId.log"
    Write-Host "Импортирован и скомпилирован MenuSuite $TargetId" -ForegroundColor Green
    Write-Host "Вернуть как было: pwsh scripts/Merge-MenuSuite.ps1 -Remove -Import"
} else {
    Write-Host ''
    Write-Host 'Импорт скрипт сам не делает: это правка ЧУЖОГО объекта, и решение о ней отдельное.'
    Write-Host "  импортировать:  pwsh scripts/Merge-MenuSuite.ps1 -Import"
    Write-Host "  оригинал лежит: $originalFile"
}
