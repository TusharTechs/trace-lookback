-- ============================================================================
-- 27_tamper_drill.sql — prove the detector fires.
--
-- RUN IN SNOWSIGHT AS ACCOUNTADMIN. Run the whole worksheet; the final
-- statement returns every result in one table.
--
-- Every integrity check in Trace reports INTACT. That is not evidence that any
-- of them work. A verification view that has never returned TAMPERED is
-- indistinguishable from `SELECT 'INTACT'`.
--
-- The action log briefly gave us a real failure (sql/25) and sql/26 fixed it
-- away. This script puts that assurance back deliberately, three times, because
-- the three checks catch different things and two of them would each miss an
-- attack the other catches.
--
-- Run as ACCOUNTADMIN on purpose: the strongest adversary the account has. The
-- claim under test is not "nobody can write to AUDIT" -- an account
-- administrator plainly can. It is "nobody can write to AUDIT without the
-- record showing it".
--
-- Only AUDIT.AUDIT_LOG is written to, and it is reseeded between drills.
-- AUDIT.EVIDENCE_CHAIN (687 packs) is verified untouched at the end rather
-- than assumed to be.
-- ============================================================================

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE COMPUTE_WH;
USE DATABASE TRACE_DB;

-- ---------------------------------------------------------------------------
-- 1. The verdict view. Permanent: the Streamlit app reads this same view, so
--    there is one definition of "verified" rather than one for the drills and
--    another for the screen.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE VIEW AUDIT.V_ACTION_LOG_VERDICT AS
SELECT
    COUNT(*)                                     AS actions,
    COALESCE(SUM(IFF(link_intact,     0, 1)), 0) AS broken_links,
    COALESCE(SUM(IFF(hash_recomputes, 0, 1)), 0) AS hash_mismatches,
    COALESCE(SUM(IFF(no_fork,         0, 1)), 0) AS forked_rows,
    CASE WHEN COUNT(*) = 0 THEN 'EMPTY'
         WHEN SUM(IFF(link_intact AND hash_recomputes AND no_fork, 0, 1)) = 0
              THEN 'INTACT'
         ELSE 'TAMPERED' END                     AS verdict
FROM AUDIT.V_ACTION_LOG_VERIFICATION;

GRANT SELECT ON VIEW AUDIT.V_ACTION_LOG_VERDICT TO ROLE TRACE_INVESTIGATOR;

-- ---------------------------------------------------------------------------
-- 2. Where the outcomes are kept.
--
--    This lives in AUDIT because it is an audit artefact: the record that the
--    controls were tested, what was tried, and what the detector said. That is
--    the second thing an examiner asks for after the evidence itself.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE TABLE AUDIT.TAMPER_DRILL_LOG (
    ord             NUMBER,
    drill           STRING,
    attack          STRING,
    actions         NUMBER,
    broken_links    NUMBER,
    hash_mismatches NUMBER,
    forked_rows     NUMBER,
    verdict         STRING,
    caught_by       STRING,
    run_at          TIMESTAMP_NTZ
);

GRANT SELECT ON TABLE AUDIT.TAMPER_DRILL_LOG TO ROLE TRACE_INVESTIGATOR;

-- ---------------------------------------------------------------------------
-- 3. A reseed, so each drill starts from a known-good chain.
--
--    This is the one procedure in AUDIT permitted to delete anything, and it
--    is DROPPED at the end of this script. Leaving a procedure that deletes
--    from an append-only evidence schema sitting in that schema is exactly
--    what an examiner would object to, and they would be right.
--
--    It is also not callable by the agent even while it exists: sql/27 forced
--    a hardening of .cortex/hooks/protect-audit.py, which until now allowed
--    CALL of any procedure in AUDIT. Blocking CREATE PROCEDURE closed half
--    that hole; a human creating one and the agent calling it was the other
--    half. Calls into AUDIT are now allowlisted by name.
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

    RETURN 'reseeded to 4 actions';
END;
$$;

-- ---------------------------------------------------------------------------
-- 4. Baseline.
-- ---------------------------------------------------------------------------

CALL AUDIT.RESET_ACTION_LOG_DEMO();

INSERT INTO AUDIT.TAMPER_DRILL_LOG
SELECT 0, 'baseline', 'nothing altered', actions, broken_links, hash_mismatches,
       forked_rows, verdict, '—', CURRENT_TIMESTAMP()
FROM AUDIT.V_ACTION_LOG_VERDICT;

-- ---------------------------------------------------------------------------
-- 5. DRILL 1 — a forged append.
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

INSERT INTO AUDIT.TAMPER_DRILL_LOG
SELECT 1, 'forged append',
       'insert a fake closure, linked correctly to the head',
       actions, broken_links, hash_mismatches, forked_rows, verdict,
       'hash recomputation', CURRENT_TIMESTAMP()
FROM AUDIT.V_ACTION_LOG_VERDICT;

CALL AUDIT.RESET_ACTION_LOG_DEMO();

-- ---------------------------------------------------------------------------
-- 6. DRILL 2 — an existing decision is quietly reworded.
--
-- The escalation to FIU is edited to read as a routine clearance. Nothing
-- structural changes: link_no, prev_hash and row_hash are all untouched, so
-- the chain still walks perfectly. Only recomputing the hash from the stored
-- content exposes it.
--
-- This is the case the original design could not have caught at all, because
-- its hashes were never reproducible.
-- ---------------------------------------------------------------------------

UPDATE AUDIT.AUDIT_LOG
SET payload = OBJECT_INSERT(payload, 'note',
        'Routine review. Cash activity consistent with stated occupation. Closing.', TRUE)
WHERE link_no = 2;

INSERT INTO AUDIT.TAMPER_DRILL_LOG
SELECT 2, 'reworded decision',
       'rewrite the FIU escalation as a routine clearance',
       actions, broken_links, hash_mismatches, forked_rows, verdict,
       'hash recomputation', CURRENT_TIMESTAMP()
FROM AUDIT.V_ACTION_LOG_VERDICT;

CALL AUDIT.RESET_ACTION_LOG_DEMO();

-- ---------------------------------------------------------------------------
-- 7. DRILL 3 — an inconvenient action is removed.
--
-- The escalation is deleted outright. Every remaining row still hashes
-- correctly, so hash recomputation alone reports nothing wrong. The gap shows
-- only in the walk: the next row points at a predecessor that is gone.
--
-- Drills 2 and 3 together are the argument for keeping both checks. Each is
-- invisible to the one that catches the other.
-- ---------------------------------------------------------------------------

DELETE FROM AUDIT.AUDIT_LOG WHERE link_no = 2;

INSERT INTO AUDIT.TAMPER_DRILL_LOG
SELECT 3, 'deleted record',
       'remove the FIU escalation entirely',
       actions, broken_links, hash_mismatches, forked_rows, verdict,
       'link walk', CURRENT_TIMESTAMP()
FROM AUDIT.V_ACTION_LOG_VERDICT;

CALL AUDIT.RESET_ACTION_LOG_DEMO();

INSERT INTO AUDIT.TAMPER_DRILL_LOG
SELECT 4, 'restored', 'reseeded after the drills', actions, broken_links,
       hash_mismatches, forked_rows, verdict, '—', CURRENT_TIMESTAMP()
FROM AUDIT.V_ACTION_LOG_VERDICT;

-- ---------------------------------------------------------------------------
-- 8. Remove the delete capability. It existed for the drills and nothing else.
-- ---------------------------------------------------------------------------

DROP PROCEDURE AUDIT.RESET_ACTION_LOG_DEMO();

-- ---------------------------------------------------------------------------
-- 9. Everything, in one result.
-- ---------------------------------------------------------------------------

SELECT ord, drill, attack, actions, broken_links, hash_mismatches,
       forked_rows, verdict, caught_by
FROM AUDIT.TAMPER_DRILL_LOG
UNION ALL
SELECT 9, 'evidence chain', 'never written to by this script',
       COUNT(*), 0, 0, 0,
       IFF(COALESCE(SUM(IFF(content_intact AND link_intact
                            AND hash_intact AND pack_present, 0, 1)), 0) = 0,
           'INTACT', 'TAMPERED'),
       '—'
FROM AUDIT.V_CHAIN_VERIFICATION
ORDER BY ord;

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
-- publishing the head hash outside the account, or signing each append with a
-- key Snowflake never sees. Neither is built here, and claiming otherwise
-- would be the kind of overstatement this file exists to avoid.
-- ---------------------------------------------------------------------------
