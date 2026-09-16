-- ============================================================================
-- 11_reload_and_score_v5.sql
--
-- Two things in one pass: reload the corpus after the history fix, then score
-- with tier-appropriate output contracts.
--
-- WHAT CHANGED IN THE CORPUS
-- Alerts now require 13 weeks of history. Previously an alert could fire in
-- week 2, giving rolling features with denominators of 1-3 and producing
-- contradictions the model was then asked to reconcile -- "100% of weeks
-- active" alongside "1 week since onset". Two of the three highest-scored
-- frontier cases were driven by that artifact.
--   ceiling 0.868 | human acc 0.731 | recall 0.595 | precision 0.573 | base 0.317
--
-- WHAT CHANGED IN THE SCORING
-- v4 measured 139/150 unparsed on llama3.1-8b: AI_COMPLETE with a JSON-schema
-- response_format does not work on that model. AI_CLASSIFY does -- it worked on
-- the very first smoke test. So the tiers get different contracts:
--
--   CHEAP    AI_CLASSIFY into 5 ordinal risk bands   -> coarse triage
--   FRONTIER AI_COMPLETE with JSON schema            -> calibrated probability
--
-- That asymmetry is the cascade design, not a workaround. A small model that
-- can reliably sort alerts into five buckets is exactly what is needed to
-- decide which cases deserve a frontier call.
-- ============================================================================

-- NOTE: PUT paths are relative to the repository root. Launch CoCo from
-- the repo root (`cd <repo> && cortex`) so the client resolves them.

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE COMPUTE_WH;
USE DATABASE TRACE_DB;

-- ---------------------------------------------------------------------------
-- PART 1 — reload
-- ---------------------------------------------------------------------------

CREATE OR REPLACE TABLE CORE.DECISION_FEATURES_STG (
    alert_id STRING, captured_at TIMESTAMP_NTZ, features STRING, feature_hash STRING);

TRUNCATE TABLE CORE.TRANSACTIONS;
TRUNCATE TABLE CORE.ALERTS;
TRUNCATE TABLE CORE.DISPOSITIONS;
TRUNCATE TABLE CORE.DECISION_FEATURES;
TRUNCATE TABLE CORE.CUSTOMERS;
TRUNCATE TABLE CORE.BRANCHES;
TRUNCATE TABLE POLICY.POLICY_VERSIONS;
TRUNCATE TABLE POLICY.RULE_PREDICATES;
TRUNCATE TABLE EVAL.GROUND_TRUTH;
TRUNCATE TABLE EVAL.CALIBRATION_SET;
TRUNCATE TABLE EVAL.INVISIBLE_POPULATION;

PUT 'file://generator/out/branches.csv'                  @TRACE_DB.PUBLIC.CORPUS_STAGE AUTO_COMPRESS = TRUE OVERWRITE = TRUE;
PUT 'file://generator/out/policy_versions.csv'           @TRACE_DB.PUBLIC.CORPUS_STAGE AUTO_COMPRESS = TRUE OVERWRITE = TRUE;
PUT 'file://generator/out/rule_predicates.csv'           @TRACE_DB.PUBLIC.CORPUS_STAGE AUTO_COMPRESS = TRUE OVERWRITE = TRUE;
PUT 'file://generator/out/customers.csv'                 @TRACE_DB.PUBLIC.CORPUS_STAGE AUTO_COMPRESS = TRUE OVERWRITE = TRUE;
PUT 'file://generator/out/alerts.csv'                    @TRACE_DB.PUBLIC.CORPUS_STAGE AUTO_COMPRESS = TRUE OVERWRITE = TRUE;
PUT 'file://generator/out/dispositions.csv'              @TRACE_DB.PUBLIC.CORPUS_STAGE AUTO_COMPRESS = TRUE OVERWRITE = TRUE;
PUT 'file://generator/out/decision_features.csv'         @TRACE_DB.PUBLIC.CORPUS_STAGE AUTO_COMPRESS = TRUE OVERWRITE = TRUE;
PUT 'file://generator/out/eval_ground_truth.csv'         @TRACE_DB.PUBLIC.CORPUS_STAGE AUTO_COMPRESS = TRUE OVERWRITE = TRUE;
PUT 'file://generator/out/eval_calibration_split.csv'    @TRACE_DB.PUBLIC.CORPUS_STAGE AUTO_COMPRESS = TRUE OVERWRITE = TRUE;
PUT 'file://generator/out/eval_invisible_population.csv' @TRACE_DB.PUBLIC.CORPUS_STAGE AUTO_COMPRESS = TRUE OVERWRITE = TRUE;
PUT 'file://generator/out/transactions.csv'              @TRACE_DB.PUBLIC.CORPUS_STAGE AUTO_COMPRESS = TRUE OVERWRITE = TRUE;

COPY INTO CORE.BRANCHES              FROM @TRACE_DB.PUBLIC.CORPUS_STAGE/branches.csv.gz                  FILE_FORMAT=(FORMAT_NAME=TRACE_DB.PUBLIC.CSV_WITH_HEADER) MATCH_BY_COLUMN_NAME=CASE_INSENSITIVE;
COPY INTO POLICY.POLICY_VERSIONS     FROM @TRACE_DB.PUBLIC.CORPUS_STAGE/policy_versions.csv.gz           FILE_FORMAT=(FORMAT_NAME=TRACE_DB.PUBLIC.CSV_WITH_HEADER) MATCH_BY_COLUMN_NAME=CASE_INSENSITIVE;
COPY INTO POLICY.RULE_PREDICATES     FROM @TRACE_DB.PUBLIC.CORPUS_STAGE/rule_predicates.csv.gz           FILE_FORMAT=(FORMAT_NAME=TRACE_DB.PUBLIC.CSV_WITH_HEADER) MATCH_BY_COLUMN_NAME=CASE_INSENSITIVE;
COPY INTO CORE.CUSTOMERS             FROM @TRACE_DB.PUBLIC.CORPUS_STAGE/customers.csv.gz                 FILE_FORMAT=(FORMAT_NAME=TRACE_DB.PUBLIC.CSV_WITH_HEADER) MATCH_BY_COLUMN_NAME=CASE_INSENSITIVE;
COPY INTO CORE.ALERTS                FROM @TRACE_DB.PUBLIC.CORPUS_STAGE/alerts.csv.gz                    FILE_FORMAT=(FORMAT_NAME=TRACE_DB.PUBLIC.CSV_WITH_HEADER) MATCH_BY_COLUMN_NAME=CASE_INSENSITIVE;
COPY INTO CORE.DISPOSITIONS          FROM @TRACE_DB.PUBLIC.CORPUS_STAGE/dispositions.csv.gz              FILE_FORMAT=(FORMAT_NAME=TRACE_DB.PUBLIC.CSV_WITH_HEADER) MATCH_BY_COLUMN_NAME=CASE_INSENSITIVE;
COPY INTO CORE.TRANSACTIONS          FROM @TRACE_DB.PUBLIC.CORPUS_STAGE/transactions.csv.gz              FILE_FORMAT=(FORMAT_NAME=TRACE_DB.PUBLIC.CSV_WITH_HEADER) MATCH_BY_COLUMN_NAME=CASE_INSENSITIVE;
COPY INTO EVAL.GROUND_TRUTH          FROM @TRACE_DB.PUBLIC.CORPUS_STAGE/eval_ground_truth.csv.gz         FILE_FORMAT=(FORMAT_NAME=TRACE_DB.PUBLIC.CSV_WITH_HEADER) MATCH_BY_COLUMN_NAME=CASE_INSENSITIVE;
COPY INTO EVAL.CALIBRATION_SET       FROM @TRACE_DB.PUBLIC.CORPUS_STAGE/eval_calibration_split.csv.gz    FILE_FORMAT=(FORMAT_NAME=TRACE_DB.PUBLIC.CSV_WITH_HEADER) MATCH_BY_COLUMN_NAME=CASE_INSENSITIVE;
COPY INTO EVAL.INVISIBLE_POPULATION  FROM @TRACE_DB.PUBLIC.CORPUS_STAGE/eval_invisible_population.csv.gz FILE_FORMAT=(FORMAT_NAME=TRACE_DB.PUBLIC.CSV_WITH_HEADER) MATCH_BY_COLUMN_NAME=CASE_INSENSITIVE;
COPY INTO CORE.DECISION_FEATURES_STG FROM @TRACE_DB.PUBLIC.CORPUS_STAGE/decision_features.csv.gz         FILE_FORMAT=(FORMAT_NAME=TRACE_DB.PUBLIC.CSV_WITH_HEADER) MATCH_BY_COLUMN_NAME=CASE_INSENSITIVE;

INSERT INTO CORE.DECISION_FEATURES (alert_id, captured_at, features, feature_hash)
SELECT alert_id, captured_at, PARSE_JSON(features), feature_hash FROM CORE.DECISION_FEATURES_STG;
DROP TABLE IF EXISTS CORE.DECISION_FEATURES_STG;

-- Must reproduce the generator: accuracy 0.731, recall 0.595, precision 0.573.
SELECT COUNT(*) AS n,
       ROUND(AVG(CASE WHEN (d.outcome <> 'CLOSED_FP') = g.is_truly_suspicious THEN 1 ELSE 0 END), 3) AS accuracy,
       ROUND(AVG(CASE WHEN g.is_truly_suspicious AND d.outcome <> 'CLOSED_FP' THEN 1.0
                      WHEN g.is_truly_suspicious THEN 0.0 END), 3)                                   AS recall,
       ROUND(AVG(CASE WHEN d.outcome <> 'CLOSED_FP' AND g.is_truly_suspicious THEN 1.0
                      WHEN d.outcome <> 'CLOSED_FP' THEN 0.0 END), 3)                                AS precision
FROM CORE.DISPOSITIONS d JOIN EVAL.GROUND_TRUTH g ON g.alert_id = d.alert_id;

-- The contradictory feature should be gone: minimum history is now 13 weeks.
SELECT MIN(features:history_weeks_available::NUMBER) AS min_history_weeks,
       MAX(features:history_weeks_available::NUMBER) AS max_history_weeks
FROM CORE.DECISION_FEATURES;

-- ---------------------------------------------------------------------------
-- PART 2 — score both tiers
-- ---------------------------------------------------------------------------

CREATE OR REPLACE TABLE EVAL.MODEL_SCORES (
    alert_id     STRING NOT NULL,
    model_name   STRING NOT NULL,
    tier         STRING NOT NULL,
    p_suspicious FLOAT,
    band         STRING,
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

-- CHEAP: ordinal banding. AI_CLASSIFY is a constrained API and holds on 8b
-- where a JSON schema does not.
INSERT INTO EVAL.MODEL_SCORES (alert_id, model_name, tier, p_suspicious, band, raw)
SELECT alert_id, 'llama3.1-8b', 'CHEAP',
       DECODE(band, 'VERY_LOW', 0.10, 'LOW', 0.30, 'MEDIUM', 0.50,
                    'HIGH', 0.70, 'VERY_HIGH', 0.90, NULL),
       band, resp
FROM (
    SELECT s.alert_id,
           AI_CLASSIFY(s.prompt,
                       ['VERY_LOW', 'LOW', 'MEDIUM', 'HIGH', 'VERY_HIGH']) AS resp,
           UPPER(AI_CLASSIFY(s.prompt,
                       ['VERY_LOW', 'LOW', 'MEDIUM', 'HIGH', 'VERY_HIGH']):labels[0]::STRING) AS band
    FROM _s s
);

-- FRONTIER: calibrated probability with reasoning.
INSERT INTO EVAL.MODEL_SCORES (alert_id, model_name, tier, p_suspicious, aggravating, mitigating, raw)
WITH fmt AS (
    SELECT {'type': 'json', 'schema': {'type': 'object', 'properties': {
        'aggravating': {'type': 'string'}, 'mitigating': {'type': 'string'},
        'probability_suspicious': {'type': 'number'}},
        'required': ['aggravating', 'mitigating', 'probability_suspicious']}} AS f
)
SELECT r.alert_id, 'claude-sonnet-4-5', 'FRONTIER',
       r.resp:probability_suspicious::FLOAT,
       r.resp:aggravating::STRING, r.resp:mitigating::STRING, r.resp
FROM (
    SELECT s.alert_id, TRY_PARSE_JSON(AI_COMPLETE(
               model => 'claude-sonnet-4-5', prompt => s.prompt,
               model_parameters => {'temperature': 0, 'max_tokens': 400},
               response_format => (SELECT f FROM fmt))) AS resp
    FROM _s s
) r;

SELECT tier, COUNT(*) AS n, SUM(CASE WHEN p_suspicious IS NULL THEN 1 ELSE 0 END) AS unparsed
FROM EVAL.MODEL_SCORES GROUP BY 1 ORDER BY 1;

-- ---------------------------------------------------------------------------
-- PART 3 — results
-- ---------------------------------------------------------------------------

WITH j AS (
    SELECT m.tier, m.p_suspicious AS p, CASE WHEN g.is_truly_suspicious THEN 1 ELSE 0 END AS y
    FROM EVAL.MODEL_SCORES m JOIN EVAL.GROUND_TRUTH g ON g.alert_id = m.alert_id
    WHERE m.p_suspicious IS NOT NULL
), r AS (SELECT tier, y, RANK() OVER (PARTITION BY tier ORDER BY p) rk FROM j)
SELECT tier, SUM(y) AS n_pos, SUM(1-y) AS n_neg,
       ROUND((SUM(CASE WHEN y=1 THEN rk ELSE 0 END) - SUM(y)*(SUM(y)+1)/2.0)
             / NULLIF(SUM(y)*SUM(1-y), 0), 3) AS auc
FROM r GROUP BY tier ORDER BY tier;

SELECT m.tier, CASE WHEN g.is_truly_suspicious THEN 'DIRTY' ELSE 'CLEAN' END AS actual,
       COUNT(*) n, ROUND(AVG(m.p_suspicious),3) mean_p, ROUND(MEDIAN(m.p_suspicious),3) median_p
FROM EVAL.MODEL_SCORES m JOIN EVAL.GROUND_TRUTH g ON g.alert_id = m.alert_id
WHERE m.p_suspicious IS NOT NULL GROUP BY 1,2 ORDER BY 1,2;

WITH j AS (
    SELECT m.tier, m.p_suspicious p, CASE WHEN g.is_truly_suspicious THEN 1 ELSE 0 END y
    FROM EVAL.MODEL_SCORES m JOIN EVAL.GROUND_TRUTH g ON g.alert_id = m.alert_id
    WHERE m.p_suspicious IS NOT NULL
), t AS (SELECT ROW_NUMBER() OVER (ORDER BY SEQ4())/20.0 thr FROM TABLE(GENERATOR(ROWCOUNT=>19)))
SELECT j.tier, t.thr,
       ROUND(AVG(CASE WHEN (j.p>=t.thr)=(j.y=1) THEN 1 ELSE 0 END),3) accuracy,
       ROUND(AVG(CASE WHEN j.y=1 AND j.p>=t.thr THEN 1.0 WHEN j.y=1 THEN 0.0 END),3) recall,
       ROUND(AVG(CASE WHEN j.p>=t.thr AND j.y=1 THEN 1.0 WHEN j.p>=t.thr THEN 0.0 END),3) precision,
       ROUND(AVG(CASE WHEN j.p>=t.thr THEN 1 ELSE 0 END),3) pct_flagged
FROM j CROSS JOIN t GROUP BY 1,2 ORDER BY 1,2;

-- Cascade viability: does the cheap band predict what the frontier concludes?
-- If VERY_LOW/LOW bands are reliably clean, they need no frontier call at all.
SELECT c.band, COUNT(*) AS n,
       ROUND(AVG(f.p_suspicious), 3)                                          AS mean_frontier_p,
       ROUND(AVG(CASE WHEN g.is_truly_suspicious THEN 1 ELSE 0 END), 3)       AS actual_dirty_rate
FROM EVAL.MODEL_SCORES c
JOIN EVAL.MODEL_SCORES f ON f.alert_id = c.alert_id AND f.tier = 'FRONTIER'
JOIN EVAL.GROUND_TRUTH  g ON g.alert_id = c.alert_id
WHERE c.tier = 'CHEAP' AND c.band IS NOT NULL
GROUP BY 1 ORDER BY DECODE(c.band,'VERY_LOW',1,'LOW',2,'MEDIUM',3,'HIGH',4,'VERY_HIGH',5);

SELECT m.tier,
       CASE WHEN g.archetype IN ('MULE','LAYERING') AND g.evidence_score < 0.40 THEN 'CLEAN_SKIN (dirty, looks clean)'
            WHEN g.archetype IN ('MULE','LAYERING') THEN 'DIRTY (looks dirty)'
            WHEN g.evidence_score > 0.55 THEN 'CLEAN (looks dirty)'
            ELSE 'CLEAN (looks clean)' END AS case_type,
       COUNT(*) n, ROUND(AVG(m.p_suspicious),3) mean_p
FROM EVAL.MODEL_SCORES m JOIN EVAL.GROUND_TRUTH g ON g.alert_id = m.alert_id
WHERE m.p_suspicious IS NOT NULL GROUP BY 1,2 ORDER BY 1,2;
