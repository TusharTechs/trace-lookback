-- ============================================================================
-- 13_adjudicate.sql — recalibrate on engine features, then adjudicate the
-- entire invisible population.
--
-- WHY RECALIBRATE
-- The replay engine validated against the generator on every feature except
-- prior_alert_count, which correlated -0.014. That was a generator bug: a
-- cumcount computed on a time-sorted copy, then indexed positionally against
-- the unsorted frame, so each alert received another alert's prior-count. The
-- SQL is the correct side. It is fixed in generate.py, but the loaded
-- DECISION_FEATURES still carries the stale value.
--
-- Rather than regenerate, the engine becomes the single source of features for
-- BOTH calibration and adjudication. They are then consistent by construction,
-- and DECISION_FEATURES reverts to what it should be: the frozen audit record
-- of what was shown at the time, not an input to the replay.
--
-- WHY IT IS SAFE TO ADJUDICATE IN THE SAME PASS
-- We persist the probability, not a verdict. The operating threshold is applied
-- analytically afterwards, so it can be re-picked from the sweep without
-- re-running a single model call.
--
-- SCALE: 150 calibration + 2,759 adjudication = ~2,900 calls on
-- claude-sonnet-4-5, roughly 2.9M tokens, on the order of USD 15.
--
-- Reference points: oracle ceiling 0.868 | human acc 0.731 | recall 0.595 |
--                   precision 0.573 | base rate 0.317
-- ============================================================================

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE COMPUTE_WH;
USE DATABASE TRACE_DB;

-- ---------------------------------------------------------------------------
-- 1. One prompt builder, driven by the engine. Works for any (customer, week)
--    whether or not an alert ever fired -- which is the whole point.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE VIEW EVAL.V_PROMPT_ENGINE AS
SELECT
    e.customer_id,
    e.week_start,
    'You are an AML analyst at an Indian bank adjudicating cash activity.'
 || CHR(10) || CHR(10)
 || 'TYPOLOGY' || CHR(10)
 || 'In structuring, deposits are kept below the reporting threshold, activity arrives in '
 || 'bursts, funds are moved out within days, and cash is disproportionate to declared income. '
 || 'In legitimate cash trade, deposits arrive steadily week after week, amounts vary naturally, '
 || 'funds are retained to pay suppliers, and turnover is consistent with a declared business. '
 || 'Both patterns produce large cash credits. Neither error is cheap: clearing laundering lets '
 || 'it continue, escalating ordinary business wastes investigator time.'
 || CHR(10) || CHR(10)
 || 'CASH ACTIVITY IN THIS 7-DAY WINDOW' || CHR(10)
 || '- Total cash credits: INR ' || TO_VARCHAR(e.aggregate_amount, '999,999,999') || CHR(10)
 || '- Deposits: ' || e.txn_count::STRING
                   || ' (average INR ' || TO_VARCHAR(e.avg_deposit, '999,999,999') || ')' || CHR(10)
 || '- Deposits sitting just below a round number: '
                   || TO_VARCHAR(e.deposits_just_under_round_pct) || '%' || CHR(10)
 || CHR(10)
 || 'PROPORTIONALITY' || CHR(10)
 || '- This week of cash equals ' || TO_VARCHAR(e.cash_vs_monthly_income)
                                  || ' times declared MONTHLY income' || CHR(10)
 || '- Declared annual income: INR ' || TO_VARCHAR(e.declared_annual_income, '999,999,999') || CHR(10)
 || '- Occupation: ' || e.occupation
                     || CASE WHEN e.occupation_is_cash_trade THEN ' (a cash-intensive trade)'
                             ELSE ' (not normally a cash-intensive trade)' END || CHR(10)
 || CHR(10)
 || 'PATTERN OVER THE PRECEDING ' || e.history_weeks_available::STRING || ' WEEKS' || CHR(10)
 || '- Weeks with any cash activity: ' || TO_VARCHAR(e.weeks_with_cash_activity_pct) || '%' || CHR(10)
 || '- Week-to-week volatility of cash volume: ' || TO_VARCHAR(e.weekly_volatility)
                                  || ' (0 = identical every week, above 1 = highly irregular)' || CHR(10)
 || '- Weeks since cash activity first appeared: '
                                  || e.weeks_since_cash_activity_began::STRING || CHR(10)
 || CHR(10)
 || 'MOVEMENT OF FUNDS' || CHR(10)
 -- A NULL ratio means there was no prior cash to transfer, not that funds were
 -- retained. Saying "0%" there invites the model to treat missing data as an
 -- innocent explanation, which is exactly what happened before this was fixed.
 || '- Share of deposited cash transferred out by NEFT/RTGS/IMPS: '
                                  || CASE WHEN e.outward_transfer_ratio IS NULL
                                          THEN 'not measurable - no cash activity in the preceding window'
                                          ELSE TO_VARCHAR(ROUND(e.outward_transfer_ratio * 100, 0)) || '%' END
                                  || CHR(10)
 || '- Distinct branches used: '  || e.distinct_branches_used::STRING || CHR(10)
 || CHR(10)
 || 'CUSTOMER CONTEXT' || CHR(10)
 || '- Internal risk rating: '    || e.risk_rating || CHR(10)
 || '- Politically exposed: '     || e.is_pep::STRING || CHR(10)
 || '- Days since KYC refresh: '  || e.days_since_kyc::STRING || CHR(10)
 || '- Prior alerts on this customer: ' || e.prior_alert_count::STRING || CHR(10)
 || CHR(10)
 || 'BASE RATE' || CHR(10)
 || 'Across cash activity of this size at this bank, roughly 3 in 10 are ultimately confirmed '
 || 'as suspicious. Most large cash alerts are legitimate business. Calibrate to that.'
 || CHR(10) || CHR(10)
 || 'Name the single strongest factor pointing to laundering and the single strongest innocent '
 || 'explanation. Then give probability_suspicious: your probability, between 0 and 1, that this '
 || 'activity is genuine money laundering. Use the full range. A well-calibrated 0.3 is more '
 || 'useful than a confident 0.9. Some accounts are deliberately operated to look like ordinary '
 || 'businesses and cannot be resolved from this evidence at all -- those should sit near the '
 || 'base rate, not at an extreme.'
        AS prompt
FROM CORE.V_POINT_IN_TIME_FEATURES e;

-- ---------------------------------------------------------------------------
-- 2. Recalibrate: 150 held-out ALERTS, engine features this time.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE TABLE EVAL.RECAL_SCORES (
    alert_id     STRING,
    p_suspicious FLOAT,
    aggravating  STRING,
    mitigating   STRING,
    raw          VARIANT,
    ran_at       TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

INSERT INTO EVAL.RECAL_SCORES (alert_id, p_suspicious, aggravating, mitigating, raw)
WITH fmt AS (
    SELECT {'type':'json','schema':{'type':'object','properties':{
        'aggravating':{'type':'string'},'mitigating':{'type':'string'},
        'probability_suspicious':{'type':'number'}},
        'required':['aggravating','mitigating','probability_suspicious']}} AS f
), s AS (
    SELECT a.alert_id, pe.prompt
    FROM CORE.ALERTS a
    JOIN EVAL.CALIBRATION_SET c   ON c.alert_id = a.alert_id AND c.split = 'HOLDOUT'
    JOIN EVAL.V_PROMPT_ENGINE pe  ON pe.customer_id = a.customer_id AND pe.week_start = a.window_start
    ORDER BY HASH(a.alert_id)
    LIMIT 150
)
SELECT r.alert_id, r.resp:probability_suspicious::FLOAT,
       r.resp:aggravating::STRING, r.resp:mitigating::STRING, r.resp
FROM (
    SELECT s.alert_id, TRY_PARSE_JSON(AI_COMPLETE(
               model => 'claude-sonnet-4-5', prompt => s.prompt,
               model_parameters => {'temperature': 0, 'max_tokens': 400},
               response_format => (SELECT f FROM fmt))) AS resp
    FROM s
) r;

-- AUC on engine features. Compare to 0.699 on generator features.
WITH j AS (
    SELECT r.p_suspicious p, CASE WHEN g.is_truly_suspicious THEN 1 ELSE 0 END y
    FROM EVAL.RECAL_SCORES r JOIN EVAL.GROUND_TRUTH g ON g.alert_id = r.alert_id
    WHERE r.p_suspicious IS NOT NULL
), rk AS (SELECT y, RANK() OVER (ORDER BY p) r FROM j)
SELECT COUNT(*) n, SUM(y) n_pos, SUM(1-y) n_neg,
       ROUND((SUM(CASE WHEN y=1 THEN r ELSE 0 END) - SUM(y)*(SUM(y)+1)/2.0)
             / NULLIF(SUM(y)*SUM(1-y),0), 3) AS auc
FROM rk;

-- Threshold sweep. Confirms or moves the 0.45 operating point.
WITH j AS (
    SELECT r.p_suspicious p, CASE WHEN g.is_truly_suspicious THEN 1 ELSE 0 END y
    FROM EVAL.RECAL_SCORES r JOIN EVAL.GROUND_TRUTH g ON g.alert_id = r.alert_id
    WHERE r.p_suspicious IS NOT NULL
), t AS (SELECT ROW_NUMBER() OVER (ORDER BY SEQ4())/20.0 thr FROM TABLE(GENERATOR(ROWCOUNT=>19)))
SELECT t.thr,
       ROUND(AVG(CASE WHEN (j.p>=t.thr)=(j.y=1) THEN 1 ELSE 0 END),3) accuracy,
       ROUND(AVG(CASE WHEN j.y=1 AND j.p>=t.thr THEN 1.0 WHEN j.y=1 THEN 0.0 END),3) recall,
       ROUND(AVG(CASE WHEN j.p>=t.thr AND j.y=1 THEN 1.0 WHEN j.p>=t.thr THEN 0.0 END),3) precision,
       ROUND(AVG(CASE WHEN j.p>=t.thr THEN 1 ELSE 0 END),3) pct_flagged
FROM j CROSS JOIN t GROUP BY 1 ORDER BY 1;

-- ---------------------------------------------------------------------------
-- 3. THE ADJUDICATION. Every one of the 2,759 customer-weeks that raised no
--    alert during the defect window. No file exists for any of these.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE TABLE EVAL.ADJUDICATION (
    customer_id      STRING,
    week_start       DATE,
    aggregate_amount NUMBER(15,2),
    p_suspicious     FLOAT,
    aggravating      STRING,
    mitigating       STRING,
    raw              VARIANT,
    model_name       STRING,
    ran_at           TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

INSERT INTO EVAL.ADJUDICATION
    (customer_id, week_start, aggregate_amount, p_suspicious, aggravating, mitigating, raw, model_name)
WITH fmt AS (
    SELECT {'type':'json','schema':{'type':'object','properties':{
        'aggravating':{'type':'string'},'mitigating':{'type':'string'},
        'probability_suspicious':{'type':'number'}},
        'required':['aggravating','mitigating','probability_suspicious']}} AS f
), s AS (
    SELECT ip.customer_id, ip.week_start, ip.aggregate_amount, pe.prompt
    FROM EVAL.INVISIBLE_POPULATION ip
    JOIN EVAL.V_PROMPT_ENGINE pe
      ON pe.customer_id = ip.customer_id AND pe.week_start = ip.week_start
)
SELECT r.customer_id, r.week_start, r.aggregate_amount,
       r.resp:probability_suspicious::FLOAT,
       r.resp:aggravating::STRING, r.resp:mitigating::STRING, r.resp,
       'claude-sonnet-4-5'
FROM (
    SELECT s.customer_id, s.week_start, s.aggregate_amount,
           TRY_PARSE_JSON(AI_COMPLETE(
               model => 'claude-sonnet-4-5', prompt => s.prompt,
               model_parameters => {'temperature': 0, 'max_tokens': 400},
               response_format => (SELECT f FROM fmt))) AS resp
    FROM s
) r;

SELECT COUNT(*) AS adjudicated,
       SUM(CASE WHEN p_suspicious IS NULL THEN 1 ELSE 0 END) AS unparsed
FROM EVAL.ADJUDICATION;

-- ---------------------------------------------------------------------------
-- 4. THE HEADLINE. What the lookback found.
-- ---------------------------------------------------------------------------

SELECT
    COUNT(*)                                                                   AS total_invisible_weeks,
    ROUND(SUM(aggregate_amount)/10000000, 1)                                   AS total_notional_cr,
    SUM(CASE WHEN p_suspicious >= 0.45 THEN 1 ELSE 0 END)                      AS flagged_at_0_45,
    ROUND(SUM(CASE WHEN p_suspicious >= 0.45 THEN aggregate_amount ELSE 0 END)/10000000, 1)
                                                                               AS flagged_notional_cr,
    COUNT(DISTINCT CASE WHEN p_suspicious >= 0.45 THEN customer_id END)        AS distinct_customers_flagged
FROM EVAL.ADJUDICATION
WHERE p_suspicious IS NOT NULL;

-- Against truth. This is the number that decides whether the system works.
SELECT
    ROUND(AVG(CASE WHEN (a.p_suspicious >= 0.45) = ip.is_truly_suspicious THEN 1 ELSE 0 END), 3) AS accuracy,
    ROUND(AVG(CASE WHEN ip.is_truly_suspicious AND a.p_suspicious >= 0.45 THEN 1.0
                   WHEN ip.is_truly_suspicious THEN 0.0 END), 3)                                 AS recall,
    ROUND(AVG(CASE WHEN a.p_suspicious >= 0.45 AND ip.is_truly_suspicious THEN 1.0
                   WHEN a.p_suspicious >= 0.45 THEN 0.0 END), 3)                                 AS precision,
    COUNT(*)                                                                                     AS n,
    SUM(CASE WHEN ip.is_truly_suspicious THEN 1 ELSE 0 END)                                      AS actually_dirty
FROM EVAL.ADJUDICATION a
JOIN EVAL.INVISIBLE_POPULATION ip
  ON ip.customer_id = a.customer_id AND ip.week_start = a.week_start
WHERE a.p_suspicious IS NOT NULL;

-- Three-band triage: clear / review / escalate.
SELECT
    CASE WHEN p_suspicious >= 0.60 THEN '3 ESCALATE (>=0.60)'
         WHEN p_suspicious >= 0.45 THEN '2 REVIEW (0.45-0.60)'
         ELSE '1 CLEAR (<0.45)' END                                     AS band,
    COUNT(*)                                                            AS weeks,
    ROUND(SUM(a.aggregate_amount)/10000000, 1)                          AS notional_cr,
    SUM(CASE WHEN ip.is_truly_suspicious THEN 1 ELSE 0 END)             AS actually_dirty,
    ROUND(AVG(CASE WHEN ip.is_truly_suspicious THEN 1 ELSE 0 END), 3)   AS dirty_rate
FROM EVAL.ADJUDICATION a
JOIN EVAL.INVISIBLE_POPULATION ip
  ON ip.customer_id = a.customer_id AND ip.week_start = a.week_start
WHERE a.p_suspicious IS NOT NULL
GROUP BY 1 ORDER BY 1;

-- The strongest cases the bank never looked at.
SELECT a.customer_id, a.week_start, a.aggregate_amount,
       ROUND(a.p_suspicious, 2) AS p, a.aggravating
FROM EVAL.ADJUDICATION a
WHERE a.p_suspicious IS NOT NULL
ORDER BY a.p_suspicious DESC, a.aggregate_amount DESC
LIMIT 5;
