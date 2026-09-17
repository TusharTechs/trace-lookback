# 16_append_only_chain.sql — Results

## CALL BUILD_EVIDENCE_CHAIN

```
chained 687 packs, head=b607da8df540cb238d9212b40f2eb90b2a320b9962aa43de941b957954954c42
```

## Chain Verification

| PACKS | LINKS | PAYLOAD_TAMPERED | CHAIN_BROKEN | HASH_MISMATCHED | ORPHAN_LINKS | VERDICT |
|---|---|---|---|---|---|---|
| 687 | 687 | 0 | 0 | 0 | 0 | INTACT |

## First 3 Chain Links

| LINK_NO | PACK_SEQ | CASE_REF | PREV_HASH | CHAIN_HASH |
|---|---|---|---|---|
| 1 | 1 | CU-100631\|2026-01-12 | GENESIS... | 07734fd736f3... |
| 2 | 2 | CU-100631\|2026-01-19 | 07734fd736f3... | 2de1fef62582... |
| 3 | 3 | CU-100631\|2026-06-15 | 2de1fef62582... | ec5c96d7492c... |

## Head of Chain

| HEAD_OF_CHAIN |
|---|
| b607da8df540cb238d9212b40f2eb90b2a320b9962aa43de941b957954954c42 |
