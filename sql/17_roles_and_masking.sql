-- ============================================================================
-- 17_roles_and_masking.sql — the controls the hook is only backing up.
--
-- RUN THIS IN SNOWSIGHT AS ACCOUNTADMIN, not through the agent.
--
-- That is not a convenience note. Three statements in this file are refused by
-- our own PreToolUse hook, and a fourth by the Restricted Session Scope:
--
--   * GRANT on AUDIT objects      -- an agent able to grant privileges on audit
--                                    data can grant itself write access
--   * CREATE OR REPLACE VIEW in AUDIT -- AUDIT.V_CHAIN_VERIFICATION lives here;
--                                    an agent that can redefine it can make
--                                    tampering report INTACT
--   * USE ROLE TRACE_INVESTIGATOR -- the build scope permits ACCOUNTADMIN only
--
-- Privilege administration and the definition of the verification surface are
-- human operations. The agent reads evidence and appends to it; it does not get
-- to decide who may write, or what "verified" means.
--
-- What this establishes:
--
--   1. TRACE_INVESTIGATOR -- reads CORE, POLICY and AUDIT; NO grant on EVAL.
--      An accuracy figure the adjudicating role could have read is not a
--      figure. Schema isolation is what makes the evaluation falsifiable.
--
--   2. Masking on CORE.CUSTOMERS PII.
--
--   3. A render view resolving identity at QUERY time. Evidence packs
--      reference the customer and never embed identity: a masking policy
--      governs a base column and cannot reach inside a VARIANT snapshot built
--      from cleartext. Embedding PII would have produced a demo where masking
--      appeared to work while every pack still carried PANs in clear.
-- ============================================================================

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE COMPUTE_WH;
USE DATABASE TRACE_DB;

-- ---------------------------------------------------------------------------
-- 1. Roles
-- ---------------------------------------------------------------------------

CREATE ROLE IF NOT EXISTS TRACE_INVESTIGATOR
    COMMENT = 'Works the escalation queue. Reads evidence, cannot alter it, cannot see ground truth.';
CREATE ROLE IF NOT EXISTS TRACE_PRIVILEGED
    COMMENT = 'Senior compliance. As investigator, plus unmasked PII.';

GRANT USAGE ON DATABASE TRACE_DB      TO ROLE TRACE_INVESTIGATOR;
GRANT USAGE ON SCHEMA TRACE_DB.CORE   TO ROLE TRACE_INVESTIGATOR;
GRANT USAGE ON SCHEMA TRACE_DB.POLICY TO ROLE TRACE_INVESTIGATOR;
GRANT USAGE ON SCHEMA TRACE_DB.AUDIT  TO ROLE TRACE_INVESTIGATOR;
GRANT USAGE ON WAREHOUSE COMPUTE_WH   TO ROLE TRACE_INVESTIGATOR;

GRANT SELECT ON ALL TABLES IN SCHEMA TRACE_DB.CORE   TO ROLE TRACE_INVESTIGATOR;
GRANT SELECT ON ALL VIEWS  IN SCHEMA TRACE_DB.CORE   TO ROLE TRACE_INVESTIGATOR;
GRANT SELECT ON ALL TABLES IN SCHEMA TRACE_DB.POLICY TO ROLE TRACE_INVESTIGATOR;
GRANT SELECT ON ALL TABLES IN SCHEMA TRACE_DB.AUDIT  TO ROLE TRACE_INVESTIGATOR;
GRANT SELECT ON ALL VIEWS  IN SCHEMA TRACE_DB.AUDIT  TO ROLE TRACE_INVESTIGATOR;

-- Append to the audit log, never amend it.
GRANT INSERT ON TABLE TRACE_DB.AUDIT.AUDIT_LOG TO ROLE TRACE_INVESTIGATOR;

-- NOTHING on TRACE_DB.EVAL. The point of the file, not an omission.

GRANT ROLE TRACE_INVESTIGATOR TO ROLE TRACE_PRIVILEGED;
GRANT ROLE TRACE_PRIVILEGED   TO ROLE ACCOUNTADMIN;

SET me = CURRENT_USER();
GRANT ROLE TRACE_INVESTIGATOR TO USER IDENTIFIER($me);
GRANT ROLE TRACE_PRIVILEGED   TO USER IDENTIFIER($me);

-- ---------------------------------------------------------------------------
-- 2. Masking. One policy per data type -- Snowflake requires the policy
--    signature to match the column, which a TEXT policy on a DATE column does
--    not.
-- ---------------------------------------------------------------------------

-- Detach first. Snowflake refuses to replace a masking policy that is still
-- attached to a column, so a second run of this file fails at CREATE OR REPLACE
-- unless the bindings are removed. On a clean account these three statements
-- error with "Column ... has no masking policy" -- expected, and harmless;
-- Run All continues past them.
ALTER TABLE CORE.CUSTOMERS MODIFY COLUMN full_name     UNSET MASKING POLICY;
ALTER TABLE CORE.CUSTOMERS MODIFY COLUMN pan           UNSET MASKING POLICY;
ALTER TABLE CORE.CUSTOMERS MODIFY COLUMN date_of_birth UNSET MASKING POLICY;

CREATE OR REPLACE MASKING POLICY TRACE_DB.PUBLIC.MASK_NAME AS (val STRING)
RETURNS STRING ->
    CASE WHEN CURRENT_ROLE() IN ('ACCOUNTADMIN', 'TRACE_PRIVILEGED') THEN val
         ELSE 'REDACTED' END;

-- PAN keeps its last four: an investigator must still be able to tie a case to
-- a file. Full redaction makes evidence unusable; full disclosure makes the
-- control pointless.
CREATE OR REPLACE MASKING POLICY TRACE_DB.PUBLIC.MASK_PAN AS (val STRING)
RETURNS STRING ->
    CASE WHEN CURRENT_ROLE() IN ('ACCOUNTADMIN', 'TRACE_PRIVILEGED') THEN val
         ELSE 'XXXXXX' || RIGHT(val, 4) END;

-- Date of birth truncates to the year: age band survives, identification does
-- not. Returning NULL would remove a legitimate analytic signal.
CREATE OR REPLACE MASKING POLICY TRACE_DB.PUBLIC.MASK_DOB AS (val DATE)
RETURNS DATE ->
    CASE WHEN CURRENT_ROLE() IN ('ACCOUNTADMIN', 'TRACE_PRIVILEGED') THEN val
         ELSE DATE_TRUNC('YEAR', val) END;

ALTER TABLE CORE.CUSTOMERS MODIFY COLUMN full_name     SET MASKING POLICY TRACE_DB.PUBLIC.MASK_NAME;
ALTER TABLE CORE.CUSTOMERS MODIFY COLUMN pan           SET MASKING POLICY TRACE_DB.PUBLIC.MASK_PAN;
ALTER TABLE CORE.CUSTOMERS MODIFY COLUMN date_of_birth SET MASKING POLICY TRACE_DB.PUBLIC.MASK_DOB;

-- ---------------------------------------------------------------------------
-- 3. Render view. Identity is resolved here, under policy, at query time.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE VIEW AUDIT.V_EVIDENCE_PACK_RENDER AS
SELECT
    ep.seq,
    ec.link_no,
    ep.case_ref,
    ep.customer_id,
    c.full_name                                            AS customer_name,
    c.pan                                                  AS customer_pan,
    ep.week_start,
    ep.payload:case:aggregate_cash::FLOAT                  AS aggregate_cash,
    ROUND(ep.p_suspicious, 2)                              AS p_suspicious,
    ep.payload:rule_as_was:policy_version_id::STRING       AS rule_then,
    ep.payload:rule_as_was:threshold_inr::FLOAT            AS threshold_then,
    ep.payload:rule_as_now:policy_version_id::STRING       AS rule_now,
    ep.payload:rule_as_now:threshold_inr::FLOAT            AS threshold_now,
    ep.payload:rule_as_was:citation::STRING                AS citation,
    ep.payload:why_no_alert_was_raised:explanation::STRING AS why_no_alert,
    ep.payload:finding:strongest_aggravating::STRING       AS aggravating,
    ep.payload:finding:strongest_mitigating::STRING        AS mitigating,
    ep.payload:evidence_as_of_window_end                   AS evidence,
    ep.content_hash,
    ec.chain_hash
FROM AUDIT.EVIDENCE_PACK ep
LEFT JOIN AUDIT.EVIDENCE_CHAIN ec ON ec.pack_seq = ep.seq
JOIN CORE.CUSTOMERS c ON c.customer_id = ep.customer_id;

GRANT SELECT ON VIEW AUDIT.V_EVIDENCE_PACK_RENDER TO ROLE TRACE_INVESTIGATOR;

-- ---------------------------------------------------------------------------
-- 4. Demonstration. Requires role switching, so Snowsight, not the agent.
-- ---------------------------------------------------------------------------

USE ROLE ACCOUNTADMIN;
SELECT 'ACCOUNTADMIN' AS acting_role, case_ref, customer_name, customer_pan,
       p_suspicious, LEFT(content_hash, 12) || '...' AS content_hash
FROM AUDIT.V_EVIDENCE_PACK_RENDER
ORDER BY p_suspicious DESC, seq LIMIT 3;

-- USE ROLE ALONE DOES NOT TEST ISOLATION.
--
-- A Snowflake session carries a primary role AND secondary roles. Users default
-- to DEFAULT_SECONDARY_ROLES = ('ALL'), so every role granted to the user stays
-- active alongside whatever USE ROLE selects. Switching to TRACE_INVESTIGATOR
-- while ACCOUNTADMIN remains active as a secondary role tests nothing: the
-- session still holds every privilege it had before.
--
-- We found this the hard way. The UPDATE below was authorized and executed,
-- failing only on a NOT NULL constraint rather than on privileges -- which
-- looked like a pass and was not one.
USE ROLE TRACE_INVESTIGATOR;
USE SECONDARY ROLES NONE;

SELECT CURRENT_ROLE() AS primary_role, CURRENT_SECONDARY_ROLES() AS secondary_roles;

SELECT 'TRACE_INVESTIGATOR' AS acting_role, case_ref, customer_name, customer_pan,
       p_suspicious, LEFT(content_hash, 12) || '...' AS content_hash
FROM AUDIT.V_EVIDENCE_PACK_RENDER
ORDER BY p_suspicious DESC, seq LIMIT 3;

-- The investigator can verify the chain but not alter it.
SELECT COUNT(*) AS links_visible FROM AUDIT.EVIDENCE_CHAIN;
SELECT verdict FROM (
    SELECT CASE WHEN COUNT(*) = 0 THEN 'EMPTY'
                WHEN SUM(CASE WHEN content_intact AND link_intact AND hash_intact
                                   AND pack_present THEN 0 ELSE 1 END) = 0
                THEN 'INTACT' ELSE 'TAMPERED' END AS verdict
    FROM AUDIT.V_CHAIN_VERIFICATION);

-- THE TEST THAT MATTERS. Must fail with "does not exist or not authorized".
-- If it returns a number, EVAL is not isolated and every accuracy figure in
-- EVALUATION.md is unfalsifiable.
SELECT COUNT(*) AS should_not_be_readable FROM EVAL.GROUND_TRUTH;

-- And the investigator must not be able to rewrite evidence even without the
-- hook -- the hook is client-side; this is the database refusing.
--
-- The value is valid JSON, deliberately. An earlier version set payload = NULL
-- and failed on the NOT NULL constraint, which LOOKED like an access-control
-- success and was not one: the statement had already been authorized and
-- executed. A write that is well-formed can only be stopped by privileges.
--
-- This statement is safe ONLY because the two lines above it dropped the
-- session to TRACE_INVESTIGATOR with no secondary roles. Run the identical SQL
-- as ACCOUNTADMIN and it succeeds, corrupting pack 1 and breaking every one of
-- the 687 chain links after it.
UPDATE AUDIT.EVIDENCE_PACK SET payload = PARSE_JSON('{"tampered":true}') WHERE seq = 1;

USE ROLE ACCOUNTADMIN;
USE SECONDARY ROLES ALL;
SHOW GRANTS TO ROLE TRACE_INVESTIGATOR;
