-- ============================================================================
-- SUPERSEDED BY sql/26_action_log_rebuild.sql — retained as history.
--
-- This version used AUTOINCREMENT `seq` as the chain's ordering key and hashed
-- a CURRENT_TIMESTAMP() separate from the one stored in event_ts. Both are
-- defects: the first forked the chain across sessions, the second made the
-- hashes impossible to recompute independently. The verification below caught
-- the fork (TAMPERED, 2 broken links) on first use. Diagnosis: sql/25.
-- Write-up: EVALUATION.md, "The action log reported TAMPERED on its own data".
--
-- Do not run this. Run sql/26 instead.
-- ============================================================================

-- ============================================================================
-- 24_case_action_log.sql — record what investigators do, append-only.
--
-- AUDIT.AUDIT_LOG was created in sql/01, granted INSERT to TRACE_INVESTIGATOR
-- in sql/17, and written to zero times. A hash-chained audit log that nothing
-- writes to is decoration.
--
-- It is also a missing capability. The system reconstructs a case, ranks it and
-- issues evidence -- and then nothing records that a human looked at it, what
-- they decided, or when. For a lookback that is the half a supervisor asks
-- about: not "did you find it" but "what did you do about it".
--
-- Every action is appended and chained. Nothing here can be edited: no role
-- holds UPDATE on AUDIT, and the PreToolUse hook refuses the statement before
-- it reaches Snowflake. A disposition recorded in error is corrected by
-- appending a superseding action, which is how a case file works on paper too.
--
-- RUN THIS IN SNOWSIGHT AS ACCOUNTADMIN.
--
-- Creating objects in AUDIT and granting on them are refused by our own hook,
-- for the same reason sql/17 is a human script: an agent that can mint a
-- procedure in the evidence schema can put an UPDATE inside it and call it,
-- and an agent that can grant on audit objects can grant itself write access.
-- Defining the evidence surface is a human operation.
--
-- The CALLs in section 4 run anywhere -- calling an existing procedure is
-- permitted. Only the DDL and the grants need Snowsight.
-- ============================================================================

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE COMPUTE_WH;
USE DATABASE TRACE_DB;

-- ---------------------------------------------------------------------------
-- 1. Append an action. INSERT only -- the chain head is read, never rewritten.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE PROCEDURE AUDIT.RECORD_CASE_ACTION(
    CASE_REF STRING,
    ACTOR    STRING,
    ACTION   STRING,
    NOTE     STRING
)
RETURNS STRING
LANGUAGE SQL
AS
$$
DECLARE
    prev    STRING DEFAULT 'GENESIS';
    content STRING;
    row_h   STRING;
    ok      NUMBER DEFAULT 0;
BEGIN
    -- Only actions on real cases. A log that accepts anything documents nothing.
    SELECT COUNT(*) INTO :ok FROM CORE.V_CASE_LEDGER WHERE case_ref = :CASE_REF;
    IF (:ok = 0) THEN
        RETURN 'REJECTED: no such case ' || :CASE_REF;
    END IF;

    IF (:ACTION NOT IN ('VIEWED','ASSIGNED','ESCALATED_TO_FIU',
                        'CLOSED_NO_ACTION','REQUESTED_INFORMATION','SUPERSEDED')) THEN
        RETURN 'REJECTED: unknown action ' || :ACTION;
    END IF;

    SELECT COALESCE(MAX_BY(row_hash, seq), 'GENESIS') INTO :prev FROM AUDIT.AUDIT_LOG;

    content := :CASE_REF || '|' || :ACTOR || '|' || :ACTION || '|'
            || COALESCE(:NOTE, '') || '|' || TO_VARCHAR(CURRENT_TIMESTAMP());
    row_h   := SHA2(:prev || content, 256);

    INSERT INTO AUDIT.AUDIT_LOG (actor, action, object_ref, payload, prev_hash, row_hash)
    SELECT :ACTOR, :ACTION, :CASE_REF,
           OBJECT_CONSTRUCT('case_ref', :CASE_REF, 'note', :NOTE,
                            'recorded_by_role', CURRENT_ROLE()),
           :prev, :row_h;

    RETURN 'RECORDED ' || :ACTION || ' on ' || :CASE_REF || ' (' || LEFT(:row_h, 12) || '…)';
END;
$$;

GRANT USAGE ON PROCEDURE AUDIT.RECORD_CASE_ACTION(STRING, STRING, STRING, STRING)
  TO ROLE TRACE_INVESTIGATOR;

-- ---------------------------------------------------------------------------
-- 2. The case file: every action on a case, in order.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE VIEW AUDIT.V_CASE_HISTORY AS
SELECT
    l.seq,
    l.object_ref                       AS case_ref,
    l.event_ts,
    l.actor,
    l.action,
    l.payload:note::STRING             AS note,
    l.payload:recorded_by_role::STRING AS acting_role,
    LEFT(l.row_hash, 12) || '…'        AS row_hash
FROM AUDIT.AUDIT_LOG l
ORDER BY l.seq;

-- Current standing of each case: the latest action that is not a plain view.
CREATE OR REPLACE VIEW AUDIT.V_CASE_STATUS AS
SELECT
    object_ref AS case_ref,
    MAX_BY(action,   seq) AS latest_action,
    MAX_BY(actor,    seq) AS latest_actor,
    MAX_BY(event_ts, seq) AS latest_at,
    COUNT(*)              AS actions_recorded
FROM AUDIT.AUDIT_LOG
WHERE action <> 'VIEWED'
GROUP BY object_ref;

GRANT SELECT ON VIEW AUDIT.V_CASE_HISTORY TO ROLE TRACE_INVESTIGATOR;
GRANT SELECT ON VIEW AUDIT.V_CASE_STATUS  TO ROLE TRACE_INVESTIGATOR;

-- ---------------------------------------------------------------------------
-- 3. Verification, same shape as the evidence chain.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE VIEW AUDIT.V_ACTION_LOG_VERIFICATION AS
SELECT
    seq,
    object_ref AS case_ref,
    COALESCE(LAG(row_hash) OVER (ORDER BY seq), 'GENESIS') = prev_hash AS link_intact
FROM AUDIT.AUDIT_LOG;

-- ---------------------------------------------------------------------------
-- 4. Demonstrate
-- ---------------------------------------------------------------------------

CALL AUDIT.RECORD_CASE_ACTION(
    (SELECT case_ref FROM AUDIT.EVIDENCE_PACK ORDER BY p_suspicious DESC LIMIT 1),
    'a.rao@bank.internal', 'ASSIGNED', 'Allocated to FIU desk for enhanced review.');

CALL AUDIT.RECORD_CASE_ACTION(
    (SELECT case_ref FROM AUDIT.EVIDENCE_PACK ORDER BY p_suspicious DESC LIMIT 1),
    'a.rao@bank.internal', 'ESCALATED_TO_FIU',
    'Cash 20.9x declared monthly income for a salaried customer after 26 weeks dormant; 85.7% of deposits just under round numbers. STR drafted under Para 5.1.');

CALL AUDIT.RECORD_CASE_ACTION(
    (SELECT case_ref FROM AUDIT.EVIDENCE_PACK ORDER BY p_suspicious DESC, seq LIMIT 1 OFFSET 1),
    'p.nair@bank.internal', 'CLOSED_NO_ACTION',
    'Customer is a registered scrap dealer; deposit rhythm consistent across 26 weeks. No further action.');

-- A correction is an append, never an edit.
CALL AUDIT.RECORD_CASE_ACTION(
    (SELECT case_ref FROM AUDIT.EVIDENCE_PACK ORDER BY p_suspicious DESC, seq LIMIT 1 OFFSET 1),
    'p.nair@bank.internal', 'SUPERSEDED',
    'Supersedes the closure above: second branch identified on review. Reopening.');

-- Actions on a case that does not exist are refused.
CALL AUDIT.RECORD_CASE_ACTION('CU-999999|2026-01-01', 'x@bank.internal', 'ASSIGNED', 'test');

-- As are invented action types.
CALL AUDIT.RECORD_CASE_ACTION(
    (SELECT case_ref FROM AUDIT.EVIDENCE_PACK LIMIT 1),
    'x@bank.internal', 'DELETE_EVERYTHING', 'test');

SELECT * FROM AUDIT.V_CASE_HISTORY;
SELECT * FROM AUDIT.V_CASE_STATUS;

SELECT COUNT(*) AS actions,
       COALESCE(SUM(CASE WHEN link_intact THEN 0 ELSE 1 END), 0) AS broken_links,
       CASE WHEN COUNT(*) = 0 THEN 'EMPTY'
            WHEN SUM(CASE WHEN link_intact THEN 0 ELSE 1 END) = 0 THEN 'INTACT'
            ELSE 'TAMPERED' END AS verdict
FROM AUDIT.V_ACTION_LOG_VERIFICATION;
