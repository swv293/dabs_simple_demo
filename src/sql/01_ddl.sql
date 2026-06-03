-- 01_ddl.sql — idempotent DDL for the bronze/silver/gold orders pipeline.
-- Parameters: :catalog, :schema  (passed by the bundle's sql_task)

CREATE SCHEMA IF NOT EXISTS IDENTIFIER(:catalog || '.' || :schema);

CREATE TABLE IF NOT EXISTS IDENTIFIER(:catalog || '.' || :schema || '.bronze_orders') (
  order_id      STRING,
  customer_id   STRING,
  product_id    STRING,
  region        STRING,
  order_date    STRING,
  amount        STRING,
  _ingested_at  TIMESTAMP
)
USING DELTA;

CREATE TABLE IF NOT EXISTS IDENTIFIER(:catalog || '.' || :schema || '.silver_orders') (
  order_id      STRING,
  customer_id   STRING,
  product_id    STRING,
  region        STRING,
  order_date    DATE,
  amount        DECIMAL(10,2),
  _ingested_at  TIMESTAMP
)
USING DELTA;

CREATE TABLE IF NOT EXISTS IDENTIFIER(:catalog || '.' || :schema || '.gold_daily_revenue') (
  order_date    DATE,
  region        STRING,
  orders        BIGINT,
  revenue       DECIMAL(14,2)
)
USING DELTA;
