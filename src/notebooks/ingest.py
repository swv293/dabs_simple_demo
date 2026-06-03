# Databricks notebook source
# MAGIC %md
# MAGIC # ingest — synthetic orders → bronze
# MAGIC
# MAGIC Generates ~5,000 synthetic order rows, writes a CSV to the bundle volume, and `COPY INTO`s `bronze_orders`.
# MAGIC
# MAGIC Widgets (set by the bundle job task):
# MAGIC - `catalog` — UC catalog (e.g. `dev_dabs_demo`)
# MAGIC - `schema`  — schema name (e.g. `demo`)
# MAGIC - `volume`  — volume name (e.g. `raw`)

# COMMAND ----------

dbutils.widgets.text("catalog", "dev_dabs_demo")
dbutils.widgets.text("schema",  "demo")
dbutils.widgets.text("volume",  "raw")

catalog = dbutils.widgets.get("catalog")
schema  = dbutils.widgets.get("schema")
volume  = dbutils.widgets.get("volume")

# COMMAND ----------

import random
from datetime import date, timedelta

def generate_orders(n: int = 5000, seed: int = 42) -> list[dict]:
    """Pure helper — also exercised by tests/unit/test_ingest_helpers.py."""
    rng = random.Random(seed)
    regions  = ["NORTH", "SOUTH", "EAST", "WEST"]
    products = [f"P{n:03d}" for n in range(1, 21)]
    today    = date.today()
    rows = []
    for i in range(n):
        rows.append({
            "order_id":    f"O{i:07d}",
            "customer_id": f"C{rng.randint(1, 500):05d}",
            "product_id":  rng.choice(products),
            "region":      rng.choice(regions),
            "order_date":  (today - timedelta(days=rng.randint(0, 29))).isoformat(),
            "amount":      f"{round(rng.uniform(5.0, 500.0), 2):.2f}",
        })
    return rows

# COMMAND ----------

orders = generate_orders()
print(f"Generated {len(orders)} synthetic orders.")

# COMMAND ----------

# MAGIC %sql
# MAGIC CREATE VOLUME IF NOT EXISTS IDENTIFIER('${catalog}.${schema}.${volume}')

# COMMAND ----------

import csv, os

volume_path = f"/Volumes/{catalog}/{schema}/{volume}"
csv_path    = f"{volume_path}/orders.csv"

with open(csv_path, "w", newline="") as f:
    writer = csv.DictWriter(f, fieldnames=list(orders[0].keys()))
    writer.writeheader()
    writer.writerows(orders)

print(f"Wrote {csv_path} ({os.path.getsize(csv_path)} bytes).")

# COMMAND ----------

spark.sql(f"""
COPY INTO {catalog}.{schema}.bronze_orders
FROM (
  SELECT order_id, customer_id, product_id, region, order_date, amount, current_timestamp() AS _ingested_at
  FROM '{volume_path}'
)
FILEFORMAT = CSV
FORMAT_OPTIONS ('header' = 'true')
COPY_OPTIONS ('mergeSchema' = 'false')
""")

count = spark.sql(f"SELECT COUNT(*) AS n FROM {catalog}.{schema}.bronze_orders").first()["n"]
print(f"bronze_orders row count: {count}")
