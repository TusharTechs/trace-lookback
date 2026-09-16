-- ============================================================================
-- 04_load_fix.sql — corrects the COPY step from 03.
--
-- 03 created the stage with SKIP_HEADER = 1, which is incompatible with
-- MATCH_BY_COLUMN_NAME: that option needs PARSE_HEADER = TRUE so Snowflake can
-- read column names from the header row rather than discard it. The two are
-- mutually exclusive.
--
-- The files are already staged. No PUT here -- do not re-upload 59 MB.
-- ============================================================================

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE COMPUTE_WH;
USE DATABASE TRACE_DB;

CREATE OR REPLACE FILE FORMAT TRACE_DB.PUBLIC.CSV_WITH_HEADER
    TYPE = CSV
    PARSE_HEADER = TRUE
    FIELD_OPTIONALLY_ENCLOSED_BY = '"'
    NULL_IF = ('', 'NULL', 'None')
    EMPTY_FIELD_AS_NULL = TRUE
    COMMENT = 'Header-aware CSV, required by MATCH_BY_COLUMN_NAME';

-- 03 dropped this after its INSERT found nothing to insert.
CREATE OR REPLACE TABLE CORE.DECISION_FEATURES_STG (
    alert_id        STRING,
    captured_at     TIMESTAMP_NTZ,
    features        STRING,
    feature_hash    STRING
);

-- ---------------------------------------------------------------------------
-- Load, parents before children.
-- ---------------------------------------------------------------------------

COPY INTO TRACE_DB.CORE.BRANCHES FROM @TRACE_DB.PUBLIC.CORPUS_STAGE/branches.csv.gz
    FILE_FORMAT = (FORMAT_NAME = TRACE_DB.PUBLIC.CSV_WITH_HEADER) MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE;

COPY INTO TRACE_DB.POLICY.POLICY_VERSIONS FROM @TRACE_DB.PUBLIC.CORPUS_STAGE/policy_versions.csv.gz
    FILE_FORMAT = (FORMAT_NAME = TRACE_DB.PUBLIC.CSV_WITH_HEADER) MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE;

COPY INTO TRACE_DB.POLICY.RULE_PREDICATES FROM @TRACE_DB.PUBLIC.CORPUS_STAGE/rule_predicates.csv.gz
    FILE_FORMAT = (FORMAT_NAME = TRACE_DB.PUBLIC.CSV_WITH_HEADER) MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE;

COPY INTO TRACE_DB.CORE.CUSTOMERS FROM @TRACE_DB.PUBLIC.CORPUS_STAGE/customers.csv.gz
    FILE_FORMAT = (FORMAT_NAME = TRACE_DB.PUBLIC.CSV_WITH_HEADER) MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE;

COPY INTO TRACE_DB.CORE.ALERTS FROM @TRACE_DB.PUBLIC.CORPUS_STAGE/alerts.csv.gz
    FILE_FORMAT = (FORMAT_NAME = TRACE_DB.PUBLIC.CSV_WITH_HEADER) MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE;

COPY INTO TRACE_DB.CORE.DISPOSITIONS FROM @TRACE_DB.PUBLIC.CORPUS_STAGE/dispositions.csv.gz
    FILE_FORMAT = (FORMAT_NAME = TRACE_DB.PUBLIC.CSV_WITH_HEADER) MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE;

COPY INTO TRACE_DB.CORE.TRANSACTIONS FROM @TRACE_DB.PUBLIC.CORPUS_STAGE/transactions.csv.gz
    FILE_FORMAT = (FORMAT_NAME = TRACE_DB.PUBLIC.CSV_WITH_HEADER) MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE;

COPY INTO TRACE_DB.EVAL.GROUND_TRUTH FROM @TRACE_DB.PUBLIC.CORPUS_STAGE/eval_ground_truth.csv.gz
    FILE_FORMAT = (FORMAT_NAME = TRACE_DB.PUBLIC.CSV_WITH_HEADER) MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE;

COPY INTO TRACE_DB.EVAL.CALIBRATION_SET FROM @TRACE_DB.PUBLIC.CORPUS_STAGE/eval_calibration_split.csv.gz
    FILE_FORMAT = (FORMAT_NAME = TRACE_DB.PUBLIC.CSV_WITH_HEADER) MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE;

COPY INTO TRACE_DB.EVAL.INVISIBLE_POPULATION FROM @TRACE_DB.PUBLIC.CORPUS_STAGE/eval_invisible_population.csv.gz
    FILE_FORMAT = (FORMAT_NAME = TRACE_DB.PUBLIC.CSV_WITH_HEADER) MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE;

COPY INTO TRACE_DB.CORE.DECISION_FEATURES_STG FROM @TRACE_DB.PUBLIC.CORPUS_STAGE/decision_features.csv.gz
    FILE_FORMAT = (FORMAT_NAME = TRACE_DB.PUBLIC.CSV_WITH_HEADER) MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE;

INSERT INTO TRACE_DB.CORE.DECISION_FEATURES (alert_id, captured_at, features, feature_hash)
SELECT alert_id, captured_at, PARSE_JSON(features), feature_hash
FROM TRACE_DB.CORE.DECISION_FEATURES_STG;

DROP TABLE IF EXISTS TRACE_DB.CORE.DECISION_FEATURES_STG;

-- ---------------------------------------------------------------------------
-- Verify. Expected, from the generator's own run:
--   transactions 646,022 | alerts 2,702 | dispositions 2,702
--   decision_features 2,702 | customers 1,200 | policy_versions 3
--   ground_truth 2,702 | invisible_pop 2,010
-- ---------------------------------------------------------------------------

SELECT 'transactions'        AS entity, COUNT(*) AS n FROM TRACE_DB.CORE.TRANSACTIONS
UNION ALL SELECT 'alerts',             COUNT(*) FROM TRACE_DB.CORE.ALERTS
UNION ALL SELECT 'dispositions',       COUNT(*) FROM TRACE_DB.CORE.DISPOSITIONS
UNION ALL SELECT 'decision_features',  COUNT(*) FROM TRACE_DB.CORE.DECISION_FEATURES
UNION ALL SELECT 'customers',          COUNT(*) FROM TRACE_DB.CORE.CUSTOMERS
UNION ALL SELECT 'policy_versions',    COUNT(*) FROM TRACE_DB.POLICY.POLICY_VERSIONS
UNION ALL SELECT 'ground_truth',       COUNT(*) FROM TRACE_DB.EVAL.GROUND_TRUTH
UNION ALL SELECT 'invisible_pop',      COUNT(*) FROM TRACE_DB.EVAL.INVISIBLE_POPULATION
ORDER BY entity;

-- The headline number, computed in the warehouse.
SELECT
    COUNT(*)                                             AS invisible_customer_weeks,
    SUM(CASE WHEN is_truly_suspicious THEN 1 ELSE 0 END) AS truly_suspicious,
    ROUND(SUM(aggregate_amount) / 10000000, 1)           AS notional_inr_crore
FROM TRACE_DB.EVAL.INVISIBLE_POPULATION;

-- The bitemporal spine. Three dates must resolve to three different versions;
-- if they do not, nothing built on top of this is trustworthy.
SELECT '2025-03-01' AS as_of, POLICY.POLICY_AS_OF('TM-STRUCT', '2025-03-01'::DATE) AS version
UNION ALL SELECT '2026-01-15', POLICY.POLICY_AS_OF('TM-STRUCT', '2026-01-15'::DATE)
UNION ALL SELECT '2026-09-16', POLICY.POLICY_AS_OF('TM-STRUCT', '2026-09-16'::DATE);

-- First real replay: alerts whose as-was verdict differs from as-now.
SELECT
    a.policy_version_id                     AS fired_under,
    COUNT(*)                                AS alerts,
    SUM(CASE WHEN a.aggregate_amount >= 800000 THEN 1 ELSE 0 END) AS would_fire_today
FROM TRACE_DB.CORE.ALERTS a
GROUP BY 1
ORDER BY 1;
