-- 02_silver.sql — type-cast + dedupe bronze_orders into silver_orders.
-- Parameters: :catalog, :schema

INSERT OVERWRITE IDENTIFIER(:catalog || '.' || :schema || '.silver_orders')
WITH ranked AS (
  SELECT
    order_id,
    customer_id,
    product_id,
    region,
    TRY_CAST(order_date AS DATE)        AS order_date,
    TRY_CAST(amount     AS DECIMAL(10,2)) AS amount,
    _ingested_at,
    ROW_NUMBER() OVER (
      PARTITION BY order_id
      ORDER BY _ingested_at DESC
    ) AS rn
  FROM IDENTIFIER(:catalog || '.' || :schema || '.bronze_orders')
  WHERE order_id IS NOT NULL
)
SELECT order_id, customer_id, product_id, region, order_date, amount, _ingested_at
FROM ranked
WHERE rn = 1 AND order_date IS NOT NULL AND amount IS NOT NULL;
