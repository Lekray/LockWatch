/*
    Кто кого блокирует прямо сейчас - и кто держит.

    Ручной разбор ОДНОГО случая: та же дорога, какой ходит сам инструмент, но одной
    съёмкой и без установки. Пригождается до установки (показать службе безопасности,
    что именно спрашивается у сервера) и после - когда нужно посмотреть глазами.

    Запускать в базе установки:  sqlcmd -S <сервер> -d <база> -E -i Show-Locks.sql
    Права: VIEW SERVER STATE на сервере. Больше ничего не нужно.

    Ответ ОДИН, и в нём сразу обе половины: и то, что о держателе знает SQL, и учётная
    запись NAV из отметки контекста. Порознь их читать неудобно, а сопоставлять приходится
    глазами по номеру сеанса - это ровно та работа, которую должен делать запрос. Отдельным
    ответом отметка лежала потому, что поднимается она динамическим запросом: имя таблицы и
    подсказка индекса известны только во время работы. Теперь очередь сперва складывается в
    переменную, отметки ищутся по ней, и печатается всё вместе.

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

    Отвечает скрипт на три вопроса сразу:

      1. Кто ждёт, кого ждёт, чего ждёт и сколько уже - с именем таблицы и номером
         ключа NAV.
      2. Кто держит - тем, что о держателе знает сам сервер: логин SQL, узел, программа,
         состояние, давность последнего запроса.
      3. Кто держит - учётной записью NAV, если инструмент установлен и виновник писал
         в таблицу контекста. Жертва называется так же и СВОЕЙ отметкой: спрашивают чаще
         про виновника, но "кто пострадал" - второй вопрос инструмента, а не десятый.

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
-- 1. Очередь: кто ждёт, за что, и что сервер знает об обеих сторонах.
-------------------------------------------------------------------------------

-- Очередь снимается ОДИН раз и складывается в переменную. Спросить сервер второй раз -
-- значит получить другую очередь: ожидания кончаются и начинаются каждую миллисекунду, и
-- две половины ответа разъехались бы молча.
DECLARE @queue TABLE (
    victim_spid int, blocker_spid int, wait_ms bigint,
    wait_type varchar(22), resource_kind varchar(9),
    object_name varchar(34), index_name varchar(34), nav_key int, on_sift bit,
    lockres varchar(22),
    blocker_login varchar(30), blocker_host varchar(18), blocker_program varchar(30),
    blocker_status varchar(12), idle_s int, open_trans int, tran_began datetime,
    victim_login varchar(30), victim_host varchar(18), victim_program varchar(30));

-- Ресурс НЕ разбирается из строки wait_type/resource_description: невыполненная просьба
-- жертвы лежит в dm_tran_locks сама, и в ней уже есть и hobt, и хэш спорной строки.
-- Разбирать текст пришлось бы по четырём образцам - у KEY, PAGE, OBJECT и RID они разные.
INSERT @queue (victim_spid, blocker_spid, wait_ms, wait_type, resource_kind,
               object_name, index_name, nav_key, on_sift, lockres,
               blocker_login, blocker_host, blocker_program, blocker_status,
               idle_s, open_trans, tran_began,
               victim_login, victim_host, victim_program)
SELECT
    wt.session_id,
    wt.blocking_session_id,
    wt.wait_duration_ms,
    CONVERT(varchar(22), wt.wait_type),
    CONVERT(varchar(9),  w.resource_type),
    CONVERT(varchar(34), o.name),
    CONVERT(varchar(34), i.name),
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
    END,
    CASE WHEN o.name LIKE '%$VSIFT$%' THEN 1 ELSE 0 END,
    CONVERT(varchar(22), w.resource_description),
    -- Держатель глазами сервера. Для ЧУЖОГО соединения - утилиты, шага задания, чьего-то
    -- окна запросов - это единственный возможный ответ на "кто": отметку контекста кладёт
    -- только сессия NAV. Для самой сессии NAV логин здесь общий, учётной записи службы,
    -- и человеком он не притворяется - на то и отдельный столбец с учётной записью.
    CONVERT(varchar(30), bs.login_name),
    CONVERT(varchar(18), bs.host_name),
    CONVERT(varchar(30), bs.program_name),
    CONVERT(varchar(12), bs.status),
    -- Спящая транзакция - это не медленный запрос, а забытое модальное окно: виновник не
    -- исполняет ничего, а транзакцию держит. Лечится звонком, а не правкой кода, и
    -- отличать одно от другого надо сразу.
    CASE WHEN bs.last_request_end_time IS NULL THEN NULL
         ELSE DATEDIFF(second, bs.last_request_end_time, GETDATE()) END,
    bs.open_transaction_count,
    ba.transaction_begin_time,
    CONVERT(varchar(30), vs.login_name),
    CONVERT(varchar(18), vs.host_name),
    CONVERT(varchar(30), vs.program_name)
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
  AND wt.session_id <> @@SPID;

-------------------------------------------------------------------------------
-- 2. Учётные записи NAV - из отметок контекста ОБЕИХ сторон.
-------------------------------------------------------------------------------

DECLARE @found TABLE (spid int, nav_user varchar(30), company varchar(20),
                      doc varchar(24), marked datetime);

IF @markTable IS NOT NULL AND EXISTS (SELECT 1 FROM @queue)
BEGIN
    -- Выданные блокировки на таблице отметок. Ключ у отметки - экземпляр службы плюс
    -- номер сеанса, то есть строка у сессии ОДНА, и держит её сама транзакция стороны.
    -- Спрашиваются ОБЕ стороны: у жертвы отметка своя, и без неё журнал называет её
    -- номером сеанса, то есть не называет.
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
      AND (l.request_session_id IN (SELECT blocker_spid FROM @queue WHERE blocker_spid IS NOT NULL)
        OR l.request_session_id IN (SELECT victim_spid FROM @queue));

    -- Обратный поиск по хэшу ключа. %%lockres%% - псевдостолбец, и он НЕ ИНДЕКСИРУЕМ:
    -- отбор по нему всегда просмотр, поэтому индекс задаётся подсказкой явно, а чтение
    -- идёт грязным - вставать в очередь за тем, кого разбираем, было бы смешно.
    -- Просмотр этот дёшев ровно потому, что таблица отметок мала: 0,005 мс на пустой и
    -- 0,026 мс на 82 тысячах строк (docs/FINDINGS.md, раздел 67).
    DECLARE @spid int, @idx sysname, @lockres varchar(100), @sql nvarchar(max);
    DECLARE marks CURSOR LOCAL FAST_FORWARD FOR SELECT spid, idx, lockres FROM @held;
    OPEN marks;
    FETCH NEXT FROM marks INTO @spid, @idx, @lockres;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @sql =
            N'SELECT @spid, CONVERT(varchar(30),[User Id]), CONVERT(varchar(20),[Company Name]),' +
            N' CONVERT(varchar(24),[Document No_]), [Marked At] FROM ' + QUOTENAME(@markTable) +
            N' WITH (INDEX(' + QUOTENAME(@idx) + N'), NOLOCK)' +
            N' WHERE %%lockres%% = @lockres;';
        INSERT @found (spid, nav_user, company, doc, marked)
        EXEC sp_executesql @sql, N'@spid int, @lockres varchar(100)', @spid = @spid, @lockres = @lockres;
        FETCH NEXT FROM marks INTO @spid, @idx, @lockres;
    END;
    CLOSE marks;
    DEALLOCATE marks;
END;

-------------------------------------------------------------------------------
-- 3. Один ответ.
-------------------------------------------------------------------------------

-- Отметка берётся САМАЯ СВЕЖАЯ из найденных. У сессии NAV она одна по устройству ключа,
-- но подставленный опыт может держать и несколько, а размножать строки очереди нельзя:
-- очередь - это факт, и число её строк менять отчёту не позволено.
SELECT
    q.victim_spid                  AS [ждёт spid],
    q.blocker_spid                 AS [держит spid],
    q.wait_ms                      AS [ждёт мс],
    q.object_name                  AS [таблица SQL],
    q.nav_key                      AS [ключ NAV],
    q.on_sift                      AS [SIFT],
    fb.nav_user                    AS [учётная запись NAV держателя],
    q.blocker_login                AS [логин держателя],
    q.blocker_host                 AS [узел держателя],
    q.blocker_program              AS [программа держателя],
    q.blocker_status               AS [состояние],
    q.idle_s                       AS [молчит с, с],
    q.open_trans                   AS [открытых транзакций],
    q.tran_began                   AS [транзакция начата],
    fv.nav_user                    AS [учётная запись NAV жертвы],
    q.victim_login                 AS [логин жертвы],
    q.victim_host                  AS [узел жертвы],
    q.victim_program               AS [программа жертвы],
    -- Документ здесь - ПОСЛЕДНИЙ, который виновник трогал в этой транзакции, а не спорный:
    -- строка отметки у сессии одна и переписывается при каждой записи. Виновник за одну
    -- транзакцию трогает много строк, спор же идёт за одну, и называть по отметке документ
    -- значило бы назвать чужой номер - выглядит он ровно так же убедительно, как свой
    -- (docs/FINDINGS.md, раздел 19). Сам инструмент берёт документ не отсюда, а обратным
    -- поиском по хэшу СПОРНОЙ строки - того самого, что в столбце рядом.
    -- Учётная запись при этом верна: сессия одна, человек за ней один.
    fb.doc                         AS [документ отметки, последний],
    q.wait_type                    AS [род ожидания],
    q.resource_kind                AS [род ресурса],
    q.index_name                   AS [индекс],
    q.lockres                      AS [хэш спорной строки]
FROM @queue q
OUTER APPLY (SELECT TOP 1 f.nav_user, f.doc FROM @found f
             WHERE f.spid = q.blocker_spid ORDER BY f.marked DESC) fb
OUTER APPLY (SELECT TOP 1 f.nav_user FROM @found f
             WHERE f.spid = q.victim_spid ORDER BY f.marked DESC) fv
-- По убыванию длительности: смотреть начинают с самого долгого, а не с первого попавшегося.
ORDER BY q.wait_ms DESC;

-- Пустой столбец учётной записи - не отказ инструмента, и объяснить это надо словами:
-- молчание читается как поломка, а поломки здесь нет.
IF @markTable IS NULL
    PRINT 'Таблицы отметок контекста в этой базе нет: инструмент не установлен, и учётную запись NAV назвать нечем - остаётся логин SQL.';
ELSE IF EXISTS (SELECT 1 FROM @queue) AND NOT EXISTS (SELECT 1 FROM @found)
BEGIN
    PRINT 'Отметки контекста ни у одной из сторон нет. Отметку кладёт только сессия NAV и';
    PRINT 'только при записи в таблицу контекста: держит блокировку чужое соединение, или';
    PRINT 'запись шла в таблицу, на которую переходника не ставили. Значит имени NAV не';
    PRINT 'существует, и назвать держателя можно лишь логином SQL.';
END;
