USE WAREHOUSE LOGI_WH;
CREATE SCHEMA IF NOT EXISTS LOGI2_DB.CLEAN;
USE SCHEMA LOGI2_DB.CLEAN;

-- 1) KEEP LATEST: one row per order, newest file wins. Text becomes real dates and numbers.
CREATE OR REPLACE TABLE latest_orders AS
SELECT order_id,
       customer_id,
       TRY_TO_DATE(order_date)         AS order_date,
       TRY_TO_DATE(ship_date)          AS ship_date,
       TRY_TO_DATE(delivery_date)      AS delivery_date,
       status,
       TRY_TO_NUMBER(amount, 10, 2)    AS amount,
       TRY_TO_DATE(updated_at)         AS updated_at
FROM LOGI2_DB.RAW.RAW_ORDERS
QUALIFY ROW_NUMBER() OVER (PARTITION BY order_id ORDER BY source_file DESC) = 1;

-- 2) SPLIT, good rows: valid status, known customer, amount above 0,
--    ship date present when the order has shipped, and not shipped before it was ordered
CREATE OR REPLACE TABLE clean_orders AS
SELECT * FROM latest_orders
WHERE status IN ('Created', 'Packed', 'Shipped', 'In Transit', 'Delivered', 'Cancelled')
  AND customer_id IN (SELECT customer_id FROM LOGI2_DB.RAW.RAW_CUSTOMERS)
  AND amount > 0
  AND (status NOT IN ('Shipped', 'In Transit', 'Delivered') OR ship_date IS NOT NULL)
  AND (ship_date IS NULL OR ship_date >= order_date);

-- 3) SPLIT, bad rows: everything that is not in the good table, with the first problem found
CREATE OR REPLACE TABLE rejected_orders AS
SELECT *,
       CASE
           WHEN status IS NULL
             OR status NOT IN ('Created', 'Packed', 'Shipped', 'In Transit', 'Delivered', 'Cancelled')
                THEN 'INVALID_STATUS'
           WHEN customer_id NOT IN (SELECT customer_id FROM LOGI2_DB.RAW.RAW_CUSTOMERS)
                THEN 'UNKNOWN_CUSTOMER'
           WHEN amount IS NULL OR amount <= 0
                THEN 'BAD_AMOUNT'
           WHEN status IN ('Shipped', 'In Transit', 'Delivered') AND ship_date IS NULL
                THEN 'MISSING_SHIP_DATE'
           WHEN ship_date < order_date
                THEN 'SHIP_BEFORE_ORDER'
       END AS issue
FROM latest_orders
WHERE order_id NOT IN (SELECT order_id FROM clean_orders);

-- expected after day 1: good = 20, bad = 5
-- expected after day 2: good = 24, bad = 6
SELECT (SELECT COUNT(*) FROM clean_orders)    AS good,
       (SELECT COUNT(*) FROM rejected_orders) AS bad;
