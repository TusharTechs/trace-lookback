# 25_chain_diagnosis.sql results

## Errors

None.

## Statement 1 — Raw chain with lag by seq and by time

| SEQ | EVENT_TS | ACTION | PREV_HASH | ROW_HASH | PRIOR_ROW_HASH_BY_SEQ | PRIOR_ROW_HASH_BY_TIME |
|-----|----------|--------|-----------|----------|-----------------------|------------------------|
| 1 | 2026-09-17 11:07:15.383 | ASSIGNED | GENESIS | 72f7fc58e18a | | |
| 2 | 2026-09-17 11:12:27.436 | ASSIGNED | ccee2e0f421e | f02bc1c00244 | 72f7fc58e18a | ccee2e0f421e |
| 101 | 2026-09-17 11:07:24.470 | ESCALATED_TO_FIU | 72f7fc58e18a | 16ee62cd15df | f02bc1c00244 | 72f7fc58e18a |
| 102 | 2026-09-17 11:07:33.239 | CLOSED_NO_ACTION | 16ee62cd15df | dfb97920c528 | 16ee62cd15df | 16ee62cd15df |
| 201 | 2026-09-17 11:07:40.510 | SUPERSEDED | dfb97920c528 | ccee2e0f421e | dfb97920c528 | dfb97920c528 |
| 202 | 2026-09-17 11:12:30.509 | ESCALATED_TO_FIU | ccee2e0f421e | c4ef81b34836 | ccee2e0f421e | f02bc1c00244 |
| 301 | 2026-09-17 11:12:32.845 | CLOSED_NO_ACTION | c4ef81b34836 | a3c09534e1c6 | c4ef81b34836 | c4ef81b34836 |
| 401 | 2026-09-17 11:12:34.988 | SUPERSEDED | a3c09534e1c6 | 17a59342ac15 | a3c09534e1c6 | a3c09534e1c6 |

## Statement 2 — Seq monotonicity vs insertion time

| ROWS_TOTAL | ROWS_OUT_OF_ORDER |
|------------|-------------------|
| 8 | 4 |

## Statement 3 — Verify chain ordered by insertion time

| ACTIONS | BROKEN_BY_TIME | VERDICT |
|---------|----------------|---------|
| 8 | 1 | STILL BROKEN - not an ordering problem |

## Statement 4 — Duplicate prev_hash values (race condition)

| PREV_HASH | CLAIMED_BY |
|-----------|------------|
| ccee2e0f421ed7edb8abe398508d1885b2f4b628608430b2be34b1b465d7ff11 | 2 |

## Statement 5 — Self-hash integrity check

| ROWS_CHECKED | SELF_HASH_MISMATCHES |
|--------------|----------------------|
| 8 | 8 |
