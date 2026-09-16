# 08_reload_v2_corpus — Verification Results

## Row Counts

| ENTITY | N |
|---|---|
| alerts | 5967 |
| customers | 1200 |
| decision_features | 5967 |
| dispositions | 5967 |
| ground_truth | 5967 |
| invisible_pop | 2759 |
| policy_versions | 3 |
| transactions | 607307 |

## Human Baseline

| N | ACCURACY | RECALL | PRECISION | BASE_RATE |
|---|---|---|---|---|
| 5967 | 0.721 | 0.614 | 0.550 | 0.314 |

## Evidence Separation by Archetype

| ARCHETYPE | N | MEAN_EVIDENCE | MIN_EVIDENCE | MAX_EVIDENCE |
|---|---|---|---|---|
| CASH_BUSINESS | 4091 | 0.325 | 0.188 | 0.857 |
| LAYERING | 726 | 0.568 | 0.223 | 0.887 |
| MULE | 1150 | 0.574 | 0.219 | 0.905 |

## Invisible (Defect) Population

| INVISIBLE_CUSTOMER_WEEKS | TRULY_SUSPICIOUS | NOTIONAL_INR_CRORE |
|---|---|---|
| 2759 | 1331 | 247.0 |
