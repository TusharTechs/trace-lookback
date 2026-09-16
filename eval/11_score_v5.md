# 11_reload_and_score_v5.sql — Results

## Human Baseline

| N | ACCURACY | RECALL | PRECISION |
|---|---|---|---|
| 4856 | 0.731 | 0.595 | 0.573 |

## History Weeks

| MIN_HISTORY_WEEKS | MAX_HISTORY_WEEKS |
|---|---|
| 13 | 26 |

## Parse Check

| TIER | N | UNPARSED |
|---|---|---|
| CHEAP | 150 | 150 |
| FRONTIER | 150 | 0 |

## AUC

| TIER | N_POS | N_NEG | AUC |
|---|---|---|---|
| FRONTIER | 61 | 89 | 0.699 |

## Score Distribution by Class

| TIER | ACTUAL | N | MEAN_P | MEDIAN_P |
|---|---|---|---|---|
| FRONTIER | CLEAN | 89 | 0.451 | 0.42 |
| FRONTIER | DIRTY | 61 | 0.568 | 0.55 |

## Threshold Sweep

| TIER | THR | ACCURACY | RECALL | PRECISION | PCT_FLAGGED |
|---|---|---|---|---|---|
| FRONTIER | 0.050000 | 0.407 | 1.000 | 0.407 | 1.000 |
| FRONTIER | 0.100000 | 0.407 | 1.000 | 0.407 | 1.000 |
| FRONTIER | 0.150000 | 0.407 | 1.000 | 0.407 | 1.000 |
| FRONTIER | 0.200000 | 0.407 | 1.000 | 0.407 | 1.000 |
| FRONTIER | 0.250000 | 0.407 | 1.000 | 0.407 | 1.000 |
| FRONTIER | 0.300000 | 0.427 | 1.000 | 0.415 | 0.980 |
| FRONTIER | 0.350000 | 0.433 | 1.000 | 0.418 | 0.973 |
| FRONTIER | 0.400000 | 0.513 | 0.967 | 0.454 | 0.867 |
| FRONTIER | 0.450000 | 0.707 | 0.885 | 0.593 | 0.607 |
| FRONTIER | 0.500000 | 0.700 | 0.770 | 0.603 | 0.520 |
| FRONTIER | 0.550000 | 0.727 | 0.508 | 0.738 | 0.280 |
| FRONTIER | 0.600000 | 0.727 | 0.377 | 0.885 | 0.173 |
| FRONTIER | 0.650000 | 0.700 | 0.295 | 0.900 | 0.133 |
| FRONTIER | 0.700000 | 0.640 | 0.115 | 1.000 | 0.047 |
| FRONTIER | 0.750000 | 0.593 | 0.000 | NULL | 0.000 |
| FRONTIER | 0.800000 | 0.593 | 0.000 | NULL | 0.000 |
| FRONTIER | 0.850000 | 0.593 | 0.000 | NULL | 0.000 |
| FRONTIER | 0.900000 | 0.593 | 0.000 | NULL | 0.000 |
| FRONTIER | 0.950000 | 0.593 | 0.000 | NULL | 0.000 |

## Cascade Viability (Cheap Band vs Frontier/Truth)

0 rows returned.

## Clean-Skin Ambiguity

| TIER | CASE_TYPE | N | MEAN_P |
|---|---|---|---|
| FRONTIER | CLEAN (looks clean) | 86 | 0.447 |
| FRONTIER | CLEAN (looks dirty) | 3 | 0.573 |
| FRONTIER | CLEAN_SKIN (dirty, looks clean) | 19 | 0.48 |
| FRONTIER | DIRTY (looks dirty) | 42 | 0.607 |
