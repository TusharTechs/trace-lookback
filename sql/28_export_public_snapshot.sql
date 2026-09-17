-- ============================================================================
-- 28_export_public_snapshot.sql — data for the public demo.
--
-- RUN IN SNOWSIGHT. Run each numbered query, then use the download icon above
-- the results pane and save it under the exact filename in the heading.
-- Put every file in  data/  on the `demo` branch of this repository
--   git checkout demo   →   data/<name>.csv   →   commit and push
--
-- Why a snapshot at all: Streamlit in Snowflake is reachable only by someone
-- logged into this account, and this trial expires around 16 Oct -- during the
-- judging window. A judge needs a link that opens, and keeps opening.
--
-- Why this is not a mock-up: query 1 exports TO_JSON(payload) as a literal
-- string -- the exact bytes Snowflake hashed. The public app recomputes
-- SHA-256 over that string in Python and compares it to content_hash, then
-- walks the chain the same way. Nothing is trusted; everything is recomputed,
-- in a different language, on a different machine, with no access to this
-- account. Verification outside the database that produced the data is a
-- stronger demonstration than verification inside it.
--
-- The corpus is entirely synthetic (generator/generate.py, seed 20260916), so
-- there is nothing confidential to export. Every name, PAN and transaction is
-- generated.
-- ============================================================================

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE COMPUTE_WH;
USE DATABASE TRACE_DB;

-- ---------------------------------------------------------------------------
-- 0. PREFLIGHT — run this first. Nothing to download.
--
--    Every row must say TABLE or VIEW. This exists because the first version
--    of this script tried to SELECT * FROM POLICY.REPLAY_SUMMARY, which is a
--    table function, not a view -- the script was written from a list of
--    object names without checking what kind of object each one was. Sixteen
--    queries in, that is an expensive way to find out.
-- ---------------------------------------------------------------------------
WITH wanted AS (
    SELECT * FROM VALUES
        ('AUDIT',  'EVIDENCE_PACK'),
        ('AUDIT',  'EVIDENCE_CHAIN'),
        ('AUDIT',  'V_EVIDENCE_PACK_RENDER'),
        ('AUDIT',  'TAMPER_DRILL_LOG'),
        ('AUDIT',  'V_CASE_HISTORY'),
        ('AUDIT',  'V_CHAIN_VERIFICATION'),
        ('EVAL',   'ADJUDICATION'),
        ('EVAL',   'INVISIBLE_POPULATION'),
        ('POLICY', 'V_THRESHOLD_SENSITIVITY'),
        ('POLICY', 'POLICY_VERSIONS'),
        ('POLICY', 'RULE_PREDICATES'),
        ('POLICY', 'CANDIDATE_PREDICATES'),
        ('POLICY', 'V_CERTIFICATION_QUEUE'),
        ('POLICY', 'V_ENFORCEABLE_PREDICATES')
    AS t(sch, obj)
)
SELECT w.sch, w.obj, COALESCE(t.table_type, '>>> MISSING <<<') AS kind
FROM wanted w
LEFT JOIN TRACE_DB.INFORMATION_SCHEMA.TABLES t
       ON t.table_schema = w.sch AND t.table_name = w.obj
ORDER BY CASE WHEN t.table_type IS NULL THEN 0 ELSE 1 END, w.sch, w.obj;

-- ---------------------------------------------------------------------------
-- 1 → evidence_pack.csv
--     TO_JSON is exported verbatim. Do not reformat this column by hand; a
--     single changed byte is supposed to break verification, and will.
-- ---------------------------------------------------------------------------
SELECT seq, case_ref, customer_id, week_start, p_suspicious,
       TO_JSON(payload) AS payload_json,
       content_hash
FROM AUDIT.EVIDENCE_PACK
ORDER BY seq;

-- ---------------------------------------------------------------------------
-- 2 → evidence_chain.csv
-- ---------------------------------------------------------------------------
SELECT link_no, pack_seq, case_ref, content_hash, prev_chain_hash, chain_hash
FROM AUDIT.EVIDENCE_CHAIN
ORDER BY link_no;

-- ---------------------------------------------------------------------------
-- 3 → pack_render_privileged.csv   (unmasked, as TRACE_PRIVILEGED would see)
-- ---------------------------------------------------------------------------
SELECT * FROM AUDIT.V_EVIDENCE_PACK_RENDER ORDER BY seq;

-- ---------------------------------------------------------------------------
-- 4 → adjudication.csv
-- ---------------------------------------------------------------------------
SELECT * FROM EVAL.ADJUDICATION ORDER BY customer_id, week_start;

-- ---------------------------------------------------------------------------
-- 5 → invisible_population.csv
-- ---------------------------------------------------------------------------
SELECT * FROM EVAL.INVISIBLE_POPULATION ORDER BY customer_id, week_start;

-- ---------------------------------------------------------------------------
-- 6 → threshold_sensitivity.csv
--
--     POLICY.REPLAY_SUMMARY is deliberately NOT exported: it is a table
--     function, and a snapshot cannot call one. This view already evaluates
--     the same replay across the full ₹5L–₹12L grid in ₹50,000 steps -- the
--     exact range of the slider -- so the public demo reads precomputed rows
--     rather than pretending to invoke a UDTF it cannot reach.
-- ---------------------------------------------------------------------------
SELECT * FROM POLICY.V_THRESHOLD_SENSITIVITY ORDER BY 1;

-- ---------------------------------------------------------------------------
-- 7 → policy_versions.csv
-- ---------------------------------------------------------------------------
SELECT * FROM POLICY.POLICY_VERSIONS ORDER BY 1;

-- ---------------------------------------------------------------------------
-- 8 → rule_predicates.csv
-- ---------------------------------------------------------------------------
SELECT * FROM POLICY.RULE_PREDICATES ORDER BY 1;

-- ---------------------------------------------------------------------------
-- 9 → candidate_predicates.csv
-- ---------------------------------------------------------------------------
SELECT * FROM POLICY.CANDIDATE_PREDICATES ORDER BY 1;

-- ---------------------------------------------------------------------------
-- 10 → certification_queue.csv
-- ---------------------------------------------------------------------------
SELECT * FROM POLICY.V_CERTIFICATION_QUEUE ORDER BY 1;

-- ---------------------------------------------------------------------------
-- 11 → enforceable_predicates.csv
-- ---------------------------------------------------------------------------
SELECT * FROM POLICY.V_ENFORCEABLE_PREDICATES ORDER BY 1;

-- ---------------------------------------------------------------------------
-- 12 → tamper_drill_log.csv
-- ---------------------------------------------------------------------------
SELECT ord, drill, attack, actions, broken_links, hash_mismatches,
       forked_rows, verdict, caught_by
FROM AUDIT.TAMPER_DRILL_LOG ORDER BY ord;

-- ---------------------------------------------------------------------------
-- 13 → case_history.csv
-- ---------------------------------------------------------------------------
SELECT * FROM AUDIT.V_CASE_HISTORY ORDER BY link_no;

-- ---------------------------------------------------------------------------
-- 14 → chain_verification.csv
--      The database's own verdict, exported so the public app can show that
--      its independent Python recomputation agrees with it.
-- ---------------------------------------------------------------------------
SELECT link_no, pack_seq, case_ref,
       content_intact, link_intact, hash_intact, pack_present
FROM AUDIT.V_CHAIN_VERIFICATION
ORDER BY link_no;

-- ===========================================================================
-- 15 → pack_render_masked.csv   (RUN THESE THREE STATEMENTS TOGETHER)
--
-- The same view read as the investigator role. Exporting both gives the
-- public demo two real database outputs to put side by side, rather than a
-- Python function pretending to be a masking policy.
--
-- USE SECONDARY ROLES NONE matters: without it the session keeps every role
-- granted to the user and the masking policy does not engage. That mistake
-- nearly passed for a working isolation test once already (EVALUATION.md,
-- "USE ROLE does not test isolation").
-- ===========================================================================
USE SECONDARY ROLES NONE;
USE ROLE TRACE_INVESTIGATOR;

SELECT * FROM TRACE_DB.AUDIT.V_EVIDENCE_PACK_RENDER ORDER BY seq;

-- Then restore:
USE ROLE ACCOUNTADMIN;
USE SECONDARY ROLES ALL;
