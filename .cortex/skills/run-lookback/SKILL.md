---
name: run-lookback
description: Run the TRACE lookback pipeline end to end, or any stage of it, in the correct order and with cost stated before spending. Use when asked to rebuild, re-run, re-adjudicate or refresh results.
---

# When to use

- "Re-run the lookback" / "rebuild everything"
- "Re-adjudicate with the new prompt"
- Any request that would invoke `AI_COMPLETE` over the population

# State the cost first, always

A full adjudication is **2,759 Cortex calls, roughly $20–25**. AI credits are
94% of this project's spend and the resource monitor does not cover them.

**Never run the full population to test a change.** Iterate on the 150-row
holdout:

```sql
... JOIN TRACE_DB.EVAL.CALIBRATION_SET c ON c.alert_id = a.alert_id
WHERE c.split = 'HOLDOUT' ... LIMIT 150
```

That is about $1. Run the population only when a reported result depends on it,
and say so before starting.

# Order

Stages are dependent. Running one out of order produces results that look fine
and are wrong.

| # | file | what it does | AI cost |
|---|---|---|---|
| 1 | `sql/01_foundation.sql` | bitemporal schema — **destructive** | none |
| 2 | `sql/02_eval_tables.sql` | ground-truth tables | none |
| 3 | `generator/generate.py` | synthetic corpus (local, seeded) | none |
| 4 | `sql/11_reload_and_score_v5.sql` | stage + load | none |
| 5 | `sql/12_replay_engine.sql` | point-in-time features + **validation gate** | none |
| 6 | `sql/13_adjudicate.sql` | recalibration, then full adjudication | **~$20–25** |
| 7 | `sql/14_evidence_packs.sql` | evidence packs | none |
| 8 | `sql/16_append_only_chain.sql` | hash chain | none |
| 9 | `sql/15_final_metrics.sql` | AUC, lift, concentration | none |

`sql/17_roles_and_masking.sql` is **run by a human in Snowsight**, not here —
four of its statements are refused by this project's own controls.

`sql/03`–`10` are superseded and retained as history. Do not run them.

# Gates — stop if these fail

**After stage 5**, the replay engine validates against the generator. Require
`amount_exact_match = 1.0000` and correlation ≥ 0.99 on `cash_vs_monthly_income`,
`weeks_with_cash_activity_pct` and `deposits_just_under_round_pct`. If those
diverge, the features the model will score differ from the ones the operating
threshold was chosen against, and the adjudication is not comparable. Stop.

`outward_transfer_ratio` (~0.91) and `distinct_branches_used` (~0.99) diverge by
design — the engine measures what actually happened rather than a simulation
parameter.

**After stage 4**, the human baseline must reproduce: accuracy 0.731, recall
0.595, precision 0.573 on 4,856 alerts. A mismatch means the load is wrong.

# Reference results

```
AUC (invisible population) 0.608     recall @0.45  0.850
precision                  0.593     packs         687
chain                      INTACT
```

Report differences against these rather than presenting new numbers as if
nothing preceded them.

# Do not

- Run `PUT` via `snow` or SnowSQL — not installed, and the Python connector's
  TLS fails on this machine regardless of network (endpoint agent + pyOpenSSL;
  see `generator/load.py`). CoCo's `sql_execute` handles `PUT` natively with
  repo-relative paths.
- Re-run a stage "to be safe". Stage 1 is destructive; stage 6 costs money.
