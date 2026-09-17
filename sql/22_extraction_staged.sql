-- ============================================================================
-- 22_extraction_staged.sql — two-stage extraction, so failure is visible.
--
-- Twice now the extraction has inserted 0 rows with no error, because the
-- model call, the parse and the flatten were fused into one INSERT...SELECT.
-- When that produces nothing there is no way to tell which step failed.
--
-- Split it:
--
--     stage 1  call the model, keep the raw response   (POLICY.EXTRACTION_RUNS)
--     stage 2  parse the stored response into rows     (CANDIDATE_PREDICATES)
--
-- Better for debugging, and better on its own terms: what the model actually
-- said is exactly the artifact a regulator would ask for when a rule's
-- provenance is questioned. Discarding it inside a CTE was a mistake.
--
-- Also resets AML-POL-009: two prior runs each appended an amendment line to
-- the document, so the text now differs from what was authored.
-- ============================================================================

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE COMPUTE_WH;
USE DATABASE TRACE_DB;

-- ---------------------------------------------------------------------------
-- 0. Reset the source document to its authored state.
-- ---------------------------------------------------------------------------

UPDATE POLICY.POLICY_DOCUMENTS
SET raw_text =
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
WHERE doc_id = 'AML-POL-009';

-- ---------------------------------------------------------------------------
-- 1. Stage one: call the model, keep everything it returned.
--
--    Required fields are now ONLY what the document actually states per
--    period. scenario_code and window_days appear once in the preamble, not
--    per threshold; demanding them per entry may be why the array came back
--    empty. They are still requested, just not required.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE TABLE POLICY.EXTRACTION_RUNS (
    run_id       STRING        DEFAULT UUID_STRING(),
    doc_id       STRING,
    text_hash    STRING,
    model_name   STRING,
    response     VARIANT,
    response_txt STRING,
    ran_at       TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

INSERT INTO POLICY.EXTRACTION_RUNS (doc_id, text_hash, model_name, response, response_txt)
SELECT
    d.doc_id,
    SHA2(d.raw_text, 256),
    'claude-sonnet-4-5',
    r.resp,
    TO_VARCHAR(r.resp)
FROM POLICY.POLICY_DOCUMENTS d,
     LATERAL (
        SELECT AI_COMPLETE(
            model => 'claude-sonnet-4-5',
            prompt =>
                'This internal bank policy states a cash threshold that changed '
             || 'over time. Extract one entry per distinct threshold period.'
             || CHR(10) || CHR(10)
             || 'threshold_value: the amount in rupees, as a number.' || CHR(10)
             || 'effective_from: ISO 8601 date, YYYY-MM-DD.' || CHR(10)
             || 'effective_to: ISO 8601 date, or omit if still in force.' || CHR(10)
             || 'window_days: the rolling window in days, stated in the preamble.' || CHR(10)
             || 'source_quote: verbatim sentence you relied on.' || CHR(10)
             || 'confidence: 0 to 1.' || CHR(10) || CHR(10)
             || 'Do not infer a threshold that is not stated.'
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
                                    'threshold_value': {'type': 'number'},
                                    'effective_from':  {'type': 'string'},
                                    'effective_to':    {'type': 'string'},
                                    'window_days':     {'type': 'number'},
                                    'source_quote':    {'type': 'string'},
                                    'confidence':      {'type': 'number'}
                                },
                                'required': ['threshold_value', 'effective_from', 'source_quote']
                            }
                        }
                    },
                    'required': ['predicates']
                }
            }) AS resp
     ) r
WHERE d.doc_id = 'AML-POL-009';

-- What came back. If predicates_found is 0 the model is the problem; if it is
-- 3 and the insert below still yields nothing, the parse is.
SELECT
    TYPEOF(response)                        AS response_type,
    ARRAY_SIZE(response:predicates)         AS predicates_found,
    LENGTH(response_txt)                    AS response_chars,
    LEFT(response_txt, 1200)                AS response_head
FROM POLICY.EXTRACTION_RUNS
ORDER BY ran_at DESC LIMIT 1;

-- ---------------------------------------------------------------------------
-- 2. Stage two: parse the stored response.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE TABLE POLICY.CANDIDATE_PREDICATES (
    candidate_id      STRING        DEFAULT UUID_STRING(),
    run_id            STRING,
    source_doc_id     STRING        NOT NULL,
    source_text_hash  STRING        NOT NULL,
    scenario_code     STRING,
    field             STRING,
    operator          STRING,
    threshold_value   NUMBER(18,2),
    threshold_unit    STRING,
    window_days       NUMBER(5,0),
    effective_from    DATE,
    effective_to      DATE,
    source_quote      STRING,
    extraction_confidence FLOAT,
    extracted_by      STRING,
    extracted_at      TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    certified_by      STRING,
    certified_at      TIMESTAMP_NTZ,
    certified_hash    STRING
);

INSERT INTO POLICY.CANDIDATE_PREDICATES
    (run_id, source_doc_id, source_text_hash, scenario_code, field, operator,
     threshold_value, threshold_unit, window_days, effective_from, effective_to,
     source_quote, extraction_confidence, extracted_by)
SELECT
    e.run_id,
    e.doc_id,
    e.text_hash,
    'TM-STRUCT-01',
    'aggregate_amount',
    '>=',
    p.value:threshold_value::NUMBER(18,2),
    'INR',
    COALESCE(p.value:window_days::NUMBER(5,0), 7),
    COALESCE(TRY_TO_DATE(p.value:effective_from::STRING),
             TRY_TO_DATE(p.value:effective_from::STRING, 'DD MON YYYY'),
             TRY_TO_DATE(p.value:effective_from::STRING, 'DD MONTH YYYY')),
    COALESCE(TRY_TO_DATE(p.value:effective_to::STRING),
             TRY_TO_DATE(p.value:effective_to::STRING, 'DD MON YYYY'),
             TRY_TO_DATE(p.value:effective_to::STRING, 'DD MONTH YYYY')),
    p.value:source_quote::STRING,
    p.value:confidence::FLOAT,
    e.model_name
FROM POLICY.EXTRACTION_RUNS e,
     LATERAL FLATTEN(input => e.response:predicates) p;

SELECT threshold_value, effective_from, effective_to, window_days,
       ROUND(extraction_confidence, 2) AS confidence,
       CASE WHEN effective_from IS NULL
            THEN 'DATE DID NOT PARSE - review before certifying' END AS warning,
       source_quote
FROM POLICY.CANDIDATE_PREDICATES ORDER BY effective_from NULLS FIRST;

-- ---------------------------------------------------------------------------
-- 3. Verification: did the compiler reproduce the hand-declared thresholds?
-- ---------------------------------------------------------------------------

SELECT
    v.effective_from,
    r.threshold_value  AS hand_declared,
    c.threshold_value  AS extracted,
    CASE WHEN c.threshold_value IS NULL           THEN 'NOT EXTRACTED'
         WHEN r.threshold_value = c.threshold_value THEN 'MATCH'
         ELSE 'DISAGREES' END AS verdict
FROM POLICY.POLICY_VERSIONS v
JOIN POLICY.RULE_PREDICATES r USING (policy_version_id)
LEFT JOIN POLICY.CANDIDATE_PREDICATES c ON c.effective_from = v.effective_from
ORDER BY 1;
