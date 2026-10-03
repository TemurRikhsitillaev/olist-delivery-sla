-- ============================================================
-- ЭТАП 3. МЕТРИКИ SLA
-- ============================================================
-- Рабочая выборка определена и обоснована в 01_data_quality.sql.
-- Этот файл создаёт представление delivered_orders; файлы 03-06
-- на него опираются, поэтому выполнять его надо до них.


-- ------------------------------------------------------------
-- ПРЕДСТАВЛЕНИЕ
-- ------------------------------------------------------------

DROP VIEW IF EXISTS delivered_orders;

CREATE VIEW delivered_orders AS
	SELECT o.order_id,
		c.customer_state,
		c.customer_city,
		o.order_purchase_timestamp,
		o.order_approved_at,
		o.order_delivered_carrier_date,
		o.order_delivered_customer_date,
		o.order_estimated_delivery_date,
		DATE_TRUNC('month', o.order_purchase_timestamp)::date AS purchase_month,

		-- Сравнение с обещанием: обе части приведены к дате, потому что
		-- order_estimated_delivery_date всегда имеет время 00:00:00.
		o.order_delivered_customer_date::date > o.order_estimated_delivery_date::date AS is_late,
		o.order_delivered_customer_date::date - o.order_estimated_delivery_date::date AS days_vs_estimate, -- плюс — опоздание, минус — запас

		-- Две меры общего срока, разного назначения:
		--   delivery_days — целые календарные дни, для сравнения с обещанной датой
		--   cycle_days    — дробные дни, для сопоставления с длительностями этапов
		o.order_delivered_customer_date::date - o.order_purchase_timestamp::date AS delivery_days,
		EXTRACT(EPOCH FROM (o.order_delivered_customer_date - o.order_purchase_timestamp)) / 86400 AS cycle_days,

		-- Этапы цикла. CASE без ELSE обнуляет интервал с нарушенной
		-- хронологией: заказ остаётся в выборке, непригоден только этот
		-- интервал. AVG и PERCENTILE_CONT пропускают NULL сами.
		EXTRACT(EPOCH FROM (o.order_approved_at - o.order_purchase_timestamp)) / 3600 AS approve_hours,

		CASE
			WHEN o.order_delivered_carrier_date >= o.order_approved_at
				THEN EXTRACT(EPOCH FROM (o.order_delivered_carrier_date - o.order_approved_at)) / 86400
		END AS handover_days,

		CASE
			WHEN o.order_delivered_customer_date >= o.order_delivered_carrier_date
				THEN EXTRACT(EPOCH FROM (o.order_delivered_customer_date - o.order_delivered_carrier_date)) / 86400
		END AS transit_days

	FROM orders AS o
		JOIN customers AS c ON o.customer_id = c.customer_id
	WHERE o.order_status = 'delivered'
		AND o.order_delivered_customer_date IS NOT NULL
		AND o.order_purchase_timestamp >= '2017-01-01'
		AND o.order_purchase_timestamp <  '2018-09-01';  -- не '<= 2018-08-31': отрезало бы весь последний день


-- ------------------------------------------------------------
-- ПРОВЕРКА ПРЕДСТАВЛЕНИЯ
-- ------------------------------------------------------------

SELECT COUNT(*)                                                                             AS total,
       COUNT(*) FILTER (WHERE order_approved_at IS NULL)                                    AS approved_null,
       COUNT(*) FILTER (WHERE order_delivered_carrier_date IS NULL)                         AS carrier_null,
       COUNT(*) FILTER (WHERE order_delivered_carrier_date < order_approved_at)             AS handover_bad,
       COUNT(*) FILTER (WHERE order_delivered_customer_date < order_delivered_carrier_date) AS transit_bad,
       COUNT(*) - COUNT(handover_days)                                                      AS handover_null,
       COUNT(*) - COUNT(transit_days)                                                       AS transit_null,
       COUNT(*) FILTER (WHERE approve_hours < 0)                                            AS approve_negative
FROM delivered_orders;

-- Ожидается: 96203 / 14 / 1 / 1350 / 19 / 1365 / 20 / 0.
-- Сходимость: 1350 + 14 + 1 = 1365 (handover), 19 + 1 = 20 (transit).
-- Расхождение означает, что изменилось представление или данные.


-- ------------------------------------------------------------
-- 1. ОБЩАЯ КАРТИНА
-- ------------------------------------------------------------

SELECT
	COUNT(*) AS orders_count,
	COUNT(*) FILTER (WHERE is_late) AS late_orders_count,
	ROUND(COUNT(*) FILTER (WHERE is_late)::numeric / COUNT(*) * 100, 2) AS late_orders_pct,
	ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY delivery_days)::numeric, 2) AS median_delivery_days,
	ROUND(PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY delivery_days)::numeric, 2) AS p90_delivery_days,
	ROUND(AVG(delivery_days)::numeric, 2) AS avg_delivery_days,
	MIN(delivery_days) AS min_delivery_days,
	MAX(delivery_days) AS max_delivery_days
FROM delivered_orders;

-- ВЫВОД

-- Всего заказов 96203, из них 6531 опоздавших, это составляет 6.79%
-- от общего количества заказов.
-- 6.79% — нижняя граница: 1107 заказов не доехали вообще и в расчёт
-- не попали, поэтому реальная доля нарушенных обещаний выше.
-- Среднее 12.5 дня — верно и полезно для объёмных расчётов.
-- Типичный срок — 10 дней, это медиана. Среднее завышено длинным правым
-- хвостом: 62% заказов укладываются быстрее среднего, то есть большинство
-- покупателей ждут меньше, чем «средний» срок обещает.
-- Отношение среднего к медиане равно 1.25 — умеренная асимметрия вправо.
-- Каждый десятый заказ едет 23 дня или дольше — больше чем вдвое против
-- типичного.
-- Есть заказы с нулевым циклом и заказы длиной до 210 дней, природа
-- не выяснена.
-- Доля заказов, где перевозка занимает основную часть цикла, у опоздавших
-- в два с половиной раза выше (45.6% против 18.6%), но разница может
-- объясняться просто большей длиной этих заказов — проверка стратификацией
-- в разборе по этапам.