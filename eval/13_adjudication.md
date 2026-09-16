# 13_adjudicate.sql — Results

## Recalibration AUC (engine features, 150 holdout alerts)

| N | N_POS | N_NEG | AUC |
|---|---|---|---|
| 150 | 61 | 89 | 0.604 |

## Recalibration Threshold Sweep

| THR | ACCURACY | RECALL | PRECISION | PCT_FLAGGED |
|---|---|---|---|---|
| 0.050000 | 0.407 | 1.000 | 0.407 | 1.000 |
| 0.100000 | 0.407 | 1.000 | 0.407 | 1.000 |
| 0.150000 | 0.407 | 1.000 | 0.407 | 1.000 |
| 0.200000 | 0.407 | 1.000 | 0.407 | 1.000 |
| 0.250000 | 0.407 | 1.000 | 0.407 | 1.000 |
| 0.300000 | 0.420 | 1.000 | 0.412 | 0.987 |
| 0.350000 | 0.420 | 1.000 | 0.412 | 0.987 |
| 0.400000 | 0.447 | 0.984 | 0.423 | 0.947 |
| 0.450000 | 0.613 | 0.820 | 0.515 | 0.647 |
| 0.500000 | 0.620 | 0.689 | 0.525 | 0.533 |
| 0.550000 | 0.707 | 0.475 | 0.707 | 0.273 |
| 0.600000 | 0.733 | 0.393 | 0.889 | 0.180 |
| 0.650000 | 0.727 | 0.344 | 0.955 | 0.147 |
| 0.700000 | 0.620 | 0.066 | 1.000 | 0.027 |
| 0.750000 | 0.600 | 0.016 | 1.000 | 0.007 |
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
| 2759 | 247.0 | 1914 | 171.3 | 218 |

## Accuracy vs Truth (invisible population, threshold 0.45)

| ACCURACY | RECALL | PRECISION | N | ACTUALLY_DIRTY |
|---|---|---|---|---|
| 0.650 | 0.856 | 0.596 | 2759 | 1331 |

## Three-Band Triage

| BAND | WEEKS | NOTIONAL_CR | ACTUALLY_DIRTY | DIRTY_RATE |
|---|---|---|---|---|
| 1 CLEAR (<0.45) | 845 | 75.6 | 191 | 0.226 |
| 2 REVIEW (0.45-0.60) | 1243 | 111.3 | 603 | 0.485 |
| 3 ESCALATE (>=0.60) | 671 | 60.0 | 537 | 0.800 |

## Top 5 Strongest Cases Never Examined

| CUSTOMER_ID | WEEK_START | AGGREGATE_AMOUNT | P | AGGRAVATING |
|---|---|---|---|---|
| CU-100484 | 2025-08-25 | 955515.11 | 0.78 | The cash volume is 20× monthly declared income for a Government Employee (not a cash business), yet 100% is immediately transferred out via electronic channels, the activity appeared suddenly just 1 week ago with no prior history (only 3.8% of preceding weeks show any cash), and 85.7% of deposits sit just below round numbers—a classic structuring signature combined with rapid layering that is inconsistent with any legitimate government salary or side business. |
| CU-101011 | 2026-06-22 | 942181.23 | 0.78 | The cash volume is 82 times declared monthly income for a Government Employee—an occupation with fixed, traceable salary payments that generate virtually no legitimate cash. The sudden burst of INR 942,181 in cash after 26 weeks of zero cash activity, combined with 87.5% of deposits sitting just below round numbers, is the textbook signature of structured placement designed to avoid reporting thresholds. |
| CU-100120 | 2026-01-19 | 941870.56 | 0.78 | The cash volume is 20.89 times declared monthly income for a Government Employee—an occupation with fixed, traceable salary payments that generate virtually no legitimate cash. The sudden burst of 941k in cash after 26 weeks of zero cash activity, combined with 85.7% of deposits sitting just below round numbers, is the textbook signature of structured placement attempting to avoid reporting thresholds. |
| CU-100635 | 2026-07-13 | 908016.04 | 0.78 | The cash volume is 21.71 times declared monthly income for a retired individual with no legitimate cash-intensive business, yet 80% of deposits sit just below round numbers (classic structuring), activity appeared suddenly 1 week ago after 26 weeks of near-silence (3.8% weeks active), and nearly half the funds are immediately transferred out electronically—this is the textbook definition of a structuring mule account being activated for a single laundering cycle. |
| CU-101011 | 2025-09-22 | 860460.57 | 0.78 | The cash volume is 74.82 times declared monthly income for a Government Employee—an occupation with fixed, traceable salary payments that generate virtually no legitimate cash. All five deposits sit just below round numbers (classic threshold avoidance), the activity appeared only 5 weeks ago in sudden bursts (19.2% of weeks active, volatility 0.27), and nearly half the cash is immediately transferred out electronically, matching the structuring typology perfectly. |
