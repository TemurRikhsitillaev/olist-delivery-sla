-- =====================================================================
-- Olist Brazilian E-Commerce: схема и загрузка
-- =====================================================================
-- Датасет: https://www.kaggle.com/datasets/olistbr/brazilian-ecommerce
-- Нужен аккаунт Kaggle. Скачай архив, распакуй, запомни путь к папке.
--
-- Порядок работы:
--   1. Создай базу:        CREATE DATABASE olist;
--   2. Подключись к ней:   \c olist
--   3. Выполни DDL ниже
--   4. Выполни блок загрузки (пути относительные, см. ниже)
--   5. Выполни блок проверки
--
-- ВАЖНО: \copy (с обратным слешем) — команда psql, она читает файл
-- на твоей машине. COPY без слеша читает файл на сервере БД и в
-- pgAdmin обычно падает с правами доступа. Поэтому загрузку делай
-- через psql, а не через Query Tool.
-- =====================================================================


-- =====================================================================
-- 1. СХЕМА
-- =====================================================================

DROP TABLE IF EXISTS order_reviews, order_payments, order_items,
                     orders, customers, sellers, products,
                     category_translation CASCADE;


CREATE TABLE customers (
    customer_id              text PRIMARY KEY,
    customer_unique_id       text NOT NULL,
    customer_zip_code_prefix text,
    customer_city            text,
    customer_state           text
);
-- customer_id уникален для заказа, customer_unique_id — реальный человек.
-- Это частая ловушка: считать клиентов по customer_id нельзя.


CREATE TABLE sellers (
    seller_id              text PRIMARY KEY,
    seller_zip_code_prefix text,
    seller_city            text,
    seller_state           text
);


CREATE TABLE products (
    product_id                 text PRIMARY KEY,
    product_category_name      text,
    product_name_length        integer,
    product_description_length integer,
    product_photos_qty         integer,
    product_weight_g           integer,
    product_length_cm          integer,
    product_height_cm          integer,
    product_width_cm           integer
);


CREATE TABLE category_translation (
    product_category_name         text PRIMARY KEY,
    product_category_name_english text
);


CREATE TABLE orders (
    order_id                      text PRIMARY KEY,
    customer_id                   text REFERENCES customers(customer_id),
    order_status                  text,
    order_purchase_timestamp      timestamp,   -- покупка
    order_approved_at             timestamp,   -- оплата подтверждена
    order_delivered_carrier_date  timestamp,   -- передан перевозчику
    order_delivered_customer_date timestamp,   -- вручён клиенту
    order_estimated_delivery_date timestamp    -- обещанная дата
);
-- Четыре даты цикла плюс обещанная. Ядро всего проекта.


CREATE TABLE order_items (
    order_id            text REFERENCES orders(order_id),
    order_item_id       integer,
    product_id          text REFERENCES products(product_id),
    seller_id           text REFERENCES sellers(seller_id),
    shipping_limit_date timestamp,
    price               numeric(10,2),
    freight_value       numeric(10,2),
    PRIMARY KEY (order_id, order_item_id)
);
-- Одна строка = одна позиция заказа. Заказ с тремя позициями даст
-- три строки: помни про дублирование при JOIN с orders.


CREATE TABLE order_payments (
    order_id             text REFERENCES orders(order_id),
    payment_sequential   integer,
    payment_type         text,
    payment_installments integer,
    payment_value        numeric(10,2),
    PRIMARY KEY (order_id, payment_sequential)
);


CREATE TABLE order_reviews (
    review_id               text,
    order_id                text REFERENCES orders(order_id),
    review_score            integer,
    review_comment_title    text,
    review_comment_message  text,
    review_creation_date    timestamp,
    review_answer_timestamp timestamp
);
-- Без PRIMARY KEY намеренно: в данных есть повторяющиеся review_id.
-- Это сам по себе факт для раздела о качестве данных.


-- =====================================================================
-- 2. ЗАГРУЗКА
-- =====================================================================
-- Замени  на свой путь.
-- Порядок важен: сначала справочники, потом orders, потом позиции.

\copy customers           FROM 'olist_customers_dataset.csv'            WITH (FORMAT csv, HEADER true)
\copy sellers             FROM 'olist_sellers_dataset.csv'              WITH (FORMAT csv, HEADER true)
\copy products            FROM 'olist_products_dataset.csv'             WITH (FORMAT csv, HEADER true)
\copy category_translation FROM 'product_category_name_translation.csv' WITH (FORMAT csv, HEADER true)
\copy orders              FROM 'olist_orders_dataset.csv'               WITH (FORMAT csv, HEADER true)
\copy order_items         FROM 'olist_order_items_dataset.csv'          WITH (FORMAT csv, HEADER true)
\copy order_payments      FROM 'olist_order_payments_dataset.csv'       WITH (FORMAT csv, HEADER true)
\copy order_reviews       FROM 'olist_order_reviews_dataset.csv'        WITH (FORMAT csv, HEADER true)

-- Геолокацию (olist_geolocation_dataset.csv, ~1 млн строк) не грузим:
-- для анализа SLA достаточно customer_state.


-- =====================================================================
-- 3. ИНДЕКСЫ
-- =====================================================================
-- Без них запросы по датам и штатам будут заметно медленнее.

CREATE INDEX idx_orders_purchase  ON orders (order_purchase_timestamp);
CREATE INDEX idx_orders_delivered ON orders (order_delivered_customer_date);
CREATE INDEX idx_orders_status    ON orders (order_status);
CREATE INDEX idx_orders_customer  ON orders (customer_id);
CREATE INDEX idx_items_order      ON order_items (order_id);
CREATE INDEX idx_reviews_order    ON order_reviews (order_id);
CREATE INDEX idx_customers_state  ON customers (customer_state);


-- =====================================================================
-- 4. ПРОВЕРКА ЗАГРУЗКИ
-- =====================================================================
-- Сверь с ожидаемыми значениями. Расхождение означает, что часть
-- строк не загрузилась — разбирайся до того, как считать метрики.

SELECT 'customers'            AS table_name, COUNT(*) AS rows, 99441 AS expected FROM customers
UNION ALL SELECT 'sellers',            COUNT(*),  3095 FROM sellers
UNION ALL SELECT 'products',           COUNT(*), 32951 FROM products
UNION ALL SELECT 'orders',             COUNT(*), 99441 FROM orders
UNION ALL SELECT 'order_items',        COUNT(*), 112650 FROM order_items
UNION ALL SELECT 'order_payments',     COUNT(*), 103886 FROM order_payments
UNION ALL SELECT 'order_reviews',      COUNT(*), 99224 FROM order_reviews
UNION ALL SELECT 'category_translation', COUNT(*), 71 FROM category_translation;


-- Период данных: убедись, что он покрывает 2016-2018
SELECT MIN(order_purchase_timestamp)::date AS first_order,
       MAX(order_purchase_timestamp)::date AS last_order
FROM orders;


-- Статусы заказов: пригодится при выборе рабочей выборки
SELECT order_status,
       COUNT(*) AS orders,
       ROUND(COUNT(*)::numeric / SUM(COUNT(*)) OVER () * 100, 2) AS share_pct
FROM orders
GROUP BY order_status
ORDER BY orders DESC;
