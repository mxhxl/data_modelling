"""
Loads one day of CSV files into Snowflake RAW tables.

  python ingest_snowflake.py day1
  python ingest_snowflake.py day2
  python ingest_snowflake.py all     (both days, day 1 first)
"""
import csv
import os
import sys
from datetime import datetime
from pathlib import Path

import snowflake.connector

if len(sys.argv) != 2 or sys.argv[1] not in ("day1", "day2", "all"):
    print(__doc__)
    sys.exit(1)

day = sys.argv[1]
# "all" takes every CSV; sorted() puts day1 files before day2 files
pattern = "*.csv" if day == "all" else f"*_{day}.csv"
files = sorted(Path("data").glob(pattern))
if not files:
    print(f"No CSV files found in the data folder for {day}.")
    sys.exit(1)

# one batch per run: id for grouping rows, timestamp for audit
loaded_at = datetime.now()
batch_id = loaded_at.strftime("%Y%m%d%H%M%S")

# credentials come from environment variables, never from the code
conn = snowflake.connector.connect(
    account=os.environ["SF_ACCOUNT"],
    user=os.environ["SF_USER"],
    password=os.environ["SF_PASSWORD"],
)
cur = conn.cursor()

# safe to re-run: only creates them if missing
# (the warehouse is the compute that runs queries; the SQL files use it too)
cur.execute("CREATE WAREHOUSE IF NOT EXISTS LOGI_WH WAREHOUSE_SIZE = XSMALL AUTO_SUSPEND = 60 AUTO_RESUME = TRUE")
cur.execute("USE WAREHOUSE LOGI_WH")
cur.execute("CREATE DATABASE IF NOT EXISTS LOGI2_DB")
cur.execute("CREATE SCHEMA IF NOT EXISTS LOGI2_DB.RAW")
cur.execute("USE SCHEMA LOGI2_DB.RAW")

for file in files:
    # orders_day1.csv -> raw_orders
    table = "raw_" + file.stem.split("_")[0]

    with open(file, newline="", encoding="utf-8") as f:
        reader = csv.reader(f)
        columns = next(reader)
        # empty cell -> None (NULL in Snowflake)
        rows = [[v or None for v in r] + [file.name, batch_id, loaded_at.isoformat()] for r in reader]

    # raw layer: everything TEXT, so bad data still loads
    col_defs = ", ".join(f"{c} TEXT" for c in columns)
    cur.execute(f"CREATE TABLE IF NOT EXISTS {table} ({col_defs}, source_file TEXT, batch_id TEXT, loaded_at TEXT)")

    # skip a file that was already loaded
    cur.execute(f"SELECT COUNT(*) FROM {table} WHERE source_file = %s", (file.name,))
    if cur.fetchone()[0] > 0:
        print(f"{file.name}: already loaded, skipped")
        continue

    marks = ", ".join(["%s"] * (len(columns) + 3))
    cur.executemany(f"INSERT INTO {table} VALUES ({marks})", rows)
    print(f"{file.name}: {len(rows)} rows -> {table}")

conn.close()
