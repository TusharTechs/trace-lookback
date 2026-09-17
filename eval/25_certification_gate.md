# 23_certification_gate.sql results

## Errors

None.

## Statement 1a — CREATE VIEW POLICY.V_CERTIFICATION_QUEUE

View created successfully.

## Statement 1b — SELECT from V_CERTIFICATION_QUEUE

| THRESHOLD_VALUE | EFFECTIVE_FROM | EFFECTIVE_TO | THRESHOLD_PROVENANCE | EFFECTIVE_TO_PROVENANCE |
|-----------------|----------------|--------------|----------------------|-------------------------|
| 800000.00 | 2023-01-01 | 2025-06-30 | EXTRACTED - supported by quote | INFERRED - derived from the next period, confirm before signing |
| 1000000.00 | 2025-07-01 | 2026-08-13 | EXTRACTED - supported by quote | INFERRED - derived from the next period, confirm before signing |
| 800000.00 | 2026-08-14 | | EXTRACTED - supported by quote | n/a - still in force |

## Statement 2 — SELECT COUNT(*) certified_and_valid (before signing)

| CERTIFIED_AND_VALID |
|---------------------|
| 0 |

## Statement 3a — CALL POLICY.CERTIFY_PREDICATE (2023-01-01, 800000)

| CERTIFY_PREDICATE |
|-------------------|
| CERTIFIED by fcc.chair@bank.internal |

## Statement 3b — SELECT from V_CERTIFIED_PREDICATES (after signing)

| THRESHOLD_VALUE | EFFECTIVE_FROM | CERTIFIED_BY | CERTIFIED_AT | CERTIFICATION_STILL_VALID |
|-----------------|----------------|--------------|--------------|---------------------------|
| 800000.00 | 2023-01-01 | fcc.chair@bank.internal | 2026-09-17 10:56:54.032 | TRUE |

## Statement 4a — UPDATE POLICY.POLICY_DOCUMENTS (amend AML-POL-009)

1 row updated.

## Statement 4b — SELECT from V_CERTIFIED_PREDICATES (after amendment)

| THRESHOLD_VALUE | EFFECTIVE_FROM | CERTIFIED_BY | CERTIFICATION_STILL_VALID | WHY |
|-----------------|----------------|--------------|---------------------------|-----|
| 800000.00 | 2023-01-01 | fcc.chair@bank.internal | FALSE | source text amended after signing |

## Statement 5 — CALL POLICY.CERTIFY_PREDICATE (2025-07-01, against changed text)

| CERTIFY_PREDICATE |
|-------------------|
| REJECTED: source document changed since extraction. Re-extract first. |

## Statement 6a — CREATE VIEW POLICY.V_ENFORCEABLE_PREDICATES

View created successfully.

## Statement 6b — SELECT COUNT(*) enforceable_now

| ENFORCEABLE_NOW |
|-----------------|
| 0 |

## Statement 6c — Next step

| NEXT_STEP |
|-----------|
| Re-run sql/22_extraction_staged.sql to re-extract against the amended text |
