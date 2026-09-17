-- ============================================================================
-- 26_action_log_rebuild.sql — fix two real flaws the verification exposed.
--
-- RUN IN SNOWSIGHT AS ACCOUNTADMIN (AUDIT DDL is a human operation).
--
-- The action log reported TAMPERED on its own data with nobody having edited
-- anything. Diagnosis in sql/25 found two defects, both ours.
--
-- 1. THE HEAD LOOKUP USED A NON-MONOTONIC COLUMN.
--    RECORD_CASE_ACTION read the chain head with MAX_BY(row_hash, seq), where
--    seq was AUTOINCREMENT. Snowflake allocates autoincrement in per-session
--    ranges and does NOT guarantee values follow insertion order: the observed
--    sequence was 1, 2, 101, 102, 201, 202, 301, 401, with four of eight rows
--    out of chronological order.
--
--    A row inserted at 11:12:27 received seq = 2. The next insert, three
--    seconds later, computed MAX_BY(row_hash, seq) -- and because 2 < 201 it
--    read the OLD head. Two rows then claimed the same predecessor and the
--    chain forked. The fix is an explicit link_no, assigned by the procedure,
--    never by the database.
--
-- 2. THE HASH COVERED A TIMESTAMP NOBODY COULD REPRODUCE.
--    The procedure hashed TO_VARCHAR(CURRENT_TIMESTAMP()) while event_ts took
--    its own DEFAULT CURRENT_TIMESTAMP() -- two separate clock reads. Every
--    row therefore failed independent self-verification: the hash could only
--    ever be confirmed by the code that wrote it.
--
--    An integrity check that cannot be recomputed from the stored record is
--    not an integrity check. The timestamp is now read once into a variable,
--    used for both the hash and the column, and formatted explicitly so the
--    recomputation is byte-identical.
--
-- A REMAINING LIMITATION, stated rather than hidden: reading the head and
-- writing the row are still two statements, so two genuinely concurrent calls
-- could both read the same head. Single-writer is safe; concurrent appends
-- would need a sequence object or a serialized transaction. Documented in
-- EVALUATION.md rather than pretended away.
-- ============================================================================

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE COMPUTE_WH;
USE DATABASE TRACE_DB;

-- ---------------------------------------------------------------------------
-- 1. Rebuild. The existing eight rows are a forked chain and demo data; they
--    are discarded rather than migrated, because migrating a broken chain
--    would produce a consistent chain over records whose linkage was never
--    valid -- which is worse than a detected break.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE TABLE AUDIT.AUDIT_LOG (
    link_no     NUMBER          NOT NULL,   -- assigned by the procedure, monotonic
    event_ts    TIMESTAMP_NTZ   NOT NULL,   -- hashed value, not a separate clock read
    actor       STRING          NOT NULL,
    action      STRING          NOT NULL,
    object_ref  STRING,
    payload     VARIANT,
    prev_hash   STRING          NOT NULL,
    row_hash    STRING          NOT NULL
);

-- ---------------------------------------------------------------------------
-- 2. The append procedure, corrected.
--
--    The canonical string is defined once here and recomputed identically in
--    the verification view. If those two ever drift, verification fails loudly
--    rather than silently passing.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE PROCEDURE AUDIT.RECORD_CASE_ACTION(
    CASE_REF STRING, ACTOR STRING, ACTION STRING, NOTE STRING)
RETURNS STRING
LANGUAGE SQL
AS
$$
DECLARE
    ts      TIMESTAMP_NTZ;
    link    NUMBER;
    prev    STRING;
    content STRING;
    row_h   STRING;
    ok      NUMBER DEFAULT 0;
BEGIN
    SELECT COUNT(*) INTO :ok FROM CORE.V_CASE_LEDGER WHERE case_ref = :CASE_REF;
    IF (:ok = 0) THEN
        RETURN 'REJECTED: no such case ' || :CASE_REF;
    END IF;

    IF (:ACTION NOT IN ('VIEWED','ASSIGNED','ESCALATED_TO_FIU',
                        'CLOSED_NO_ACTION','REQUESTED_INFORMATION','SUPERSEDED')) THEN
        RETURN 'REJECTED: unknown action ' || :ACTION;
    END IF;

    -- One clock read, used for both the hash and the stored column.
    ts := CURRENT_TIMESTAMP();

    -- link_no is ours, so it is monotonic by construction.
    SELECT COALESCE(MAX(link_no), 0) + 1,
           COALESCE(MAX_BY(row_hash, link_no), 'GENESIS')
      INTO :link, :prev
      FROM AUDIT.AUDIT_LOG;

    -- Canonical form. Mirrored exactly in AUDIT.V_ACTION_LOG_VERIFICATION.
    content := :CASE_REF || '|' || :ACTOR || '|' || :ACTION || '|'
            || COALESCE(:NOTE, '') || '|'
            || TO_VARCHAR(:ts, 'YYYY-MM-DD HH24:MI:SS.FF3');
    row_h := SHA2(:prev || content, 256);

    INSERT INTO AUDIT.AUDIT_LOG
        (link_no, event_ts, actor, action, object_ref, payload, prev_hash, row_hash)
    SELECT :link, :ts, :ACTOR, :ACTION, :CASE_REF,
           OBJECT_CONSTRUCT('case_ref', :CASE_REF, 'note', :NOTE,
                            'recorded_by_role', CURRENT_ROLE()),
           :prev, :row_h;

    RETURN 'RECORDED ' || :ACTION || ' as link ' || :link
        || ' (' || LEFT(:row_h, 12) || '…)';
END;
$$;

GRANT USAGE ON PROCEDURE AUDIT.RECORD_CASE_ACTION(STRING, STRING, STRING, STRING)
  TO ROLE TRACE_INVESTIGATOR;

-- ---------------------------------------------------------------------------
-- 3. Verification, now genuinely independent.
--
--    Recomputes each row's hash from the STORED record. Nothing here trusts a
--    value the writer produced -- that is what makes it a check rather than a
--    receipt.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE VIEW AUDIT.V_ACTION_LOG_VERIFICATION AS
SELECT
    link_no,
    object_ref AS case_ref,
    -- the link points at its predecessor
    COALESCE(LAG(row_hash) OVER (ORDER BY link_no), 'GENESIS') = prev_hash AS link_intact,
    -- and the row's own hash derives from what is stored
    SHA2(prev_hash || object_ref || '|' || actor || '|' || action || '|'
         || COALESCE(payload:note::STRING, '') || '|'
         || TO_VARCHAR(event_ts, 'YYYY-MM-DD HH24:MI:SS.FF3'), 256) = row_hash
                                                                        AS hash_recomputes,
    -- and no two rows claim the same predecessor
    COUNT(*) OVER (PARTITION BY prev_hash) = 1                          AS no_fork
FROM AUDIT.AUDIT_LOG;

CREATE OR REPLACE VIEW AUDIT.V_CASE_HISTORY AS
SELECT link_no, object_ref AS case_ref, event_ts, actor, action,
       payload:note::STRING AS note,
       payload:recorded_by_role::STRING AS acting_role,
       LEFT(row_hash, 12) || '…' AS row_hash
FROM AUDIT.AUDIT_LOG;

CREATE OR REPLACE VIEW AUDIT.V_CASE_STATUS AS
SELECT object_ref AS case_ref,
       MAX_BY(action,   link_no) AS latest_action,
       MAX_BY(actor,    link_no) AS latest_actor,
       MAX_BY(event_ts, link_no) AS latest_at,
       COUNT(*) AS actions_recorded
FROM AUDIT.AUDIT_LOG
WHERE action <> 'VIEWED'
GROUP BY object_ref;

GRANT SELECT ON VIEW AUDIT.V_ACTION_LOG_VERIFICATION TO ROLE TRACE_INVESTIGATOR;
GRANT SELECT ON VIEW AUDIT.V_CASE_HISTORY            TO ROLE TRACE_INVESTIGATOR;
GRANT SELECT ON VIEW AUDIT.V_CASE_STATUS             TO ROLE TRACE_INVESTIGATOR;

-- ---------------------------------------------------------------------------
-- 4. Re-record and verify.
-- ---------------------------------------------------------------------------

CALL AUDIT.RECORD_CASE_ACTION(
    (SELECT case_ref FROM AUDIT.EVIDENCE_PACK ORDER BY p_suspicious DESC LIMIT 1),
    'a.rao@bank.internal', 'ASSIGNED', 'Allocated to FIU desk for enhanced review.');
CALL AUDIT.RECORD_CASE_ACTION(
    (SELECT case_ref FROM AUDIT.EVIDENCE_PACK ORDER BY p_suspicious DESC LIMIT 1),
    'a.rao@bank.internal', 'ESCALATED_TO_FIU',
    'Cash 20.9x declared monthly income after 26 weeks dormant; 85.7% of deposits just under round numbers. STR drafted under Para 5.1.');
CALL AUDIT.RECORD_CASE_ACTION(
    (SELECT case_ref FROM AUDIT.EVIDENCE_PACK ORDER BY p_suspicious DESC, seq LIMIT 1 OFFSET 1),
    'p.nair@bank.internal', 'CLOSED_NO_ACTION',
    'Registered scrap dealer; deposit rhythm consistent across 26 weeks. No further action.');
CALL AUDIT.RECORD_CASE_ACTION(
    (SELECT case_ref FROM AUDIT.EVIDENCE_PACK ORDER BY p_suspicious DESC, seq LIMIT 1 OFFSET 1),
    'p.nair@bank.internal', 'SUPERSEDED',
    'Supersedes the closure above: second branch identified on review. Reopening.');

SELECT * FROM AUDIT.V_CASE_HISTORY ORDER BY link_no;

SELECT
    COUNT(*) AS actions,
    COALESCE(SUM(CASE WHEN link_intact     THEN 0 ELSE 1 END), 0) AS broken_links,
    COALESCE(SUM(CASE WHEN hash_recomputes THEN 0 ELSE 1 END), 0) AS hash_mismatches,
    COALESCE(SUM(CASE WHEN no_fork         THEN 0 ELSE 1 END), 0) AS forked_rows,
    CASE WHEN COUNT(*) = 0 THEN 'EMPTY'
         WHEN SUM(CASE WHEN link_intact AND hash_recomputes AND no_fork
                       THEN 0 ELSE 1 END) = 0 THEN 'INTACT'
         ELSE 'TAMPERED' END AS verdict
FROM AUDIT.V_ACTION_LOG_VERIFICATION;
