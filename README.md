# TRACE — public demo

Live demo of **TRACE**, a regulatory lookback and decision replay engine for AML
built on Snowflake Cortex and CoCo CLI.

▶ **[Open the demo](https://share.streamlit.io)** *(link updated after deployment)*

---

## Why this repository exists

The real application is **Streamlit in Snowflake**, running next to the data
inside a Snowflake account. That is the correct place for it — no customer data
leaves the account and every model call happens in Cortex — and it is also why
it cannot be linked publicly: opening it requires a login to that account.

This is a snapshot of that system, exported after the runs recorded in the main
repository, so that anyone can open a working link.

## What is real here

- **The data.** Every row was exported from the live Snowflake account. Nothing
  is typed in or illustrative.
- **The verification.** The chain pages recompute SHA-256 over the exact bytes
  Snowflake hashed and walk the chain independently, in Python, on a machine
  with no access to the database. They do not read a stored verdict. Verifying
  the evidence outside the system that produced it is the stronger check.
- **The tamper page.** Edit any evidence payload and watch the hash diverge and
  every downstream link fall over. Nothing persists; reload restores it.

## What is not

- **Writes.** Recording an investigator decision uses an append-only stored
  procedure that lives in Snowflake.
- **Live computation.** The replay engine recomputes over 607,307 transactions
  in SQL. Those results are exported here, not recomputed on demand.

## The corpus is synthetic

Generated with a fixed seed. Every customer, name, PAN and transaction is
fabricated, so publishing it carries no disclosure risk — and it is why ground
truth exists at all. The generator knows which customers were laundering; the
adjudicating model never sees that column.

---

## Running locally

```bash
pip install -r requirements.txt
streamlit run streamlit_app.py
```

Expects the exported CSVs in `data/`.

## Full source

Source, architecture, and the evaluation — including the measurement error we
made, the two security bypasses our own tests caught, and the hash chain that
correctly reported `TAMPERED` on its own data — are in the main repository.
