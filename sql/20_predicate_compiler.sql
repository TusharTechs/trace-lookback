-- ============================================================================
-- 20_predicate_compiler.sql — policy text to machine-checkable rule.
--
-- Until now RULE_PREDICATES was hand-declared. The thresholds the replay
-- engine enforces were typed in by us, which means the chain from "what the
-- policy says" to "what the system enforces" was a human transcription with no
-- record.
--
-- This closes it:
--
--     policy document
--        -> LLM proposes a predicate          (probabilistic, uncertified)
--        -> a human certifies it              (recorded, bound to source text)
--        -> deterministic SQL executes it     (never the model)
--
-- The division matters more than the extraction. The model reads prose, which
-- is what models are good at. It never decides an outcome. And certification
-- binds to a HASH OF THE SOURCE TEXT: amend the policy and every certification
-- derived from it lapses automatically, because the thing a human approved is
-- no longer the thing on file.
--
-- VERIFICATION: the compiler reads a policy document it has never been told
-- the answer to and should independently reproduce the three threshold
-- versions already hardcoded in RULE_PREDICATES. That is a real test -- if the
-- extracted values disagree with the hand-declared ones, one of them is wrong.
-- ============================================================================

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE COMPUTE_WH;
USE DATABASE TRACE_DB;

-- ---------------------------------------------------------------------------
-- 1. The source document. A threshold schedule of the kind a Financial Crime
--    Committee would minute. Synthetic, internal, cites RBI paragraph numbers
--    the way an internal policy does. No regulator text reproduced.
-- ---------------------------------------------------------------------------

INSERT INTO POLICY.POLICY_DOCUMENTS
    (doc_id, title, issuer, published_on, para_anchor, raw_text)
SELECT 'AML-POL-009', 'Internal AML Policy — TM-STRUCT-01 Threshold Schedule',
       'INTERNAL', '2026-08-14'::DATE, 'Para 4.2.1 (Schedule A)',
'Schedule A records the aggregate cash credit threshold applied under scenario
TM-STRUCT-01, measured over a rolling seven-day window per customer.

From 1 January 2023 the threshold was eight lakh rupees (INR 800,000). Alerts
were generated where aggregate cash credits equalled or exceeded that amount
within the window.

With effect from 1 July 2025 the Committee raised the threshold to ten lakh
rupees (INR 1,000,000), citing alert volume. The impact assessment required
under Para 4.2.1 was not completed before implementation.

Following a supervisory observation the threshold was restored to eight lakh
rupees (INR 800,000) with effect from 14 August 2026, and a lookback was
directed under Para 7.4 covering the full period during which the raised
threshold was in force.'
WHERE NOT EXISTS (SELECT 1 FROM POLICY.POLICY_DOCUMENTS WHERE doc_id = 'AML-POL-009');

-- ---------------------------------------------------------------------------
-- 2. Candidate predicates. The model writes here and nowhere else. Nothing in
--    this table can drive a replay until a human moves it.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE TABLE POLICY.CANDIDATE_PREDICATES (
    candidate_id      STRING        DEFAULT UUID_STRING(),
    source_doc_id     STRING        NOT NULL,
    source_text_hash  STRING        NOT NULL,   -- certification binds to this
    scenario_code     STRING,
    subject           STRING,
    field             STRING,
    operator          STRING,
    threshold_value   NUMBER(18,2),
    threshold_unit    STRING,
    window_days       NUMBER(5,0),
    effective_from    DATE,
    effective_to      DATE,
    source_quote      STRING,                   -- the sentence relied on
    extraction_confidence FLOAT,
    extracted_by      STRING,
    extracted_at      TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    certified_by      STRING,                   -- NULL until a human signs
    certified_at      TIMESTAMP_NTZ,
    certified_hash    STRING                    -- source hash AT certification
);

-- ---------------------------------------------------------------------------
-- 3. Extraction. One model call over one document.
--
--    The prompt demands a verbatim quote per predicate. A predicate that
--    cannot point at the sentence it came from is not auditable, and requiring
--    the quote also makes fabrication visible -- an invented threshold has no
--    sentence to cite.
-- ---------------------------------------------------------------------------

INSERT INTO POLICY.CANDIDATE_PREDICATES
    (source_doc_id, source_text_hash, scenario_code, subject, field, operator,
     threshold_value, threshold_unit, window_days, effective_from, effective_to,
     source_quote, extraction_confidence, extracted_by)
WITH doc AS (
    SELECT doc_id, raw_text, SHA2(raw_text, 256) AS text_hash
    FROM POLICY.POLICY_DOCUMENTS WHERE doc_id = 'AML-POL-009'
), extracted AS (
    -- NO TRY_PARSE_JSON. AI_COMPLETE with response_format returns an OBJECT,
    -- not a string; wrapping it in TRY_PARSE_JSON yields NULL and FLATTEN over
    -- NULL produces zero rows -- silently. Confirmed with TYPEOF in
    -- sql/21_extraction_debug.sql. FLATTEN the variant directly.
    SELECT
        d.doc_id, d.text_hash,
        (AI_COMPLETE(
            model => 'claude-sonnet-4-5',
            prompt =>
                'Extract every distinct threshold rule stated in this internal '
             || 'bank policy as machine-checkable predicates. One entry per '
             || 'distinct effective period.' || CHR(10) || CHR(10)
             || 'For each: the scenario code, what is measured, the comparison '
             || 'operator, the numeric threshold in rupees, the rolling window '
             || 'in days, the date it took effect, the date it ceased to apply '
             || '(null if still in force), and a VERBATIM quote of the sentence '
             || 'you relied on.' || CHR(10) || CHR(10)
             || 'Dates MUST be ISO 8601 (YYYY-MM-DD). The model has been '
             || 'observed returning prose dates such as "1 January 2023", '
             || 'which parse to NULL and vanish without error.' || CHR(10)
             || 'Do not infer a threshold that is not stated. If a value is '
             || 'absent, omit the entry rather than estimating one.'
             || CHR(10) || CHR(10) || 'POLICY TEXT:' || CHR(10) || d.raw_text,
            model_parameters => {'temperature': 0, 'max_tokens': 2000},
            response_format => {
                'type': 'json',
                'schema': {
                    'type': 'object',
                    'properties': {
                        'predicates': {
                            'type': 'array',
                            'items': {
                                'type': 'object',
                                'properties': {
                                    'scenario_code':   {'type': 'string'},
                                    'subject':         {'type': 'string'},
                                    'field':           {'type': 'string'},
                                    'operator':        {'type': 'string'},
                                    'threshold_value': {'type': 'number'},
                                    'threshold_unit':  {'type': 'string'},
                                    'window_days':     {'type': 'number'},
                                    'effective_from':  {'type': 'string'},
                                    'effective_to':    {'type': 'string'},
                                    'source_quote':    {'type': 'string'},
                                    'confidence':      {'type': 'number'}
                                },
                                'required': ['scenario_code','subject','operator',
                                             'threshold_value','window_days',
                                             'effective_from','source_quote','confidence']
                            }
                        }
                    },
                    'required': ['predicates']
                }
            })) AS resp
    FROM doc d
)
SELECT
    e.doc_id,
    e.text_hash,
    p.value:scenario_code::STRING,
    p.value:subject::STRING,
    COALESCE(p.value:field::STRING, 'aggregate_amount'),
    p.value:operator::STRING,
    p.value:threshold_value::NUMBER(18,2),
    COALESCE(p.value:threshold_unit::STRING, 'INR'),
    p.value:window_days::NUMBER(5,0),
    COALESCE(TRY_TO_DATE(p.value:effective_from::STRING),
             TRY_TO_DATE(p.value:effective_from::STRING, 'DD MON YYYY'),
             TRY_TO_DATE(p.value:effective_from::STRING, 'DD MONTH YYYY')),
    COALESCE(TRY_TO_DATE(p.value:effective_to::STRING),
             TRY_TO_DATE(p.value:effective_to::STRING, 'DD MON YYYY'),
             TRY_TO_DATE(p.value:effective_to::STRING, 'DD MONTH YYYY')),
    p.value:source_quote::STRING,
    p.value:confidence::FLOAT,
    'claude-sonnet-4-5'
FROM extracted e,
     LATERAL FLATTEN(input => e.resp:predicates) p;

SELECT scenario_code, operator, threshold_value, window_days,
       effective_from, effective_to, ROUND(extraction_confidence, 2) AS confidence,
       certified_by,
       CASE WHEN effective_from IS NULL
            THEN 'DATE DID NOT PARSE - review before certifying' END AS warning
FROM POLICY.CANDIDATE_PREDICATES ORDER BY effective_from NULLS FIRST;

-- ---------------------------------------------------------------------------
-- 4. VERIFICATION. The compiler was never told the answer. Compare what it
--    extracted to the thresholds hand-declared in RULE_PREDICATES.
-- ---------------------------------------------------------------------------

SELECT
    COALESCE(c.effective_from, v.effective_from)                    AS effective_from,
    r.threshold_value                                               AS hand_declared,
    c.threshold_value                                               AS extracted,
    CASE WHEN r.threshold_value = c.threshold_value THEN 'MATCH'
         WHEN c.threshold_value IS NULL             THEN 'NOT EXTRACTED'
         WHEN r.threshold_value IS NULL             THEN 'EXTRACTED BUT NOT DECLARED'
         ELSE 'DISAGREES' END                                       AS verdict,
    r.window_days                                                   AS hand_window,
    c.window_days                                                   AS extracted_window
FROM POLICY.POLICY_VERSIONS v
JOIN POLICY.RULE_PREDICATES r USING (policy_version_id)
FULL OUTER JOIN POLICY.CANDIDATE_PREDICATES c
     ON c.effective_from = v.effective_from
ORDER BY 1;

-- The quotes. A predicate that cannot cite its sentence is not auditable.
SELECT threshold_value, effective_from, source_quote
FROM POLICY.CANDIDATE_PREDICATES ORDER BY effective_from;

-- ---------------------------------------------------------------------------
-- 5. Certification. A human signs; the signature binds to the source text.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE PROCEDURE POLICY.CERTIFY_PREDICATE(CANDIDATE_ID STRING, CERTIFIER STRING)
RETURNS STRING
LANGUAGE SQL
AS
$$
DECLARE
    cur_hash  STRING;
    src_hash  STRING;
    doc       STRING;
BEGIN
    SELECT source_doc_id, source_text_hash INTO :doc, :src_hash
    FROM POLICY.CANDIDATE_PREDICATES WHERE candidate_id = :CANDIDATE_ID;

    IF (:doc IS NULL) THEN
        RETURN 'REJECTED: no such candidate';
    END IF;

    -- Refuse to certify against text that has changed since extraction.
    SELECT SHA2(raw_text, 256) INTO :cur_hash
    FROM POLICY.POLICY_DOCUMENTS WHERE doc_id = :doc;

    IF (:cur_hash <> :src_hash) THEN
        RETURN 'REJECTED: source document changed since extraction. Re-extract first.';
    END IF;

    UPDATE POLICY.CANDIDATE_PREDICATES
       SET certified_by = :CERTIFIER,
           certified_at = CURRENT_TIMESTAMP(),
           certified_hash = :cur_hash
     WHERE candidate_id = :CANDIDATE_ID;

    RETURN 'CERTIFIED by ' || :CERTIFIER;
END;
$$;

-- Only certified predicates whose source text is UNCHANGED are usable.
-- Amend the policy and every certification derived from it lapses, because
-- what the human approved is no longer what is on file.
CREATE OR REPLACE VIEW POLICY.V_CERTIFIED_PREDICATES AS
SELECT c.*,
       SHA2(d.raw_text, 256) = c.certified_hash AS certification_still_valid
FROM POLICY.CANDIDATE_PREDICATES c
JOIN POLICY.POLICY_DOCUMENTS d ON d.doc_id = c.source_doc_id
WHERE c.certified_by IS NOT NULL;

-- ---------------------------------------------------------------------------
-- 6. Demonstrate the gate
-- ---------------------------------------------------------------------------

-- Nothing is usable yet: the model proposed, nobody signed.
SELECT COUNT(*) AS certified_and_valid
FROM POLICY.V_CERTIFIED_PREDICATES WHERE certification_still_valid;

-- Certify the two 8L predicates; deliberately leave the 10L one unsigned so
-- the difference between proposed and approved is visible.
CALL POLICY.CERTIFY_PREDICATE(
    (SELECT candidate_id FROM POLICY.CANDIDATE_PREDICATES
      WHERE threshold_value = 800000 ORDER BY effective_from LIMIT 1),
    'fcc.chair@bank.internal');

SELECT threshold_value, effective_from, certified_by, certification_still_valid
FROM POLICY.V_CERTIFIED_PREDICATES;

-- Now amend the source document. Every certification derived from it must lapse.
UPDATE POLICY.POLICY_DOCUMENTS
   SET raw_text = raw_text || CHR(10) || 'Amended 2026-09-17: wording clarified.'
 WHERE doc_id = 'AML-POL-009';

SELECT threshold_value, effective_from, certified_by,
       certification_still_valid,
       'source text amended after certification' AS why
FROM POLICY.V_CERTIFIED_PREDICATES;

-- And certification of anything else against the changed text is refused.
CALL POLICY.CERTIFY_PREDICATE(
    (SELECT candidate_id FROM POLICY.CANDIDATE_PREDICATES
      WHERE threshold_value = 1000000 LIMIT 1),
    'fcc.chair@bank.internal');
