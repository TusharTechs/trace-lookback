-- ============================================================================
-- 08_reload_v2_corpus.sql — reload after the generator rework.
--
-- v1's corpus had no learnable signal: guilty and innocent drew declared
-- income from the same distribution, so the discriminating feature did not
-- discriminate. Both models responded rationally by flagging nearly everything
-- (llama3.1-8b 100/100, claude-sonnet-4-5 78/100).
--
-- v2 separates the classes by observable behaviour and introduces irreducible
-- ambiguity through behavioural mimicry. Measured on the regenerated corpus:
--
--   oracle ceiling on the evidence : 0.862
--   human accuracy vs truth        : 0.721
--   human recall vs truth          : 0.614
--   human precision vs truth       : 0.550
--   base rate (alerts truly dirty) : 0.314
--
-- The 14-point gap between human performance and the ceiling is the headroom
-- a model has to earn. It is deliberately not larger.
--
-- EVAL.GROUND_TRUTH changes shape: ambiguity/p_correct are gone (they belonged
-- to the discarded noise model); evidence_score and reviewer_noise_sd replace
-- them.
-- ============================================================================

-- NOTE: PUT paths are relative to the repository root. Launch CoCo from
-- the repo root (`cd <repo> && cortex`) so the client resolves them.

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE COMPUTE_WH;
USE DATABASE TRACE_DB;

-- ---------------------------------------------------------------------------
-- Schema change + clear-down
-- ---------------------------------------------------------------------------

CREATE OR REPLACE TABLE EVAL.GROUND_TRUTH (
    alert_id            STRING  NOT NULL PRIMARY KEY,
    is_truly_suspicious BOOLEAN NOT NULL,
    archetype           STRING  NOT NULL,   -- CLEAN | CASH_BUSINESS | MULE | LAYERING
    evidence_score      FLOAT,              -- weighted read of the observable features
    reviewer_noise_sd   FLOAT,              -- how corrupted this reviewer's read was
    reviewer_fatigue    FLOAT               -- caseload pressure that day
);

CREATE OR REPLACE TABLE CORE.DECISION_FEATURES_STG (
    alert_id     STRING,
    captured_at  TIMESTAMP_NTZ,
    features     STRING,
    feature_hash STRING
);

TRUNCATE TABLE CORE.TRANSACTIONS;
TRUNCATE TABLE CORE.ALERTS;
TRUNCATE TABLE CORE.DISPOSITIONS;
TRUNCATE TABLE CORE.DECISION_FEATURES;
TRUNCATE TABLE CORE.CUSTOMERS;
TRUNCATE TABLE CORE.BRANCHES;
TRUNCATE TABLE POLICY.POLICY_VERSIONS;
TRUNCATE TABLE POLICY.RULE_PREDICATES;
TRUNCATE TABLE EVAL.CALIBRATION_SET;
TRUNCATE TABLE EVAL.INVISIBLE_POPULATION;

-- Results from the v1 corpus are not comparable to v2 and must not be mixed.
DROP TABLE IF EXISTS EVAL.MODEL_DISPOSITIONS;
DROP TABLE IF EXISTS EVAL.MODEL_DISPOSITIONS_V2;

-- ---------------------------------------------------------------------------
-- Stage. OVERWRITE replaces the v1 files in place.
-- ---------------------------------------------------------------------------

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

-- ---------------------------------------------------------------------------
-- Load
-- ---------------------------------------------------------------------------

COPY INTO CORE.BRANCHES FROM @TRACE_DB.PUBLIC.CORPUS_STAGE/branches.csv.gz
    FILE_FORMAT = (FORMAT_NAME = TRACE_DB.PUBLIC.CSV_WITH_HEADER) MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE;
COPY INTO POLICY.POLICY_VERSIONS FROM @TRACE_DB.PUBLIC.CORPUS_STAGE/policy_versions.csv.gz
    FILE_FORMAT = (FORMAT_NAME = TRACE_DB.PUBLIC.CSV_WITH_HEADER) MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE;
COPY INTO POLICY.RULE_PREDICATES FROM @TRACE_DB.PUBLIC.CORPUS_STAGE/rule_predicates.csv.gz
    FILE_FORMAT = (FORMAT_NAME = TRACE_DB.PUBLIC.CSV_WITH_HEADER) MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE;
COPY INTO CORE.CUSTOMERS FROM @TRACE_DB.PUBLIC.CORPUS_STAGE/customers.csv.gz
    FILE_FORMAT = (FORMAT_NAME = TRACE_DB.PUBLIC.CSV_WITH_HEADER) MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE;
COPY INTO CORE.ALERTS FROM @TRACE_DB.PUBLIC.CORPUS_STAGE/alerts.csv.gz
    FILE_FORMAT = (FORMAT_NAME = TRACE_DB.PUBLIC.CSV_WITH_HEADER) MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE;
COPY INTO CORE.DISPOSITIONS FROM @TRACE_DB.PUBLIC.CORPUS_STAGE/dispositions.csv.gz
    FILE_FORMAT = (FORMAT_NAME = TRACE_DB.PUBLIC.CSV_WITH_HEADER) MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE;
COPY INTO CORE.TRANSACTIONS FROM @TRACE_DB.PUBLIC.CORPUS_STAGE/transactions.csv.gz
    FILE_FORMAT = (FORMAT_NAME = TRACE_DB.PUBLIC.CSV_WITH_HEADER) MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE;
COPY INTO EVAL.GROUND_TRUTH FROM @TRACE_DB.PUBLIC.CORPUS_STAGE/eval_ground_truth.csv.gz
    FILE_FORMAT = (FORMAT_NAME = TRACE_DB.PUBLIC.CSV_WITH_HEADER) MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE;
COPY INTO EVAL.CALIBRATION_SET FROM @TRACE_DB.PUBLIC.CORPUS_STAGE/eval_calibration_split.csv.gz
    FILE_FORMAT = (FORMAT_NAME = TRACE_DB.PUBLIC.CSV_WITH_HEADER) MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE;
COPY INTO EVAL.INVISIBLE_POPULATION FROM @TRACE_DB.PUBLIC.CORPUS_STAGE/eval_invisible_population.csv.gz
    FILE_FORMAT = (FORMAT_NAME = TRACE_DB.PUBLIC.CSV_WITH_HEADER) MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE;
COPY INTO CORE.DECISION_FEATURES_STG FROM @TRACE_DB.PUBLIC.CORPUS_STAGE/decision_features.csv.gz
    FILE_FORMAT = (FORMAT_NAME = TRACE_DB.PUBLIC.CSV_WITH_HEADER) MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE;

INSERT INTO CORE.DECISION_FEATURES (alert_id, captured_at, features, feature_hash)
SELECT alert_id, captured_at, PARSE_JSON(features), feature_hash
FROM CORE.DECISION_FEATURES_STG;

DROP TABLE IF EXISTS CORE.DECISION_FEATURES_STG;

-- ---------------------------------------------------------------------------
-- Verify. Expected: transactions 613,716 | alerts 5,967 | dispositions 5,967
--                  decision_features 5,967 | customers 1,200 | ground_truth 5,967
--                  invisible_pop 2,759 | policy_versions 3
-- ---------------------------------------------------------------------------

SELECT 'transactions'       AS entity, COUNT(*) AS n FROM CORE.TRANSACTIONS
UNION ALL SELECT 'alerts',            COUNT(*) FROM CORE.ALERTS
UNION ALL SELECT 'dispositions',      COUNT(*) FROM CORE.DISPOSITIONS
UNION ALL SELECT 'decision_features', COUNT(*) FROM CORE.DECISION_FEATURES
UNION ALL SELECT 'customers',         COUNT(*) FROM CORE.CUSTOMERS
UNION ALL SELECT 'policy_versions',   COUNT(*) FROM POLICY.POLICY_VERSIONS
UNION ALL SELECT 'ground_truth',      COUNT(*) FROM EVAL.GROUND_TRUTH
UNION ALL SELECT 'invisible_pop',     COUNT(*) FROM EVAL.INVISIBLE_POPULATION
ORDER BY entity;

-- Human baseline, recomputed in the warehouse. Must reproduce the generator's
-- own numbers: accuracy 0.721, recall 0.614, precision 0.550.
SELECT
    COUNT(*)                                                                      AS n,
    ROUND(AVG(CASE WHEN (d.outcome <> 'CLOSED_FP') = g.is_truly_suspicious
                   THEN 1 ELSE 0 END), 3)                                         AS accuracy,
    ROUND(AVG(CASE WHEN g.is_truly_suspicious AND d.outcome <> 'CLOSED_FP' THEN 1.0
                   WHEN g.is_truly_suspicious THEN 0.0 END), 3)                   AS recall,
    ROUND(AVG(CASE WHEN d.outcome <> 'CLOSED_FP' AND g.is_truly_suspicious THEN 1.0
                   WHEN d.outcome <> 'CLOSED_FP' THEN 0.0 END), 3)                AS precision,
    ROUND(AVG(CASE WHEN g.is_truly_suspicious THEN 1 ELSE 0 END), 3)              AS base_rate
FROM CORE.DISPOSITIONS d
JOIN EVAL.GROUND_TRUTH g ON g.alert_id = d.alert_id;

-- Separation of the evidence by class. Overlapping ranges are the point.
SELECT
    archetype,
    COUNT(*)                        AS n,
    ROUND(AVG(evidence_score), 3)   AS mean_evidence,
    ROUND(MIN(evidence_score), 3)   AS min_evidence,
    ROUND(MAX(evidence_score), 3)   AS max_evidence
FROM EVAL.GROUND_TRUTH
GROUP BY 1 ORDER BY mean_evidence;

-- The defect population.
SELECT
    COUNT(*)                                             AS invisible_customer_weeks,
    SUM(CASE WHEN is_truly_suspicious THEN 1 ELSE 0 END) AS truly_suspicious,
    ROUND(SUM(aggregate_amount) / 10000000, 1)           AS notional_inr_crore
FROM EVAL.INVISIBLE_POPULATION;
