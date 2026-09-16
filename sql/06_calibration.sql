-- ============================================================================
-- 06_calibration.sql — model adjudication, smoke test first.
--
-- This is the gate. The model reads the SAME frozen evidence a human reviewer
-- saw -- CORE.DECISION_FEATURES, nothing else -- and adjudicates. We then
-- measure agreement with the human label.
--
-- Leakage discipline:
--   * the prompt is built ONLY from DECISION_FEATURES (the point-in-time snapshot)
--   * it never sees CORE.DISPOSITIONS (the human's answer)
--   * it never sees EVAL.GROUND_TRUTH (archetype, is_truly_suspicious)
--   * temperature 0 so the run is reproducible
--
-- Run part A and B. Read the output. Only then run 07.
-- ============================================================================

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE COMPUTE_WH;
USE DATABASE TRACE_DB;

-- ---------------------------------------------------------------------------
-- A. Structures
-- ---------------------------------------------------------------------------

CREATE OR REPLACE TABLE EVAL.MODEL_DISPOSITIONS (
    alert_id    STRING          NOT NULL,
    model_name  STRING          NOT NULL,
    tier        STRING          NOT NULL,   -- CHEAP | FRONTIER
    verdict     STRING,                     -- SUSPICIOUS | NOT_SUSPICIOUS
    confidence  FLOAT,                      -- drives cascade escalation and abstention
    reason      STRING,
    raw         VARIANT,                    -- kept so parse failures are countable
    ran_at      TIMESTAMP_NTZ   DEFAULT CURRENT_TIMESTAMP()
);

-- The prompt. Deliberately presents the evidence flatly and does not hint at a
-- preferred answer -- a prompt that says "detect structuring" produces a model
-- that finds structuring everywhere, which would inflate agreement on the
-- suspicious class and destroy it on the 62% of cases that are legitimate.
CREATE OR REPLACE VIEW EVAL.V_ADJUDICATION_PROMPT AS
SELECT
    f.alert_id,
    'You are reviewing an anti-money-laundering alert at an Indian bank. '
 || 'Decide whether the activity is genuinely suspicious or has a legitimate explanation. '
 || 'Many alerts are raised on businesses that handle cash lawfully -- jewellers, petrol pumps, '
 || 'kirana stores, transport operators. Cash volume alone is not suspicious. '
 || 'Weigh the amount against the declared income, the stated occupation, and the prior history.'
 || CHR(10) || CHR(10)
 || 'ALERT EVIDENCE' || CHR(10)
 || '- Aggregate cash credits in window: INR ' || TO_VARCHAR(f.features:aggregate_amount::NUMBER, '999,999,999') || CHR(10)
 || '- Number of cash deposits: '            || f.features:txn_count::STRING || CHR(10)
 || '- Window: '                             || f.features:window_start::STRING || ' to ' || f.features:window_end::STRING || CHR(10)
 || '- Alert threshold then in force: INR '  || TO_VARCHAR(f.features:threshold_applied::NUMBER, '999,999,999') || CHR(10)
 || CHR(10)
 || 'CUSTOMER PROFILE' || CHR(10)
 || '- Occupation: '                         || f.features:occupation::STRING || CHR(10)
 || '- Declared annual income: INR '         || TO_VARCHAR(f.features:declared_annual_income::NUMBER, '999,999,999') || CHR(10)
 || '- Internal risk rating: '               || f.features:risk_rating::STRING || CHR(10)
 || '- Politically exposed person: '         || f.features:is_pep::STRING || CHR(10)
 || '- Days since KYC refresh: '             || f.features:days_since_kyc::STRING || CHR(10)
 || CHR(10)
 || 'PRIOR BEHAVIOUR' || CHR(10)
 || '- Previous alerts on this customer: '   || f.features:prior_alert_count::STRING || CHR(10)
 || '- Share of turnover in cash (180d): '   || TO_VARCHAR(ROUND(f.features:cash_ratio_prior_180d::FLOAT * 100, 1)) || '%' || CHR(10)
 || '- Average monthly credits (180d): INR ' || TO_VARCHAR(f.features:avg_monthly_credit_prior_180d::NUMBER, '999,999,999') || CHR(10)
 || CHR(10)
 || 'Respond with your verdict, a confidence between 0 and 1, and one sentence of reasoning. '
 || 'Use a low confidence when the evidence genuinely does not settle the question.'
        AS prompt
FROM CORE.DECISION_FEATURES f;

-- Eyeball one before spending anything.
SELECT prompt FROM EVAL.V_ADJUDICATION_PROMPT LIMIT 1;

-- ---------------------------------------------------------------------------
-- B. Smoke test: 20 alerts on the cheap tier.
--
-- Checks three things before scale: the prompt renders, response_format
-- returns parseable JSON, and the model does not simply answer SUSPICIOUS to
-- everything. Roughly 12k tokens -- effectively free.
-- ---------------------------------------------------------------------------

INSERT INTO EVAL.MODEL_DISPOSITIONS (alert_id, model_name, tier, verdict, confidence, reason, raw)
SELECT
    r.alert_id,
    'llama3.1-8b',
    'CHEAP',
    UPPER(r.resp:verdict::STRING),
    r.resp:confidence::FLOAT,
    r.resp:reason::STRING,
    r.resp
FROM (
    SELECT
        p.alert_id,
        TRY_PARSE_JSON(
            AI_COMPLETE(
                model  => 'llama3.1-8b',
                prompt => p.prompt,
                model_parameters => {'temperature': 0, 'max_tokens': 250},
                response_format  => {
                    'type': 'json',
                    'schema': {
                        'type': 'object',
                        'properties': {
                            'verdict':    {'type': 'string', 'enum': ['SUSPICIOUS', 'NOT_SUSPICIOUS']},
                            'confidence': {'type': 'number'},
                            'reason':     {'type': 'string'}
                        },
                        'required': ['verdict', 'confidence', 'reason']
                    }
                }
            )
        ) AS resp
    FROM EVAL.V_ADJUDICATION_PROMPT p
    JOIN EVAL.CALIBRATION_SET c ON c.alert_id = p.alert_id
    WHERE c.split = 'HOLDOUT'
    ORDER BY p.alert_id
    LIMIT 20
) r;

-- Did it parse, and is it discriminating?
SELECT
    COUNT(*)                                                     AS n,
    SUM(CASE WHEN raw IS NULL THEN 1 ELSE 0 END)                 AS parse_failures,
    SUM(CASE WHEN verdict = 'SUSPICIOUS' THEN 1 ELSE 0 END)      AS called_suspicious,
    SUM(CASE WHEN verdict = 'NOT_SUSPICIOUS' THEN 1 ELSE 0 END)  AS called_clean,
    ROUND(AVG(confidence), 3)                                    AS mean_confidence,
    ROUND(MIN(confidence), 3)                                    AS min_confidence,
    ROUND(MAX(confidence), 3)                                    AS max_confidence
FROM EVAL.MODEL_DISPOSITIONS
WHERE tier = 'CHEAP';

-- Read a few. If the reasoning is vacuous, the prompt needs work before scale.
SELECT alert_id, verdict, confidence, reason
FROM EVAL.MODEL_DISPOSITIONS
WHERE tier = 'CHEAP'
ORDER BY confidence
LIMIT 8;

-- Blunt sanity check against the human label on these 20. Not a result --
-- twenty rows prove nothing -- but an all-SUSPICIOUS or all-CLEAN model is
-- visible here and worth catching now.
SELECT
    m.verdict,
    d.outcome,
    COUNT(*) AS n
FROM EVAL.MODEL_DISPOSITIONS m
JOIN CORE.DISPOSITIONS d ON d.alert_id = m.alert_id
WHERE m.tier = 'CHEAP'
GROUP BY 1, 2
ORDER BY 1, 2;
