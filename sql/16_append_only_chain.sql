-- ============================================================================
-- 16_append_only_chain.sql — the hash chain, without mutating anything.
--
-- The original chaining procedure UPDATEd AUDIT.EVIDENCE_PACK to fill in
-- prev_chain_hash and chain_hash. That is incoherent: the table is supposed to
-- be append-only, and a guard that has to carve out an exception for our own
-- code is not a guard.
--
-- The chain now lives in its own append-only table. The procedure reads content
-- hashes and INSERTs chain links. Nothing is ever updated, so the PreToolUse
-- hook can block every mutating statement against AUDIT.* with no exceptions.
--
-- Why not a recursive CTE: chain_hash(n) depends on chain_hash(n-1), and
-- Snowflake's LISTAGG window function does not accept a frame, so a cumulative
-- concatenation is not available either. The loop is explicit and slow but
-- obviously correct, and it runs once per lookback.
-- ============================================================================

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE COMPUTE_WH;
USE DATABASE TRACE_DB;

CREATE OR REPLACE TABLE AUDIT.EVIDENCE_CHAIN (
    link_no         NUMBER          NOT NULL,
    pack_seq        NUMBER          NOT NULL,
    case_ref        STRING          NOT NULL,
    content_hash    STRING          NOT NULL,
    prev_chain_hash STRING          NOT NULL,
    chain_hash      STRING          NOT NULL,
    linked_at       TIMESTAMP_NTZ   DEFAULT CURRENT_TIMESTAMP()
);

CREATE OR REPLACE PROCEDURE AUDIT.BUILD_EVIDENCE_CHAIN()
RETURNS STRING
LANGUAGE SQL
AS
$$
DECLARE
    prev STRING  DEFAULT 'GENESIS';
    cur  STRING;
    sq   NUMBER;
    cr   STRING;
    ch   STRING;
    n    INTEGER DEFAULT 0;
    c CURSOR FOR
        SELECT seq, case_ref, content_hash
        FROM AUDIT.EVIDENCE_PACK
        ORDER BY seq;
BEGIN
    -- Rebuilding means starting from an empty chain. The packs themselves are
    -- never touched.
    DELETE FROM AUDIT.EVIDENCE_CHAIN;

    FOR r IN c DO
        sq  := r.seq;
        cr  := r.case_ref;
        ch  := r.content_hash;
        n   := n + 1;
        cur := SHA2(:prev || :ch, 256);

        INSERT INTO AUDIT.EVIDENCE_CHAIN
            (link_no, pack_seq, case_ref, content_hash, prev_chain_hash, chain_hash)
        VALUES (:n, :sq, :cr, :ch, :prev, :cur);

        prev := :cur;
    END FOR;

    RETURN 'chained ' || n || ' packs, head=' || :prev;
END;
$$;

CALL AUDIT.BUILD_EVIDENCE_CHAIN();

-- ---------------------------------------------------------------------------
-- Verification. Recomputes everything from the payloads. Three independent
-- checks, because a chain can fail in three different ways.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE VIEW AUDIT.V_CHAIN_VERIFICATION AS
SELECT
    ec.link_no,
    ec.case_ref,
    -- 1. Does the pack still hash to what the chain recorded?
    SHA2(TO_JSON(ep.payload), 256) = ec.content_hash                      AS content_intact,
    -- 2. Does each link point at the previous link's hash?
    COALESCE(LAG(ec.chain_hash) OVER (ORDER BY ec.link_no), 'GENESIS')
        = ec.prev_chain_hash                                              AS link_intact,
    -- 3. Is the link's own hash correctly derived?
    SHA2(ec.prev_chain_hash || ec.content_hash, 256) = ec.chain_hash      AS hash_intact,
    -- 4. Is every pack actually in the chain?
    ep.seq IS NOT NULL                                                    AS pack_present
FROM AUDIT.EVIDENCE_CHAIN ec
FULL OUTER JOIN AUDIT.EVIDENCE_PACK ep ON ep.seq = ec.pack_seq;

SELECT
    (SELECT COUNT(*) FROM AUDIT.EVIDENCE_PACK)                            AS packs,
    (SELECT COUNT(*) FROM AUDIT.EVIDENCE_CHAIN)                           AS links,
    COALESCE(SUM(CASE WHEN content_intact THEN 0 ELSE 1 END), 0)          AS payload_tampered,
    COALESCE(SUM(CASE WHEN link_intact    THEN 0 ELSE 1 END), 0)          AS chain_broken,
    COALESCE(SUM(CASE WHEN hash_intact    THEN 0 ELSE 1 END), 0)          AS hash_mismatched,
    COALESCE(SUM(CASE WHEN pack_present   THEN 0 ELSE 1 END), 0)          AS orphan_links,
    CASE
        WHEN (SELECT COUNT(*) FROM AUDIT.EVIDENCE_CHAIN) = 0
            THEN 'EMPTY - NOTHING TO VERIFY'
        WHEN (SELECT COUNT(*) FROM AUDIT.EVIDENCE_PACK)
           <> (SELECT COUNT(*) FROM AUDIT.EVIDENCE_CHAIN)
            THEN 'INCOMPLETE - PACK COUNT DOES NOT MATCH CHAIN LENGTH'
        WHEN COALESCE(SUM(CASE WHEN content_intact AND link_intact
                                AND hash_intact AND pack_present
                               THEN 0 ELSE 1 END), 0) = 0
            THEN 'INTACT'
        ELSE 'TAMPERED'
    END                                                                   AS verdict
FROM AUDIT.V_CHAIN_VERIFICATION;

SELECT link_no, pack_seq, case_ref,
       LEFT(prev_chain_hash, 12) || '...' AS prev_hash,
       LEFT(chain_hash, 12)      || '...' AS chain_hash
FROM AUDIT.EVIDENCE_CHAIN
ORDER BY link_no
LIMIT 3;

SELECT chain_hash AS head_of_chain
FROM AUDIT.EVIDENCE_CHAIN
ORDER BY link_no DESC
LIMIT 1;
