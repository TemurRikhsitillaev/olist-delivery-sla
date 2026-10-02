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

-- Статус shipped (1107 заказов, 1.1%) — отдельный объект: заказы
-- в пути на момент выгрузки. Это цензурирование, разбор в
-- проверке 6.

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
		COUNT(*) FILTER (WHERE order_delivered_customer_date IS NOT NULL AND order_delivered_carrier_date IS NOT NULL) AS customer_count
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
	ROUND(customer_to_carrier::numeric / NULLIF(customer_count, 0) * 100, 3) AS customer_to_carrier_pct
FROM checks;

-- Нарушений approved < purchase нет.

-- carrier < approved: 1359 из 97644 (1.39%). Заказ передан
-- перевозчику раньше, чем подтверждён платёж. Две версии:
-- задержка записи о платеже либо отгрузка по авторизации, не
-- дожидаясь проводки (вероятно для boleto). Различать по величине
-- разрыва и типу платежа. На общее время доставки не влияет —
-- исключаем только из расчёта интервала "оплата → отгрузка".

-- customer < carrier: 23 из 96475 (0.024%). Дата отгрузки
-- записана позже даты вручения. Артефакт логирования. Исключаем
-- из расчёта времени в пути: длительность вышла бы отрицательной.


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







