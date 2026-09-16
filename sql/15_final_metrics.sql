-- ============================================================================
-- 15_final_metrics.sql — the metrics that describe the actual claim.
--
-- Every AUC quoted so far was measured on the ALERT population (150 held-out
-- alerts, base rate 0.32) because that is where human dispositions exist for
-- comparison. But the product claim is about the INVISIBLE population: 2,759
-- customer-weeks, base rate 0.48, enriched with sudden-onset accounts because
-- that band is precisely where a structuring operation would sit while the
-- threshold was raised.
--
-- Those are different distributions. Quoting the alert-population AUC as if it
-- described performance on the invisible population was wrong, and the band
-- table (23.4% -> 47.9% -> 79.5% dirty) already suggested the two diverge.
-- This measures the right thing.
-- ============================================================================

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE COMPUTE_WH;
USE DATABASE TRACE_DB;

-- ---------------------------------------------------------------------------
-- 1. AUC on the invisible population -- the headline discrimination metric.
-- ---------------------------------------------------------------------------

WITH j AS (
    SELECT a.p_suspicious AS p,
           CASE WHEN ip.is_truly_suspicious THEN 1 ELSE 0 END AS y
    FROM EVAL.ADJUDICATION a
    JOIN EVAL.INVISIBLE_POPULATION ip
      ON ip.customer_id = a.customer_id AND ip.week_start = a.week_start
    WHERE a.p_suspicious IS NOT NULL
), r AS (
    SELECT y, RANK() OVER (ORDER BY p) AS rk FROM j
)
SELECT
    COUNT(*)      AS n,
    SUM(y)        AS n_dirty,
    SUM(1 - y)    AS n_clean,
    ROUND(AVG(y), 3) AS base_rate,
    ROUND((SUM(CASE WHEN y = 1 THEN rk ELSE 0 END) - SUM(y) * (SUM(y) + 1) / 2.0)
          / NULLIF(SUM(y) * SUM(1 - y), 0), 3) AS auc_invisible_population
FROM r;

-- ---------------------------------------------------------------------------
-- 2. Score distribution by class. Separated means with overlapping ranges is
--    the signature we expect; identical means would mean no signal.
-- ---------------------------------------------------------------------------

SELECT
    CASE WHEN ip.is_truly_suspicious THEN 'DIRTY' ELSE 'CLEAN' END AS actual,
    COUNT(*)                          AS n,
    ROUND(AVG(a.p_suspicious), 3)     AS mean_p,
    ROUND(MEDIAN(a.p_suspicious), 3)  AS median_p,
    ROUND(MIN(a.p_suspicious), 3)     AS min_p,
    ROUND(MAX(a.p_suspicious), 3)     AS max_p
FROM EVAL.ADJUDICATION a
JOIN EVAL.INVISIBLE_POPULATION ip
  ON ip.customer_id = a.customer_id AND ip.week_start = a.week_start
WHERE a.p_suspicious IS NOT NULL
GROUP BY 1 ORDER BY 1;

-- ---------------------------------------------------------------------------
-- 3. Lift curve. The enterprise framing: workload against yield.
--    "Work the top N% of the queue, recover M% of the laundering."
-- ---------------------------------------------------------------------------

WITH scored AS (
    SELECT a.p_suspicious AS p,
           CASE WHEN ip.is_truly_suspicious THEN 1 ELSE 0 END AS y,
           a.aggregate_amount
    FROM EVAL.ADJUDICATION a
    JOIN EVAL.INVISIBLE_POPULATION ip
      ON ip.customer_id = a.customer_id AND ip.week_start = a.week_start
    WHERE a.p_suspicious IS NOT NULL
), ranked AS (
    SELECT s.*,
           PERCENT_RANK() OVER (ORDER BY p DESC) AS pr,
           SUM(y) OVER ()                        AS total_dirty
    FROM scored s
), deciles AS (
    SELECT CEIL(LEAST(pr, 0.9999) * 10) AS decile, y, aggregate_amount, total_dirty
    FROM ranked
)
SELECT
    decile                                                            AS risk_decile,
    COUNT(*)                                                          AS weeks,
    SUM(y)                                                            AS dirty_found,
    ROUND(AVG(y), 3)                                                  AS hit_rate,
    ROUND(SUM(aggregate_amount) / 10000000, 1)                        AS notional_cr,
    ROUND(SUM(SUM(y)) OVER (ORDER BY decile) / MAX(total_dirty), 3)   AS cumulative_recall
FROM deciles
GROUP BY decile, total_dirty
ORDER BY decile;

-- ---------------------------------------------------------------------------
-- 4. Does the escalation queue concentrate on particular branches? Nothing in
--    the prompt mentions branches, so any concentration is discovered, not told.
-- ---------------------------------------------------------------------------

SELECT
    c.branch_id,
    b.branch_name,
    b.city,
    COUNT(*)                                                    AS escalated_weeks,
    COUNT(DISTINCT p.customer_id)                               AS customers,
    ROUND(SUM(p.payload:case:aggregate_cash::FLOAT) / 10000000, 1) AS notional_cr
FROM AUDIT.EVIDENCE_PACK p
JOIN CORE.CUSTOMERS c ON c.customer_id = p.customer_id
JOIN CORE.BRANCHES  b ON b.branch_id  = c.branch_id
GROUP BY 1, 2, 3
ORDER BY escalated_weeks DESC;

-- For contrast: how the whole invisible population distributes across branches.
-- If escalations concentrate more tightly than the population, that is a
-- finding an investigator would act on.
SELECT
    c.branch_id,
    b.branch_name,
    COUNT(*)                                                     AS invisible_weeks,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1)           AS pct_of_population
FROM EVAL.INVISIBLE_POPULATION ip
JOIN CORE.CUSTOMERS c ON c.customer_id = ip.customer_id
JOIN CORE.BRANCHES  b ON b.branch_id  = c.branch_id
GROUP BY 1, 2
ORDER BY invisible_weeks DESC;
