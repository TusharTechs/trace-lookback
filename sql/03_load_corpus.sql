-- ============================================================================
-- 03_load_corpus.sql — stage and load the generated corpus.
--
-- Run through CoCo CLI. On networks that inspect TLS, the Python connector
-- cannot complete a handshake: the proxy re-signs the Snowflake certificate
-- with a private root, and the connector's pyOpenSSL stack honours neither the
-- OS trust store nor REQUESTS_CA_BUNDLE. CoCo is a native binary using system
-- trust and connects cleanly, so it does the load.
--
-- PUT is a client-side command: paths resolve against the CoCo working directory.
-- ============================================================================

-- NOTE: PUT paths are relative to the repository root. Launch CoCo from
-- the repo root (`cd <repo> && cortex`) so the client resolves them.

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE COMPUTE_WH;
USE DATABASE TRACE_DB;

-- PARSE_HEADER, not SKIP_HEADER: MATCH_BY_COLUMN_NAME needs the header row
-- read rather than discarded, and the two options are mutually exclusive.
CREATE STAGE IF NOT EXISTS TRACE_DB.PUBLIC.CORPUS_STAGE
    FILE_FORMAT = (
        TYPE = CSV
        PARSE_HEADER = TRUE
        FIELD_OPTIONALLY_ENCLOSED_BY = '"'
        NULL_IF = ('', 'NULL', 'None')
        EMPTY_FIELD_AS_NULL = TRUE
    )
    COMMENT = 'Synthetic AML corpus, staged for COPY INTO';

-- ---------------------------------------------------------------------------
-- Stage. Smallest first: if branches.csv does not PUT, nothing else will.
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

-- 59 MB. Slowest step by far; everything else is seconds.
PUT 'file://generator/out/transactions.csv'              @TRACE_DB.PUBLIC.CORPUS_STAGE AUTO_COMPRESS = TRUE OVERWRITE = TRUE;

LIST @TRACE_DB.PUBLIC.CORPUS_STAGE;

-- ---------------------------------------------------------------------------
-- Load. MATCH_BY_COLUMN_NAME reconciles the generator's lowercase CSV headers
-- with Snowflake's uppercase identifiers, so column order does not matter.
-- ---------------------------------------------------------------------------

COPY INTO TRACE_DB.CORE.BRANCHES              FROM @TRACE_DB.PUBLIC.CORPUS_STAGE/branches.csv.gz                  MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE;
COPY INTO TRACE_DB.POLICY.POLICY_VERSIONS     FROM @TRACE_DB.PUBLIC.CORPUS_STAGE/policy_versions.csv.gz           MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE;
COPY INTO TRACE_DB.POLICY.RULE_PREDICATES     FROM @TRACE_DB.PUBLIC.CORPUS_STAGE/rule_predicates.csv.gz           MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE;
COPY INTO TRACE_DB.CORE.CUSTOMERS             FROM @TRACE_DB.PUBLIC.CORPUS_STAGE/customers.csv.gz                 MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE;
COPY INTO TRACE_DB.CORE.ALERTS                FROM @TRACE_DB.PUBLIC.CORPUS_STAGE/alerts.csv.gz                    MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE;
COPY INTO TRACE_DB.CORE.DISPOSITIONS          FROM @TRACE_DB.PUBLIC.CORPUS_STAGE/dispositions.csv.gz              MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE;
COPY INTO TRACE_DB.CORE.TRANSACTIONS          FROM @TRACE_DB.PUBLIC.CORPUS_STAGE/transactions.csv.gz              MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE;
COPY INTO TRACE_DB.EVAL.GROUND_TRUTH          FROM @TRACE_DB.PUBLIC.CORPUS_STAGE/eval_ground_truth.csv.gz         MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE;
COPY INTO TRACE_DB.EVAL.CALIBRATION_SET       FROM @TRACE_DB.PUBLIC.CORPUS_STAGE/eval_calibration_split.csv.gz    MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE;
COPY INTO TRACE_DB.EVAL.INVISIBLE_POPULATION  FROM @TRACE_DB.PUBLIC.CORPUS_STAGE/eval_invisible_population.csv.gz MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE;

-- VARIANT cannot be loaded directly from CSV: land the JSON as text, parse in.
COPY INTO TRACE_DB.CORE.DECISION_FEATURES_STG FROM @TRACE_DB.PUBLIC.CORPUS_STAGE/decision_features.csv.gz         MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE;

INSERT INTO TRACE_DB.CORE.DECISION_FEATURES (alert_id, captured_at, features, feature_hash)
SELECT alert_id, captured_at, PARSE_JSON(features), feature_hash
FROM TRACE_DB.CORE.DECISION_FEATURES_STG;

DROP TABLE IF EXISTS TRACE_DB.CORE.DECISION_FEATURES_STG;

-- ---------------------------------------------------------------------------
-- Verify against Snowflake rather than trusting the generator's own summary.
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

-- The defect, straight from the warehouse. This is the demo's headline number.
SELECT
    COUNT(*)                                                    AS invisible_customer_weeks,
    SUM(CASE WHEN is_truly_suspicious THEN 1 ELSE 0 END)        AS truly_suspicious,
    ROUND(SUM(aggregate_amount) / 10000000, 1)                  AS notional_inr_crore
FROM TRACE_DB.EVAL.INVISIBLE_POPULATION;

-- Point-in-time policy resolution must return three different versions.
SELECT '2025-03-01' AS as_of, POLICY.POLICY_AS_OF('TM-STRUCT', '2025-03-01'::DATE) AS version
UNION ALL SELECT '2026-01-15', POLICY.POLICY_AS_OF('TM-STRUCT', '2026-01-15'::DATE)
UNION ALL SELECT '2026-09-16', POLICY.POLICY_AS_OF('TM-STRUCT', '2026-09-16'::DATE);
