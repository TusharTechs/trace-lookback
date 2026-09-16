# 13_adjudicate.sql — Results (v2, with NULL outward_transfer_ratio fix)

## Recalibration AUC (engine features, 150 holdout alerts)

| N | N_POS | N_NEG | AUC |
|---|---|---|---|
| 150 | 61 | 89 | 0.541 |

## Recalibration Threshold Sweep

| THR | ACCURACY | RECALL | PRECISION | PCT_FLAGGED |
|---|---|---|---|---|
| 0.050000 | 0.407 | 1.000 | 0.407 | 1.000 |
| 0.100000 | 0.407 | 1.000 | 0.407 | 1.000 |
| 0.150000 | 0.407 | 1.000 | 0.407 | 1.000 |
| 0.200000 | 0.407 | 1.000 | 0.407 | 1.000 |
| 0.250000 | 0.407 | 1.000 | 0.407 | 1.000 |
| 0.300000 | 0.407 | 1.000 | 0.407 | 1.000 |
| 0.350000 | 0.407 | 1.000 | 0.407 | 1.000 |
| 0.400000 | 0.420 | 0.984 | 0.411 | 0.973 |
| 0.450000 | 0.593 | 0.721 | 0.500 | 0.587 |
| 0.500000 | 0.640 | 0.689 | 0.545 | 0.513 |
| 0.550000 | 0.713 | 0.475 | 0.725 | 0.267 |
| 0.600000 | 0.713 | 0.393 | 0.800 | 0.200 |
| 0.650000 | 0.667 | 0.262 | 0.762 | 0.140 |
| 0.700000 | 0.600 | 0.066 | 0.571 | 0.047 |
| 0.750000 | 0.593 | 0.000 | NULL | 0.000 |
| 0.800000 | 0.593 | 0.000 | NULL | 0.000 |
| 0.850000 | 0.593 | 0.000 | NULL | 0.000 |
| 0.900000 | 0.593 | 0.000 | NULL | 0.000 |
| 0.950000 | 0.593 | 0.000 | NULL | 0.000 |

## Adjudication Parse Check

| ADJUDICATED | UNPARSED |
|---|---|
| 2759 | 0 |

## Headline

| TOTAL_INVISIBLE_WEEKS | TOTAL_NOTIONAL_CR | FLAGGED_AT_0_45 | FLAGGED_NOTIONAL_CR | DISTINCT_CUSTOMERS_FLAGGED |
|---|---|---|---|---|
| 2759 | 247.0 | 1910 | 170.8 | 216 |

## Accuracy vs Truth (invisible population, threshold 0.45)

| ACCURACY | RECALL | PRECISION | N | ACTUALLY_DIRTY |
|---|---|---|---|---|
| 0.646 | 0.850 | 0.593 | 2759 | 1331 |

## Three-Band Triage

| BAND | WEEKS | NOTIONAL_CR | ACTUALLY_DIRTY | DIRTY_RATE |
|---|---|---|---|---|
| 1 CLEAR (<0.45) | 849 | 76.1 | 199 | 0.234 |
| 2 REVIEW (0.45-0.60) | 1223 | 109.4 | 586 | 0.479 |
| 3 ESCALATE (>=0.60) | 687 | 61.4 | 546 | 0.795 |

## Top 5 Strongest Cases Never Examined

| CUSTOMER_ID | WEEK_START | AGGREGATE_AMOUNT | P | AGGRAVATING |
|---|---|---|---|---|
| CU-101011 | 2025-08-18 | 956977.64 | 0.78 | The cash volume is 83 times declared monthly income for a Government Employee—an occupation with fixed, traceable salary payments that generate zero legitimate cash receipts. The sudden burst of INR 956,978 in cash after 26 weeks of complete dormancy, with 75% of deposits sitting just below round numbers, is the textbook signature of structuring: someone is using this salaried account as a conduit because it looks low-risk on paper. |
| CU-100484 | 2025-08-25 | 955515.11 | 0.78 | The cash volume is 20× monthly declared income for a Government Employee (not a cash business), yet 100% is immediately transferred out electronically, the activity appeared suddenly just 1 week ago with no prior cash history (active only 3.8% of preceding weeks), and 85.7% of deposits sit just below round-number thresholds—a textbook structuring signature with no business retention pattern. |
| CU-101011 | 2026-06-29 | 948357.37 | 0.78 | The cash volume is 82.47 times declared monthly income for a Government Employee—an occupation with fixed, traceable salary payments that generate virtually no legitimate cash. Combined with 88% immediate outward transfer and activity appearing in only 3.8% of weeks with extreme volatility (1.5), this matches classic structuring: sudden bursts of unexplained cash that are quickly layered out through electronic transfers. |
| CU-100120 | 2026-01-19 | 941870.56 | 0.78 | The cash volume is 20.89 times declared monthly income for a Government Employee—an occupation with fixed, traceable salary payments that generate zero legitimate cash receipts—yet INR 941,871 in cash appeared across 7 deposits in a single week after 26 consecutive weeks of zero cash activity, with 85.7% of deposits sitting just below round numbers, creating a textbook burst pattern inconsistent with any plausible government employment scenario. |
| CU-100150 | 2026-04-13 | 935379.93 | 0.78 | Government Employee occupation receiving cash equal to 50% of declared monthly income every week. This profile is fundamentally incompatible with legitimate activity—government salaries are paid electronically, and civil servants have no plausible source for INR 935k in weekly cash that would represent INR 3.7M+ monthly (double their declared annual income of INR 22.3M). The occupation-income mismatch is the clearest structuring red flag. |
