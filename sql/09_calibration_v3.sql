-- ============================================================================
-- 09_calibration_v3.sql — head-to-head on the v2 corpus.
--
-- Prior attempts and why they failed:
--   v1  biased prompt ("cash volume alone is not suspicious") -> model cleared
--       everything it could. kappa ~= -0.01 on 20 rows.
--   v2  symmetric prompt, but the corpus had no signal: guilty and innocent
--       drew declared income from the same distribution. llama3.1-8b called
--       100/100 suspicious, claude-sonnet-4-5 78/100. Both were right to.
--   v3  corpus rebuilt so classes differ by observable behaviour, with ~20% of
--       mules behaving as clean skins. Measured in-warehouse:
--
--           oracle ceiling on the evidence : 0.862
--           human accuracy                 : 0.721
--           human recall                   : 0.614
--           human precision                : 0.550
--           base rate                      : 0.314
--
-- A result above ~0.88 means something is leaking, not that the model is
-- brilliant. The target band is 0.75-0.86.
--
-- The prompt carries typology guidance stated SYMMETRICALLY -- what structuring
-- looks like AND what legitimate cash trade looks like. Withholding it would
-- test whether the model happens to know Indian AML practice; stating only the
-- suspicious half would be the v1 error inverted.
-- ============================================================================

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE COMPUTE_WH;
USE DATABASE TRACE_DB;

DROP VIEW IF EXISTS EVAL.V_ADJUDICATION_PROMPT;
DROP VIEW IF EXISTS EVAL.V_ADJUDICATION_PROMPT_V2;
DROP VIEW IF EXISTS EVAL.V_ALERT_EVIDENCE;

CREATE OR REPLACE VIEW EVAL.V_PROMPT AS
SELECT
    f.alert_id,
    'You are an AML analyst at an Indian bank adjudicating a transaction monitoring alert.'
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
 || '- Total cash credits: INR '        || TO_VARCHAR(f.features:aggregate_amount::NUMBER, '999,999,999') || CHR(10)
 || '- Deposits: '                      || f.features:txn_count::STRING
                                        || ' (average INR ' || TO_VARCHAR(f.features:avg_deposit::NUMBER, '999,999,999') || ')' || CHR(10)
 || '- Deposits sitting just below a round number: '
                                        || TO_VARCHAR(f.features:deposits_just_under_round_pct::FLOAT) || '%' || CHR(10)
 || '- Alert threshold then in force: INR '
                                        || TO_VARCHAR(f.features:threshold_applied::NUMBER, '999,999,999') || CHR(10)
 || CHR(10)
 || 'PROPORTIONALITY' || CHR(10)
 || '- This week of cash equals '       || TO_VARCHAR(f.features:cash_vs_monthly_income::FLOAT)
                                        || ' times declared MONTHLY income' || CHR(10)
 || '- Declared annual income: INR '    || TO_VARCHAR(f.features:declared_annual_income::NUMBER, '999,999,999') || CHR(10)
 || '- Occupation: '                    || f.features:occupation::STRING
                                        || CASE WHEN f.features:occupation_is_cash_trade::BOOLEAN
                                                THEN ' (a cash-intensive trade)'
                                                ELSE ' (not normally a cash-intensive trade)' END || CHR(10)
 || CHR(10)
 || 'PATTERN OVER THE PRECEDING 6 MONTHS' || CHR(10)
 || '- Weeks with any cash activity: '  || TO_VARCHAR(f.features:weeks_with_cash_activity_pct::FLOAT) || '%' || CHR(10)
 || '- Week-to-week volatility of cash volume: ' || TO_VARCHAR(f.features:weekly_volatility::FLOAT)
                                        || ' (0 = identical every week, above 1 = highly irregular)' || CHR(10)
 || '- Weeks since cash activity first appeared: '
                                        || f.features:weeks_since_cash_activity_began::STRING || CHR(10)
 || CHR(10)
 || 'MOVEMENT OF FUNDS' || CHR(10)
 || '- Share of deposited cash transferred out within days: '
                                        || TO_VARCHAR(ROUND(f.features:outward_transfer_ratio::FLOAT * 100, 0)) || '%' || CHR(10)
 || '- Distinct branches used: '        || f.features:distinct_branches_used::STRING || CHR(10)
 || CHR(10)
 || 'CUSTOMER CONTEXT' || CHR(10)
 || '- Internal risk rating: '          || f.features:risk_rating::STRING || CHR(10)
 || '- Politically exposed: '           || f.features:is_pep::STRING || CHR(10)
 || '- Days since KYC refresh: '        || f.features:days_since_kyc::STRING || CHR(10)
 || '- Prior alerts on this customer: ' || f.features:prior_alert_count::STRING || CHR(10)
 || CHR(10)
 || 'Name the single strongest factor pointing to laundering and the single strongest innocent '
 || 'explanation, then give your verdict. Some accounts are deliberately operated to look like '
 || 'ordinary businesses and cannot be resolved from this evidence -- use LOW confidence for '
 || 'those rather than guessing.'
        AS prompt
FROM CORE.DECISION_FEATURES f;

SELECT prompt FROM EVAL.V_PROMPT LIMIT 1;

-- ---------------------------------------------------------------------------

CREATE OR REPLACE TABLE EVAL.MODEL_DISPOSITIONS (
    alert_id        STRING NOT NULL,
    model_name      STRING NOT NULL,
    tier            STRING NOT NULL,
    verdict         STRING,
    confidence_band STRING,
    aggravating     STRING,
    mitigating      STRING,
    raw             VARIANT,
    ran_at          TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE OR REPLACE TEMPORARY VIEW _sample AS
SELECT p.alert_id, p.prompt
FROM EVAL.V_PROMPT p
JOIN EVAL.CALIBRATION_SET c ON c.alert_id = p.alert_id
WHERE c.split = 'HOLDOUT'
ORDER BY HASH(p.alert_id)
LIMIT 100;

INSERT INTO EVAL.MODEL_DISPOSITIONS
    (alert_id, model_name, tier, verdict, confidence_band, aggravating, mitigating, raw)
WITH fmt AS (
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
    } AS f
)
SELECT r.alert_id, r.model_name, r.tier,
       UPPER(r.resp:verdict::STRING), UPPER(r.resp:confidence_band::STRING),
       r.resp:aggravating::STRING, r.resp:mitigating::STRING, r.resp
FROM (
    SELECT s.alert_id, 'llama3.1-8b' AS model_name, 'CHEAP' AS tier,
           TRY_PARSE_JSON(AI_COMPLETE(
               model => 'llama3.1-8b', prompt => s.prompt,
               model_parameters => {'temperature': 0, 'max_tokens': 400},
               response_format => (SELECT f FROM fmt))) AS resp
    FROM _sample s
    UNION ALL
    SELECT s.alert_id, 'claude-sonnet-4-5', 'FRONTIER',
           TRY_PARSE_JSON(AI_COMPLETE(
               model => 'claude-sonnet-4-5', prompt => s.prompt,
               model_parameters => {'temperature': 0, 'max_tokens': 400},
               response_format => (SELECT f FROM fmt))) AS resp
    FROM _sample s
) r;

-- ---------------------------------------------------------------------------
-- Results
-- ---------------------------------------------------------------------------

WITH j AS (
    SELECT m.tier,
           CASE WHEN m.verdict = 'SUSPICIOUS' THEN 1 ELSE 0 END AS mp,
           CASE WHEN d.outcome <> 'CLOSED_FP' THEN 1 ELSE 0 END AS hp,
           CASE WHEN g.is_truly_suspicious    THEN 1 ELSE 0 END AS tp
    FROM EVAL.MODEL_DISPOSITIONS m
    JOIN CORE.DISPOSITIONS d ON d.alert_id = m.alert_id
    JOIN EVAL.GROUND_TRUTH g ON g.alert_id = m.alert_id
    WHERE m.verdict IS NOT NULL
), a AS (
    SELECT tier, COUNT(*) n,
           AVG(CASE WHEN mp = hp THEN 1 ELSE 0 END) po,
           AVG(mp) pm, AVG(hp) ph,
           AVG(CASE WHEN mp = tp THEN 1 ELSE 0 END) acc,
           AVG(CASE WHEN tp = 1 AND mp = 1 THEN 1.0 WHEN tp = 1 THEN 0.0 END) rec,
           AVG(CASE WHEN mp = 1 AND tp = 1 THEN 1.0 WHEN mp = 1 THEN 0.0 END) prec
    FROM j GROUP BY tier
)
SELECT tier, n,
       ROUND((po - (pm*ph + (1-pm)*(1-ph))) / NULLIF(1 - (pm*ph + (1-pm)*(1-ph)), 0), 3) AS kappa_vs_human,
       ROUND(acc, 3)  AS accuracy_vs_truth,
       ROUND(rec, 3)  AS recall_vs_truth,
       ROUND(prec, 3) AS precision_vs_truth,
       ROUND(pm, 3)   AS pct_called_suspicious
FROM a ORDER BY tier;

-- Human on the SAME 100 alerts, so the comparison is like for like.
SELECT 'HUMAN' AS tier, COUNT(*) AS n,
       ROUND(AVG(CASE WHEN (d.outcome <> 'CLOSED_FP') = g.is_truly_suspicious THEN 1 ELSE 0 END), 3) AS accuracy_vs_truth,
       ROUND(AVG(CASE WHEN g.is_truly_suspicious AND d.outcome <> 'CLOSED_FP' THEN 1.0
                      WHEN g.is_truly_suspicious THEN 0.0 END), 3)                                  AS recall_vs_truth,
       ROUND(AVG(CASE WHEN d.outcome <> 'CLOSED_FP' AND g.is_truly_suspicious THEN 1.0
                      WHEN d.outcome <> 'CLOSED_FP' THEN 0.0 END), 3)                               AS precision_vs_truth
FROM _sample s
JOIN CORE.DISPOSITIONS d ON d.alert_id = s.alert_id
JOIN EVAL.GROUND_TRUTH g ON g.alert_id = s.alert_id;

-- Does confidence predict correctness? Without this the cascade has no
-- escalation trigger and abstention has nothing to threshold on.
SELECT m.tier, m.confidence_band, COUNT(*) AS n,
       ROUND(AVG(CASE WHEN (m.verdict = 'SUSPICIOUS') = g.is_truly_suspicious THEN 1 ELSE 0 END), 3) AS accuracy_vs_truth,
       ROUND(AVG(g.evidence_score), 3) AS mean_evidence
FROM EVAL.MODEL_DISPOSITIONS m
JOIN EVAL.GROUND_TRUTH g ON g.alert_id = m.alert_id
WHERE m.verdict IS NOT NULL
GROUP BY 1, 2
ORDER BY 1, DECODE(m.confidence_band, 'HIGH', 1, 'MEDIUM', 2, 'LOW', 3);

-- Does the model abstain on the clean skins? These are the mimicry cases --
-- genuinely dirty accounts whose record looks legitimate. If LOW confidence
-- concentrates here, the uncertainty signal is tracking real ambiguity.
SELECT m.tier, m.confidence_band,
       COUNT(*) AS n,
       SUM(CASE WHEN g.archetype IN ('MULE','LAYERING') AND g.evidence_score < 0.40 THEN 1 ELSE 0 END) AS clean_skin_cases
FROM EVAL.MODEL_DISPOSITIONS m
JOIN EVAL.GROUND_TRUTH g ON g.alert_id = m.alert_id
WHERE m.verdict IS NOT NULL
GROUP BY 1, 2 ORDER BY 1, 2;

SELECT alert_id, verdict, confidence_band, aggravating, mitigating
FROM EVAL.MODEL_DISPOSITIONS
WHERE tier = 'FRONTIER' AND confidence_band = 'LOW'
LIMIT 5;
