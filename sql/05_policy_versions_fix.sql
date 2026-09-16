-- ============================================================================
-- 05_policy_versions_fix.sql
--
-- policy_versions.csv carries a stray window_days column: the generator was
-- emitting a rule parameter on the version record. Fixed at source in
-- generate.py, but the file is already staged, and MATCH_BY_COLUMN_NAME maps
-- the nine named columns correctly regardless -- it only objects to the count.
-- Tolerate the extra column for this one load.
-- ============================================================================

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE COMPUTE_WH;
USE DATABASE TRACE_DB;

COPY INTO TRACE_DB.POLICY.POLICY_VERSIONS
FROM @TRACE_DB.PUBLIC.CORPUS_STAGE/policy_versions.csv.gz
FILE_FORMAT = (
    TYPE = CSV
    PARSE_HEADER = TRUE
    FIELD_OPTIONALLY_ENCLOSED_BY = '"'
    NULL_IF = ('', 'NULL', 'None')
    EMPTY_FIELD_AS_NULL = TRUE
    ERROR_ON_COLUMN_COUNT_MISMATCH = FALSE
)
MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE;

SELECT policy_version_id, version_no, effective_from, effective_to, change_summary
FROM TRACE_DB.POLICY.POLICY_VERSIONS
ORDER BY version_no;

-- The bitemporal spine. Three dates, three different versions, or nothing
-- built on top of this can be trusted.
SELECT '2025-03-01' AS as_of, POLICY.POLICY_AS_OF('TM-STRUCT', '2025-03-01'::DATE) AS version
UNION ALL SELECT '2026-01-15', POLICY.POLICY_AS_OF('TM-STRUCT', '2026-01-15'::DATE)
UNION ALL SELECT '2026-09-16', POLICY.POLICY_AS_OF('TM-STRUCT', '2026-09-16'::DATE);

-- ---------------------------------------------------------------------------
-- The first genuine as-was / as-now replay.
--
-- For every alert, the threshold that actually applied when it fired, against
-- the threshold in force today. PV-TM-STRUCT-002 is the defect window.
-- ---------------------------------------------------------------------------
WITH current_threshold AS (
    SELECT p.threshold_value AS thr
    FROM TRACE_DB.POLICY.RULE_PREDICATES p
    JOIN TRACE_DB.POLICY.POLICY_VERSIONS v USING (policy_version_id)
    WHERE v.effective_to IS NULL
)
SELECT
    a.policy_version_id                                        AS fired_under,
    COUNT(*)                                                   AS alerts_raised,
    MIN(a.aggregate_amount)                                    AS smallest_alert,
    SUM(CASE WHEN a.aggregate_amount >= (SELECT thr FROM current_threshold)
             THEN 1 ELSE 0 END)                                AS still_alerts_today
FROM TRACE_DB.CORE.ALERTS a
GROUP BY 1
ORDER BY 1;

-- And the inverse -- the part sampling cannot see. Activity that raised no
-- alert at all under PV-TM-STRUCT-002, but would today.
SELECT
    COUNT(*)                                             AS invisible_customer_weeks,
    SUM(CASE WHEN is_truly_suspicious THEN 1 ELSE 0 END) AS truly_suspicious,
    ROUND(SUM(aggregate_amount) / 10000000, 1)           AS notional_inr_crore,
    ROUND(100.0 * SUM(CASE WHEN is_truly_suspicious THEN 1 ELSE 0 END) / COUNT(*), 1)
                                                         AS pct_truly_suspicious
FROM TRACE_DB.EVAL.INVISIBLE_POPULATION;
