---
name: verify-chain
description: Verify the integrity of the evidence-pack hash chain and report a verdict an examiner would accept. Use when asked whether the audit trail is intact, or after any change to AUDIT.
---

# When to use

- "Is the audit trail intact?" / "has anything been tampered with?"
- After rebuilding evidence packs or the chain
- Before presenting evidence to anyone

# How the chain works

Each pack's payload hashes to `content_hash`. Each chain link hashes
`prev_chain_hash || content_hash`. Editing, removing or reordering any pack
breaks every link after it.

The chain lives in `AUDIT.EVIDENCE_CHAIN`, separate from `AUDIT.EVIDENCE_PACK`,
so that building it never mutates a pack.

# Run this

```sql
SELECT
    (SELECT COUNT(*) FROM TRACE_DB.AUDIT.EVIDENCE_PACK)  AS packs,
    (SELECT COUNT(*) FROM TRACE_DB.AUDIT.EVIDENCE_CHAIN) AS links,
    COALESCE(SUM(CASE WHEN content_intact THEN 0 ELSE 1 END), 0) AS payload_tampered,
    COALESCE(SUM(CASE WHEN link_intact    THEN 0 ELSE 1 END), 0) AS chain_broken,
    COALESCE(SUM(CASE WHEN hash_intact    THEN 0 ELSE 1 END), 0) AS hash_mismatched,
    COALESCE(SUM(CASE WHEN pack_present   THEN 0 ELSE 1 END), 0) AS orphan_links
FROM TRACE_DB.AUDIT.V_CHAIN_VERIFICATION;
```

Then the head, which is the single value someone can record and re-check later:

```sql
SELECT chain_hash AS head_of_chain
FROM TRACE_DB.AUDIT.EVIDENCE_CHAIN ORDER BY link_no DESC LIMIT 1;
```

# Reading the result

All four counters zero **and** `packs = links` **and** `links > 0` → `INTACT`.

Report anything else precisely; do not summarise a partial failure as "mostly
fine".

- `payload_tampered > 0` — a pack's contents changed after it was written
- `chain_broken > 0` — a link does not point at its predecessor: something was
  removed or reordered
- `hash_mismatched > 0` — a link's own hash is not correctly derived
- `orphan_links > 0` — a pack exists that the chain does not cover

`packs <> links` is **incomplete**, not intact. A chain that silently omits
packs passes a naive check; that is the tamper worth catching.

Zero packs is `EMPTY — NOTHING TO VERIFY`, never `INTACT`. Reporting an empty
table as verified is false assurance, which is the one failure an integrity
check must not have.

# If it reports TAMPERED

Do not attempt to repair anything. `AUDIT` is append-only and you do not hold
the privileges. Report which counter failed and which `link_no` values, and
stop. Rebuilding the chain over altered packs would produce a consistent chain
over corrupted evidence, which is worse than a detected break.
