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








