USE WAREHOUSE LOGI_WH;
USE SCHEMA LOGI2_DB.CLEAN;

-- 1) KEEP LATEST: one row per customer, newest file wins
CREATE OR REPLACE TABLE latest_customers AS
SELECT customer_id,
       customer_name,
       city,
       country,
       TRY_TO_DATE(updated_at) AS updated_at
FROM LOGI2_DB.RAW.RAW_CUSTOMERS
QUALIFY ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY source_file DESC) = 1;

-- 2) History table (SCD Type 2): a move adds a new row, the old row is kept
CREATE TABLE IF NOT EXISTS dim_customer (
    customer_key  INTEGER AUTOINCREMENT,   -- id of one customer VERSION
    customer_id   TEXT,
    customer_name TEXT,
    city          TEXT,
    country       TEXT,
    valid_from    DATE,
    valid_to      DATE,                    -- empty = still current
    is_current    BOOLEAN
);

-- 3) CLOSE: customers whose city or country changed lose their "current" status
UPDATE dim_customer
SET valid_to   = latest_customers.updated_at,
    is_current = FALSE
FROM latest_customers
WHERE dim_customer.customer_id = latest_customers.customer_id
  AND dim_customer.is_current = TRUE
  AND (dim_customer.city <> latest_customers.city
    OR dim_customer.country <> latest_customers.country);

-- 4) ADD: a current row for every customer without one (new customers + the ones just closed)
INSERT INTO dim_customer (customer_id, customer_name, city, country, valid_from, valid_to, is_current)
SELECT customer_id, customer_name, city, country, updated_at, NULL, TRUE
FROM latest_customers
WHERE customer_id NOT IN (SELECT customer_id FROM dim_customer WHERE is_current = TRUE);

-- expected after day 1: 10 rows
-- expected after day 2: 13 rows
SELECT COUNT(*) AS dim_rows FROM dim_customer;
