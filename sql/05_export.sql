-- ============================================================
-- ЭТАП 6. ВЫГРУЗКА ДЛЯ ДАШБОРДА
-- ============================================================
--
-- Что здесь: три листа для Google Sheets и блок проверок.
--
-- База: заказы, доехавшие до клиента, с 2017-01-01 до 2018-09-01,
-- всего 96 203 заказа.
--
-- Ограничения:
-- 1 097 заказов так и не доехали и в расчёт сроков не попали —
-- реальные сроки хуже посчитанных.
-- Август 2018 — последний месяц выгрузки, и он неполный, поэтому
-- последняя точка на графике по месяцам выглядит лучше, чем было
-- на самом деле.
--
-- 1. Плоская таблица по заказам — неагрегированный лист с данными на уровне
--    заказа, по нему строятся распределения и любые разрезы.
-- 2. Сводка по месяцам — как менялась доля опозданий и сроки от месяца к месяцу.
-- 3. Сводка по штатам — географическая ось: где сроки хуже, где ниже оценка.
-- 4. Проверки — сверка итогов трёх листов между собой и с источником.
--
-- ============================================================


-- ------------------------------------------------------------
-- 1. ПЛОСКАЯ ТАБЛИЦА ПО ЗАКАЗАМ
-- ------------------------------------------------------------

WITH by_last_review AS (
	SELECT *,
		ROW_NUMBER() OVER (PARTITION BY order_id ORDER BY review_creation_date DESC, review_id DESC) AS rn
	FROM order_reviews
),
reviews_by_order AS (
	SELECT order_id, review_id, review_score, review_creation_date
	FROM by_last_review
	WHERE rn = 1
),
delivery_bucket AS (
	SELECT
		CASE
			WHEN delivery_days <= 3 THEN '0-3'
			WHEN delivery_days BETWEEN 4 AND 7 THEN '4-7'
			WHEN delivery_days BETWEEN 8 AND 14 THEN '8-14'
			WHEN delivery_days BETWEEN 15 AND 23 THEN '15-23'
			WHEN delivery_days BETWEEN 24 AND 30 THEN '24-30'
			WHEN delivery_days BETWEEN 31 AND 60 THEN '31-60'
			ELSE '61+'
		END AS bucket,
		CASE
			WHEN delivery_days <= 3 THEN 1
			WHEN delivery_days BETWEEN 4 AND 7 THEN 2
			WHEN delivery_days BETWEEN 8 AND 14 THEN 3
			WHEN delivery_days BETWEEN 15 AND 23 THEN 4
			WHEN delivery_days BETWEEN 24 AND 30 THEN 5
			WHEN delivery_days BETWEEN 31 AND 60 THEN 6
			ELSE 7
		END AS bucket_no,
		order_id, purchase_month, customer_state, delivery_days, days_vs_estimate, is_late,
		order_estimated_delivery_date::date - order_purchase_timestamp::date AS promise_days
	FROM delivered_orders
)

SELECT d.order_id, d.purchase_month, d.customer_state, d.delivery_days, d.days_vs_estimate,
	d.is_late, d.promise_days, r.review_score, d.bucket, d.bucket_no
FROM delivery_bucket AS d
	LEFT JOIN reviews_by_order AS r ON d.order_id = r.order_id;

-- Результат: 96 203 строки.
-- Одна строка — один доставленный заказ; столбцы: сроки, обещание, признак
-- опоздания, корзина срока и оценка.
--
-- LEFT JOIN используется вместо INNER JOIN, чтобы строки не отбрасывались:
-- заказ, которому не нашлось пары в reviews_by_order, просто не попал бы
-- в результат. Таких заказов 643 — при INNER JOIN в листе осталось бы
-- 95 560 строк, и он перестал бы сходиться с двумя другими и с блоком
-- проверок.


-- ------------------------------------------------------------
-- 2. СВОДКА ПО МЕСЯЦАМ
-- ------------------------------------------------------------

WITH by_last_review AS (
	SELECT *,
		ROW_NUMBER() OVER (PARTITION BY order_id ORDER BY review_creation_date DESC, review_id DESC) AS rn
	FROM order_reviews
),
reviews_by_order AS (
	SELECT order_id, review_id, review_score, review_creation_date
	FROM by_last_review
	WHERE rn = 1
)

SELECT
	d.purchase_month,
	COUNT(*) AS orders_count,
	COUNT(*) FILTER (WHERE d.is_late) AS late_orders_count,
	ROUND(COUNT(*) FILTER (WHERE d.is_late)::numeric / COUNT(*) * 100, 2) AS late_orders_pct,
	ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY d.delivery_days)::numeric, 2) AS median_delivery_days,
	ROUND(PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY d.delivery_days)::numeric, 2) AS p90_delivery_days,
	ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (
		ORDER BY d.order_estimated_delivery_date::date - d.order_purchase_timestamp::date
	)::numeric, 2) AS median_promise_days,
	ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (
		ORDER BY d.order_estimated_delivery_date::date - d.order_purchase_timestamp::date
	)::numeric, 0)
	- ROUND(PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY d.delivery_days)::numeric, 0)
	AS cushion_days,
	COUNT(r.review_score) AS reviews_count,
	ROUND(AVG(r.review_score)::numeric, 2) AS avg_review_score,
	ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY r.review_score)::numeric, 2) AS median_review_score
FROM delivered_orders AS d
	LEFT JOIN reviews_by_order AS r ON d.order_id = r.order_id
GROUP BY d.purchase_month
ORDER BY d.purchase_month;

-- Результат: 20 строк, январь 2017 — август 2018.
--
-- month   | orders | late | late_% | med_dlv | p90_dlv | med_prom | cushion | reviews | avg_rev | med_rev
-- --------+--------+------+--------+---------+---------+----------+---------+---------+---------+--------
-- 2017-01 |    750 |   22 |   2.93 |      11 |      19 |       39 |      20 |     741 |    4.20 |    5.00
-- 2017-02 |   1653 |   49 |   2.96 |      11 |      22 |       31 |       9 |    1643 |    4.20 |    5.00
-- 2017-03 |   2546 |  116 |   4.56 |      10 |      21 |       23 |       2 |    2527 |    4.19 |    5.00
-- 2017-04 |   2303 |  151 |   6.56 |      13 |      25 |       26 |       1 |    2290 |    4.14 |    5.00
-- 2017-05 |   3545 |  106 |   2.99 |      10 |      19 |       24 |       5 |    3517 |    4.24 |    5.00
-- 2017-06 |   3135 |   95 |   3.03 |      11 |      20 |       24 |       4 |    3111 |    4.22 |    5.00
-- 2017-07 |   3872 |  108 |   2.79 |      10 |      20 |       24 |       4 |    3842 |    4.26 |    5.00
-- 2017-08 |   4193 |  122 |   2.91 |      10 |      19 |       23 |       4 |    4165 |    4.31 |    5.00
-- 2017-09 |   4150 |  182 |   4.39 |      10 |      20 |       23 |       3 |    4118 |    4.27 |    5.00
-- 2017-10 |   4478 |  187 |   4.18 |      10 |      20 |       23 |       3 |    4446 |    4.21 |    5.00
-- 2017-11 |   7288 |  904 |  12.40 |      13 |      27 |       23 |      -4 |    7237 |    3.99 |    5.00
-- 2017-12 |   5513 |  411 |   7.46 |      13 |      28 |       28 |       0 |    5461 |    4.09 |    5.00
-- 2018-01 |   7069 |  403 |   5.70 |      12 |      25 |       26 |       1 |    7013 |    4.11 |    5.00
-- 2018-02 |   6555 |  926 |  14.13 |      14 |      31 |       25 |      -6 |    6507 |    3.88 |    5.00
-- 2018-03 |   7003 | 1328 |  18.96 |      13 |      32 |       22 |     -10 |    6948 |    3.81 |    5.00
-- 2018-04 |   6798 |  306 |   4.50 |       9 |      21 |       24 |       3 |    6752 |    4.21 |    5.00
-- 2018-05 |   6749 |  443 |   6.56 |       9 |      21 |       22 |       1 |    6722 |    4.24 |    5.00
-- 2018-06 |   6096 |   71 |   1.16 |       8 |      16 |       28 |      12 |    6072 |    4.31 |    5.00
-- 2018-07 |   6156 |  208 |   3.38 |       7 |      16 |       20 |       4 |    6118 |    4.32 |    5.00
-- 2018-08 |   6351 |  393 |   6.19 |       7 |      13 |       14 |       1 |    6330 |    4.31 |    5.00
--
-- Сходится: 96 203 заказа, 6 531 опоздание, 6.79% — те же числа, что в 02.
-- Отзывов 95 560, то есть 643 заказа без отзыва (04).
--
-- cushion_days = median_promise_days − p90_delivery_days: насколько типичное
-- обещание месяца перекрывает медленный хвост фактической доставки. Ноль —
-- граница; минус означает, что обещание хвост уже не перекрывает.
-- Это индикатор, а не доля опозданий.


-- ------------------------------------------------------------
-- 3. СВОДКА ПО ШТАТАМ
-- ------------------------------------------------------------

WITH by_last_review AS (
	SELECT *,
		ROW_NUMBER() OVER (PARTITION BY order_id ORDER BY review_creation_date DESC, review_id DESC) AS rn
	FROM order_reviews
),
reviews_by_order AS (
	SELECT order_id, review_id, review_score, review_creation_date
	FROM by_last_review
	WHERE rn = 1
)

SELECT
	d.customer_state,
	COUNT(*) AS orders_count,
	COUNT(*) FILTER (WHERE d.is_late) AS late_orders_count,
	ROUND(COUNT(*) FILTER (WHERE d.is_late)::numeric / COUNT(*) * 100, 2) AS late_orders_pct,
	ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY d.delivery_days)::numeric, 2) AS median_delivery_days,
	ROUND(PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY d.delivery_days)::numeric, 2) AS p90_delivery_days,
	ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (
		ORDER BY d.order_estimated_delivery_date::date - d.order_purchase_timestamp::date
	)::numeric, 2) AS median_promise_days,
	COUNT(r.review_score) AS reviews_count,
	ROUND(AVG(r.review_score)::numeric, 2) AS avg_review_score,
	ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY r.review_score)::numeric, 2) AS median_review_score
FROM delivered_orders AS d
	LEFT JOIN reviews_by_order AS r ON d.order_id = r.order_id
GROUP BY d.customer_state
ORDER BY orders_count DESC, d.customer_state;

-- Результат: 27 строк, отсортировано по числу заказов.
--
-- state | orders | late | late_% | med_dlv | p90_dlv | med_prom | reviews | avg_rev | med_rev
-- ------+--------+------+--------+---------+---------+----------+---------+---------+--------
-- SP    |  40399 | 1817 |   4.50 |       7 |      16 |       19 |   40171 |    4.25 |    5.00
-- RJ    |  12310 | 1495 |  12.14 |      12 |      29 |       25 |   12172 |    3.97 |    5.00
-- MG    |  11319 |  519 |   4.59 |      10 |      20 |       24 |   11251 |    4.19 |    5.00
-- RS    |   5327 |  325 |   6.10 |      13 |      26 |       29 |    5309 |    4.19 |    5.00
-- PR    |   4903 |  199 |   4.06 |      10 |      20 |       25 |    4880 |    4.24 |    5.00
-- SC    |   3537 |  291 |   8.23 |      13 |      26 |       26 |    3510 |    4.13 |    5.00
-- BA    |   3253 |  396 |  12.17 |      17 |      32 |       30 |    3226 |    3.93 |    5.00
-- DF    |   2074 |  118 |   5.69 |      11 |      22 |       25 |    2064 |    4.13 |    5.00
-- ES    |   1992 |  214 |  10.74 |      14 |      25 |       26 |    1966 |    4.08 |    5.00
-- GO    |   1950 |  128 |   6.56 |      14 |      25 |       27 |    1939 |    4.10 |    5.00
-- PE    |   1587 |  153 |   9.64 |      16 |      31 |       32 |    1573 |    4.08 |    5.00
-- CE    |   1273 |  176 |  13.83 |      18 |   34.80 |       32 |    1267 |    3.94 |    5.00
-- PA    |    942 |  106 |  11.25 |      21 |      39 |       37 |     929 |    3.91 |    5.00
-- MT    |    885 |   53 |   5.99 |      16 |      28 |       32 |     878 |    4.14 |    5.00
-- MA    |    713 |  125 |  17.53 |      19 |      34 |       31 |     709 |    3.83 |    4.00
-- MS    |    701 |   68 |   9.70 |      14 |      25 |       26 |     699 |    4.16 |    5.00
-- PB    |    516 |   54 |  10.47 |      18 |      35 |       33 |     511 |    4.07 |    5.00
-- PI    |    475 |   66 |  13.89 |      16 |      30 |       30 |     470 |    3.99 |    5.00
-- RN    |    470 |   44 |   9.36 |      16 |   32.10 |       32 |     467 |    4.14 |    5.00
-- AL    |    396 |   85 |  21.46 |      22 |   39.50 |       32 |     393 |    3.85 |    4.00
-- SE    |    332 |   51 |  15.36 |      18 |      35 |       30 |     331 |    3.90 |    5.00
-- TO    |    274 |   27 |   9.85 |      16 |      28 |       29 |     273 |    4.15 |    5.00
-- RO    |    243 |    7 |   2.88 |      18 |      29 |       38 |     242 |    4.17 |    5.00
-- AM    |    145 |    4 |   2.76 |      26 |      39 |       46 |     144 |    4.24 |    5.00
-- AC    |     80 |    3 |   3.75 |      18 |   31.20 |       41 |      80 |    4.09 |    5.00
-- AP    |     67 |    2 |   2.99 |      25 |   34.40 |       48 |      66 |    4.24 |    5.00
-- RR    |     40 |    5 |  12.50 |      25 |   53.10 |       45 |      40 |    3.90 |    4.50
--
-- Сходится: 96 203 заказа, 6 531 опоздание, 6.79%, 95 560 отзывов.
-- На три штата (SP, RJ, MG) приходится 66.6% всех заказов.
--
-- В штатах RR и AP заказов 40 и 67 — они не сопоставимы с SP, где заказов
-- 40 399. В RR один заказ стоит 2.5 процентных пункта: одна задержавшаяся
-- партия двигает долю с 12.5% до 20%. В SP один заказ стоит 0.0025 пункта.
-- Поэтому разница между 12.5% и 20% в RR может не значить ничего, а в SP
-- такая же разница — это полторы тысячи заказов. В дашборде надо смотреть
-- на orders_count рядом с долей.


-- ------------------------------------------------------------
-- 4. ПРОВЕРКИ
-- ------------------------------------------------------------
-- Запросы по месяцам и по штатам продублированы из блоков 2 и 3.
-- При правке блоков править и здесь.

WITH by_last_review AS (
	SELECT *,
		ROW_NUMBER() OVER (PARTITION BY order_id ORDER BY review_creation_date DESC, review_id DESC) AS rn
	FROM order_reviews
),
reviews_by_order AS (
	SELECT order_id, review_id, review_score, review_creation_date
	FROM by_last_review
	WHERE rn = 1
),
delivery_bucket AS (
	SELECT
		order_id, purchase_month, customer_state, delivery_days, days_vs_estimate, is_late,
		order_estimated_delivery_date::date - order_purchase_timestamp::date AS promise_days
	FROM delivered_orders
),
by_month AS (
	SELECT
		d.purchase_month,
		COUNT(*) AS orders_count,
		COUNT(*) FILTER (WHERE d.is_late) AS late_orders_count
	FROM delivered_orders AS d
		LEFT JOIN reviews_by_order AS r ON d.order_id = r.order_id
	GROUP BY d.purchase_month
),
by_state AS (
	SELECT
		d.customer_state,
		COUNT(*) AS orders_count,
		COUNT(*) FILTER (WHERE d.is_late) AS late_orders_count
	FROM delivered_orders AS d
		LEFT JOIN reviews_by_order AS r ON d.order_id = r.order_id
	GROUP BY d.customer_state
)

-- Ожидание: 96203 / 6531 / 6.79
SELECT 'flat table of orders' AS check_name,
	COUNT(*) AS orders_count,
	COUNT(*) FILTER (WHERE d.is_late) AS late_orders_count,
	ROUND(COUNT(*) FILTER (WHERE d.is_late)::numeric / COUNT(*) * 100, 2) AS late_orders_pct
FROM delivery_bucket AS d
	LEFT JOIN reviews_by_order AS r ON d.order_id = r.order_id

UNION ALL

-- Ожидание: 96203 / 6531 / 6.79
SELECT 'total by month',
	SUM(orders_count),
	SUM(late_orders_count),
	ROUND(SUM(late_orders_count)::numeric / SUM(orders_count) * 100, 2)
FROM by_month

UNION ALL

-- Ожидание: 96203 / 6531 / 6.79
SELECT 'total by state',
	SUM(orders_count),
	SUM(late_orders_count),
	ROUND(SUM(late_orders_count)::numeric / SUM(orders_count) * 100, 2)
FROM by_state

UNION ALL

-- Ожидание: 96203 / 6531 / 6.79
SELECT 'delivered_orders',
	COUNT(*),
	COUNT(*) FILTER (WHERE is_late),
	ROUND(COUNT(*) FILTER (WHERE is_late)::numeric / COUNT(*) * 100, 2)
FROM delivered_orders;

-- Результат:
-- check_name           | orders_count | late_orders_count | late_orders_pct
-- ---------------------+--------------+-------------------+----------------
-- flat table of orders |        96203 |              6531 |            6.79
-- total by month       |        96203 |              6531 |            6.79
-- total by state       |        96203 |              6531 |            6.79
-- delivered_orders     |        96203 |              6531 |            6.79
--
-- Все четыре строки совпали: три листа согласованы между собой и с источником.
-- Совпадение первой строки с четвёртой доказывает, что LEFT JOIN к отзывам
-- не размножил ни одного заказа — дедупликация по rn = 1 отработала.