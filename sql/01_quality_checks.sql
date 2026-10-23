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

-- 2) CHECK: label each order with the first problem found (empty = no problem)
CREATE OR REPLACE TABLE checked_orders AS
SELECT *,
       CASE
           WHEN status IS NULL
             OR status NOT IN ('Created', 'Packed', 'Shipped', 'In Transit', 'Delivered', 'Cancelled')
                THEN 'INVALID_STATUS'
           WHEN status IN ('Shipped', 'In Transit', 'Delivered') AND ship_date IS NULL
                THEN 'MISSING_SHIP_DATE'
           WHEN ship_date < order_date
                THEN 'SHIP_BEFORE_ORDER'
       END AS issue
FROM latest_orders;

-- 3) SPLIT, good rows: no problem found
CREATE OR REPLACE TABLE clean_orders AS
SELECT * FROM checked_orders
WHERE issue IS NULL;

-- 4) SPLIT, bad rows: the problem is written in the issue column
CREATE OR REPLACE TABLE rejected_orders AS
SELECT * FROM checked_orders
WHERE issue IS NOT NULL;

-- expected after day 1: good = 20, bad = 5
-- expected after day 2: good = 24, bad = 6
SELECT (SELECT COUNT(*) FROM clean_orders)    AS good,
       (SELECT COUNT(*) FROM rejected_orders) AS bad;
