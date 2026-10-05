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


-- ------------------------------------------------------------
-- 2. РАСПРЕДЕЛЕНИЕ ВРЕМЕНИ ДОСТАВКИ
-- ------------------------------------------------------------

WITH bucketed AS (
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
		END AS bucket_no
	FROM delivered_orders
)

SELECT bucket,
	COUNT(*) AS orders,
	ROUND(COUNT(*)::numeric / SUM(COUNT(*)) OVER () * 100, 2) AS pct,
	ROUND(SUM(COUNT(*)) OVER (ORDER BY bucket_no)::numeric / SUM(COUNT(*)) OVER () * 100, 2) AS cum_pct
FROM bucketed
GROUP BY bucket_no, bucket
ORDER BY bucket_no;

-- 0-3   : orders  6952,  pct  7.23,  cum_pct   7.23
-- 4-7   : orders 23708,  pct 24.64,  cum_pct  31.87
-- 8-14  : orders 37899,  pct 39.39,  cum_pct  71.26
-- 15-23 : orders 18573,  pct 19.31,  cum_pct  90.57
-- 24-30 : orders  4824,  pct  5.01,  cum_pct  95.59
-- 31-60 : orders  3952,  pct  4.11,  cum_pct  99.69
-- 61+   : orders   295,  pct  0.31,  cum_pct 100.00

-- Накопленная доля на границе 23 дня — 90.57%, что совпадает с p90 = 23
-- из первой задачи: два независимых расчёта сошлись.

-- ВЫВОД

-- Самый большой процент заказов в корзине 8-14, почти 40% (37899).
-- Из предыдущих вычислений мы знаем, что типичный заказ занимает 10 дней
-- на выполнение всего цикла. Эти 10 дней лежат в промежутке этой корзины.
-- Также среднее 12.5 дней, тоже в промежутке этой корзины. А также
-- 7 заказов из 10 доезжают за 2 недели. В этой корзине самый большой
-- процент (концентрация), а это означает предсказуемость, предсказуемость
-- меняет вопрос из "почему всё плохо?" на "чем отличается хвост?".

-- Слева корзина 0-3 (промежуток 4 дня), доля от общего 7.23% (6952 заказов).
-- Это самые быстро выполненные заказы. Скорее всего это из-за
-- географического местоположения клиента и продавца (склада). Левый край
-- задаёт нижнюю границу того, что компания в принципе может обещать
-- массовому покупателю. Цикл состоит из подтверждения оплаты, сборки,
-- передачи перевозчику и перевозки, и каждый шаг отнимает время, которое
-- нельзя обнулить. Распределение выходит на пик за неделю, а спадает
-- в течение полугода: подъём короткий, хвост длинный.

-- Справа корзины 31-60 и 61+. Доля 31-60 составляет 4.11% (3952) от общего, а 61+ составляет 0.31% (295) от общего.
-- Плотность по корзинам: 15–23 — 2.15% на день, 24–30 — 0.72%, 31–60 — 0.14%, 61+ — 0.002%. Соотношение 3 -> 5 -> 70,
-- у обычного длинного хвоста плотность падает примерно в одно и то же число раз на каждом шаге, а здесь падение разгоняется.
-- Стоит также упомянуть, что заказы, которые долго проходят весь цикл, чаще всего не доезжают, те самые
-- заказы, которые находятся в статусе shipped (1107), где медиана 283 дня. В выборке только заказы, дошедшие до вручения: видимая часть хвоста —
-- 295 заказов в корзине 61+, невидимая — 1107 недоехавших. В реальности хвост тяжелее.

-- Если брать медиану, тогда половина заказов будет опаздывать.
-- Если компания хочет укладываться в 90% случаев, тогда доставка 23 дня.
-- Если компания хочет укладываться в 95% случаев, тогда доставка 30 дней.
-- Если компания хочет укладываться в 99.7% случаев, тогда доставка 60 дней.
-- В сравнении 23 и 30 дней: разница 7 дней за 5.02 процентных пункта,
-- то есть 1.4 дня на пункт.
-- В сравнении 30 и 60 дней: разница 30 дней за 4.10 процентных пункта,
-- то есть 7.3 дня на пункт.
-- Каждый пункт надёжности до 30 дней обходится примерно впятеро дешевле,
-- чем после.
-- 30 дней — точка перелома: дальше каждый пункт надёжности стоит
-- непропорционально дорого. Окончательный выбор зависит от того,
-- сколько компания теряет на опоздании и сколько — на длинном сроке
-- в карточке товара; этих данных в выборке нет.


-- ------------------------------------------------------------
-- 3. НАСКОЛЬКО ОПАЗДЫВАЮТ ТЕ, КТО ОПАЗДЫВАЕТ
-- ------------------------------------------------------------

WITH bucketed AS (
	SELECT
		CASE
			WHEN days_vs_estimate BETWEEN 1 AND 3 THEN '1-3'
			WHEN days_vs_estimate BETWEEN 4 AND 7 THEN '4-7'
			WHEN days_vs_estimate BETWEEN 8 AND 14 THEN '8-14'
			WHEN days_vs_estimate BETWEEN 15 AND 23 THEN '15-23'
			WHEN days_vs_estimate BETWEEN 24 AND 30 THEN '24-30'
			WHEN days_vs_estimate BETWEEN 31 AND 60 THEN '31-60'
			ELSE '61+'
		END AS bucket,
		CASE
			WHEN days_vs_estimate BETWEEN 1 AND 3 THEN 1
			WHEN days_vs_estimate BETWEEN 4 AND 7 THEN 2
			WHEN days_vs_estimate BETWEEN 8 AND 14 THEN 3
			WHEN days_vs_estimate BETWEEN 15 AND 23 THEN 4
			WHEN days_vs_estimate BETWEEN 24 AND 30 THEN 5
			WHEN days_vs_estimate BETWEEN 31 AND 60 THEN 6
			ELSE 7
		END AS bucket_no,
		days_vs_estimate
	FROM delivered_orders
	WHERE is_late
)

SELECT bucket,
	COUNT(*) AS orders,
	ROUND(COUNT(*) ::numeric / SUM(COUNT(*)) OVER () * 100, 2) AS pct,
	SUM(COUNT(*)) OVER (ORDER BY bucket_no) AS cum_orders,
	ROUND(SUM(COUNT(*)) OVER (ORDER BY bucket_no) ::numeric / SUM(COUNT(*)) OVER () * 100, 2) AS cum_pct,
	ROUND(COUNT(*)::numeric / (SELECT COUNT(*) FROM delivered_orders) * 100, 2) AS pct_of_all
FROM bucketed
GROUP BY bucket_no, bucket
ORDER BY bucket_no;

-- SELECT
-- 	PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY days_vs_estimate) AS median,
-- 	PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY days_vs_estimate) AS p90,
-- 	MAX(days_vs_estimate) AS max_days_vs_estimate
-- FROM bucketed;

-- Дальше все доли считаются от 6531 опоздавшего заказа.
-- Самая большая доля опозданий в первые 3 дня (28.62% - 1869). Дальше начинается спад.
-- Половина опоздавших заказов уложились в 7 дней. 9 из 10 опоздавших заказов уложились в 22 дня или меньше (p90 - 22).
-- 79 заказов опоздали на 2 месяца и больше, максимум 188 дней, и это только те, которые доехали. Кроме того,
-- 1107 заказов не доехали вовсе и в таблицу не попали; самые тяжёлые случаи находятся именно там.
-- В пересчёте на всю выборку (96 203 заказа) 3 заказа из 100 приезжают больше чем на неделю позже обещания.
-- Гипотеза о том, что опоздания в основном незначительные, не подтвердилась. Чуть меньше трети укладываются в три дня,
-- а больше 2 недель опаздывают 1382 заказа - это 21% опозданий и 1.44% всей выборки. Для компании Olist за 20 месяцев
-- это не единичные случаи, а регулярно воспроизводящийся сбой.




