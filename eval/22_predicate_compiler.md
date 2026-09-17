# 20_predicate_compiler.sql results

## Errors

None. All statements executed without SQL errors. However, the AI_COMPLETE extraction inserted 0 rows again — the same failure as the previous run. The document text now carries two appended amendment lines from successive runs, but the extraction still produces no rows despite the fix removing TRY_PARSE_JSON. CANDIDATE_PREDICATES is empty, so all downstream statements operate on an empty table.

## Statement 1 — INSERT INTO POLICY.POLICY_DOCUMENTS (AML-POL-009)

0 rows inserted (row already exists from previous run).

## Statement 2 — CREATE TABLE POLICY.CANDIDATE_PREDICATES

Table created successfully.

## Statement 3 — INSERT INTO POLICY.CANDIDATE_PREDICATES (AI_COMPLETE extraction)

0 rows inserted.

## Statement 4 — SELECT extracted candidates

| SCENARIO_CODE | OPERATOR | THRESHOLD_VALUE | WINDOW_DAYS | EFFECTIVE_FROM | EFFECTIVE_TO | CONFIDENCE | CERTIFIED_BY | WARNING |
|---------------|----------|-----------------|-------------|----------------|--------------|------------|--------------|---------|

0 rows returned.

## Statement 5 — Verification: extracted vs hand-declared

| EFFECTIVE_FROM | HAND_DECLARED | EXTRACTED | VERDICT | HAND_WINDOW | EXTRACTED_WINDOW |
|----------------|---------------|-----------|---------|-------------|------------------|
| 2023-01-01 | 800000.00 | | NOT EXTRACTED | 7 | |
| 2025-07-01 | 1000000.00 | | NOT EXTRACTED | 7 | |
| 2026-08-14 | 800000.00 | | NOT EXTRACTED | 7 | |

## Statement 6 — Source quotes

| THRESHOLD_VALUE | EFFECTIVE_FROM | SOURCE_QUOTE |
|-----------------|----------------|--------------|

0 rows returned.

## Statement 7 — CREATE PROCEDURE POLICY.CERTIFY_PREDICATE

Procedure created successfully.

## Statement 8 — CREATE VIEW POLICY.V_CERTIFIED_PREDICATES

View created successfully.

## Statement 9 — SELECT COUNT(*) certified_and_valid

| CERTIFIED_AND_VALID |
|---------------------|
| 0 |

## Statement 10 — CALL POLICY.CERTIFY_PREDICATE (800000 predicate)

| CERTIFY_PREDICATE |
|-------------------|
| REJECTED: no such candidate |

## Statement 11 — SELECT from V_CERTIFIED_PREDICATES

0 rows returned.

## Statement 12 — UPDATE POLICY.POLICY_DOCUMENTS (amend AML-POL-009)

1 row updated.

## Statement 13 — SELECT from V_CERTIFIED_PREDICATES after amendment

0 rows returned.

## Statement 14 — CALL POLICY.CERTIFY_PREDICATE (1000000 predicate against changed text)

| CERTIFY_PREDICATE |
|-------------------|
| REJECTED: no such candidate |
