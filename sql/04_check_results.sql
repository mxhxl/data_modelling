-- Run one query at a time: select it, then press Ctrl+Enter.
USE WAREHOUSE LOGI_WH;
USE SCHEMA LOGI2_DB.CLEAN;

-- A) Why were orders rejected?
SELECT order_id, status, ship_date, issue
FROM rejected_orders
ORDER BY order_id;

-- B) Orders per status (clean data only)
SELECT status, COUNT(*) AS orders, SUM(amount) AS total_amount
FROM fact_orders
GROUP BY status
ORDER BY orders DESC;

-- C) Customers who moved (history kept)
SELECT customer_id, city, country, valid_from, valid_to, is_current
FROM dim_customer
WHERE customer_id IN (SELECT customer_id FROM dim_customer GROUP BY customer_id HAVING COUNT(*) > 1)
ORDER BY customer_id, valid_from;

-- D) Old orders keep the OLD city
SELECT f.order_id, d.customer_id, d.city AS city_when_ordered
FROM fact_orders f
JOIN dim_customer d ON d.customer_key = f.customer_key
WHERE d.is_current = FALSE
ORDER BY f.order_id;

-- E) Order journey (orders whose status changed)
SELECT order_id, status, changed_at
FROM order_status_history
WHERE order_id IN (SELECT order_id FROM order_status_history GROUP BY order_id HAVING COUNT(*) > 1)
ORDER BY order_id, changed_at;
