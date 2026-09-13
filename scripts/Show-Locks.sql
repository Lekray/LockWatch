/*
    Кто кого блокирует прямо сейчас - и кто держит.

    Ручной разбор ОДНОГО случая: та же дорога, какой ходит сам инструмент, но одной
    съёмкой и без установки. Пригождается до установки (показать службе безопасности,
    что именно спрашивается у сервера) и после - когда нужно посмотреть глазами.

    Запускать в базе установки:  sqlcmd -S <сервер> -d <база> -E -i Show-Locks.sql
    Права: VIEW SERVER STATE на сервере. Больше ничего не нужно.

    Ширину столбцов скрипт задаёт САМ, приведением к varchar нужной длины. Без этого
    sqlcmd печатает каждый nvarchar(128) во всю объявленную ширину - строка уходит далеко
    за экран, консоль её переносит, и значения оказываются под чужой шапкой. Выглядит это
    как "логин держателя не пишется", хотя он на месте: просто уехал на перенос.

    Файл лежит в UTF-8 С BOM, и это не вкусовщина: без BOM sqlcmd читает его как OEM, и
    русская шапка приезжает в консоль мусором. Правка файла чем угодно, что BOM снимает,
    ломает ровно это - данные при том остаются верными, и беда выглядит как "кракозябры
    в SSMS", а не как испорченный файл.

    ЧЕГО ЗДЕСЬ НЕТ НАРОЧНО. Это СЪЁМКА, а не сторож: цикла по этому тексту быть не
    должно. sys.dm_tran_locks стоит 45,6 мс при шестидесяти тысячах блокировок, и отбор
    в WHERE не помогает вовсе (docs/FINDINGS.md, раздел 2) - опрашивать её раз в
    несколько секунд значит греть сервер ровно тогда, когда ему и без того плохо.
    Сторож устроен иначе: очередь ждущих задач опрашивается часто, а dm_tran_locks -
    один раз на проход и только при непустой очереди.

    Отвечает скрипт на три вопроса подряд:

      1. Кто ждёт, кого ждёт, чего ждёт и сколько уже - с именем таблицы и номером
         ключа NAV.
      2. Кто держит - тем, что о держателе знает сам сервер: логин SQL, узел, программа,
         состояние, давность последнего запроса.
      3. Кто держит - учётной записью NAV, если инструмент установлен и виновник писал
         в таблицу контекста.

    Почему вопроса про "кто" ДВА. Со стороны SQL пользователя NAV назвать нельзя: все
    сессии службы идут под одной учётной записью, program_name у всех одинаков,
    context_info пуст, узел - имя сервера (docs/USERNAME.md). Имя обязана называть
    сторона NAV, и единственная дорога, не стоящая новых прав, - отметка контекста:
    подписчик на таблице документа кладёт строку с USERID в ТОЙ ЖЕ транзакции, что и
    сама запись, поэтому транзакция виновника держит на этой строке монопольную
    блокировку. Её и находим, а по хэшу ключа поднимаем саму строку.
*/

SET NOCOUNT ON;

-- Таблица отметок ищется ПО ОБРАЗЦУ ИМЕНИ, а не по номеру: имя в SQL несёт префикс
-- компании, а компаний в базе может быть несколько. Нет её - значит инструмент здесь
-- не установлен, и третий вопрос останется без ответа.
DECLARE @markTable sysname =
    (SELECT TOP 1 name FROM sys.objects WHERE type = 'U' AND name LIKE '%LockWatch Context Mark');

-------------------------------------------------------------------------------
-- 1 и 2. Очередь: кто ждёт, за что, и что сервер знает о держателе.
-------------------------------------------------------------------------------

-- Ресурс НЕ разбирается из строки wait_type/resource_description: невыполненная просьба
-- жертвы лежит в dm_tran_locks сама, и в ней уже есть и hobt, и хэш спорной строки.
-- Разбирать текст пришлось бы по четырём образцам - у KEY, PAGE, OBJECT и RID они разные.
SELECT
    wt.session_id                                   AS [ждёт spid],
    wt.blocking_session_id                          AS [держит spid],
    wt.wait_duration_ms                             AS [ждёт мс],
    CONVERT(varchar(22), wt.wait_type)              AS [род ожидания],
    CONVERT(varchar(9),  w.resource_type)           AS [род ресурса],
    CONVERT(varchar(34), o.name)                    AS [таблица SQL],
    CONVERT(varchar(34), i.name)                    AS [индекс],
    -- Правил разбора имени ДВА, и одним не обойтись (docs/FINDINGS.md, раздел 5).
    -- У таблицы номер ключа NAV - суффикс имени индекса после последнего доллара:
    -- кластерный зовётся <Компания>$<Таблица>$0, вторичные - $1, $5, $13. Номера не
    -- сплошные: у выключенного ключа индекса в SQL нет вовсе.
    -- У SIFT-представления индекс у всех один и тот же, VSIFTIDX, номера он не несёт;
    -- номер там - число после ПОСЛЕДНЕГО $VSIFT$ в имени самого объекта.
    CASE
        WHEN o.name LIKE '%$VSIFT$%'
            THEN TRY_CONVERT(int, REVERSE(LEFT(REVERSE(o.name),
                     CHARINDEX('$TFISV$', REVERSE(o.name)) - 1)))
        WHEN CHARINDEX('$', REVERSE(i.name)) > 0
            THEN TRY_CONVERT(int, REVERSE(LEFT(REVERSE(i.name),
                     CHARINDEX('$', REVERSE(i.name)) - 1)))
        ELSE NULL
    END                                             AS [ключ NAV],
    CASE WHEN o.name LIKE '%$VSIFT$%' THEN 1 ELSE 0 END AS [SIFT],
    CONVERT(varchar(22), w.resource_description)    AS [хэш спорной строки],
    -- Держатель глазами сервера. Для ЧУЖОГО соединения - утилиты, шага задания, чьего-то
    -- окна запросов - это единственный возможный ответ на "кто": отметку контекста кладёт
    -- только сессия NAV. Для самой сессии NAV логин здесь общий, учётной записи службы,
    -- и человеком он не притворяется - на то и отдельная колонка ниже.
    CONVERT(varchar(30), bs.login_name)             AS [логин держателя],
    CONVERT(varchar(18), bs.host_name)              AS [узел держателя],
    CONVERT(varchar(30), bs.program_name)           AS [программа держателя],
    CONVERT(varchar(12), bs.status)                 AS [состояние],
    -- Спящая транзакция - это не медленный запрос, а забытое модальное окно: виновник не
    -- исполняет ничего, а транзакцию держит. Лечится звонком, а не правкой кода, и
    -- отличать одно от другого надо сразу.
    CASE WHEN bs.last_request_end_time IS NULL THEN NULL
         ELSE DATEDIFF(second, bs.last_request_end_time, GETDATE()) END AS [молчит с, с],
    bs.open_transaction_count                       AS [открытых транзакций],
    ba.transaction_begin_time                       AS [транзакция начата],
    CONVERT(varchar(30), vs.login_name)             AS [логин жертвы],
    CONVERT(varchar(18), vs.host_name)              AS [узел жертвы],
    CONVERT(varchar(30), vs.program_name)           AS [программа жертвы]
FROM sys.dm_os_waiting_tasks wt
JOIN sys.dm_exec_sessions vs ON vs.session_id = wt.session_id
LEFT JOIN sys.dm_exec_sessions bs ON bs.session_id = wt.blocking_session_id
LEFT JOIN sys.dm_tran_session_transactions bt ON bt.session_id = wt.blocking_session_id
LEFT JOIN sys.dm_tran_active_transactions ba ON ba.transaction_id = bt.transaction_id
OUTER APPLY (
    SELECT TOP 1 l.resource_type, l.resource_associated_entity_id,
           RTRIM(l.resource_description) AS resource_description
    FROM sys.dm_tran_locks l
    WHERE l.request_session_id = wt.session_id
      AND l.request_status <> 'GRANT'
      AND l.resource_database_id = DB_ID()
) w
LEFT JOIN sys.partitions p ON p.hobt_id = w.resource_associated_entity_id
LEFT JOIN sys.objects o ON o.object_id = p.object_id
LEFT JOIN sys.indexes i ON i.object_id = p.object_id AND i.index_id = p.index_id
WHERE wt.wait_type LIKE 'LCK[_]%'
  AND wt.session_id <> @@SPID
-- По убыванию длительности: смотреть начинают с самого долгого, а не с первого попавшегося.
ORDER BY wt.wait_duration_ms DESC;

-------------------------------------------------------------------------------
-- 3. Учётная запись NAV - из отметки контекста виновника.
-------------------------------------------------------------------------------

IF @markTable IS NULL
BEGIN
    PRINT 'Таблицы отметок контекста в этой базе нет: инструмент не установлен,';
    PRINT 'и учётную запись NAV назвать нечем - остаётся логин SQL выше.';
    RETURN;
END;

-- Выданные блокировки виновников на таблице отметок. Ключ у отметки - экземпляр службы
-- плюс номер сеанса, то есть строка у сессии ОДНА, и держит её сама транзакция виновника.
DECLARE @held TABLE (spid int, idx sysname, lockres varchar(100));

INSERT @held (spid, idx, lockres)
SELECT DISTINCT l.request_session_id, i.name, RTRIM(l.resource_description)
FROM sys.dm_tran_locks l
JOIN sys.partitions p ON p.hobt_id = l.resource_associated_entity_id
JOIN sys.objects o ON o.object_id = p.object_id
JOIN sys.indexes i ON i.object_id = p.object_id AND i.index_id = p.index_id
WHERE l.resource_type = 'KEY'
  AND l.request_status = 'GRANT'
  AND l.request_owner_type = 'TRANSACTION'
  AND l.resource_database_id = DB_ID()
  AND o.name = @markTable
  AND l.request_session_id IN (
        SELECT wt.blocking_session_id FROM sys.dm_os_waiting_tasks wt
        WHERE wt.wait_type LIKE 'LCK[_]%' AND wt.blocking_session_id IS NOT NULL);

IF NOT EXISTS (SELECT 1 FROM @held)
BEGIN
    PRINT 'Отметки контекста у держателей нет. Это не отказ инструмента:';
    PRINT 'отметку кладёт только сессия NAV и только при записи в таблицу контекста.';
    PRINT 'Держит блокировку чужое соединение или запись шла в другую таблицу -';
    PRINT 'значит имени NAV не существует, и назвать держателя можно лишь логином SQL.';
    RETURN;
END;

-- Обратный поиск по хэшу ключа. %%lockres%% - псевдостолбец, и он НЕ ИНДЕКСИРУЕМ:
-- отбор по нему всегда просмотр, поэтому индекс задаётся подсказкой явно, а чтение идёт
-- грязным - вставать в очередь за тем, кого разбираем, было бы смешно.
-- Просмотр этот дёшев ровно потому, что таблица отметок мала: 0,005 мс на пустой и
-- 0,026 мс на 82 тысячах строк (docs/FINDINGS.md, раздел 67).
DECLARE @found TABLE (spid int, [Учётная запись NAV] varchar(30),
                      [Компания] varchar(20), [Документ] varchar(24), [Отмечено] datetime);
DECLARE @spid int, @idx sysname, @lockres varchar(100), @sql nvarchar(max);

DECLARE marks CURSOR LOCAL FAST_FORWARD FOR SELECT spid, idx, lockres FROM @held;
OPEN marks;
FETCH NEXT FROM marks INTO @spid, @idx, @lockres;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @sql =
        N'SELECT @spid, [User Id], [Company Name], [Document No_], [Marked At] FROM ' +
        QUOTENAME(@markTable) + N' WITH (INDEX(' + QUOTENAME(@idx) + N'), NOLOCK)' +
        N' WHERE %%lockres%% = @lockres;';
    INSERT @found (spid, [Учётная запись NAV], [Компания], [Документ], [Отмечено])
    EXEC sp_executesql @sql, N'@spid int, @lockres varchar(100)', @spid = @spid, @lockres = @lockres;
    FETCH NEXT FROM marks INTO @spid, @idx, @lockres;
END;
CLOSE marks;
DEALLOCATE marks;

-- Документ здесь - ПОСЛЕДНИЙ, который виновник трогал в этой транзакции, а не спорный:
-- строка отметки у сессии одна и переписывается при каждой записи. Виновник за одну
-- транзакцию трогает много строк, спор же идёт за одну, и называть по отметке документ
-- значило бы назвать чужой номер - выглядит он ровно так же убедительно, как свой
-- (docs/FINDINGS.md, раздел 19). Сам инструмент берёт документ не отсюда, а обратным
-- поиском по хэшу СПОРНОЙ строки - того самого, что в первом ответе.
-- Учётная запись при этом верна: сессия одна, человек за ней один.
SELECT f.spid AS [держит spid], f.[Учётная запись NAV], f.[Компания],
       f.[Документ] AS [документ отметки (последний, не спорный)], f.[Отмечено]
FROM @found f
ORDER BY f.spid;
