-- 03_gold.sql — aggregate silver_orders to gold_daily_revenue.
-- Parameters: :catalog, :schema

INSERT OVERWRITE IDENTIFIER(:catalog || '.' || :schema || '.gold_daily_revenue')
SELECT
  order_date,
  region,
  COUNT(*)      AS orders,
  SUM(amount)   AS revenue
FROM IDENTIFIER(:catalog || '.' || :schema || '.silver_orders')
GROUP BY order_date, region;
