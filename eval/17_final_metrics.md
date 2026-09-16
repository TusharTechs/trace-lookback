# 15_final_metrics.sql — Results

## AUC on Invisible Population

| N | N_DIRTY | N_CLEAN | BASE_RATE | AUC_INVISIBLE_POPULATION |
|---|---|---|---|---|
| 2759 | 1331 | 1428 | 0.482 | 0.608 |

## Score Distribution by Class

| ACTUAL | N | MEAN_P | MEDIAN_P | MIN_P | MAX_P |
|---|---|---|---|---|---|
| CLEAN | 1428 | 0.482 | 0.48 | 0.18 | 0.78 |
| DIRTY | 1331 | 0.572 | 0.58 | 0.28 | 0.78 |

## Lift Curve (Risk Deciles)

| RISK_DECILE | WEEKS | DIRTY_FOUND | HIT_RATE | NOTIONAL_CR | CUMULATIVE_RECALL |
|---|---|---|---|---|---|
| 0 | 9 | 8 | 0.889 | 0.8 | 0.006 |
| 1 | 483 | 392 | 0.812 | 43.1 | 0.301 |
| 2 | 195 | 146 | 0.749 | 17.5 | 0.410 |
| 3 | 289 | 205 | 0.709 | 25.7 | 0.564 |
| 4 | 710 | 273 | 0.385 | 63.6 | 0.769 |
| 7 | 898 | 268 | 0.298 | 80.8 | 0.971 |
| 10 | 175 | 39 | 0.223 | 15.4 | 1.000 |

## Branch Concentration (Escalated)

| BRANCH_ID | BRANCH_NAME | CITY | ESCALATED_WEEKS | CUSTOMERS | NOTIONAL_CR |
|---|---|---|---|---|---|
| BR-206 | Karol Bagh | New Delhi | 203 | 27 | 18.1 |
| BR-114 | Surat Ring Road | Surat | 139 | 21 | 12.4 |
| BR-101 | Andheri East | Mumbai | 90 | 9 | 8.2 |
| BR-102 | Bandra Kurla | Mumbai | 86 | 15 | 7.7 |
| BR-401 | Salt Lake | Kolkata | 52 | 12 | 4.6 |
| BR-205 | Connaught Place | New Delhi | 41 | 10 | 3.7 |
| BR-311 | Koramangala | Bengaluru | 38 | 7 | 3.4 |
| BR-312 | T Nagar | Chennai | 38 | 10 | 3.4 |

## Branch Concentration (Invisible Population)

| BRANCH_ID | BRANCH_NAME | INVISIBLE_WEEKS | PCT_OF_POPULATION |
|---|---|---|---|
| BR-206 | Karol Bagh | 621 | 22.5 |
| BR-114 | Surat Ring Road | 549 | 19.9 |
| BR-102 | Bandra Kurla | 343 | 12.4 |
| BR-401 | Salt Lake | 306 | 11.1 |
| BR-101 | Andheri East | 283 | 10.3 |
| BR-205 | Connaught Place | 248 | 9.0 |
| BR-311 | Koramangala | 242 | 8.8 |
| BR-312 | T Nagar | 167 | 6.1 |
