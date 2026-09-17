# sql/27_tamper_drill.sql — run output

Snowsight, `ACCOUNTADMIN`, `TRACE_DB`, `COMPUTE_WH` (X-Small).
Three deliberate attacks on the case action log, to establish that the
verification returns `TAMPERED` when it should.

Three attempts were needed. The first two failures are recorded because the
point of this file is what actually happened, not the run that worked.

---

## Attempt 1 — compilation error

```
SQL compilation error: error line 116 at position 16 invalid identifier 'ACTOR'
```

The per-row detail query selected `actor` and `action` from
`AUDIT.V_ACTION_LOG_VERIFICATION`, which exposes only `link_no`, `case_ref`,
`link_intact`, `hash_recomputes` and `no_fork`. Fixed by joining to
`AUDIT.AUDIT_LOG` rather than widening the view, so the view keeps one
definition (in `sql/26`).

The script died *after* drill 1's forged insert and *before* its reseed, so
the log was left tampered. Harmless — step 0 of the script deletes and
reseeds — but worth noting that a half-run of this script leaves state dirty.

---

## Attempt 2 — ran, but the results were unreadable

Completed. Final statement returned:

| SCOPE | LINKS | FAULTS |
|---|---|---|
| EVIDENCE CHAIN | 687 | 0 |

473 ms.

The evidence chain was confirmed untouched, but **the three drill verdicts
were not visible.** Snowsight displays only the last statement's result pane,
so each drill's verdict was overwritten by the next statement. The run looked
like it had only checked the evidence chain.

This is a reporting defect, not a logic one, and it is exactly the kind that
would have been mistaken for success. Outcomes now accumulate into
`AUDIT.TAMPER_DRILL_LOG` and the final statement returns all of them at once.

---

## Attempt 3 — full result

`CALL`s, drills and reseeds as scripted; final statement returns the drill log
unioned with the evidence-chain check. 6 rows, 595 ms.

| ORD | DRILL | ATTACK | ACTIONS | BROKEN_LINKS | HASH_MISMATCHES | FORKED_ROWS | VERDICT | CAUGHT_BY |
|---|---|---|---|---|---|---|---|---|
| 0 | baseline | nothing altered | 4 | 0 | 0 | 0 | `INTACT` | — |
| 1 | forged append | insert a fake closure, linked correctly to the head | 5 | 0 | **1** | 0 | `TAMPERED` | hash recomputation |
| 2 | reworded decision | rewrite the FIU escalation as a routine clearance | 4 | 0 | **1** | 0 | `TAMPERED` | hash recomputation |
| 3 | deleted record | remove the FIU escalation entirely | 3 | **1** | 0 | 0 | `TAMPERED` | link walk |
| 4 | restored | reseeded after the drills | 4 | 0 | 0 | 0 | `INTACT` | — |
| 9 | evidence chain | never written to by this script | 687 | 0 | 0 | 0 | `INTACT` | — |

### Reading rows 2 and 3

These were the falsifiable predictions, and they are the reason the drill
exists rather than a sentence asserting the chain is sound.

- **Drill 2** edits content only. `link_no`, `prev_hash` and `row_hash` are
  untouched, so the chain walks perfectly: `broken_links 0`. Caught solely by
  recomputing the hash from stored content.
- **Drill 3** removes a row. Every survivor still hashes correctly:
  `hash_mismatches 0`. Caught solely by the walk.

`0/1` against `1/0`. Each attack is invisible to the check that catches the
other, so a verification built on either alone would have returned `INTACT`
on one of them. The third column is justified by measurement.

Row 3 was the one stated in advance as the falsifier: had it returned
`hash_mismatches 1`, the model of what deletion does to the chain would have
been wrong.

### Evidence chain

Row 9 confirms `AUDIT.EVIDENCE_CHAIN` at 687 links with 0 faults after all
three attacks — the drills touch `AUDIT_LOG` only. This is checked rather
than asserted.

---

## What this run does not establish

An adversary holding `ACCOUNTADMIN` who also reads this repository can append
a **well-formed** forgery: the canonical string is public, so a `row_hash`
that recomputes correctly and links to the head can be computed. It would
appear in this table as `INTACT`, because it is indistinguishable from a real
append.

The chain makes the past tamper-evident. It does not make the present
unforgeable. See `EVALUATION.md`, "What the drills do not prove".
