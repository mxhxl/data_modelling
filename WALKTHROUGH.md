# Walkthrough: understand every part

Read this once with the files open beside it. Goal: you can explain the project in your own words.

---

## 1. The problem

A logistics company exports a file of orders every day. The file is messy:
- orders marked *Shipped* with **no ship date**
- **typos in the status** (`Shiped`)
- orders that **shipped before they were ordered**

Reports built on this are wrong. So this pipeline finds the bad rows, sets them aside, and keeps only good rows in clean tables. It also keeps **history**: how an order moved forward, and where a customer used to live.

Think of a **warehouse dock**: boxes arrive, an inspector checks them, damaged ones go on a "problem" shelf, good ones go on the proper shelves.

---

## 2. The flow

```
data/*.csv
   |  ingest_snowflake.py        (Python)
   v
RAW tables       raw_orders, raw_customers      everything TEXT, nothing rejected
   |  01_quality_checks.sql
   v
clean_orders / rejected_orders
   |  02_customer_history.sql
   v
dim_customer                                    customers with history
   |  03_load_orders.sql
   v
fact_orders + order_status_history              final tables
```

Each day you run the Python script once, then the three SQL files in order.

**Why run one day at a time?** The SQL builds its tables from whatever is in the raw tables at that moment. Day 1 first gives it the original customers and orders. Day 2 then shows what *changed*: customers who moved, orders whose status moved forward. If both days are loaded before the SQL runs, the pipeline only ever sees the newest version, so there is no history and no "only 10 new orders". The results are still correct, but the history and incremental parts have nothing to show.

| Table | One row means |
|---|---|
| `raw_orders`, `raw_customers` | a row exactly as in the CSV (+ source_file, batch_id, loaded_at) |
| `latest_orders`, `latest_customers` | the newest version of each order / customer |
| `clean_orders` / `rejected_orders` | good orders / bad orders (rejected ones also show the problem found) |
| `dim_customer` | one **version** of a customer |
| `fact_orders` | one order (final) |
| `order_status_history` | one status an order has had |

Fact = things that *happen* (orders). Dimension = things that *describe* (customers).

---

## 3. The Python script: `ingest_snowflake.py`

What it does, in order:
1. Reads the day from the command (`day1` or `day2`) and finds that day's CSV files.
2. Connects to Snowflake. The login comes from the `$env:SF_...` variables you typed in PowerShell, so no password is in the code.
3. Creates the warehouse `LOGI_WH` (the compute that runs queries), the database `LOGI2_DB` and the schema `RAW` if missing.
4. For each file, creates a raw table with **all columns as TEXT**. This way bad data still loads.
5. Skips the file if it was already loaded (checks `source_file`).
6. Inserts the rows. Empty cells become `NULL`.

Python only **moves data**. The thinking is in SQL.

---

## 4. The SQL steps

### `01_quality_checks.sql`

**1) Keep latest.** The day 2 file repeats day 1 orders. We want one row per order.
```sql
QUALIFY ROW_NUMBER() OVER (PARTITION BY order_id ORDER BY source_file DESC) = 1
```
In words: for each `order_id`, number its rows with the newest file first, and keep number 1. `TRY_TO_DATE` and `TRY_TO_NUMBER` turn text into real dates and numbers (and give `NULL` instead of an error if the text is bad).

**2) Good rows.** `clean_orders` = orders that pass every rule in a `WHERE`: valid status, known customer, amount above 0, ship date present once shipped, not shipped before ordered.

**3) Bad rows.** `rejected_orders` = every order that is **not in** `clean_orders`. One `CASE` writes the first problem found next to each bad order:
```sql
CASE
  WHEN status IS NULL OR status NOT IN ('Created', ... ) THEN 'INVALID_STATUS'
  WHEN customer_id NOT IN (SELECT customer_id FROM ...RAW_CUSTOMERS) THEN 'UNKNOWN_CUSTOMER'
  WHEN amount IS NULL OR amount <= 0 THEN 'BAD_AMOUNT'
  WHEN status IN ('Shipped','In Transit','Delivered') AND ship_date IS NULL THEN 'MISSING_SHIP_DATE'
  WHEN ship_date < order_date THEN 'SHIP_BEFORE_ORDER'
END AS issue
```
`CASE` is just if / else-if. The `WHERE` decides good or bad, and the `CASE` only explains why.

Result: day 1 gives **20 good, 5 bad**. Day 2 gives **24 good, 6 bad** (one broken order was fixed, two new ones were broken).

### `02_customer_history.sql` (SCD Type 2)

**Problem:** customer C003 moved from Mumbai to Singapore. If we overwrite the city, old orders look like they went to Singapore. Wrong.

**Fix:** don't overwrite. Close the old row, add a new one.

| customer_id | city | valid_from | valid_to | is_current |
|---|---|---|---|---|
| C003 | Mumbai | 2026-01-10 | 2026-01-11 | false |
| C003 | Singapore | 2026-01-11 | (empty) | true |

- **Step 1:** `latest_customers` = newest version of each customer (same `QUALIFY` trick).
- **Step 3, close:** `UPDATE dim_customer ... FROM latest_customers` marks the current row as old if the city or country is different.
- **Step 4, add:** `INSERT` a current row for every customer who has **no** current row. That covers new customers and the ones just closed.

Result: 10 rows after day 1, **13** after day 2 (2 moved + 1 new).

### `03_load_orders.sql` (incremental)

**2) Incremental.**
```sql
WHERE updated_at > (SELECT COALESCE(MAX(updated_at), '1900-01-01') FROM fact_orders)
```
In words: only take clean orders newer than the newest one already in `fact_orders`. `COALESCE(a, b)` means "use a, or b if a is empty" (the first run has nothing loaded yet).
Day 2 processed only **10** clean orders, not all 30.

**3) History.** If the order is new, or its status changed, save a row in `order_status_history`. This builds the order's journey (Created, then Packed, then Shipped).

**4) MERGE.** MERGE = update if it exists, insert if it is new.
```sql
WHEN MATCHED THEN UPDATE SET status = s.status, ...
WHEN NOT MATCHED THEN INSERT (...) VALUES (...)
```
`customer_key` is only set on insert. So old orders keep the old customer version (this is why result query D shows old cities).

### `04_check_results.sql`
Five simple queries (A to E) to look at the results. Select one, press Ctrl+Enter.

---

## 5. SQL words cheat sheet

| SQL | Plain meaning |
|---|---|
| `SELECT ... FROM ... WHERE` | read rows that match |
| `JOIN` / `LEFT JOIN` | combine two tables. LEFT keeps rows even with no match |
| `GROUP BY` + `COUNT(*)` | count rows per group |
| `CREATE OR REPLACE TABLE ... AS SELECT` | build a table from a query (rebuilt each run) |
| `QUALIFY ROW_NUMBER() ...` | keep the first row of each group |
| `CASE WHEN ... THEN ...` | if / else-if |
| `IN` / `NOT IN` | is (not) in a list |
| `IS NULL` | the cell is empty |
| `COALESCE(a, b)` | use a, or b if a is empty |
| `UPDATE ... SET` | change existing rows |
| `INSERT INTO ... SELECT` | add rows from a query |
| `MERGE` | update if exists, insert if new |

---

## 6. Git

```powershell
git add .
git commit -m "describe the change"
git log --oneline
```
Never commit a password. `.gitignore` already blocks `.env`.

---

## 7. Interview cheat sheet

**30-second pitch**
> "I built a small data pipeline for logistics orders on Snowflake. A Python script loads daily CSV files into raw tables. SQL then keeps the latest version of each order and runs data quality checks for missing ship dates and invalid statuses, splitting the orders into clean and rejected tables. Clean orders load incrementally with a MERGE, so only new or changed rows are processed. Customers are stored with history, so an old order still shows the address that was true at the time."

**What is an incremental load?**
Only process new or changed rows instead of everything. I compare `updated_at` with the newest one already loaded. On day 2 only 10 clean orders were processed, not 30.

**What is SCD Type 2?**
Keeping history in a dimension table. When a customer moves I close the old row and add a new one, instead of overwriting.

**How do you handle bad data?**
The raw layer loads everything as text, so nothing is lost. Quality checks label each bad order with a reason and send it to `rejected_orders`. Good orders go on. Day 1: 5 of 25 were rejected.

**Why load everything as TEXT first?**
So bad values (like a typo in a date) don't make the load fail. I convert them to real types later with `TRY_TO_DATE`.

**What happens if you run it twice?**
Nothing changes. The ingest skips files already loaded, and the SQL finds no new rows.

**What if a rejected order gets fixed in the source?**
It comes back with a newer `updated_at`, passes the checks, and gets loaded. One order did this on day 2.

**What would you improve?**
- Match orders to the customer version by order date.
- More rules (negative amounts, duplicate IDs).
- Schedule it to run daily.
- Keep a permanent log of rejected rows.

**Be honest about the limits**
The data is fake, small, and generated with AI. It's a learning project, not a production system. Saying this plainly makes you more credible.

---

## 8. Practice

1. **Break a row.** In `data/orders_day1.csv`, blank the `ship_date` of a "Shipped" order. Re-run day 1 (after `DROP DATABASE LOGI2_DB;`). Find it in `rejected_orders`.
2. **Add a rule.** In `01_quality_checks.sql`, add a line to the good-rows `WHERE` (for example `AND amount < 10000`) and a matching line to the `CASE`.
3. **Explain aloud.** Say the 30-second pitch without looking.
