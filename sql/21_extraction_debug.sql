-- ============================================================================
-- 21_extraction_debug.sql — what does AI_COMPLETE actually return?
--
-- The predicate extraction inserted 0 rows. Rather than guess at the cause --
-- nested-array response_format, TRY_PARSE_JSON on an already-parsed object, a
-- wrong FLATTEN path -- look at the raw value. Three cheap calls.
-- ============================================================================

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE COMPUTE_WH;
USE DATABASE TRACE_DB;

-- A. No response_format at all. Does the model produce the content?
SELECT AI_COMPLETE(
    model => 'claude-sonnet-4-5',
    prompt => 'List every distinct cash threshold stated in this policy, with '
           || 'its effective date. Reply as compact JSON only, no prose: '
           || '{"predicates":[{"threshold_value":800000,"effective_from":"2023-01-01"}]}'
           || CHR(10) || CHR(10)
           || (SELECT raw_text FROM POLICY.POLICY_DOCUMENTS WHERE doc_id = 'AML-POL-009'),
    model_parameters => {'temperature': 0, 'max_tokens': 800}
) AS plain_text_response;

-- B. With response_format. What TYPE comes back, and what does it look like?
WITH r AS (
    SELECT AI_COMPLETE(
        model => 'claude-sonnet-4-5',
        prompt => 'Extract every distinct threshold rule stated in this policy. '
               || 'One entry per effective period. Quote the sentence relied on.'
               || CHR(10) || CHR(10)
               || (SELECT raw_text FROM POLICY.POLICY_DOCUMENTS WHERE doc_id = 'AML-POL-009'),
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
                                'source_quote':    {'type': 'string'}
                            },
                            'required': ['threshold_value','effective_from','source_quote']
                        }
                    }
                },
                'required': ['predicates']
            }
        }) AS raw
)
SELECT
    TYPEOF(raw)                               AS returned_type,
    LEFT(TO_VARCHAR(raw), 900)                AS first_900_chars,
    TRY_PARSE_JSON(TO_VARCHAR(raw)) IS NULL   AS parse_json_fails,
    ARRAY_SIZE(TRY_PARSE_JSON(TO_VARCHAR(raw)):predicates) AS predicates_found
FROM r;

-- C. Does FLATTEN reach the array when the value is treated as VARIANT
--    directly, without a TRY_PARSE_JSON round-trip?
WITH r AS (
    SELECT AI_COMPLETE(
        model => 'claude-sonnet-4-5',
        prompt => 'Extract every distinct threshold rule stated in this policy.'
               || CHR(10) || CHR(10)
               || (SELECT raw_text FROM POLICY.POLICY_DOCUMENTS WHERE doc_id = 'AML-POL-009'),
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
                                'effective_from':  {'type': 'string'}
                            },
                            'required': ['threshold_value','effective_from']
                        }
                    }
                },
                'required': ['predicates']
            }
        }) AS raw
)
SELECT p.value:threshold_value::NUMBER AS threshold_value,
       p.value:effective_from::STRING  AS effective_from
FROM r, LATERAL FLATTEN(input => r.raw:predicates) p;
