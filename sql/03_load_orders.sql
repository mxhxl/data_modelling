USE WAREHOUSE LOGI_WH;
USE SCHEMA LOGI2_DB.CLEAN;

-- 1) Final tables (only created the first time)
CREATE TABLE IF NOT EXISTS fact_orders (
    order_id      TEXT,
    customer_key  INTEGER,       -- customer version when the order was first loaded
    customer_id   TEXT,
    order_date    DATE,
    ship_date     DATE,
    delivery_date DATE,
    status        TEXT,
    amount        NUMBER(10, 2),
    updated_at    DATE
);

CREATE TABLE IF NOT EXISTS order_status_history (
    order_id   TEXT,
    status     TEXT,
    changed_at DATE
);

-- 2) INCREMENTAL: only clean orders newer than the latest one already loaded
CREATE OR REPLACE TABLE new_orders AS
SELECT *
FROM clean_orders
WHERE updated_at > (SELECT COALESCE(MAX(updated_at), '1900-01-01'::DATE) FROM fact_orders);

-- 3) HISTORY: save the status if the order is new or its status changed
INSERT INTO order_status_history (order_id, status, changed_at)
SELECT n.order_id, n.status, n.updated_at
FROM new_orders n
LEFT JOIN fact_orders f ON f.order_id = n.order_id
WHERE f.order_id IS NULL
   OR f.status <> n.status;

-- 4) MERGE: update the order if it exists, insert it if new
--    customer_key is only set on insert, so old orders keep their old customer version.
MERGE INTO fact_orders
USING (
    SELECT n.*, d.customer_key
    FROM new_orders n
    LEFT JOIN dim_customer d
           ON d.customer_id = n.customer_id
          AND d.is_current = TRUE
) s
ON fact_orders.order_id = s.order_id
WHEN MATCHED THEN UPDATE SET
    ship_date     = s.ship_date,
    delivery_date = s.delivery_date,
    status        = s.status,
    amount        = s.amount,
    updated_at    = s.updated_at
WHEN NOT MATCHED THEN INSERT
    (order_id, customer_key, customer_id, order_date, ship_date, delivery_date, status, amount, updated_at)
VALUES
    (s.order_id, s.customer_key, s.customer_id, s.order_date, s.ship_date, s.delivery_date, s.status, s.amount, s.updated_at);

-- expected after day 1: processed 20, total 20
-- expected after day 2: processed 10, total 24
SELECT (SELECT COUNT(*) FROM new_orders)  AS processed_this_run,
       (SELECT COUNT(*) FROM fact_orders) AS orders_in_total;
