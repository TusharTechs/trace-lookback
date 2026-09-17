-- ============================================================================
-- 23_certification_gate.sql — LLM proposes, a human certifies, SQL executes.
--
-- The compiler now extracts three thresholds from AML-POL-009 and all three
-- match the hand-declared predicates. Extraction being correct is not the
-- claim, though. The claim is that nothing a model produced can drive a replay
-- until a person signs for it, and that the signature lapses if the source
-- text changes underneath it.
--
-- INFERRED VS EXTRACTED
-- The model returned effective_to dates of 2025-06-30 and 2026-08-13. Neither
-- appears in the document; it derived them from the following period's start.
-- The inference is correct and the reasoning is sound, but the source_quote
-- does not support it. A value traceable to a sentence and a value a model
-- worked out are different things to a regulator, so the certifying view
-- flags which is which rather than presenting them identically.
-- ============================================================================

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE COMPUTE_WH;
USE DATABASE TRACE_DB;

-- ---------------------------------------------------------------------------
-- 1. What a certifier is being asked to sign.
--
--    Each field is marked according to whether the quoted sentence supports
--    it. An inferred boundary is not wrong -- it needs a human to confirm it.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE VIEW POLICY.V_CERTIFICATION_QUEUE AS
SELECT
    candidate_id,
    source_doc_id,
    threshold_value,
    effective_from,
    effective_to,
    window_days,
    source_quote,
    -- Does the quote contain the threshold digits, ignoring separators?
    CASE WHEN REPLACE(REPLACE(source_quote, ',', ''), ' ', '')
              ILIKE '%' || TO_VARCHAR(threshold_value::INT) || '%'
         THEN 'EXTRACTED - supported by quote'
         ELSE 'INFERRED - not present in quote, confirm before signing'
    END AS threshold_provenance,
    CASE WHEN effective_to IS NULL THEN 'n/a - still in force'
         WHEN source_quote ILIKE '%' || TO_VARCHAR(effective_to, 'DD Month YYYY') || '%'
           OR source_quote ILIKE '%' || TO_VARCHAR(effective_to) || '%'
         THEN 'EXTRACTED - supported by quote'
         ELSE 'INFERRED - derived from the next period, confirm before signing'
    END AS effective_to_provenance,
    certified_by
FROM POLICY.CANDIDATE_PREDICATES;

SELECT threshold_value, effective_from, effective_to,
       threshold_provenance, effective_to_provenance
FROM POLICY.V_CERTIFICATION_QUEUE ORDER BY effective_from;

-- ---------------------------------------------------------------------------
-- 2. Nothing is usable yet. The model proposed; nobody signed.
-- ---------------------------------------------------------------------------

SELECT COUNT(*) AS certified_and_valid
FROM POLICY.V_CERTIFIED_PREDICATES WHERE certification_still_valid;

-- ---------------------------------------------------------------------------
-- 3. A human signs the first predicate.
-- ---------------------------------------------------------------------------

CALL POLICY.CERTIFY_PREDICATE(
    (SELECT candidate_id FROM POLICY.CANDIDATE_PREDICATES
      WHERE effective_from = '2023-01-01'::DATE LIMIT 1),
    'fcc.chair@bank.internal');

SELECT threshold_value, effective_from, certified_by, certified_at,
       certification_still_valid
FROM POLICY.V_CERTIFIED_PREDICATES ORDER BY effective_from;

-- ---------------------------------------------------------------------------
-- 4. The source document is amended. Nobody revokes anything.
-- ---------------------------------------------------------------------------

UPDATE POLICY.POLICY_DOCUMENTS
   SET raw_text = raw_text || CHR(10) || CHR(10)
       || 'Amendment, 17 September 2026: Schedule A is restated without change '
       || 'of substance following Committee review.'
 WHERE doc_id = 'AML-POL-009';

-- The certification lapses on its own, because the hash it was bound to no
-- longer matches the document. This is the behaviour a regulator cares about:
-- approval attaches to a specific text, not to a row.
SELECT threshold_value, effective_from, certified_by,
       certification_still_valid,
       'source text amended after signing' AS why
FROM POLICY.V_CERTIFIED_PREDICATES ORDER BY effective_from;

-- ---------------------------------------------------------------------------
-- 5. And nothing further can be certified against the changed text.
-- ---------------------------------------------------------------------------

CALL POLICY.CERTIFY_PREDICATE(
    (SELECT candidate_id FROM POLICY.CANDIDATE_PREDICATES
      WHERE effective_from = '2025-07-01'::DATE LIMIT 1),
    'fcc.chair@bank.internal');

-- ---------------------------------------------------------------------------
-- 6. Only certified, still-valid predicates may drive a replay.
--
--    This is the join the replay engine would use in production. It is empty
--    right now, and that is correct: the policy changed, so every approval
--    derived from it must be renewed before the rule can be enforced again.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE VIEW POLICY.V_ENFORCEABLE_PREDICATES AS
SELECT threshold_value, effective_from, effective_to, window_days,
       source_quote, certified_by, certified_at
FROM POLICY.V_CERTIFIED_PREDICATES
WHERE certification_still_valid;

SELECT COUNT(*) AS enforceable_now FROM POLICY.V_ENFORCEABLE_PREDICATES;

-- Re-extract against the amended text, and the cycle begins again with a fresh
-- hash. Left as the operator's next step rather than run here.
SELECT 'Re-run sql/22_extraction_staged.sql to re-extract against the amended text'
       AS next_step;
