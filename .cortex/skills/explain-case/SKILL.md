---
name: explain-case
description: Retrieve and explain a single escalated case from its evidence pack — why it was flagged, what rule applied then and now, and what the evidence showed. Use when asked about a specific customer, case_ref or escalation.
---

# When to use

- "Why was CU-100120 escalated?"
- "Show me the case for <case_ref>"
- "What did the model see for this customer?"

# Where to read from

**Always `AUDIT.V_EVIDENCE_PACK_RENDER`, never the raw payload.** The render
view joins `CORE.CUSTOMERS`, so masking policies apply at query time and the
answer respects the caller's role. Reading `AUDIT.EVIDENCE_PACK.payload`
directly bypasses that — and the payload deliberately holds no identity anyway.

```sql
SELECT * FROM TRACE_DB.AUDIT.V_EVIDENCE_PACK_RENDER
WHERE case_ref = '<CUSTOMER_ID>|<YYYY-MM-DD>';
```

By customer, when the week is unknown:

```sql
SELECT case_ref, week_start, aggregate_cash, p_suspicious
FROM TRACE_DB.AUDIT.V_EVIDENCE_PACK_RENDER
WHERE customer_id = '<id>' ORDER BY p_suspicious DESC;
```

# How to explain it

Answer in this order. It mirrors what an examiner asks.

1. **Why there is no file.** Quote `why_no_alert` verbatim — it states the
   amount, the threshold then in force, and the shortfall. This is the whole
   reason the case exists.
2. **The rule then and now.** `rule_then` / `threshold_then` with `citation`,
   against `rule_now` / `threshold_now`.
3. **Both sides of the finding.** Give `aggravating` **and** `mitigating`. The
   model is required to argue both; presenting only the incriminating half
   misrepresents the adjudication.
4. **The evidence**, from `evidence` — proportionality to declared income,
   deposit pattern, movement of funds, occupation.
5. **The hashes**, so the reader can verify rather than trust.

# Language discipline

`p_suspicious` is a **model-assigned probability**, not a finding of fact. Say
"scored 0.78" or "ranked in the escalation band", never "is money laundering"
or "was found to be suspicious".

The alert/no-alert determination is deterministic SQL and can be stated flatly.
The adjudication cannot.

If a field is absent from `evidence`, say it was **not measurable**, not that it
was zero. A sudden-onset account has no prior-window outflow ratio; reporting
that as "0% transferred out" once led the model to cite it as exculpatory.

# Do not

- Join `EVAL.*` to check whether the case was "really" suspicious. That is the
  answer key; consulting it to answer a case question is contamination.
- Offer to amend or close the case. `AUDIT` is append-only.
