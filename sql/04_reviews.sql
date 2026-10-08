-- ============================================================
-- ЭТАП 5. СВЯЗЬ ОПОЗДАНИЙ С ОЦЕНКАМИ
-- ============================================================
-- Опирается на delivered_orders из 02_sla_overview.sql.
-- Вопрос: что покупатель наказывает — нарушенное обещание
-- или медленную доставку.
--
-- Отзывы сворачиваются до одного на заказ (последний по
-- review_creation_date, при равенстве — по review_id). Без свёртки
-- 547 заказов с несколькими отзывами размножились бы при джойне
-- (проверка 4 в 01_data_quality.sql).


-- ------------------------------------------------------------
-- 1. РАСПРЕДЕЛЕНИЕ ОЦЕНОК
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

SELECT r.review_score,
	COUNT(*) AS orders_count,
	ROUND(COUNT(*) / SUM(COUNT(*)) OVER () * 100, 2) AS pct
FROM delivered_orders AS d
	LEFT JOIN reviews_by_order AS r ON d.order_id = r.order_id
GROUP BY r.review_score
ORDER BY r.review_score NULLS LAST;

-- Результат:
--       оценка   заказов      доля
--            1     9 314     9.68%
--            2     2 914     3.03%
--            3     7 897     8.21%
--            4    18 843    19.59%
--            5    56 592    58.83%
--   без отзыва       643     0.67%
--
-- Сумма — 96 203, совпадает с размером выборки: свёртка отзывов
-- не размножила строки.


-- ------------------------------------------------------------
-- 2. ОЦЕНКА У ОПОЗДАВШИХ И НЕОПОЗДАВШИХ
-- ------------------------------------------------------------
-- Дальше база — 95 560 заказов с отзывом: 643 без оценки
-- исключены, усреднять по ним нечего.

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

SELECT d.is_late,
	COUNT(*) AS orders_count,
	ROUND(AVG(r.review_score)::numeric, 2) AS avg_review_score,
	PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY r.review_score) AS median_review_score,
	COUNT(*) FILTER (WHERE r.review_score = 1) AS orders_with_score_1,
	ROUND(COUNT(*) FILTER (WHERE r.review_score = 1)::numeric / COUNT(*) * 100, 2) AS pct_orders_with_score_1,
	COUNT(*) FILTER (WHERE r.review_score = 2) AS orders_with_score_2,
	ROUND(COUNT(*) FILTER (WHERE r.review_score = 2)::numeric / COUNT(*) * 100, 2) AS pct_orders_with_score_2
FROM delivered_orders AS d
	JOIN reviews_by_order AS r ON d.order_id = r.order_id
GROUP BY d.is_late;

-- Результат:
--   группа      заказов   средняя   медиана   оценка 1   оценка 2
--   вовремя      89 182      4.29       5.0      6.60%      2.65%
--   опоздали      6 378      2.27       1.0     53.78%      8.62%
--
-- База — 95 560 заказов с отзывом.


-- ------------------------------------------------------------
-- 3. ОЦЕНКА И ВРЕМЯ ДОСТАВКИ СРЕДИ НЕОПОЗДАВШИХ
-- ------------------------------------------------------------
-- Корзины те же, что в задаче 2 файла 02 — чтобы строки можно было
-- сопоставлять с распределением времени доставки.
-- База — 89 182 неопоздавших заказа с отзывом.

WITH by_last_review AS (
	SELECT *,
		ROW_NUMBER() OVER (PARTITION BY order_id ORDER BY review_creation_date DESC, review_id DESC) AS rn
	FROM order_reviews
),
reviews_by_order AS (
	SELECT order_id, review_id, review_score, review_creation_date
	FROM by_last_review
	WHERE rn = 1
), on_time_bucketed AS (
	SELECT order_id,
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
		END AS bucket_no
	FROM delivered_orders
	WHERE is_late = FALSE
)

SELECT otb.bucket, COUNT(*) AS orders_count,
	ROUND(AVG(r.review_score)::numeric, 2) AS avg_review_score,
	ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY r.review_score)::numeric, 2) AS median_review_score,
	COUNT(*) FILTER (WHERE r.review_score = 1) AS orders_with_score_1,
	ROUND(COUNT(*) FILTER (WHERE r.review_score = 1)::numeric / COUNT(*) * 100, 2) AS pct_orders_with_score_1,
	COUNT(*) FILTER (WHERE r.review_score = 2) AS orders_with_score_2,
	ROUND(COUNT(*) FILTER (WHERE r.review_score = 2)::numeric / COUNT(*) * 100, 2) AS pct_orders_with_score_2
FROM on_time_bucketed AS otb
	JOIN reviews_by_order AS r ON otb.order_id = r.order_id
GROUP BY otb.bucket_no, otb.bucket
ORDER BY otb.bucket_no;

-- Результат:
--   корзина   заказов   средняя   медиана   оценка 1   оценка 2
--   0-3         6 926      4.46         5      5.02%      2.01%
--   4-7        23 516      4.40         5      5.51%      2.17%
--   8-14       37 361      4.31         5      6.42%      2.45%
--   15-23      17 481      4.14         5      8.02%      3.44%
--   24-30       3 104      3.92         4      9.95%      4.64%
--   31-60         792      3.63         4     16.29%      6.82%
--   61+             2      3.00         3     50.00%      0.00%
--
-- База — 89 182 неопоздавших заказа с отзывом, сумма по корзинам сходится.
-- Корзина 61+ — два заказа, выводов по ней не делаем.


-- ------------------------------------------------------------
-- ВЫВОД
-- ------------------------------------------------------------

-- Разбивка по корзинам вовремя доехавших заказов показала что оценка падает с 4.46 до 3.63,
-- а доля плохих отзывов растёт с 7.03% до 23.11%. Медиана оценки держится на пятёрке до 23
-- дней и после падает на четвёрку. Если сдвинуть обещание до 41 дня вместо 23, компания
-- избежит штрафа за нарушение обещания, но получит штраф за медленную доставку. Расширение
-- обещания не решает проблему, а переносит ущерб.

-- Медленная доставка в пределах обещания поднимает долю плохих отзывов на 16 пунктов.
-- Нарушение обещания поднимает долю плохих отзывов с 9.25% до 62.40% (разница примерно 53 пункта).

-- Долгие доставки не случайны - дальние штаты, тяжёлые товары. Эти причины могут сами по себе
-- портить оценку, помимо срока. Значит 16 пунктов - верхняя оценка эффекта, часть разницы
-- может приходиться на сами направления и товары.