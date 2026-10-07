-- ============================================================
-- ЭТАП 2. КАЧЕСТВО ДАННЫХ
-- ============================================================
-- Шесть проверок перед расчётом метрик. Задача этапа — определить
-- рабочую выборку и выписать её ограничения.
-- Итог этапа — в конце файла. Выборка реализована представлением
-- delivered_orders в sql/02_sla_overview.sql.


-- 1. ПОЛНОТА ДАТ ПО СТАТУСАМ

WITH by_order_statuses AS (
	SELECT order_status,
		COUNT(*) AS orders_count,
		COUNT(*) FILTER (WHERE order_approved_at IS NULL) AS no_approved,
		COUNT(*) FILTER (WHERE order_delivered_carrier_date IS NULL) AS no_carrier,
		COUNT(*) FILTER (WHERE order_delivered_customer_date IS NULL) AS no_delivered
	FROM orders
	GROUP BY order_status
)

SELECT order_status,
	orders_count,
	no_approved,
	ROUND(no_approved::numeric / orders_count * 100, 2) AS no_approved_pct,
	no_carrier,
	ROUND(no_carrier::numeric / orders_count * 100, 2) AS no_carrier_pct,
	no_delivered,
	ROUND(no_delivered::numeric / orders_count * 100, 2) AS no_delivered_pct
FROM by_order_statuses
ORDER BY orders_count DESC;

-- ВЫВОД

-- Паттерн пропусков соответствует жизненному циклу: каждый статус
-- заполняет даты ровно до своей точки. Данные консистентны.

-- Для анализа сроков доставки пригоден только статус delivered
-- (96478 заказов, 97.0% всех): он единственный содержит дату
-- вручения. У остальных семи статусов она отсутствует у 100%
-- записей по определению — заказ не доставлен.

-- Аномалии в delivered: 14 заказов без даты подтверждения платежа,
-- 2 без даты отгрузки, 8 без даты вручения. Всего не более 24
-- записей (0.025%), на метрики не влияют. Восемь без даты вручения
-- исключаем из расчёта сроков — разбор в проверке 2.

-- Статус shipped (1107 заказов, 1.1%) — отдельный объект:
-- отгружены, вручение не зафиксировано. Разбор в проверке 6.

-- order_estimated_delivery_date заполнена во всех 99441 заказах.



-- 2. ДОСТАВЛЕННЫЕ БЕЗ ДАТЫ ДОСТАВКИ

SELECT order_id,
	order_status,
	order_purchase_timestamp,
	order_approved_at,
	order_delivered_carrier_date,
	order_delivered_customer_date
FROM orders
WHERE order_status = 'delivered' AND order_delivered_customer_date IS NULL
ORDER BY order_id;

-- ВЫВОД

-- 8 заказов (0.008% от delivered) помечены доставленными, но даты
-- вручения не имеют. У 7 из них есть дата передачи перевозчику —
-- значит заказ реально отгружался, и не записан только последний
-- шаг. Похоже на сбой логирования, а не на особый бизнес-случай.

-- Один заказ не имеет ни даты отгрузки, ни даты вручения: он
-- попадает одновременно в обе группы аномалий из проверки 1.
-- Уникальных аномальных записей в delivered — 23, а не 24.

-- Решение: исключаем эти 8 из расчёта сроков доставки (срок по ним
-- посчитать нечем). На метрики не влияют: 0.008%. В README
-- указываем явно.


-- 3. НАРУШЕНИЯ ПОРЯДКА ДАТ

WITH checks AS (
	SELECT
		COUNT(*) FILTER (WHERE order_approved_at < order_purchase_timestamp) AS approved_to_purchase,
		COUNT(*) FILTER (WHERE order_purchase_timestamp IS NOT NULL AND order_approved_at IS NOT NULL) AS approved_count,
		COUNT(*) FILTER (WHERE order_delivered_carrier_date < order_approved_at) AS carrier_to_approved,
		COUNT(*) FILTER (WHERE order_delivered_carrier_date IS NOT NULL AND order_approved_at IS NOT NULL) AS carrier_count,
		COUNT(*) FILTER (WHERE order_delivered_customer_date < order_delivered_carrier_date) AS customer_to_carrier,
		COUNT(*) FILTER (WHERE order_delivered_customer_date IS NOT NULL AND order_delivered_carrier_date IS NOT NULL) AS customer_count,
		COUNT(*) FILTER (WHERE order_delivered_carrier_date < order_purchase_timestamp) AS carrier_to_purchase,
		COUNT(*) FILTER (WHERE order_delivered_carrier_date IS NOT NULL) AS carrier_base
	FROM orders
)

SELECT
	approved_to_purchase,
	approved_count,
	ROUND(approved_to_purchase::numeric / NULLIF(approved_count, 0) * 100, 3) AS approved_to_purchase_pct,
	carrier_to_approved,
	carrier_count,
	ROUND(carrier_to_approved::numeric / NULLIF(carrier_count, 0) * 100, 3) AS carrier_to_approved_pct,
	customer_to_carrier,
	customer_count,
	ROUND(customer_to_carrier::numeric / NULLIF(customer_count, 0) * 100, 3) AS customer_to_carrier_pct,
	carrier_to_purchase,
	carrier_base,
	ROUND(carrier_to_purchase::numeric / NULLIF(carrier_base, 0) * 100, 3) AS carrier_to_purchase_pct
FROM checks;

-- Числа выше посчитаны по всей таблице orders. Для рабочей выборки
-- важно, сколько из них попадёт в неё, а сколько останется снаружи.
-- Разложение по статусам:

SELECT order_status,
       COUNT(*)                                                                             AS orders,
       COUNT(*) FILTER (WHERE order_delivered_carrier_date < order_approved_at)             AS handover_bad,
       COUNT(*) FILTER (WHERE order_delivered_customer_date < order_delivered_carrier_date) AS transit_bad
FROM orders
GROUP BY order_status
ORDER BY handover_bad DESC;

-- delivered 1350 / 23, shipped 9 / 0, остальные шесть статусов по нулям.
-- Сумма handover_bad = 1359 сходится с общей проверкой выше.
-- Асимметрия объясняется структурно: нарушение customer < carrier требует
-- заполненной даты вручения и потому встречается только у delivered,
-- а carrier < approved такого ограничителя не имеет и захватывает shipped.

-- Сколько из них в хвосте 2016 года, который не войдёт в рабочую выборку:

SELECT COUNT(*) FILTER (WHERE order_delivered_carrier_date < order_approved_at)             AS handover_bad,
       COUNT(*) FILTER (WHERE order_delivered_customer_date < order_delivered_carrier_date) AS transit_bad
FROM orders
WHERE order_status = 'delivered'
  AND order_delivered_customer_date IS NOT NULL
  AND order_purchase_timestamp < '2017-01-01';

-- 0 и 4. Значит в рабочей выборке останется 1350 и 19.

-- ВЫВОД

-- Нарушений approved < purchase нет.

-- carrier < approved: 1359 из 97644 (1.39%) — самое частое нарушение
-- хронологии в данных. Заказ передан перевозчику раньше, чем подтверждён
-- платёж. Две версии: задержка записи о платеже либо отгрузка по
-- авторизации, не дожидаясь проводки (вероятно для boleto). Различать
-- по величине разрыва и типу платежа. На общее время доставки не влияет —
-- исключаем только из расчёта интервала "оплата → отгрузка".
-- В рабочую выборку из них попадают 1350, остальные 9 — в статусе shipped.

-- carrier < purchase: 166 заказов (0.17%). Отгрузка записана раньше
-- оформления заказа. Интервал "покупка → отгрузка" для метрик SLA
-- не рассчитывается, поэтому на выборку это нарушение не влияет.

-- customer < carrier: 23 из 96475 (0.024%). Дата отгрузки записана
-- позже даты вручения. Артефакт логирования. Исключаем из расчёта
-- времени в пути: длительность вышла бы отрицательной.
-- В рабочую выборку из них попадают 19, остальные 4 — в хвосте 2016 года.


-- 4. ДУБЛИ В ОТЗЫВАХ

SELECT
	(SELECT COUNT(*) FROM order_reviews) AS total_rows,
    (SELECT COUNT(*) FROM (
        SELECT review_id FROM order_reviews GROUP BY review_id HAVING COUNT(*) > 1
     )) AS review_ids_with_duplicates,
	 (SELECT COUNT(*) FROM (
		SELECT review_id FROM order_reviews GROUP BY review_id HAVING COUNT(*) = 1
	 )) AS review_ids_with_no_duplicates,
	 (SELECT COUNT(*) FROM (
        SELECT order_id FROM order_reviews GROUP BY order_id HAVING COUNT(*) = 1
     )) AS orders_with_one_review,
    (SELECT COUNT(*) FROM (
        SELECT order_id FROM order_reviews GROUP BY order_id HAVING COUNT(*) > 1
     )) AS orders_with_several_reviews;

-- Количество всего строк 99224.
-- Отзывы где review_id дублируются 789, а review_id встречается один раз 97621.
-- Заказы с одним отзывом 98126, а заказов с несколькими отзывами 547.

SELECT CASE WHEN distinct_orders > 1 THEN 'разные заказы'
            ELSE 'тот же заказ' END AS pattern,
       COUNT(*) AS review_ids
FROM (
    SELECT review_id,
           COUNT(*) AS rows,
           COUNT(DISTINCT order_id) AS distinct_orders
    FROM order_reviews
    GROUP BY review_id
    HAVING COUNT(*) > 1
) t
GROUP BY 1;

-- только одна строка: 'разные заказы' -> 789

-- ВЫВОД

-- Настоящих дублей строк нет: все 789 повторяющихся review_id
-- относятся к разным заказам, пара (review_id, order_id) уникальна.
-- Один опрос покрывает покупку целиком, которая могла разбиться
-- на несколько заказов.

-- При джойне размножение дают не они, а 547 заказов с несколькими
-- разными отзывами. Перед соединением отзывы
-- сворачиваем до одной строки на заказ (последний по
-- review_creation_date).

-- Ограничение для анализа связи сроков с оценками: у 789 отзывов
-- (0.8%) оценка относится к нескольким заказам сразу, поэтому
-- привязка опоздания к конкретной оценке для них приблизительна.


-- 5. РАСПРЕДЕЛЕНИЕ ЗАКАЗОВ ПО МЕСЯЦАМ

WITH orders_count_by_month AS (
	SELECT
		DATE_TRUNC('month', order_purchase_timestamp)::date AS month,
		COUNT(*) AS orders_count
	FROM orders
	GROUP BY 1
)
SELECT *
FROM orders_count_by_month
ORDER BY month;

-- Заказы последних двух месяцев — посмотреть целиком, их всего 20

SELECT *
FROM orders
WHERE order_purchase_timestamp >= '2018-09-01'
ORDER BY order_purchase_timestamp;

-- ВЫВОД

-- Рабочий период: 2017-01 … 2018-08, 20 месяцев, 99092 заказа
-- (99.65% от всех). Исключается 349 заказов (0.35%) по двум
-- разным причинам.

-- 1. Период запуска: 2016-09 (4 заказа), 2016-10 (324),
-- 2016-12 (1). Ноябрь 2016 в данных отсутствует полностью.
-- Площадка только начинала работать: от 4 до 324 заказов в месяц
-- против медианы 4285 по рабочему периоду. Данные корректны, но
-- объём не позволяет считать месячные метрики — одна просрочка
-- из четырёх заказов даст 25%, и эта цифра ничего не описывает.

-- 2. Обрыв выгрузки: 2018-09 (16 заказов) и 2018-10 (4).
-- Падение в четыреста раз после восьми месяцев по 6-7 тысяч —
-- не изменение спроса. Проверка строк показала, что из 20 заказов
-- 19 отменены и 1 остался в пути; доставленных нет ни одного.
-- В срез попали только заказы, успевшие достичь конечного статуса
-- к моменту выгрузки, а за две недели это успевают почти
-- исключительно отмены. Выборка смещена по исходу: по этим
-- месяцам нельзя считать ни сроки доставки, ни долю отмен —
-- последняя вышла бы 95% и была бы артефактом отбора.

-- Внутри рабочего периода объём растёт с 800 заказов в январе
-- 2017 до 6-7 тысяч в 2018. Это надо учитывать при сравнении
-- месяцев: доли сопоставимы, абсолютные числа — нет.

-- Отдельно: ноябрь 2017 — 7544 заказа по всем статусам, максимум за всю историю
-- при соседних 4631 и 5673. Чёрная пятница. Не аномалия данных,
-- а повод проверить, просело ли выполнение в пиковую нагрузку.


-- 6. ЦЕНЗУРИРОВАНИЕ НА КОНЦЕ ПЕРИОДА

-- Сколько заказов осталось в статусе shipped

SELECT COUNT(*) AS shipped_orders
FROM orders
WHERE order_status = 'shipped';

SELECT COUNT(*) AS shipped_orders
FROM orders
WHERE order_status = 'shipped'
    AND order_purchase_timestamp >= '2017-01-01'
    AND order_purchase_timestamp <  '2018-09-01';

-- 1097. По всей таблице 1107. Разница в 10 заказов: 9 куплены в 2016 году
-- (проверка 6, распределение по годам), 1 — в сентябре 2018 (проверка 5,
-- тот самый единственный заказ в пути из двадцати). Оба за границами периода.

WITH days_passed_orders AS (
	SELECT order_id,
		EXTRACT(DAY FROM (
			(SELECT MAX(order_purchase_timestamp) FROM orders) - order_purchase_timestamp
		)) AS days_passed
	FROM orders
	WHERE order_status = 'shipped'
)
SELECT MIN(days_passed) AS min_days_passed,
	ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY days_passed)::numeric, 0) AS median_days_passed,
	ROUND(AVG(days_passed)::numeric, 0) AS avg_days_passed,
	MAX(days_passed) AS max_days_passed
FROM days_passed_orders;

-- Распределение зависших заказов по годам покупки

SELECT EXTRACT(YEAR FROM order_purchase_timestamp) AS year,
	COUNT(*) AS shipped_orders
FROM orders
WHERE order_status = 'shipped'
GROUP BY 1
ORDER BY 1;

-- ВЫВОД

-- 1107 заказов (1.1%) в статусе shipped: отгружены, вручение не
-- зафиксировано. Время с момента покупки до конца периода данных:
-- минимум 44 дня, медиана 283, среднее 315, максимум 772.

-- ЦЕНЗУРИРОВАНИЯ В ДАННЫХ НЕТ. Если бы это были заказы в пути на
-- момент выгрузки, они сидели бы в последних днях периода — день,
-- два, неделя с момента покупки. Минимум 44 дня означает, что
-- заказов, отгруженных в последние шесть недель, в данных нет
-- вообще. Это согласуется с проверкой 5: выгрузка включает только
-- заказы, достигшие конечного состояния, поэтому свежие заказы
-- "в пути" в неё не попали.

-- Заказ, отгруженный 283 дня назад и не доставленный, не едет —
-- он потерян, возвращён без оформления или факт вручения не
-- записан. Это зависшие заказы, а не заказы в пути.

-- Следствие: отрезать последние недели периода не требуется,
-- метрики сроков можно считать по всему рабочему периоду.

-- Смещение всё же остаётся, но другого рода: заказы,
-- которые не доехали никогда, то есть заведомо худшие случаи,
-- 1107 по таблице, 1097 внутри периода. Они
-- выпадают из расчёта времени доставки, значит реальная картина
-- хуже посчитанной. Доля 1.1%, на медиану не влияет, но в выводах
-- указывается.

-- Распределение по годам покупки: 9 заказов 2016 года, 530 — 2017,
-- 568 — 2018. Зависшие заказы встречаются во всём периоде
-- равномерно, а не скапливаются в конце — ещё одно подтверждение,
-- что дело не в цензурировании.


-- ============================================================
-- ИТОГ ЭТАПА: РАБОЧАЯ ВЫБОРКА
-- ============================================================

-- Период: покупки с 2017-01-01 по 2018-08-29 включительно
-- (2018-08-29 15:00 — последняя покупка в данных), 20 месяцев.
-- В коде фильтр пишется как order_purchase_timestamp < '2018-09-01'.
-- Сравнение с '2018-08-31' отрезало бы весь последний день: правая
-- часть приводится к 2018-08-31 00:00:00.

-- Статус: delivered — единственный, где заполнена дата вручения.

-- Размер выборки:
--     96 478  заказов delivered
--   −      8  без order_delivered_customer_date (проверка 2)
--   −    267  куплены до 2017-01-01 (хвост 2016 года, проверка 5)
--   = 96 203

-- Отдельные интервалы считаются не по всей выборке. Строка при этом
-- не исключается: обнуляется только непригодный интервал, остальные
-- метрики по заказу остаются в расчёте.
--
--   оплата → отгрузка — значения нет у 1365 заказов:
--     1350  carrier < approved
--       14  без order_approved_at
--        1  без order_delivered_carrier_date
--     По всей таблице orders нарушений carrier < approved 1359
--     (проверка 3). Недостающие 9 — в статусе shipped, в выборку
--     они не входят.
--
--   отгрузка → вручение — значения нет у 20 заказов:
--       19  customer < carrier
--        1  без order_delivered_carrier_date (тот же заказ)
--     По всей таблице таких нарушений 23 (проверка 3). Ещё 4 — в
--     хвосте 2016 года.
--
--   Интервал покупка → отгрузка (166 нарушений carrier < purchase
--   по всей таблице) не рассчитывается: для метрик SLA он не нужен.

-- Выборка реализована представлением delivered_orders
-- в sql/02_sla_overview.sql.

-- Известные ограничения выборки:
--   1097 зависших заказов не доехали и в расчёт сроков не попадают —
--   реальные сроки хуже посчитанных. По всей таблице их 1107.
--   789 отзывов (0.8%) относятся к нескольким заказам сразу —
--   привязка оценки к конкретному опозданию приблизительна.


-- Проверка арифметики выборки

SELECT
    (SELECT COUNT(*) FROM orders
     WHERE order_status = 'delivered'
       AND order_delivered_customer_date IS NOT NULL)        AS delivered_ok,
    (SELECT COUNT(*) FROM orders
     WHERE order_status = 'delivered'
       AND order_delivered_customer_date IS NOT NULL
       AND order_purchase_timestamp < '2017-01-01')          AS before_period,
    (SELECT MAX(order_purchase_timestamp) FROM orders
     WHERE order_status = 'delivered')                       AS last_purchase;

-- 96470 / 267 / 2018-08-29 15:00.
-- 96470 − 267 = 96203 — совпадает с размером delivered_orders.