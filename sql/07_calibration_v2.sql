-- ============================================================================
-- 07_calibration_v2.sql — corrected prompt, derived ratios, head-to-head.
--
-- v1 scored kappa ~= -0.01 on a 20-row smoke test. Three causes, in order of
-- blame:
--
--  1. PROMPT BIAS (ours). v1 said "cash volume alone is not suspicious" and
--     "many alerts are raised on businesses that handle cash lawfully". That is
--     a thumb on the scale toward clearing, and the model obeyed it. v2 states
--     the aggravating and mitigating considerations symmetrically and asks for
--     both to be named.
--
--  2. ARITHMETIC (ours). v1 handed the model an amount and an annual income and
--     expected it to infer a ratio. Small models are bad at this. v2 computes
--     the ratios in SQL and passes them as numbers.
--
--  3. CONFIDENCE (the model's). Self-reported confidence spanned 0.4-0.6 with
--     no spread -- useless for abstention. v2 asks for a discrete band and,
--     more importantly, measures whether the frontier tier does better. The
--     cascade design waits on that evidence rather than assuming it.
--
-- Deliberately keeping temperature 0. Self-consistency sampling would give a
-- better uncertainty estimate, but a regulatory replay that returns different
-- answers on re-run is not defensible. Determinism is a requirement here, not a
-- convenience.
-- ============================================================================

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE COMPUTE_WH;
USE DATABASE TRACE_DB;

-- ---------------------------------------------------------------------------
-- Derived evidence. Computed in SQL because these ratios ARE the discriminator
-- and must not depend on a language model doing division.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE VIEW EVAL.V_ALERT_EVIDENCE AS
SELECT
    f.alert_id,
    f.features:aggregate_amount::NUMBER          AS agg_amount,
    f.features:txn_count::NUMBER                 AS txn_count,
    f.features:occupation::STRING                AS occupation,
    f.features:declared_annual_income::NUMBER    AS annual_income,
    f.features:risk_rating::STRING               AS risk_rating,
    f.features:is_pep::STRING                    AS is_pep,
    f.features:days_since_kyc::NUMBER            AS days_since_kyc,
    f.features:prior_alert_count::NUMBER         AS prior_alerts,
    f.features:cash_ratio_prior_180d::FLOAT      AS cash_ratio,
    f.features:threshold_applied::NUMBER         AS threshold_applied,
    f.features:window_start::STRING              AS window_start,
    f.features:window_end::STRING                AS window_end,

    -- One week of cash against one month of declared income. A salaried
    -- professional banking 15x their monthly income in cash in seven days is
    -- the signal; a jeweller doing the same is ordinary trade.
    ROUND(f.features:aggregate_amount::NUMBER
          / NULLIF(f.features:declared_annual_income::NUMBER / 12, 0), 2)
                                                 AS cash_vs_monthly_income,

    ROUND(f.features:aggregate_amount::NUMBER
          / NULLIF(f.features:txn_count::NUMBER, 0), 0)
                                                 AS avg_deposit_size,

    -- Does the occupation explain cash at all? Stated plainly so the model
    -- does not have to know Indian trade norms.
    CASE WHEN f.features:occupation::STRING IN (
            'Jeweller', 'Petrol Pump Operator', 'Kirana Store Owner',
            'Restaurant Owner', 'Scrap Dealer', 'Transport Operator')
         THEN 'YES - cash-intensive trade'
         ELSE 'NO - occupation does not normally involve large cash receipts'
    END                                          AS occupation_explains_cash
FROM CORE.DECISION_FEATURES f;

-- ---------------------------------------------------------------------------
-- v2 prompt. Symmetric framing, ratios supplied, both sides demanded.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE VIEW EVAL.V_ADJUDICATION_PROMPT_V2 AS
SELECT
    e.alert_id,
    'You are an AML analyst at an Indian bank adjudicating a transaction monitoring alert. '
 || 'Decide whether the activity is suspicious or has a legitimate explanation. '
 || 'Both errors are costly: clearing genuine laundering lets it continue, and escalating '
 || 'ordinary business wastes investigator time. Judge on the evidence given.'
 || CHR(10) || CHR(10)
 || 'CASH ACTIVITY IN A 7-DAY WINDOW' || CHR(10)
 || '- Total cash credits: INR '   || TO_VARCHAR(e.agg_amount, '999,999,999') || CHR(10)
 || '- Deposits: '                 || e.txn_count::STRING
                                   || ' (average INR ' || TO_VARCHAR(e.avg_deposit_size, '999,999,999') || ' each)' || CHR(10)
 || '- Window: '                   || e.window_start || ' to ' || e.window_end || CHR(10)
 || CHR(10)
 || 'PROPORTIONALITY' || CHR(10)
 || '- This week of cash equals ' || TO_VARCHAR(e.cash_vs_monthly_income)
                                  || ' times the customer''s declared MONTHLY income.' || CHR(10)
 || '- Declared annual income: INR ' || TO_VARCHAR(e.annual_income, '999,999,999') || CHR(10)
 || '- Occupation: '              || e.occupation || CHR(10)
 || '- Does this occupation normally involve large cash receipts? ' || e.occupation_explains_cash || CHR(10)
 || CHR(10)
 || 'CONTEXT' || CHR(10)
 || '- Internal risk rating: '    || e.risk_rating || CHR(10)
 || '- Politically exposed: '     || e.is_pep || CHR(10)
 || '- Days since KYC refresh: '  || e.days_since_kyc::STRING || CHR(10)
 || '- Prior alerts on this customer: ' || e.prior_alerts::STRING || CHR(10)
 || '- Share of turnover in cash over 180 days: ' || TO_VARCHAR(ROUND(e.cash_ratio * 100, 1)) || '%' || CHR(10)
 || CHR(10)
 || 'Name the single strongest factor pointing to laundering, and the single strongest '
 || 'innocent explanation, before giving your verdict. Set confidence to LOW when the two '
 || 'are genuinely balanced.'
        AS prompt
FROM EVAL.V_ALERT_EVIDENCE e;

SELECT prompt FROM EVAL.V_ADJUDICATION_PROMPT_V2 LIMIT 1;

-- ---------------------------------------------------------------------------
-- Head-to-head on the same 100 held-out alerts.
-- ~60k tokens on each side. Cheap tier is negligible; frontier is cents.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE TABLE EVAL.MODEL_DISPOSITIONS_V2 (
    alert_id        STRING  NOT NULL,
    model_name      STRING  NOT NULL,
    tier            STRING  NOT NULL,
    verdict         STRING,
    confidence_band STRING,          -- HIGH | MEDIUM | LOW
    aggravating     STRING,
    mitigating      STRING,
    raw             VARIANT,
    ran_at          TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE OR REPLACE TEMPORARY VIEW _sample AS
SELECT p.alert_id, p.prompt
FROM EVAL.V_ADJUDICATION_PROMPT_V2 p
JOIN EVAL.CALIBRATION_SET c ON c.alert_id = p.alert_id
WHERE c.split = 'HOLDOUT'
ORDER BY HASH(p.alert_id)          -- deterministic, unbiased sample
LIMIT 100;

INSERT INTO EVAL.MODEL_DISPOSITIONS_V2
    (alert_id, model_name, tier, verdict, confidence_band, aggravating, mitigating, raw)
WITH schema_def AS (
    SELECT {
        'type': 'json',
        'schema': {
            'type': 'object',
            'properties': {
                'aggravating':     {'type': 'string'},
                'mitigating':      {'type': 'string'},
                'verdict':         {'type': 'string', 'enum': ['SUSPICIOUS', 'NOT_SUSPICIOUS']},
                'confidence_band': {'type': 'string', 'enum': ['HIGH', 'MEDIUM', 'LOW']}
            },
            'required': ['aggravating', 'mitigating', 'verdict', 'confidence_band']
        }
    } AS fmt
)
SELECT
    r.alert_id, r.model_name, r.tier,
    UPPER(r.resp:verdict::STRING),
    UPPER(r.resp:confidence_band::STRING),
    r.resp:aggravating::STRING,
    r.resp:mitigating::STRING,
    r.resp
FROM (
    SELECT s.alert_id, 'llama3.1-8b' AS model_name, 'CHEAP' AS tier,
           TRY_PARSE_JSON(AI_COMPLETE(
               model => 'llama3.1-8b', prompt => s.prompt,
               model_parameters => {'temperature': 0, 'max_tokens': 400},
               response_format => (SELECT fmt FROM schema_def))) AS resp
    FROM _sample s
    UNION ALL
    SELECT s.alert_id, 'claude-sonnet-4-5' AS model_name, 'FRONTIER' AS tier,
           TRY_PARSE_JSON(AI_COMPLETE(
               model => 'claude-sonnet-4-5', prompt => s.prompt,
               model_parameters => {'temperature': 0, 'max_tokens': 400},
               response_format => (SELECT fmt FROM schema_def))) AS resp
    FROM _sample s
) r;

-- ---------------------------------------------------------------------------
-- Results. Three numbers per tier that decide the architecture.
-- ---------------------------------------------------------------------------

WITH j AS (
    SELECT
        m.tier,
        m.confidence_band,
        CASE WHEN m.verdict = 'SUSPICIOUS'       THEN 1 ELSE 0 END AS model_pos,
        CASE WHEN d.outcome <> 'CLOSED_FP'       THEN 1 ELSE 0 END AS human_pos,
        CASE WHEN g.is_truly_suspicious          THEN 1 ELSE 0 END AS truth_pos
    FROM EVAL.MODEL_DISPOSITIONS_V2 m
    JOIN CORE.DISPOSITIONS  d ON d.alert_id = m.alert_id
    JOIN EVAL.GROUND_TRUTH  g ON g.alert_id = m.alert_id
    WHERE m.verdict IS NOT NULL
),
agg AS (
    SELECT tier,
           COUNT(*) AS n,
           AVG(CASE WHEN model_pos = human_pos THEN 1 ELSE 0 END) AS po_human,
           AVG(model_pos) AS pm,
           AVG(human_pos) AS ph,
           AVG(CASE WHEN model_pos = truth_pos THEN 1 ELSE 0 END) AS acc_truth,
           AVG(CASE WHEN truth_pos = 1 AND model_pos = 1 THEN 1.0
                    WHEN truth_pos = 1 THEN 0.0 END)              AS recall_truth
    FROM j GROUP BY tier
)
SELECT
    tier, n,
    ROUND(po_human, 3)                                                   AS agreement_with_human,
    ROUND((po_human - (pm*ph + (1-pm)*(1-ph)))
          / NULLIF(1 - (pm*ph + (1-pm)*(1-ph)), 0), 3)                   AS kappa_vs_human,
    ROUND(acc_truth, 3)                                                  AS accuracy_vs_truth,
    ROUND(recall_truth, 3)                                               AS recall_vs_truth,
    ROUND(pm, 3)                                                         AS pct_called_suspicious
FROM agg ORDER BY tier;

-- Human baseline on the same 100 alerts, so the comparison is like for like.
SELECT
    'HUMAN' AS tier,
    COUNT(*) AS n,
    ROUND(AVG(CASE WHEN (d.outcome <> 'CLOSED_FP') = g.is_truly_suspicious THEN 1 ELSE 0 END), 3) AS accuracy_vs_truth,
    ROUND(AVG(CASE WHEN g.is_truly_suspicious AND d.outcome <> 'CLOSED_FP' THEN 1.0
                   WHEN g.is_truly_suspicious THEN 0.0 END), 3)                                  AS recall_vs_truth
FROM _sample s
JOIN CORE.DISPOSITIONS d ON d.alert_id = s.alert_id
JOIN EVAL.GROUND_TRUTH g ON g.alert_id = s.alert_id;

-- Is the confidence band worth anything? If accuracy does not fall from HIGH
-- to LOW, there is no abstention signal and the cascade needs another trigger.
SELECT
    m.tier, m.confidence_band,
    COUNT(*) AS n,
    ROUND(AVG(CASE WHEN (m.verdict = 'SUSPICIOUS') = g.is_truly_suspicious THEN 1 ELSE 0 END), 3) AS accuracy_vs_truth
FROM EVAL.MODEL_DISPOSITIONS_V2 m
JOIN EVAL.GROUND_TRUTH g ON g.alert_id = m.alert_id
GROUP BY 1, 2
ORDER BY 1, DECODE(m.confidence_band, 'HIGH', 1, 'MEDIUM', 2, 'LOW', 3);

-- Read the frontier model's actual reasoning on the hardest cases.
SELECT alert_id, verdict, confidence_band, aggravating, mitigating
FROM EVAL.MODEL_DISPOSITIONS_V2
WHERE tier = 'FRONTIER' AND confidence_band = 'LOW'
LIMIT 5;
