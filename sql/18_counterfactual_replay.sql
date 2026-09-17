-- ============================================================================
-- 18_counterfactual_replay.sql — the replay engine, made callable.
--
-- Everything so far replays ONE policy change: the threshold that was wrong
-- between 2025-07-01 and 2026-08-14. That is the case study, not the product.
--
-- The product claim is "change the rule and ask which historical decisions
-- would have differed". Until now that machinery existed but could only be run
-- by editing SQL. This exposes it as a function: give it any threshold and any
-- window, and it reconstructs, across the full transaction record, exactly
-- which customer-weeks that rule would have caught and which the bank actually
-- alerted on.
--
-- No model calls. The counterfactual is deterministic SQL over 607,307
-- transactions -- which is the point: a regulator can re-derive it.
-- ============================================================================

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE COMPUTE_WH;
USE DATABASE TRACE_DB;

-- ---------------------------------------------------------------------------
-- 1. The counterfactual. For a candidate threshold over a period, every
--    customer-week it would catch, flagged by whether an alert actually fired.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION POLICY.REPLAY_AT_THRESHOLD(
    CANDIDATE_THRESHOLD FLOAT,
    WINDOW_FROM         DATE,
    WINDOW_TO           DATE
)
RETURNS TABLE (
    customer_id      STRING,
    week_start       DATE,
    cash_amount      FLOAT,
    deposit_count    NUMBER,
    alerted_in_life  BOOLEAN   -- did the bank actually raise an alert that week?
)
AS
$$
    -- Explicit casts: V_WEEKLY_CASH returns NUMBER(27,2) and Snowflake rejects
    -- a UDTF whose declared column type does not match the body exactly.
    SELECT
        w.customer_id,
        w.week_start,
        w.cash_amount::FLOAT,
        w.deposit_count::NUMBER,
        a.alert_id IS NOT NULL
    FROM CORE.V_WEEKLY_CASH w
    LEFT JOIN CORE.ALERTS a
           ON a.customer_id = w.customer_id
          AND a.window_start = w.week_start
    WHERE w.week_start >= WINDOW_FROM
      AND w.week_start <= WINDOW_TO
      AND w.cash_amount >= CANDIDATE_THRESHOLD
$$;

-- ---------------------------------------------------------------------------
-- 2. Summary: what a candidate rule would have changed.
--
--    "newly_captured" is the number that matters. Those are customer-weeks the
--    candidate threshold catches and the live rule did not -- activity with no
--    alert, no disposition and no file.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION POLICY.REPLAY_SUMMARY(
    CANDIDATE_THRESHOLD FLOAT,
    WINDOW_FROM         DATE,
    WINDOW_TO           DATE
)
RETURNS TABLE (
    would_catch         NUMBER,
    already_alerted     NUMBER,
    newly_captured      NUMBER,
    newly_captured_cr   FLOAT,
    distinct_customers  NUMBER
)
AS
$$
    SELECT
        COUNT(*),
        SUM(CASE WHEN alerted_in_life THEN 1 ELSE 0 END),
        SUM(CASE WHEN alerted_in_life THEN 0 ELSE 1 END),
        ROUND(SUM(CASE WHEN alerted_in_life THEN 0 ELSE cash_amount END) / 10000000, 2),
        COUNT(DISTINCT CASE WHEN NOT alerted_in_life THEN customer_id END)
    FROM TABLE(POLICY.REPLAY_AT_THRESHOLD(CANDIDATE_THRESHOLD, WINDOW_FROM, WINDOW_TO))
$$;

-- ---------------------------------------------------------------------------
-- 3. Sensitivity curve. Every threshold from 5L to 12L across the defect
--    window, so the shape of the decision is visible rather than one point.
--
--    This is what a threshold-tuning exercise produces after weeks of
--    consultant time, computed here over the full record in seconds.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE VIEW POLICY.V_THRESHOLD_SENSITIVITY AS
WITH candidates AS (
    SELECT 500000 + (SEQ4() * 50000) AS threshold
    FROM TABLE(GENERATOR(ROWCOUNT => 15))
), defect_window AS (
    SELECT effective_from AS w_from, effective_to AS w_to
    FROM POLICY.POLICY_VERSIONS
    WHERE policy_version_id = 'PV-TM-STRUCT-002'
), weekly AS (
    SELECT w.customer_id, w.week_start, w.cash_amount,
           a.alert_id IS NOT NULL AS alerted_in_life
    FROM CORE.V_WEEKLY_CASH w
    LEFT JOIN CORE.ALERTS a
           ON a.customer_id = w.customer_id AND a.window_start = w.week_start
    CROSS JOIN defect_window d
    WHERE w.week_start >= d.w_from AND w.week_start < d.w_to
)
SELECT
    c.threshold,
    COUNT(*)                                                             AS would_catch,
    SUM(CASE WHEN wk.alerted_in_life THEN 0 ELSE 1 END)                  AS newly_captured,
    ROUND(SUM(CASE WHEN wk.alerted_in_life THEN 0 ELSE wk.cash_amount END) / 10000000, 1)
                                                                         AS newly_captured_cr,
    COUNT(DISTINCT CASE WHEN NOT wk.alerted_in_life THEN wk.customer_id END)
                                                                         AS customers_affected
FROM candidates c
JOIN weekly wk ON wk.cash_amount >= c.threshold
GROUP BY c.threshold
ORDER BY c.threshold;

-- ---------------------------------------------------------------------------
-- 4. Demonstration
-- ---------------------------------------------------------------------------

-- The actual defect: the live rule was 10,00,000, the corrected rule 8,00,000.
-- Casts are required: an integer literal is NUMBER(7,0) and the function
-- declares FLOAT, which Snowflake will not coerce for a UDTF argument.
SELECT 'live rule (10L)' AS scenario, *
FROM TABLE(POLICY.REPLAY_SUMMARY(1000000::FLOAT, '2025-07-01'::DATE, '2026-08-13'::DATE))
UNION ALL
SELECT 'corrected rule (8L)', *
FROM TABLE(POLICY.REPLAY_SUMMARY(800000::FLOAT, '2025-07-01'::DATE, '2026-08-13'::DATE))
UNION ALL
SELECT 'stricter still (7L)', *
FROM TABLE(POLICY.REPLAY_SUMMARY(700000::FLOAT, '2025-07-01'::DATE, '2026-08-13'::DATE));

-- The full curve.
SELECT * FROM POLICY.V_THRESHOLD_SENSITIVITY;

-- Yield per candidate threshold, against truth.
--
-- RESTRICTED TO THE ADJUDICATED BAND ON PURPOSE. EVAL.INVISIBLE_POPULATION
-- contains only the 8L-10L window -- the weeks that raised no alert while
-- PV-TM-STRUCT-002 was live. Those are the only customer-weeks anyone has
-- ground truth for.
--
-- An earlier version of this query joined on `aggregate_amount >= threshold`
-- across the whole range and returned 2,759 rows at a 0.482 hit rate for every
-- threshold from 5L to 8L. That is not a finding: below 8L the join simply
-- returns the entire table each time. It looked like a flat yield curve and
-- was an artifact of the population's definition.
--
-- Evaluating stricter thresholds honestly would mean adjudicating the weeks
-- between 5L and 8L, which has not been done. Volume for those rows is real
-- (above); yield is unknown, and is reported as unknown.
SELECT
    s.threshold,
    s.newly_captured,
    s.newly_captured_cr,
    CASE WHEN s.threshold >= 800000 THEN COUNT(ip.customer_id) END        AS adjudicated_weeks,
    CASE WHEN s.threshold >= 800000
         THEN SUM(CASE WHEN ip.is_truly_suspicious THEN 1 ELSE 0 END) END AS truly_suspicious,
    CASE WHEN s.threshold >= 800000
         THEN ROUND(AVG(CASE WHEN ip.is_truly_suspicious THEN 1 ELSE 0 END), 3)
         ELSE NULL END                                                    AS hit_rate,
    CASE WHEN s.threshold < 800000
         THEN 'not adjudicated - outside the evaluated band' END          AS note
FROM POLICY.V_THRESHOLD_SENSITIVITY s
LEFT JOIN EVAL.INVISIBLE_POPULATION ip
       ON ip.aggregate_amount >= s.threshold
      AND s.threshold >= 800000
GROUP BY 1, 2, 3
ORDER BY 1;
