-- ============================================================================
-- 25_chain_diagnosis.sql — why did the action log report TAMPERED?
--
-- Eight actions, two broken links. Nobody edited anything, so either the chain
-- is genuinely broken by a flaw in how it is built, or the verification
-- reconstructs the order wrongly. Both are worth knowing; neither should be
-- assumed.
--
-- Leading suspicion is our own design. RECORD_CASE_ACTION reads the head with
-- MAX_BY(row_hash, seq) and the verification walks LAG(...) OVER (ORDER BY seq).
-- Snowflake AUTOINCREMENT guarantees uniqueness, NOT that values follow
-- insertion order -- EVIDENCE_PACK already jumped to 1101 on a rebuild. If seq
-- and insertion order disagree, the verification is walking a different
-- sequence than the one the hashes were computed over.
-- ============================================================================

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE COMPUTE_WH;
USE DATABASE TRACE_DB;

-- 1. The raw chain. Read prev_hash against the previous row's row_hash by eye.
SELECT
    seq,
    event_ts,
    action,
    LEFT(prev_hash, 12) AS prev_hash,
    LEFT(row_hash, 12)  AS row_hash,
    LEFT(LAG(row_hash) OVER (ORDER BY seq), 12) AS prior_row_hash_by_seq,
    LEFT(LAG(row_hash) OVER (ORDER BY event_ts, seq), 12) AS prior_row_hash_by_time
FROM AUDIT.AUDIT_LOG
ORDER BY seq;

-- 2. Is seq monotonic with insertion time? If these disagree, seq is not a
--    safe ordering key and the verification is at fault, not the chain.
SELECT
    COUNT(*)                                                        AS rows_total,
    SUM(CASE WHEN seq_rank <> time_rank THEN 1 ELSE 0 END)          AS rows_out_of_order
FROM (
    SELECT ROW_NUMBER() OVER (ORDER BY seq)            AS seq_rank,
           ROW_NUMBER() OVER (ORDER BY event_ts, seq)  AS time_rank
    FROM AUDIT.AUDIT_LOG
);

-- 3. Verify against insertion TIME rather than seq. If this says INTACT while
--    ordering by seq says TAMPERED, the chain is sound and the ordering key
--    was wrong.
WITH byt AS (
    SELECT event_ts, seq, prev_hash, row_hash,
           COALESCE(LAG(row_hash) OVER (ORDER BY event_ts, seq), 'GENESIS') AS expected_prev
    FROM AUDIT.AUDIT_LOG
)
SELECT COUNT(*) AS actions,
       SUM(CASE WHEN expected_prev = prev_hash THEN 0 ELSE 1 END) AS broken_by_time,
       CASE WHEN SUM(CASE WHEN expected_prev = prev_hash THEN 0 ELSE 1 END) = 0
            THEN 'INTACT when ordered by insertion time'
            ELSE 'STILL BROKEN - not an ordering problem' END AS verdict
FROM byt;

-- 4. Are there duplicate prev_hash values? Two rows claiming the same
--    predecessor means two inserts read the same head -- a genuine race, and a
--    real flaw in reading the head and writing in separate statements.
SELECT prev_hash, COUNT(*) AS claimed_by
FROM AUDIT.AUDIT_LOG
GROUP BY prev_hash HAVING COUNT(*) > 1
ORDER BY claimed_by DESC;

-- 5. Does every row's own hash still derive correctly from what it recorded?
--    This is independent of ordering. If these all pass, no payload was
--    altered and the issue is purely how the links are walked.
SELECT
    COUNT(*) AS rows_checked,
    SUM(CASE WHEN row_hash = SHA2(prev_hash || object_ref || '|' || actor || '|'
                                  || action || '|' || COALESCE(payload:note::STRING, '')
                                  || '|' || TO_VARCHAR(event_ts), 256)
             THEN 0 ELSE 1 END) AS self_hash_mismatches
FROM AUDIT.AUDIT_LOG;
