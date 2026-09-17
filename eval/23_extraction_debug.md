# 21_extraction_debug.sql results

## Errors

None.

## Statement A — Plain text AI_COMPLETE (no response_format)

| PLAIN_TEXT_RESPONSE |
|---------------------|
| ```json {"predicates":[{"threshold_value":800000,"effective_from":"2023-01-01"},{"threshold_value":1000000,"effective_from":"2025-07-01"},{"threshold_value":800000,"effective_from":"2026-08-14"}]} ``` |

## Statement B — With response_format: returned type, parseability, predicate count

| RETURNED_TYPE | FIRST_900_CHARS | PARSE_JSON_FAILS | PREDICATES_FOUND |
|---------------|-----------------|------------------|------------------|
| OBJECT | {"predicates":[{"effective_from":"1 January 2023","source_quote":"From 1 January 2023 the threshold was eight lakh rupees (INR 800,000).","threshold_value":800000},{"effective_from":"1 July 2025","source_quote":"With effect from 1 July 2025 the Committee raised the threshold to ten lakh rupees (INR 1,000,000), citing alert volume.","threshold_value":1000000},{"effective_from":"14 August 2026","source_quote":"Following a supervisory observation the threshold was restored to eight lakh rupees (INR 800,000) with effect from 14 August 2026, and a lookback was directed under Para 7.4 covering the full period during which the raised threshold was in force.","threshold_value":800000}]} | FALSE | 3 |

## Statement C — FLATTEN directly on VARIANT (no TRY_PARSE_JSON round-trip)

| THRESHOLD_VALUE | EFFECTIVE_FROM |
|-----------------|----------------|
| 800000 | 2023-01-01 |
| 1000000 | 2025-07-01 |
| 800000 | 2026-08-14 |
