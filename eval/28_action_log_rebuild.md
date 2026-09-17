# sql/26_action_log_rebuild.sql — run output

Snowsight, `ACCOUNTADMIN`, `TRACE_DB`, `COMPUTE_WH` (X-Small).
Rebuild of the case action log after the fork found in `eval/27_chain_diagnosis.md`.

## Final statement — verification

```sql
SELECT
    COUNT(*) AS actions,
    COALESCE(SUM(CASE WHEN link_intact     THEN 0 ELSE 1 END), 0) AS broken_links,
    COALESCE(SUM(CASE WHEN hash_recomputes THEN 0 ELSE 1 END), 0) AS hash_mismatches,
    COALESCE(SUM(CASE WHEN no_fork         THEN 0 ELSE 1 END), 0) AS forked_rows,
    ...
FROM AUDIT.V_ACTION_LOG_VERIFICATION;
```

| ACTIONS | BROKEN_LINKS | HASH_MISMATCHES | FORKED_ROWS | VERDICT |
|---|---|---|---|---|
| 4 | 0 | 0 | 0 | `INTACT` |

204 ms.

`HASH_MISMATCHES 0` is the load-bearing cell. Before this rebuild every row
failed self-verification (`eval/27_chain_diagnosis.md`, Q5: 8 of 8), because
the procedure hashed a `CURRENT_TIMESTAMP()` separate from the one stored in
`event_ts`. Zero here means the canonical string in `RECORD_CASE_ACTION` and
the one in `V_ACTION_LOG_VERIFICATION` agree, and the hash can therefore be
recomputed from the stored row by someone who did not write it.

## Not captured

The `SELECT * FROM AUDIT.V_CASE_HISTORY ORDER BY link_no` immediately above
this was not screenshotted; Snowsight shows one result pane at a time. The
four rows it returns are the same four reseeded by every later run and appear
in `eval/29_tamper_drill.md` as the baseline.
