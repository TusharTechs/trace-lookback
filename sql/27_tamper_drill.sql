-- ============================================================================
-- 27_tamper_drill.sql — prove the detector fires.
--
-- RUN IN SNOWSIGHT AS ACCOUNTADMIN.
--
-- Every integrity check in Trace currently reports INTACT. That is not
-- evidence that any of them work. A verification view that has never returned
-- TAMPERED is indistinguishable from `SELECT 'INTACT'`.
--
-- The action log briefly gave us a real failure (sql/25) and sql/26 fixed it
-- away. This script puts that assurance back deliberately, and does it three
-- times, because the three checks catch different things and two of them
-- would each miss an attack the other catches.
--
-- Run as ACCOUNTADMIN on purpose: this is the strongest adversary the account
-- has. The claim being tested is not "nobody can write to AUDIT" -- an account
-- administrator plainly can. It is "nobody can write to AUDIT without the
-- record showing it".
--
-- Only AUDIT.AUDIT_LOG is touched, which holds four demo actions and is
-- rebuilt after each drill. AUDIT.EVIDENCE_CHAIN (687 packs) is never written
-- to here.
-- ============================================================================

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE COMPUTE_WH;
USE DATABASE TRACE_DB;

-- ---------------------------------------------------------------------------
-- 0. A reseed, so each drill starts from a known-good chain.
--
--    Deliberately NOT granted to any role. It exists for this drill only, and
--    it is the one procedure in AUDIT permitted to delete anything.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE PROCEDURE AUDIT.RESET_ACTION_LOG_DEMO()
RETURNS STRING
LANGUAGE SQL
AS
$$
DECLARE
    top_case STRING;
    nxt_case STRING;
BEGIN
    DELETE FROM AUDIT.AUDIT_LOG;

    SELECT case_ref INTO :top_case
      FROM AUDIT.EVIDENCE_PACK ORDER BY p_suspicious DESC LIMIT 1;
    SELECT case_ref INTO :nxt_case
      FROM AUDIT.EVIDENCE_PACK ORDER BY p_suspicious DESC, seq LIMIT 1 OFFSET 1;

    CALL AUDIT.RECORD_CASE_ACTION(:top_case, 'a.rao@bank.internal',
        'ASSIGNED', 'Allocated to FIU desk for enhanced review.');
    CALL AUDIT.RECORD_CASE_ACTION(:top_case, 'a.rao@bank.internal',
        'ESCALATED_TO_FIU',
        'Cash 20.9x declared monthly income after 26 weeks dormant; 85.7% of deposits just under round numbers. STR drafted under Para 5.1.');
    CALL AUDIT.RECORD_CASE_ACTION(:nxt_case, 'p.nair@bank.internal',
        'CLOSED_NO_ACTION',
        'Registered scrap dealer; deposit rhythm consistent across 26 weeks. No further action.');
    CALL AUDIT.RECORD_CASE_ACTION(:nxt_case, 'p.nair@bank.internal',
        'SUPERSEDED',
        'Supersedes the closure above: second branch identified on review. Reopening.');

    RETURN 'action log reseeded to 4 actions';
END;
$$;

-- A single rollup, reused unchanged after every drill. One definition, so a
-- drill cannot pass because its own verification was written to be lenient.
CREATE OR REPLACE VIEW AUDIT.V_ACTION_LOG_VERDICT AS
SELECT
    COUNT(*)                                                     AS actions,
    COALESCE(SUM(IFF(link_intact,     0, 1)), 0)                 AS broken_links,
    COALESCE(SUM(IFF(hash_recomputes, 0, 1)), 0)                 AS hash_mismatches,
    COALESCE(SUM(IFF(no_fork,         0, 1)), 0)                 AS forked_rows,
    CASE WHEN COUNT(*) = 0 THEN 'EMPTY'
         WHEN SUM(IFF(link_intact AND hash_recomputes AND no_fork, 0, 1)) = 0
              THEN 'INTACT'
         ELSE 'TAMPERED' END                                     AS verdict
FROM AUDIT.V_ACTION_LOG_VERIFICATION;

GRANT SELECT ON VIEW AUDIT.V_ACTION_LOG_VERDICT TO ROLE TRACE_INVESTIGATOR;

CALL AUDIT.RESET_ACTION_LOG_DEMO();
SELECT 'BASELINE' AS drill, * FROM AUDIT.V_ACTION_LOG_VERDICT;   -- expect INTACT

-- ---------------------------------------------------------------------------
-- DRILL 1 — a forged append.
--
-- The adversary is careful: they read the current head and link to it
-- correctly, so the chain walks cleanly straight through their row. What they
-- cannot do is produce a row_hash that recomputes from the content they wrote.
--
-- This is the drill that justifies the hash-recomputation check. Link-walking
-- alone reports this attack as INTACT.
-- ---------------------------------------------------------------------------

INSERT INTO AUDIT.AUDIT_LOG
    (link_no, event_ts, actor, action, object_ref, payload, prev_hash, row_hash)
WITH h AS (SELECT MAX(link_no) AS n, MAX_BY(row_hash, link_no) AS head
           FROM AUDIT.AUDIT_LOG),
     c AS (SELECT case_ref FROM AUDIT.EVIDENCE_PACK
           ORDER BY p_suspicious DESC LIMIT 1)
SELECT h.n + 1, CURRENT_TIMESTAMP(),
       'mallory@bank.internal', 'CLOSED_NO_ACTION', c.case_ref,
       OBJECT_CONSTRUCT('case_ref', c.case_ref,
                        'note', 'Reviewed at desk level. No concerns. Closing.',
                        'recorded_by_role', 'ACCOUNTADMIN'),
       h.head,                       -- links correctly: the walk will not notice
       SHA2('plausible-looking-but-fabricated', 256)
FROM h, c;

SELECT 'DRILL 1 forged append' AS drill, * FROM AUDIT.V_ACTION_LOG_VERDICT;
-- expect: broken_links 0, hash_mismatches 1, forked_rows 0, TAMPERED

-- Which row failed, and who wrote it. Joined rather than widening the
-- verification view, so that view keeps exactly one definition (sql/26).
SELECT v.link_no, l.actor, l.action,
       v.link_intact, v.hash_recomputes, v.no_fork
FROM AUDIT.V_ACTION_LOG_VERIFICATION v
JOIN AUDIT.AUDIT_LOG l ON l.link_no = v.link_no
ORDER BY v.link_no;

CALL AUDIT.RESET_ACTION_LOG_DEMO();

-- ---------------------------------------------------------------------------
-- DRILL 2 — an existing decision is quietly reworded.
--
-- The escalation to FIU is edited to read as a routine clearance. Nothing
-- structural changes: link_no, prev_hash and row_hash are all untouched, so
-- the chain still walks perfectly. Only recomputing the hash from the stored
-- content exposes it.
--
-- This is the case the original design could not have caught, because its
-- hashes were not reproducible at all.
-- ---------------------------------------------------------------------------

UPDATE AUDIT.AUDIT_LOG
SET payload = OBJECT_INSERT(payload, 'note',
        'Routine review. Cash activity consistent with stated occupation. Closing.', TRUE)
WHERE link_no = 2;

SELECT 'DRILL 2 reworded decision' AS drill, * FROM AUDIT.V_ACTION_LOG_VERDICT;
-- expect: broken_links 0, hash_mismatches 1, forked_rows 0, TAMPERED

CALL AUDIT.RESET_ACTION_LOG_DEMO();

-- ---------------------------------------------------------------------------
-- DRILL 3 — an inconvenient action is removed.
--
-- The escalation is deleted outright. Every remaining row still hashes
-- correctly, so hash recomputation alone reports nothing wrong. The gap shows
-- only in the walk: link 3 points at a predecessor that is no longer there.
--
-- Drills 2 and 3 together are the argument for keeping both checks. Each one
-- is invisible to the other.
-- ---------------------------------------------------------------------------

DELETE FROM AUDIT.AUDIT_LOG WHERE link_no = 2;

SELECT 'DRILL 3 deleted record' AS drill, * FROM AUDIT.V_ACTION_LOG_VERDICT;
-- expect: broken_links 1, hash_mismatches 0, forked_rows 0, TAMPERED

CALL AUDIT.RESET_ACTION_LOG_DEMO();

-- ---------------------------------------------------------------------------
-- Restore, and confirm we are back to a clean chain.
-- ---------------------------------------------------------------------------

SELECT 'RESTORED' AS drill, * FROM AUDIT.V_ACTION_LOG_VERDICT;   -- expect INTACT

-- The evidence chain was never touched by this script. Confirm that directly
-- rather than asserting it.
SELECT 'EVIDENCE CHAIN' AS scope,
       COUNT(*) AS links,
       COALESCE(SUM(IFF(content_intact AND link_intact
                        AND hash_intact AND pack_present, 0, 1)), 0) AS faults
FROM AUDIT.V_CHAIN_VERIFICATION;

-- ---------------------------------------------------------------------------
-- WHAT THIS DOES NOT PROVE.
--
-- An adversary holding ACCOUNTADMIN who also reads this repository can append
-- a *well-formed* forged action: the canonical string is public, so they can
-- compute a row_hash that recomputes correctly and links to the head. It will
-- verify, because it is indistinguishable from a real append.
--
-- That is the true property of a hash chain and it is worth stating exactly.
-- The chain makes the PAST tamper-evident -- nothing already recorded can be
-- altered or removed without the record showing it, as drills 2 and 3
-- demonstrate. It does not make the PRESENT unforgeable.
--
-- Closing that gap needs something the database does not hold: periodically
-- publishing the head hash somewhere outside the account, or signing each
-- append with a key Snowflake never sees. Neither is built here, and claiming
-- otherwise would be the kind of overstatement this file exists to avoid.
-- ---------------------------------------------------------------------------
