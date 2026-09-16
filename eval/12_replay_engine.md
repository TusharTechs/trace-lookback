# 12_replay_engine.sql — Results

## Feature Agreement (Correlation)

| N_MATCHED | AMOUNT_EXACT_MATCH | CORR_CASH_RATIO | CORR_ACTIVE_PCT | CORR_VOLATILITY | CORR_JUST_UNDER | CORR_OUTFLOW | CORR_BRANCHES | CORR_PRIOR_ALERTS |
|---|---|---|---|---|---|---|---|---|
| 4856 | 0.9998 | 1 | 1 | 0.999 | 1 | 0.912 | 0.992 | -0.014 |

## Median Absolute Difference

| MAD_CASH_RATIO | MAD_ACTIVE_PCT | MAD_VOLATILITY | MAD_JUST_UNDER | MAD_OUTFLOW | MAD_BRANCHES |
|---|---|---|---|---|---|
| 0 | 0 | 0.01 | 0 | 0.07 | 0.00 |

## Coverage

| INVISIBLE_WEEKS | WITH_FEATURES |
|---|---|
| 2759 | 2759 |

## Sample Invisible Population Features

| CUSTOMER_ID | WEEK_START | AGGREGATE_AMOUNT | TXN_COUNT | OCCUPATION | CASH_VS_MONTHLY_INCOME | WEEKS_WITH_CASH_ACTIVITY_PCT | WEEKLY_VOLATILITY | DEPOSITS_JUST_UNDER_ROUND_PCT | OUTWARD_TRANSFER_RATIO | DISTINCT_BRANCHES_USED | HISTORY_WEEKS_AVAILABLE |
|---|---|---|---|---|---|---|---|---|---|---|---|
| CU-100849 | 2026-04-13 | 999989.27 | 12 | Kirana Store Owner | 0.93 | 96.2 | 0.22 | 16.7 | 0.24 | 1 | 26 |
| CU-100427 | 2026-08-03 | 999821.97 | 6 | Petrol Pump Operator | 0.25 | 69.2 | 0.16 | 83.3 | 0.59 | 1 | 26 |
| CU-100944 | 2026-06-01 | 999618.49 | 6 | Consultant | 0.56 | 69.2 | 0.22 | 83.3 | 0.51 | 1 | 26 |
| CU-100992 | 2025-12-29 | 999434.21 | 9 | Restaurant Owner | 0.57 | 84.6 | 0.16 | 88.9 | 0.58 | 1 | 26 |
| CU-100306 | 2026-06-29 | 999239.14 | 8 | Jeweller | 0.81 | 80.8 | 0.17 | 12.5 | 0.31 | 1 | 26 |
