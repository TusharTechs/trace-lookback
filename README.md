# TRACE

**Regulatory lookback engine for AML.** When a transaction-monitoring threshold
turns out to have been wrong, the activity it missed raised no alert — so there
is no file to re-read and nothing to sample. TRACE replays every transaction
against the corrected rule and adjudicates what sampling cannot reach.

Built on Snowflake Cortex and CoCo CLI.
*Snowflake CoCo CLI Hackathon 2026 — GCC Edition · Challenge 1: Risk, Fraud and
Regulatory Intelligence Copilot.*

---

## The gap

A bank raises its structuring threshold from ₹8,00,000 to ₹10,00,000 as an
alert-efficiency measure. Thirteen months later a supervisor observes that the
calibration was wrong and it is reverted.

Everything that happened in the ₹8L–₹10L band during those thirteen months
**generated no alert, no disposition and no case file.**

This matters because of how threshold validation actually works. Above-the-line
/ below-the-line testing — the industry workhorse, expected under FFIEC-style
model-validation guidance and staffed heavily out of Indian GCCs — proceeds by
**sampling a few hundred below-the-line alerts** and extrapolating. It is only
as good as the dispositions it samples.

When the gap produced no alerts at all, there is nothing in the sample frame.
The method cannot see the problem it exists to find.

In this corpus that blind spot is **2,759 customer-weeks and ₹247.0 crore**.

---

## What it does

Deterministic SQL scans all 607,307 transactions and reconstructs, for every
customer-week, the evidence a reviewer *would* have seen. Cortex then
adjudicates each one — inside Snowflake, next to the data.

**2,759 weeks adjudicated. Zero parse failures.**

| | |
|---|---|
| Genuinely suspicious in that population | 1,331 |
| **Recovered at the review threshold** | **1,139 — recall 0.856** |
| Precision | 0.596 |
| Cost of the full lookback | ~**$15** |

The output is a ranked triage, not a verdict:

| band | weeks | notional | actually suspicious | hit rate |
|---|---|---|---|---|
| **ESCALATE** ≥ 0.60 | 671 | ₹60.0 Cr | 537 | **80.0%** |
| REVIEW 0.45–0.60 | 1,243 | ₹111.3 Cr | 603 | 48.5% |
| DEPRIORITISE < 0.45 | 845 | ₹75.6 Cr | 191 | 22.6% |

Read as workload against yield: **examine 24% of the population, recover 40% of
the laundering.** Examine 69%, recover 86%.

The lowest band is *deprioritise*, never *clear*. It still contains 191
genuinely suspicious weeks.

---

## How it works

**Bitemporal by construction.** Two time axes are kept strictly separate:
*event time* (when something happened) and *knowledge time* (when we learned it
or acted). Policy versions carry their own validity interval and are immutable —
a changed threshold inserts a new row, never updates the old one, because
updating in place relabels history. `POLICY.POLICY_AS_OF()` resolves the version
in force on any date, and every replay goes through it.

Time Travel is deliberately **not** used: retention caps at 90 days, and a
lookback spans years.

**Evidence is frozen, never recomputed.** `CORE.DECISION_FEATURES` stores what
was visible at decision time, hashed. Reconstructing it later would silently
import knowledge the reviewer did not have — late-arriving data, corrections, a
KYC update filed afterwards — which is precisely the flaw an examiner probes.

**The replay engine** (`CORE.V_POINT_IN_TIME_FEATURES`) computes the same
feature set from the raw transaction record for *any* customer-week, whether or
not an alert fired. Every rolling feature uses the 26 weeks **strictly before**
the week in question; letting the current week into its own history is how a
replay flatters itself. It is validated against the generator at correlation
**1.000** on the features that must match exactly.

**Adjudication is scored, not classified.** The model returns a probability,
never a verdict. Operating thresholds (0.45 review, 0.60 escalate) are chosen
from a sweep and applied afterwards — so they can be re-chosen without
re-running a single model call. `temperature = 0` throughout: a regulatory
replay that returns different answers on re-run is not defensible.

---

## Why this has to live in Snowflake

Exhaustive replay means reconstructing evidence across the full transaction
record and adjudicating every candidate. Shipping 607,307 transactions and
thousands of narrative adjudications to an external model API is a
data-residency problem, a compliance problem, and an economic one.

Cortex runs the model **next to the data**, under the account's existing RBAC
and masking policies. Nothing leaves. The compute model is not an
implementation detail here — it is what makes the method possible.

**CoCo CLI** executes the entire SQL layer against the account, under a
server-side **Restricted Session Scope** (`--with-restricted-session-scope`) —
a privilege ceiling that applies while an agent is active and cannot grant more
than the user already holds. Worth noting its documented boundary: RSS covers
the agent's SQL tool, **not** Bash, Python or MCP tools that open their own
connection. Knowing where a control stops is part of using it honestly.

---

## What is built, and what is not

**Built and measured:**

- Bitemporal schema — immutable policy versions, frozen decision features, hash-chained audit table, `EVAL` schema isolated so no agent role can read the answer key
- Synthetic corpus generator with a documented reviewer noise model and behavioural mimicry
- Point-in-time replay engine in SQL, validated against the generator
- Cortex adjudication over the full invisible population, with a calibrated operating point
- Column masking policies (Enterprise), Restricted Session Scope

**Not built yet** — named plainly rather than implied:

- Evidence-pack generation (case narrative + policy citation + hash chain)
- Streamlit interface
- Cortex Agent / Cortex Search over a policy corpus, and the LLM→predicate compiler with human certification
- `PreToolUse` hook enforcing append-only writes to the audit log
- CI regression gate via `cortex exec` (headless tool allowlisting is unresolved)

---

## Layout

```
sql/01_foundation.sql        bitemporal schema
sql/02_eval_tables.sql       ground-truth tables, isolated from the agent role
sql/11_reload_and_score_v5   stage + load the corpus
sql/12_replay_engine.sql     point-in-time features, with a validation gate
sql/13_adjudicate.sql        recalibration, then full adjudication
sql/03–10                    superseded; retained as history
generator/generate.py        synthetic corpus (seeded, deterministic)
generator/load.py            optional Python loader
eval/                        raw outputs of every run
EVALUATION.md                what was measured, and what it does not show
```

Scripts `03`–`10` are kept on purpose. They record two corpus designs that
failed and a measurement error that inflated an early result. The history is
part of the argument.

---

## Reproduce

```bash
uv run --with numpy --with pandas generator/generate.py --scale slice
```

Then, from the repo root, run `sql/01`, `02`, `11`, `12`, `13` in order —
through CoCo CLI, Snowsight, or any Snowflake client. `PUT` paths are relative
to the repo root.

Requires Snowflake **Enterprise** (masking and row-access policies) in a region
with Cortex model availability. Developed on `AWS_US_WEST_2`.

---

## Honest limitations

[`EVALUATION.md`](EVALUATION.md) is the full account. In short:

- **AUC is 0.604** against an oracle ceiling of 0.868. Real signal in the record
  is not being extracted.
- **The model does not beat human reviewers head-to-head.** On alerts that *did*
  fire, it trades precision for recall and wins on neither at a single
  threshold. Its value is reaching a population no analyst reviewed at all —
  there, the baseline is not a human, it is zero.
- **Clean skins are not detected, by design.** ~20% of mules behave exactly like
  legitimate businesses; they are irreducible, and the model correctly scores
  them as ambiguous rather than resolving them.
- **The corpus is enriched** — 31.7% of alerts are truly suspicious versus ~2% in
  production. Absolute rates are inflated; the ranking metrics are not.
- **Data is fully synthetic.** "Accuracy vs truth" is only computable because
  ground truth is generated. In production only agreement with human
  dispositions would be available.

---

*Synthetic data only. No real customer, transaction or institutional data is
used anywhere in this repository.*
