-- ============================================================================
-- 10_calibration_v4.sql — score, don't classify.
--
-- WHAT WENT WRONG IN v3 (a measurement error, not a model failure)
-- We asked for a binary verdict and scored accuracy at whatever threshold the
-- model picked internally. That conflates two separable things: can the model
-- RANK cases by risk, and is its decision threshold in the right place. A model
-- that ranks perfectly but flags at p>0.2 scores identically to one with no
-- signal at all.
--
-- v3 frontier: accuracy 0.480, recall 0.935, precision 0.367, 79% flagged,
-- against a human baseline of 0.770 / 0.677 / 0.618 on the same 100 alerts.
-- That profile is consistent EITHER with no discrimination OR with good
-- discrimination and a badly placed threshold. AUC distinguishes them; nothing
-- we measured did.
--
-- v4 therefore asks for a probability and measures AUC first. The operating
-- threshold is ours to choose afterwards, which is how risk systems are
-- actually built, and it makes abstention a middle band rather than something
-- the model has to volunteer (in v3 it never once said LOW).
--
-- The prompt also states the base rate. An analyst knows roughly 3 in 10 of
-- these alerts are confirmed; withholding it guarantees over-flagging.
--
-- Reference points on this corpus:
--     oracle ceiling (evidence) 0.862 | human acc 0.721 | human recall 0.614
--     base rate 0.314
-- AUC below ~0.65 means the evidence is not reaching the model.
-- AUC above ~0.95 means something is leaking.
-- ============================================================================

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE COMPUTE_WH;
USE DATABASE TRACE_DB;

-- ---------------------------------------------------------------------------
-- 0. Why did the CHEAP tier vanish from v3? Diagnose before rerunning.
-- ---------------------------------------------------------------------------

SELECT tier, model_name,
       COUNT(*)                                            AS rows_inserted,
       SUM(CASE WHEN raw IS NULL THEN 1 ELSE 0 END)        AS raw_null,
       SUM(CASE WHEN verdict IS NULL THEN 1 ELSE 0 END)    AS verdict_null
FROM EVAL.MODEL_DISPOSITIONS
GROUP BY 1, 2 ORDER BY 1;

-- If raw came back non-null but unparsed, look at what it actually returned.
SELECT tier, TO_VARCHAR(raw) AS raw_text
FROM EVAL.MODEL_DISPOSITIONS
WHERE verdict IS NULL
LIMIT 3;

-- ---------------------------------------------------------------------------
-- 1. Prompt v4: base rate stated, probability requested.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE VIEW EVAL.V_PROMPT_V4 AS
SELECT
    p.alert_id,
    REPLACE(
        p.prompt,
        'Name the single strongest factor pointing to laundering and the single strongest innocent '
     || 'explanation, then give your verdict. Some accounts are deliberately operated to look like '
     || 'ordinary businesses and cannot be resolved from this evidence -- use LOW confidence for '
     || 'those rather than guessing.',
        'BASE RATE' || CHR(10)
     || 'Across alerts of this type at this bank, roughly 3 in 10 are ultimately confirmed as '
     || 'suspicious. Most large cash alerts are legitimate business. Calibrate to that.'
     || CHR(10) || CHR(10)
     || 'Name the single strongest factor pointing to laundering and the single strongest innocent '
     || 'explanation. Then give probability_suspicious: your probability, between 0 and 1, that '
     || 'this activity is genuine money laundering. Use the full range. A well-calibrated 0.3 is '
     || 'more useful than a confident 0.9. Some accounts are deliberately operated to look like '
     || 'ordinary businesses and cannot be resolved from this evidence at all -- those should sit '
     || 'near the base rate, not at an extreme.'
    ) AS prompt
FROM EVAL.V_PROMPT p;

SELECT prompt FROM EVAL.V_PROMPT_V4 LIMIT 1;

-- ---------------------------------------------------------------------------
-- 2. Score 150 held-out alerts on both tiers.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE TABLE EVAL.MODEL_SCORES (
    alert_id     STRING NOT NULL,
    model_name   STRING NOT NULL,
    tier         STRING NOT NULL,
    p_suspicious FLOAT,
    aggravating  STRING,
    mitigating   STRING,
    raw          VARIANT,
    ran_at       TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE OR REPLACE TEMPORARY VIEW _s AS
SELECT p.alert_id, p.prompt
FROM EVAL.V_PROMPT_V4 p
JOIN EVAL.CALIBRATION_SET c ON c.alert_id = p.alert_id
WHERE c.split = 'HOLDOUT'
ORDER BY HASH(p.alert_id)
LIMIT 150;

INSERT INTO EVAL.MODEL_SCORES
    (alert_id, model_name, tier, p_suspicious, aggravating, mitigating, raw)
WITH fmt AS (
    SELECT {
        'type': 'json',
        'schema': {
            'type': 'object',
            'properties': {
                'aggravating':          {'type': 'string'},
                'mitigating':           {'type': 'string'},
                'probability_suspicious': {'type': 'number'}
            },
            'required': ['aggravating', 'mitigating', 'probability_suspicious']
        }
    } AS f
)
SELECT r.alert_id, r.model_name, r.tier,
       r.resp:probability_suspicious::FLOAT,
       r.resp:aggravating::STRING, r.resp:mitigating::STRING, r.resp
FROM (
    SELECT s.alert_id, 'llama3.1-8b' AS model_name, 'CHEAP' AS tier,
           TRY_PARSE_JSON(AI_COMPLETE(
               model => 'llama3.1-8b', prompt => s.prompt,
               model_parameters => {'temperature': 0, 'max_tokens': 400},
               response_format => (SELECT f FROM fmt))) AS resp
    FROM _s s
    UNION ALL
    SELECT s.alert_id, 'claude-sonnet-4-5', 'FRONTIER',
           TRY_PARSE_JSON(AI_COMPLETE(
               model => 'claude-sonnet-4-5', prompt => s.prompt,
               model_parameters => {'temperature': 0, 'max_tokens': 400},
               response_format => (SELECT f FROM fmt))) AS resp
    FROM _s s
) r;

SELECT tier, COUNT(*) AS n,
       SUM(CASE WHEN p_suspicious IS NULL THEN 1 ELSE 0 END) AS unparsed
FROM EVAL.MODEL_SCORES GROUP BY 1 ORDER BY 1;

-- ---------------------------------------------------------------------------
-- 3. AUC -- the metric that should have come first.
--    Threshold-independent: does the model RANK dirty above clean at all?
--    Mann-Whitney formulation, ties handled by average rank.
-- ---------------------------------------------------------------------------

WITH j AS (
    SELECT m.tier, m.p_suspicious AS p,
           CASE WHEN g.is_truly_suspicious THEN 1 ELSE 0 END AS y
    FROM EVAL.MODEL_SCORES m
    JOIN EVAL.GROUND_TRUTH g ON g.alert_id = m.alert_id
    WHERE m.p_suspicious IS NOT NULL
), r AS (
    SELECT tier, y, RANK() OVER (PARTITION BY tier ORDER BY p) AS rk
    FROM j
)
SELECT tier,
       SUM(y)                                  AS n_pos,
       SUM(1 - y)                              AS n_neg,
       ROUND((SUM(CASE WHEN y = 1 THEN rk ELSE 0 END)
              - SUM(y) * (SUM(y) + 1) / 2.0)
             / NULLIF(SUM(y) * SUM(1 - y), 0), 3) AS auc
FROM r GROUP BY tier ORDER BY tier;

-- Score distribution by class. Overlapping means with separated tails is the
-- signature of a usable ranker.
SELECT m.tier,
       CASE WHEN g.is_truly_suspicious THEN 'DIRTY' ELSE 'CLEAN' END AS actual,
       COUNT(*) AS n,
       ROUND(AVG(m.p_suspicious), 3)   AS mean_p,
       ROUND(MEDIAN(m.p_suspicious), 3) AS median_p,
       ROUND(MIN(m.p_suspicious), 3)   AS min_p,
       ROUND(MAX(m.p_suspicious), 3)   AS max_p
FROM EVAL.MODEL_SCORES m
JOIN EVAL.GROUND_TRUTH g ON g.alert_id = m.alert_id
WHERE m.p_suspicious IS NOT NULL
GROUP BY 1, 2 ORDER BY 1, 2;

-- ---------------------------------------------------------------------------
-- 4. Threshold sweep. We pick the operating point, not the model.
-- ---------------------------------------------------------------------------

WITH j AS (
    SELECT m.tier, m.p_suspicious AS p,
           CASE WHEN g.is_truly_suspicious THEN 1 ELSE 0 END AS y
    FROM EVAL.MODEL_SCORES m
    JOIN EVAL.GROUND_TRUTH g ON g.alert_id = m.alert_id
    WHERE m.p_suspicious IS NOT NULL
), t AS (
    SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) / 20.0 AS thr
    FROM TABLE(GENERATOR(ROWCOUNT => 19))
)
SELECT j.tier, t.thr,
       ROUND(AVG(CASE WHEN (j.p >= t.thr) = (j.y = 1) THEN 1 ELSE 0 END), 3) AS accuracy,
       ROUND(AVG(CASE WHEN j.y = 1 AND j.p >= t.thr THEN 1.0
                      WHEN j.y = 1 THEN 0.0 END), 3)                          AS recall,
       ROUND(AVG(CASE WHEN j.p >= t.thr AND j.y = 1 THEN 1.0
                      WHEN j.p >= t.thr THEN 0.0 END), 3)                     AS precision,
       ROUND(AVG(CASE WHEN j.p >= t.thr THEN 1 ELSE 0 END), 3)                AS pct_flagged
FROM j CROSS JOIN t
GROUP BY 1, 2
HAVING COUNT(*) > 0
ORDER BY 1, 2;

-- ---------------------------------------------------------------------------
-- 5. Does the score track genuine ambiguity? Clean skins are dirty accounts
--    whose record looks legitimate -- nobody can resolve them. A good ranker
--    should place them mid-scale, not confidently clean.
-- ---------------------------------------------------------------------------

SELECT m.tier,
       CASE WHEN g.archetype IN ('MULE','LAYERING') AND g.evidence_score < 0.40 THEN 'CLEAN_SKIN (dirty, looks clean)'
            WHEN g.archetype IN ('MULE','LAYERING')                             THEN 'DIRTY (looks dirty)'
            WHEN g.evidence_score > 0.55                                        THEN 'CLEAN (looks dirty)'
            ELSE 'CLEAN (looks clean)' END AS case_type,
       COUNT(*) AS n,
       ROUND(AVG(m.p_suspicious), 3) AS mean_p
FROM EVAL.MODEL_SCORES m
JOIN EVAL.GROUND_TRUTH g ON g.alert_id = m.alert_id
WHERE m.p_suspicious IS NOT NULL
GROUP BY 1, 2 ORDER BY 1, 2;

SELECT alert_id, ROUND(p_suspicious, 2) AS p, aggravating, mitigating
FROM EVAL.MODEL_SCORES
WHERE tier = 'FRONTIER'
ORDER BY p_suspicious DESC LIMIT 3;

SELECT alert_id, ROUND(p_suspicious, 2) AS p, aggravating, mitigating
FROM EVAL.MODEL_SCORES
WHERE tier = 'FRONTIER'
ORDER BY p_suspicious ASC LIMIT 3;
