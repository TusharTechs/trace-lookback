# 18_counterfactual_replay.sql results

## Errors

### Statement 4 — Demonstration (three-scenario UNION ALL)

```
SQL compilation error: error line 2 at position 11
Invalid argument types for function 'POLICY.REPLAY_SUMMARY': (NUMBER(7,0), DATE, DATE)
```

## Statement 1 — CREATE FUNCTION POLICY.REPLAY_AT_THRESHOLD

Function created successfully.

## Statement 2 — CREATE FUNCTION POLICY.REPLAY_SUMMARY

Function created successfully.

## Statement 3 — CREATE VIEW POLICY.V_THRESHOLD_SENSITIVITY

View created successfully.

## Statement 5 — SELECT * FROM POLICY.V_THRESHOLD_SENSITIVITY

| THRESHOLD | WOULD_CATCH | NEWLY_CAPTURED | NEWLY_CAPTURED_CR | CUSTOMERS_AFFECTED |
|-----------|-------------|----------------|-------------------|--------------------|
| 500000 | 8549 | 5150 | 400.6 | 258 |
| 550000 | 8152 | 4753 | 379.7 | 258 |
| 600000 | 7712 | 4313 | 354.4 | 258 |
| 650000 | 7304 | 3905 | 328.9 | 257 |
| 700000 | 6863 | 3464 | 299.1 | 251 |
| 750000 | 6467 | 3068 | 270.4 | 243 |
| 800000 | 6111 | 2712 | 242.8 | 227 |
| 850000 | 5386 | 1993 | 183.4 | 217 |
| 900000 | 4662 | 1283 | 121.3 | 209 |
| 950000 | 3943 | 573 | 55.6 | 183 |
| 1000000 | 3363 | 0 | 0.0 | 0 |
| 1050000 | 2984 | 0 | 0.0 | 0 |
| 1100000 | 2601 | 0 | 0.0 | 0 |
| 1150000 | 2239 | 0 | 0.0 | 0 |
| 1200000 | 1911 | 0 | 0.0 | 0 |

## Statement 6 — Yield per threshold vs eval truth

| THRESHOLD | NEWLY_CAPTURED | NEWLY_CAPTURED_CR | ADJUDICATED_WEEKS | TRULY_SUSPICIOUS | HIT_RATE | NOTE |
|-----------|----------------|-------------------|-------------------|------------------|----------|------|
| 500000 | 5150 | 400.6 | | | | not adjudicated - outside the evaluated band |
| 550000 | 4753 | 379.7 | | | | not adjudicated - outside the evaluated band |
| 600000 | 4313 | 354.4 | | | | not adjudicated - outside the evaluated band |
| 650000 | 3905 | 328.9 | | | | not adjudicated - outside the evaluated band |
| 700000 | 3464 | 299.1 | | | | not adjudicated - outside the evaluated band |
| 750000 | 3068 | 270.4 | | | | not adjudicated - outside the evaluated band |
| 800000 | 2712 | 242.8 | 2759 | 1331 | 0.482 | |
| 850000 | 1993 | 183.4 | 2027 | 951 | 0.469 | |
| 900000 | 1283 | 121.3 | 1305 | 595 | 0.456 | |
| 950000 | 573 | 55.6 | 581 | 230 | 0.396 | |
| 1000000 | 0 | 0.0 | 0 | 0 | 0.000 | |
| 1050000 | 0 | 0.0 | 0 | 0 | 0.000 | |
| 1100000 | 0 | 0.0 | 0 | 0 | 0.000 | |
| 1150000 | 0 | 0.0 | 0 | 0 | 0.000 | |
| 1200000 | 0 | 0.0 | 0 | 0 | 0.000 | |
