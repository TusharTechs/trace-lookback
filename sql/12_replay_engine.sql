-- ============================================================================
-- 12_replay_engine.sql — point-in-time features computed from the record.
--
-- The invisible population has no DECISION_FEATURES: no alert fired, so nothing
-- was ever snapshotted. Adjudicating those weeks means reconstructing what a
-- reviewer WOULD have seen, from CORE.TRANSACTIONS, as of that week.
--
-- This is the replay engine. It computes the same feature set the generator
-- produced, but from the transaction record rather than simulation state, for
-- ANY (customer, week) -- whether or not an alert fired.
--
-- CRITICAL: the model was calibrated on generator-computed features and the
-- 0.45 operating point was chosen against those. If SQL-computed features
-- differ materially, that threshold does not transfer. Part 4 validates the
-- engine against CORE.DECISION_FEATURES on the alert population, where both
-- exist, BEFORE anything is adjudicated. If agreement is poor, stop.
--
-- Two known divergences, stated up front rather than discovered later:
--   * distinct_branches_used -- the generator used a customer-level constant;
--     SQL counts branches actually used.
--   * outward_transfer_ratio -- the generator intended cash * ratio but emitted
--     1-4 transfers of (ratio * cash / 3), so realised outflow scatters around
--     the intended value. SQL measures what was actually transferred.
-- In both cases the SQL value is the more honest one: a reviewer sees transfers
-- that happened, not a simulation parameter.
--
-- Dialect notes (both bit on the first attempt):
--   * Snowflake has no named WINDOW clause -- every OVER is written inline.
--   * QUALIFY requires a window function; a plain predicate belongs in WHERE.
-- ============================================================================

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE COMPUTE_WH;
USE DATABASE TRACE_DB;

-- ---------------------------------------------------------------------------
-- 1. Weekly aggregates. Monday-anchored via DAYOFWEEKISO so week boundaries
--    do not depend on the session's WEEK_START parameter.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE VIEW CORE.V_WEEKLY_CASH AS
SELECT
    customer_id,
    DATEADD(day, -(DAYOFWEEKISO(value_date) - 1), value_date) AS week_start,
    SUM(amount)                                                AS cash_amount,
    COUNT(*)                                                   AS deposit_count,
    COUNT(DISTINCT branch_id)                                  AS branches_this_week,
    AVG(CASE WHEN (amount >= 45000  AND amount < 50000)
               OR (amount >= 90000  AND amount < 100000)
               OR (amount >= 180000 AND amount < 200000)
               OR (amount >= 450000 AND amount < 500000)
             THEN 1.0 ELSE 0.0 END)                            AS just_under_round_frac
FROM CORE.TRANSACTIONS
WHERE mode = 'CASH' AND direction = 'CR'
GROUP BY 1, 2;

-- Money leaving by transfer. UPI/card spend is excluded -- living expenses are
-- not layering.
CREATE OR REPLACE VIEW CORE.V_WEEKLY_OUTFLOW AS
SELECT
    customer_id,
    DATEADD(day, -(DAYOFWEEKISO(value_date) - 1), value_date) AS week_start,
    SUM(amount)                                                AS outflow_amount
FROM CORE.TRANSACTIONS
WHERE direction = 'DR' AND mode IN ('NEFT', 'RTGS', 'IMPS')
GROUP BY 1, 2;

CREATE OR REPLACE VIEW CORE.V_WEEKLY_ALERTS AS
SELECT
    customer_id,
    DATEADD(day, -(DAYOFWEEKISO(generated_at::DATE) - 1), generated_at::DATE) AS week_start,
    COUNT(*) AS alert_count
FROM CORE.ALERTS
GROUP BY 1, 2;

-- ---------------------------------------------------------------------------
-- 2. Calendar spine. Weeks with no cash must exist as zero rows, or "share of
--    weeks with activity" has no denominator.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE VIEW CORE.V_CUSTOMER_WEEK AS
WITH bounds AS (
    SELECT MIN(DATEADD(day, -(DAYOFWEEKISO(value_date) - 1), value_date)) AS w0,
           MAX(DATEADD(day, -(DAYOFWEEKISO(value_date) - 1), value_date)) AS w1
    FROM CORE.TRANSACTIONS
), weeks AS (
    SELECT DATEADD(week, SEQ4(), (SELECT w0 FROM bounds)) AS week_start
    FROM TABLE(GENERATOR(ROWCOUNT => 250))
)
SELECT c.customer_id, w.week_start
FROM CORE.CUSTOMERS c
CROSS JOIN weeks w
WHERE w.week_start <= (SELECT w1 FROM bounds);

-- ---------------------------------------------------------------------------
-- 3. The engine. Every rolling feature is computed over the 26 weeks STRICTLY
--    BEFORE the week in question (ROWS BETWEEN 26 PRECEDING AND 1 PRECEDING).
--    Letting the current week into its own history is how a replay flatters
--    itself, and it would invalidate every number downstream.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE VIEW CORE.V_POINT_IN_TIME_FEATURES AS
WITH base AS (
    SELECT
        cw.customer_id,
        cw.week_start,
        DATEADD(day, 6, cw.week_start)     AS week_end,
        COALESCE(wc.cash_amount, 0)        AS cash_amount,
        COALESCE(wc.deposit_count, 0)      AS deposit_count,
        COALESCE(wc.branches_this_week, 0) AS branches_this_week,
        wc.just_under_round_frac,
        COALESCE(wo.outflow_amount, 0)     AS outflow_amount,
        COALESCE(wa.alert_count, 0)        AS alert_count
    FROM CORE.V_CUSTOMER_WEEK cw
    LEFT JOIN CORE.V_WEEKLY_CASH    wc ON wc.customer_id = cw.customer_id AND wc.week_start = cw.week_start
    LEFT JOIN CORE.V_WEEKLY_OUTFLOW wo ON wo.customer_id = cw.customer_id AND wo.week_start = cw.week_start
    LEFT JOIN CORE.V_WEEKLY_ALERTS  wa ON wa.customer_id = cw.customer_id AND wa.week_start = cw.week_start
), rolled AS (
    SELECT
        b.customer_id, b.week_start, b.week_end,
        b.cash_amount, b.deposit_count, b.just_under_round_frac,

        COUNT(*) OVER (PARTITION BY b.customer_id ORDER BY b.week_start
                       ROWS BETWEEN 26 PRECEDING AND 1 PRECEDING)                       AS history_weeks,
        SUM(CASE WHEN b.cash_amount > 0 THEN 1 ELSE 0 END)
            OVER (PARTITION BY b.customer_id ORDER BY b.week_start
                  ROWS BETWEEN 26 PRECEDING AND 1 PRECEDING)                            AS active_weeks,
        AVG(CASE WHEN b.cash_amount > 0 THEN b.cash_amount END)
            OVER (PARTITION BY b.customer_id ORDER BY b.week_start
                  ROWS BETWEEN 26 PRECEDING AND 1 PRECEDING)                            AS mean_active_cash,
        STDDEV(CASE WHEN b.cash_amount > 0 THEN b.cash_amount END)
            OVER (PARTITION BY b.customer_id ORDER BY b.week_start
                  ROWS BETWEEN 26 PRECEDING AND 1 PRECEDING)                            AS sd_active_cash,
        MIN(CASE WHEN b.cash_amount > 0 THEN b.week_start END)
            OVER (PARTITION BY b.customer_id ORDER BY b.week_start
                  ROWS BETWEEN 26 PRECEDING AND 1 PRECEDING)                            AS first_active_week,
        SUM(b.cash_amount)
            OVER (PARTITION BY b.customer_id ORDER BY b.week_start
                  ROWS BETWEEN 26 PRECEDING AND 1 PRECEDING)                            AS hist_cash,
        SUM(b.outflow_amount)
            OVER (PARTITION BY b.customer_id ORDER BY b.week_start
                  ROWS BETWEEN 26 PRECEDING AND 1 PRECEDING)                            AS hist_outflow,
        MAX(b.branches_this_week)
            OVER (PARTITION BY b.customer_id ORDER BY b.week_start
                  ROWS BETWEEN 26 PRECEDING AND 1 PRECEDING)                            AS max_branches_hist,
        SUM(b.alert_count)
            OVER (PARTITION BY b.customer_id ORDER BY b.week_start
                  ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING)                     AS prior_alert_count
    FROM base b
)
SELECT
    r.customer_id,
    r.week_start,
    r.week_end,
    r.cash_amount                                                        AS aggregate_amount,
    r.deposit_count                                                      AS txn_count,
    ROUND(r.cash_amount / NULLIF(r.deposit_count, 0), 0)                 AS avg_deposit,
    ROUND(COALESCE(r.just_under_round_frac, 0) * 100, 1)                 AS deposits_just_under_round_pct,
    c.occupation,
    c.occupation IN ('Jeweller','Petrol Pump Operator','Kirana Store Owner',
                     'Restaurant Owner','Scrap Dealer','Transport Operator')
                                                                         AS occupation_is_cash_trade,
    c.declared_annual_income,
    ROUND(r.cash_amount / NULLIF(c.declared_annual_income / 12, 0), 2)   AS cash_vs_monthly_income,
    c.risk_rating,
    c.is_pep,
    DATEDIFF(day, c.kyc_completed_on, r.week_end)                        AS days_since_kyc,
    r.history_weeks                                                      AS history_weeks_available,
    ROUND(100.0 * r.active_weeks / NULLIF(r.history_weeks, 0), 1)        AS weeks_with_cash_activity_pct,
    -- CV over ACTIVE weeks only, matching the generator. 1.5 is its default
    -- when fewer than three active weeks exist.
    CASE WHEN r.active_weeks >= 3
         THEN ROUND(r.sd_active_cash / NULLIF(r.mean_active_cash, 0), 2)
         ELSE 1.5 END                                                    AS weekly_volatility,
    COALESCE(DATEDIFF(week, r.first_active_week, r.week_start), 0)       AS weeks_since_cash_activity_began,
    GREATEST(COALESCE(r.max_branches_hist, 1), 1)                        AS distinct_branches_used,
    -- NULL, not 0, when there was no prior cash to transfer.
    --
    -- This ratio is computed over the preceding window. For a sudden-onset
    -- account -- no cash for 26 weeks, then a large burst -- the denominator is
    -- zero. Coalescing that to 0 renders as "0% of cash was moved out", which
    -- the model read as evidence of funds being RETAINED, and cited as a
    -- mitigating factor on the highest-scored case in the whole run. An absence
    -- of data was presented as a measurement.
    --
    -- NULL propagates into the prompt as "no prior cash activity", which is
    -- what the record actually says.
    CASE WHEN COALESCE(r.hist_cash, 0) > 0
         THEN ROUND(LEAST(r.hist_outflow / r.hist_cash, 1.0), 2)
         ELSE NULL END                                                   AS outward_transfer_ratio,
    COALESCE(r.prior_alert_count, 0)                                     AS prior_alert_count
FROM rolled r
JOIN CORE.CUSTOMERS c ON c.customer_id = r.customer_id
WHERE r.history_weeks >= 13;

-- ---------------------------------------------------------------------------
-- 4. VALIDATION GATE
-- ---------------------------------------------------------------------------

CREATE OR REPLACE VIEW EVAL.V_FEATURE_VALIDATION AS
SELECT
    a.alert_id,
    df.features:aggregate_amount::FLOAT              AS gen_amount,
    pit.aggregate_amount                             AS sql_amount,
    df.features:cash_vs_monthly_income::FLOAT        AS gen_cash_ratio,
    pit.cash_vs_monthly_income                       AS sql_cash_ratio,
    df.features:weeks_with_cash_activity_pct::FLOAT  AS gen_active_pct,
    pit.weeks_with_cash_activity_pct                 AS sql_active_pct,
    df.features:weekly_volatility::FLOAT             AS gen_volatility,
    pit.weekly_volatility                            AS sql_volatility,
    df.features:deposits_just_under_round_pct::FLOAT AS gen_just_under,
    pit.deposits_just_under_round_pct                AS sql_just_under,
    df.features:outward_transfer_ratio::FLOAT        AS gen_outflow,
    pit.outward_transfer_ratio                       AS sql_outflow,
    df.features:distinct_branches_used::NUMBER       AS gen_branches,
    pit.distinct_branches_used                       AS sql_branches,
    df.features:prior_alert_count::NUMBER            AS gen_prior_alerts,
    pit.prior_alert_count                            AS sql_prior_alerts
FROM CORE.ALERTS a
JOIN CORE.DECISION_FEATURES df ON df.alert_id = a.alert_id
JOIN CORE.V_POINT_IN_TIME_FEATURES pit
     ON pit.customer_id = a.customer_id AND pit.week_start = a.window_start;

SELECT
    COUNT(*)                                                                    AS n_matched,
    ROUND(AVG(CASE WHEN ABS(gen_amount - sql_amount) < 1 THEN 1 ELSE 0 END), 4) AS amount_exact_match,
    ROUND(CORR(gen_cash_ratio,   sql_cash_ratio),   3)                          AS corr_cash_ratio,
    ROUND(CORR(gen_active_pct,   sql_active_pct),   3)                          AS corr_active_pct,
    ROUND(CORR(gen_volatility,   sql_volatility),   3)                          AS corr_volatility,
    ROUND(CORR(gen_just_under,   sql_just_under),   3)                          AS corr_just_under,
    ROUND(CORR(gen_outflow,      sql_outflow),      3)                          AS corr_outflow,
    ROUND(CORR(gen_branches,     sql_branches),     3)                          AS corr_branches,
    ROUND(CORR(gen_prior_alerts, sql_prior_alerts), 3)                          AS corr_prior_alerts
FROM EVAL.V_FEATURE_VALIDATION;

SELECT
    ROUND(MEDIAN(ABS(gen_cash_ratio - sql_cash_ratio)), 3) AS mad_cash_ratio,
    ROUND(MEDIAN(ABS(gen_active_pct - sql_active_pct)), 2) AS mad_active_pct,
    ROUND(MEDIAN(ABS(gen_volatility - sql_volatility)), 3) AS mad_volatility,
    ROUND(MEDIAN(ABS(gen_just_under - sql_just_under)), 2) AS mad_just_under,
    ROUND(MEDIAN(ABS(gen_outflow - sql_outflow)), 3)       AS mad_outflow,
    ROUND(MEDIAN(ABS(gen_branches - sql_branches)), 2)     AS mad_branches
FROM EVAL.V_FEATURE_VALIDATION;

SELECT
    (SELECT COUNT(*) FROM EVAL.INVISIBLE_POPULATION) AS invisible_weeks,
    (SELECT COUNT(*) FROM EVAL.INVISIBLE_POPULATION ip
       JOIN CORE.V_POINT_IN_TIME_FEATURES pit
         ON pit.customer_id = ip.customer_id AND pit.week_start = ip.week_start) AS with_features;

-- Reconstructed evidence for weeks that raised no alert and have no file.
SELECT pit.customer_id, pit.week_start, pit.aggregate_amount, pit.txn_count, pit.occupation,
       pit.cash_vs_monthly_income, pit.weeks_with_cash_activity_pct, pit.weekly_volatility,
       pit.deposits_just_under_round_pct, pit.outward_transfer_ratio,
       pit.distinct_branches_used, pit.history_weeks_available
FROM CORE.V_POINT_IN_TIME_FEATURES pit
JOIN EVAL.INVISIBLE_POPULATION ip
  ON ip.customer_id = pit.customer_id AND ip.week_start = pit.week_start
ORDER BY pit.aggregate_amount DESC
LIMIT 5;
