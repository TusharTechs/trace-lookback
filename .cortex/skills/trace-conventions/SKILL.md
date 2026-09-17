---
name: trace-conventions
description: House rules for the TRACE codebase — Snowflake dialect traps, architectural invariants, and cost discipline. Load before writing any SQL against TRACE_DB.
---

# When to use

Before writing or running any SQL against `TRACE_DB`. Every item below cost us a
failed run; none are stylistic.

# Architectural invariants

**AUDIT is append-only.** `UPDATE`, `DELETE`, `MERGE`, `TRUNCATE`, `DROP`,
`ALTER`, `CREATE OR REPLACE` and `GRANT` against `AUDIT.*` are refused by a
`PreToolUse` hook, and no role holds those privileges. This is not a
misconfiguration to route around. To correct a record, **insert a corrective
record**. To rebuild the chain, `CALL AUDIT.BUILD_EVIDENCE_CHAIN()` — it only
inserts.

Changing anything in `AUDIT` — including views — is a human operation in
Snowsight. `AUDIT.V_CHAIN_VERIFICATION` lives there, and an agent able to
redefine it could make tampering report `INTACT`.

**Never read PII from an evidence pack payload.** `AUDIT.EVIDENCE_PACK.payload`
deliberately contains no name or PAN. Masking policies govern base columns and
cannot reach inside a materialised VARIANT. Identity comes from
`AUDIT.V_EVIDENCE_PACK_RENDER`, which joins `CORE.CUSTOMERS` so the policy
engages at query time.

**EVAL is the answer key.** `EVAL.GROUND_TRUTH`, `EVAL.CALIBRATION_SET` and
`EVAL.INVISIBLE_POPULATION` hold labels. Never join them into anything that
produces a model prompt, a feature, or an evidence pack. An accuracy figure the
scoring path could have read is not a figure.

**Rolling features exclude the current row.** Everything in
`CORE.V_POINT_IN_TIME_FEATURES` uses
`ROWS BETWEEN 26 PRECEDING AND 1 PRECEDING`. Letting the current week into its
own history is how a replay flatters itself.

# Snowflake dialect traps

**No named `WINDOW` clause.** Snowflake does not support `WINDOW w AS (...)`.
Write every `OVER (...)` inline, however repetitive.

**`QUALIFY` needs a window function.** A plain predicate belongs in `WHERE`.

**`POLICY.POLICY_AS_OF()` cannot be called per-row against a column.** It wraps
a scalar subquery; Snowflake raises *"Unsupported subquery type cannot be
evaluated inside Function object"*. For set-based work, join the validity
interval directly:

```sql
JOIN POLICY.POLICY_VERSIONS pv
  ON pv.policy_code = 'TM-STRUCT'
 AND pv.effective_from <= <date>
 AND (pv.effective_to IS NULL OR pv.effective_to > <date>)
```

The UDF remains correct with a literal date.

**`MATCH_BY_COLUMN_NAME` requires `PARSE_HEADER = TRUE`**, which is mutually
exclusive with `SKIP_HEADER`. Use `TRACE_DB.PUBLIC.CSV_WITH_HEADER`.

**Cursor fields need bindings.** In Snowflake Scripting, `r.seq` will not
resolve inside embedded SQL. Assign to a local variable and bind with `:`.

**`PUT` works natively through CoCo's `sql_execute`,** with paths relative to
the repo root. Do not reach for `snow` or SnowSQL — neither is installed, and
the Python connector cannot complete a TLS handshake on networks that inspect
traffic.

**`AI_COMPLETE` with a JSON-schema `response_format` does not work on
`llama3.1-8b`** — it returns NULL. Only `claude-sonnet-4-5` is used for
adjudication. `AI_CLASSIFY` works on small models but returns a shape that must
be inspected, not assumed.

# Cost discipline

AI credits are **94% of this project's spend**; warehouse compute is 6%. The
resource monitor covers warehouse credits only and will never fire.

A full adjudication is **2,759 Cortex calls, roughly $20–25**. Do not run one to
test a prompt change. Iterate on the 150-row holdout in
`EVAL.CALIBRATION_SET WHERE split = 'HOLDOUT'` — about $1 — and only run the
population when a result depends on it.

Always state the expected call count and cost before running anything that
invokes `AI_COMPLETE` over more than a few hundred rows.

# Testing isolation

`USE ROLE` alone proves nothing. Sessions carry secondary roles defaulting to
`ALL`, so `ACCOUNTADMIN` stays active behind whatever role you select. Always:

```sql
USE ROLE TRACE_INVESTIGATOR;
USE SECONDARY ROLES NONE;
```

And when testing that a write is refused, write a **valid** value. An earlier
test set `payload = NULL` and failed on a `NOT NULL` constraint, which looked
like an access-control success and was not one.
