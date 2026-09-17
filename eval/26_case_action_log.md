# 24_case_action_log.sql results

## Errors

### GRANT USAGE ON PROCEDURE AUDIT.RECORD_CASE_ACTION

```
[Hook] Blocked: BLOCKED: GRANT against the AUDIT schema.
AUDIT is append-only. It holds the evidence packs and hash chain that would be handed to an examiner; a record that can be edited is not evidence.
Permitted: SELECT, INSERT, CALL. To rebuild the chain use CALL AUDIT.BUILD_EVIDENCE_CHAIN(), which only inserts.
```

### CREATE OR REPLACE VIEW AUDIT.V_CASE_HISTORY

```
[Hook] Blocked: BLOCKED: CREATE OR REPLACE VIEW against the AUDIT schema.
AUDIT is append-only. It holds the evidence packs and hash chain that would be handed to an examiner; a record that can be edited is not evidence.
Permitted: SELECT, INSERT, CALL. To rebuild the chain use CALL AUDIT.BUILD_EVIDENCE_CHAIN(), which only inserts.
```

### CREATE OR REPLACE VIEW AUDIT.V_CASE_STATUS

```
[Hook] Blocked: BLOCKED: CREATE OR REPLACE VIEW against the AUDIT schema.
AUDIT is append-only. It holds the evidence packs and hash chain that would be handed to an examiner; a record that can be edited is not evidence.
Permitted: SELECT, INSERT, CALL. To rebuild the chain use CALL AUDIT.BUILD_EVIDENCE_CHAIN(), which only inserts.
```

### GRANT SELECT ON VIEW AUDIT.V_CASE_HISTORY

```
[Hook] Blocked: BLOCKED: GRANT against the AUDIT schema.
AUDIT is append-only. It holds the evidence packs and hash chain that would be handed to an examiner; a record that can be edited is not evidence.
Permitted: SELECT, INSERT, CALL. To rebuild the chain use CALL AUDIT.BUILD_EVIDENCE_CHAIN(), which only inserts.
```

### GRANT SELECT ON VIEW AUDIT.V_CASE_STATUS

```
[Hook] Blocked: BLOCKED: GRANT against the AUDIT schema.
AUDIT is append-only. It holds the evidence packs and hash chain that would be handed to an examiner; a record that can be edited is not evidence.
Permitted: SELECT, INSERT, CALL. To rebuild the chain use CALL AUDIT.BUILD_EVIDENCE_CHAIN(), which only inserts.
```

### CREATE OR REPLACE VIEW AUDIT.V_ACTION_LOG_VERIFICATION

```
[Hook] Blocked: BLOCKED: CREATE OR REPLACE VIEW against the AUDIT schema.
AUDIT is append-only. It holds the evidence packs and hash chain that would be handed to an examiner; a record that can be edited is not evidence.
Permitted: SELECT, INSERT, CALL. To rebuild the chain use CALL AUDIT.BUILD_EVIDENCE_CHAIN(), which only inserts.
```

### SELECT * FROM AUDIT.V_CASE_HISTORY

```
SQL compilation error:
Object 'TRACE_DB.AUDIT.V_CASE_HISTORY' does not exist or not authorized.
```

### SELECT * FROM AUDIT.V_CASE_STATUS

```
SQL compilation error:
Object 'TRACE_DB.AUDIT.V_CASE_STATUS' does not exist or not authorized.
```

### SELECT FROM AUDIT.V_ACTION_LOG_VERIFICATION

```
SQL compilation error:
Object 'TRACE_DB.AUDIT.V_ACTION_LOG_VERIFICATION' does not exist or not authorized.
```

## Statement 1 — CREATE PROCEDURE AUDIT.RECORD_CASE_ACTION

Procedure created successfully.

## Statement 4a — CALL RECORD_CASE_ACTION (assign top case)

| RECORD_CASE_ACTION |
|--------------------|
| RECORDED ASSIGNED on CU-100120\|2026-01-19 (72f7fc58e18a…) |

## Statement 4b — CALL RECORD_CASE_ACTION (escalate to FIU)

| RECORD_CASE_ACTION |
|--------------------|
| RECORDED ESCALATED_TO_FIU on CU-100120\|2026-01-19 (16ee62cd15df…) |

## Statement 4c — CALL RECORD_CASE_ACTION (close second case)

| RECORD_CASE_ACTION |
|--------------------|
| RECORDED CLOSED_NO_ACTION on CU-100150\|2026-04-13 (dfb97920c528…) |

## Statement 4d — CALL RECORD_CASE_ACTION (supersede the closure)

| RECORD_CASE_ACTION |
|--------------------|
| RECORDED SUPERSEDED on CU-100150\|2026-04-13 (ccee2e0f421e…) |

## Statement 4e — CALL RECORD_CASE_ACTION (non-existent case)

| RECORD_CASE_ACTION |
|--------------------|
| REJECTED: no such case CU-999999\|2026-01-01 |

## Statement 4f — CALL RECORD_CASE_ACTION (unknown action type)

| RECORD_CASE_ACTION |
|--------------------|
| REJECTED: unknown action DELETE_EVERYTHING |
