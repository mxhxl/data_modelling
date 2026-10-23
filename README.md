# Logistics Data Model & Quality Monitor

A small data pipeline: load logistics CSV files into Snowflake with Python, then check and clean the orders with SQL.

## What it does
1. **Ingest (Python):** `ingest_snowflake.py` loads one day of CSV files into raw Snowflake tables (all TEXT, so bad data still loads).
   Each row is tagged with `source_file`, `batch_id` and `loaded_at`.
2. **Quality checks (SQL):** `01_quality_checks.sql` keeps the latest version of each order, then splits orders into good rows and rejected rows (with the reason).
3. **Customer history (SQL):** `02_customer_history.sql` keeps old and new rows when a customer moves (SCD Type 2).
4. **Load orders (SQL):** `03_load_orders.sql` loads only new or changed good orders (incremental), and saves each order's status journey.

## Flow
```
data/*.csv -> Python -> LOGI2_DB.RAW -> SQL -> LOGI2_DB.CLEAN
                        raw_customers         clean_orders, rejected_orders
                        raw_orders            dim_customer (history)
                                              fact_orders, order_status_history
```

## Data
Tiny on purpose. Day 1: 25 orders, 10 customers. Day 2: 30 orders (the same 25 plus 5 new), 11 customers.
It has planted problems: invalid statuses, missing ship dates, orders shipped before they were placed.
Day 2 also has status changes, 2 customers who moved, and 1 broken order that got fixed.

## How to run
In PowerShell, from this folder:
```powershell
pip install -r requirements.txt
$env:SF_ACCOUNT="your_account"
$env:SF_USER="your_user"
$env:SF_PASSWORD="your_password"
python ingest_snowflake.py day1
```
Then in a Snowflake worksheet, paste and run (Run All) these files **in this order**:
`sql/01_quality_checks.sql`, then `sql/02_customer_history.sql`, then `sql/03_load_orders.sql`.

Check the numbers at the bottom of each file. Then do day 2:
```powershell
python ingest_snowflake.py day2
```
Run the same three SQL files again. Use `sql/04_check_results.sql` to look at the results.

| | After day 1 | After day 2 |
|---|---|---|
| good / rejected orders | 20 / 5 | 24 / 6 |
| `dim_customer` rows | 10 | 13 |
| orders processed this run / total | 20 / 20 | 10 / 24 |

`python ingest_snowflake.py all` loads both days in one go. It is fine for a quick test, but the history demo (customers who moved, status journeys) needs the SQL run between the days, so use `day1` and `day2` for that.

Running the same day twice is safe: the ingest skips files it already loaded, and the SQL finds nothing new.
To start over, run `DROP DATABASE LOGI2_DB;` in a worksheet.

## Resume bullets, and where to find them
| Bullet | Where |
|---|---|
| Relational data model for the order lifecycle | `fact_orders`, `dim_customer`, `order_status_history` (`sql/02` and `sql/03`) |
| Incremental load logic | `new_orders` and `MERGE` in `sql/03_load_orders.sql` |
| Slowly changing dimensions | `sql/02_customer_history.sql` |
| Automated quality checks (missing shipment dates, bad statuses) | the `WHERE` and `CASE` in `sql/01_quality_checks.sql` |
| Validated, query-ready tables | `clean_orders`, `fact_orders` |

Read [WALKTHROUGH.md](WALKTHROUGH.md) to understand every step, plus interview answers.

## Known limits
- The data is fake and small. It was generated with AI.
- The incremental load compares `updated_at` with the newest one already loaded. A late order with an older `updated_at` would be missed.
- Orders are linked to the customer version that was current when the order first loaded. Real systems match by order date.
- `rejected_orders` shows what is rejected *now*. An order disappears from it once the source fixes it.

## Tools
Python, Snowflake, SQL, Git
