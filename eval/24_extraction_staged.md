# 22_extraction_staged.sql results

## Errors

None.

## Statement 0 — UPDATE POLICY.POLICY_DOCUMENTS (reset AML-POL-009)

1 row updated.

## Statement 1a — CREATE TABLE POLICY.EXTRACTION_RUNS

Table created successfully.

## Statement 1b — INSERT INTO POLICY.EXTRACTION_RUNS (AI_COMPLETE call)

1 row inserted.

## Statement 1c — Inspect raw response

| RESPONSE_TYPE | PREDICATES_FOUND | RESPONSE_CHARS | RESPONSE_HEAD |
|---------------|------------------|----------------|---------------|
| OBJECT | 3 | 710 | {"predicates":[{"confidence":1,"effective_from":"2023-01-01","effective_to":"2025-06-30","source_quote":"From 1 January 2023 the threshold was eight lakh rupees (INR 800,000).","threshold_value":800000,"window_days":7},{"confidence":1,"effective_from":"2025-07-01","effective_to":"2026-08-13","source_quote":"With effect from 1 July 2025 the Committee raised the threshold to ten lakh rupees (INR 1,000,000), citing alert volume.","threshold_value":1000000,"window_days":7},{"confidence":1,"effective_from":"2026-08-14","source_quote":"Following a supervisory observation the threshold was restored to eight lakh rupees (INR 800,000) with effect from 14 August 2026","threshold_value":800000,"window_days":7}]} |

## Statement 2a — CREATE TABLE POLICY.CANDIDATE_PREDICATES

Table created successfully.

## Statement 2b — INSERT INTO POLICY.CANDIDATE_PREDICATES (parse stored response)

3 rows inserted.

## Statement 2c — SELECT candidate predicates

| THRESHOLD_VALUE | EFFECTIVE_FROM | EFFECTIVE_TO | WINDOW_DAYS | CONFIDENCE | WARNING | SOURCE_QUOTE |
|-----------------|----------------|--------------|-------------|------------|---------|--------------|
| 800000.00 | 2023-01-01 | 2025-06-30 | 7 | 1 | | From 1 January 2023 the threshold was eight lakh rupees (INR 800,000). |
| 1000000.00 | 2025-07-01 | 2026-08-13 | 7 | 1 | | With effect from 1 July 2025 the Committee raised the threshold to ten lakh rupees (INR 1,000,000), citing alert volume. |
| 800000.00 | 2026-08-14 | | 7 | 1 | | Following a supervisory observation the threshold was restored to eight lakh rupees (INR 800,000) with effect from 14 August 2026 |

## Statement 3 — Verification: extracted vs hand-declared

| EFFECTIVE_FROM | HAND_DECLARED | EXTRACTED | VERDICT |
|----------------|---------------|-----------|---------|
| 2023-01-01 | 800000.00 | 800000.00 | MATCH |
| 2025-07-01 | 1000000.00 | 1000000.00 | MATCH |
| 2026-08-14 | 800000.00 | 800000.00 | MATCH |
