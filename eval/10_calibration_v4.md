# 10_calibration_v4.sql — Results

## Diagnostic: v3 CHEAP Tier

| TIER | MODEL_NAME | ROWS_INSERTED | RAW_NULL | VERDICT_NULL |
|---|---|---|---|---|
| CHEAP | llama3.1-8b | 100 | 100 | 100 |
| FRONTIER | claude-sonnet-4-5 | 100 | 0 | 0 |

| TIER | RAW_TEXT |
|---|---|
| CHEAP | None |
| CHEAP | None |
| CHEAP | None |

## Rendered Prompt (first row)

```
You are an AML analyst at an Indian bank adjudicating a transaction monitoring alert.

TYPOLOGY
In structuring, deposits are kept below the reporting threshold, activity arrives in bursts, funds are moved out within days, and cash is disproportionate to declared income. In legitimate cash trade, deposits arrive steadily week after week, amounts vary naturally, funds are retained to pay suppliers, and turnover is consistent with a declared business. Both patterns produce large cash credits. Neither error is cheap: clearing laundering lets it continue, escalating ordinary business wastes investigator time.

CASH ACTIVITY IN THIS 7-DAY WINDOW
- Total cash credits: INR      823,978
- Deposits: 5 (average INR      164,796)
- Deposits sitting just below a round number: 100%
- Alert threshold then in force: INR      800,000

PROPORTIONALITY
- This week of cash equals 0.35 times declared MONTHLY income
- Declared annual income: INR   28,456,000
- Occupation: Government Employee (not normally a cash-intensive trade)

PATTERN OVER THE PRECEDING 6 MONTHS
- Weeks with any cash activity: 50%
- Week-to-week volatility of cash volume: 1.5 (0 = identical every week, above 1 = highly irregular)
- Weeks since cash activity first appeared: 2

MOVEMENT OF FUNDS
- Share of deposited cash transferred out within days: 51%
- Distinct branches used: 1

CUSTOMER CONTEXT
- Internal risk rating: LOW
- Politically exposed: false
- Days since KYC refresh: 500
- Prior alerts on this customer: 0

BASE RATE
Across alerts of this type at this bank, roughly 3 in 10 are ultimately confirmed as suspicious. Most large cash alerts are legitimate business. Calibrate to that.

Name the single strongest factor pointing to laundering and the single strongest innocent explanation. Then give probability_suspicious: your probability, between 0 and 1, that this activity is genuine money laundering. Use the full range. A well-calibrated 0.3 is more useful than a confident 0.9. Some accounts are deliberately operated to look like ordinary businesses and cannot be resolved from this evidence at all -- those should sit near the base rate, not at an extreme.
```

## Parse Check

| TIER | N | UNPARSED |
|---|---|---|
| CHEAP | 150 | 139 |
| FRONTIER | 150 | 0 |

## AUC

| TIER | N_POS | N_NEG | AUC |
|---|---|---|---|
| CHEAP | 2 | 9 | 0.167 |
| FRONTIER | 48 | 102 | 0.664 |

## Score Distribution by Class

| TIER | ACTUAL | N | MEAN_P | MEDIAN_P | MIN_P | MAX_P |
|---|---|---|---|---|---|---|
| CHEAP | CLEAN | 9 | 0.533 | 0.55 | 0.45 | 0.55 |
| CHEAP | DIRTY | 2 | 0.55 | 0.55 | 0.55 | 0.55 |
| FRONTIER | CLEAN | 102 | 0.474 | 0.42 | 0.25 | 0.75 |
| FRONTIER | DIRTY | 48 | 0.578 | 0.58 | 0.42 | 0.72 |

## Threshold Sweep

| TIER | THR | ACCURACY | RECALL | PRECISION | PCT_FLAGGED |
|---|---|---|---|---|---|
| CHEAP | 0.050000 | 0.182 | 1.000 | 0.182 | 1.000 |
| CHEAP | 0.100000 | 0.182 | 1.000 | 0.182 | 1.000 |
| CHEAP | 0.150000 | 0.182 | 1.000 | 0.182 | 1.000 |
| CHEAP | 0.200000 | 0.182 | 1.000 | 0.182 | 1.000 |
| CHEAP | 0.250000 | 0.182 | 1.000 | 0.182 | 1.000 |
| CHEAP | 0.300000 | 0.182 | 1.000 | 0.182 | 1.000 |
| CHEAP | 0.350000 | 0.182 | 1.000 | 0.182 | 1.000 |
| CHEAP | 0.400000 | 0.182 | 1.000 | 0.182 | 1.000 |
| CHEAP | 0.450000 | 0.182 | 1.000 | 0.182 | 1.000 |
| CHEAP | 0.500000 | 0.273 | 1.000 | 0.200 | 0.909 |
| CHEAP | 0.550000 | 0.364 | 1.000 | 0.222 | 0.818 |
| CHEAP | 0.600000 | 0.818 | 0.000 | NULL | 0.000 |
| CHEAP | 0.650000 | 0.818 | 0.000 | NULL | 0.000 |
| CHEAP | 0.700000 | 0.818 | 0.000 | NULL | 0.000 |
| CHEAP | 0.750000 | 0.818 | 0.000 | NULL | 0.000 |
| CHEAP | 0.800000 | 0.818 | 0.000 | NULL | 0.000 |
| CHEAP | 0.850000 | 0.818 | 0.000 | NULL | 0.000 |
| CHEAP | 0.900000 | 0.818 | 0.000 | NULL | 0.000 |
| CHEAP | 0.950000 | 0.818 | 0.000 | NULL | 0.000 |
| FRONTIER | 0.050000 | 0.320 | 1.000 | 0.320 | 1.000 |
| FRONTIER | 0.100000 | 0.320 | 1.000 | 0.320 | 1.000 |
| FRONTIER | 0.150000 | 0.320 | 1.000 | 0.320 | 1.000 |
| FRONTIER | 0.200000 | 0.320 | 1.000 | 0.320 | 1.000 |
| FRONTIER | 0.250000 | 0.320 | 1.000 | 0.320 | 1.000 |
| FRONTIER | 0.300000 | 0.353 | 1.000 | 0.331 | 0.967 |
| FRONTIER | 0.350000 | 0.360 | 1.000 | 0.333 | 0.960 |
| FRONTIER | 0.400000 | 0.440 | 1.000 | 0.364 | 0.880 |
| FRONTIER | 0.450000 | 0.647 | 0.854 | 0.471 | 0.580 |
| FRONTIER | 0.500000 | 0.693 | 0.833 | 0.513 | 0.520 |
| FRONTIER | 0.550000 | 0.693 | 0.563 | 0.519 | 0.347 |
| FRONTIER | 0.600000 | 0.713 | 0.438 | 0.568 | 0.247 |
| FRONTIER | 0.650000 | 0.700 | 0.313 | 0.556 | 0.180 |
| FRONTIER | 0.700000 | 0.693 | 0.125 | 0.600 | 0.067 |
| FRONTIER | 0.750000 | 0.673 | 0.000 | 0.000 | 0.007 |
| FRONTIER | 0.800000 | 0.680 | 0.000 | NULL | 0.000 |
| FRONTIER | 0.850000 | 0.680 | 0.000 | NULL | 0.000 |
| FRONTIER | 0.900000 | 0.680 | 0.000 | NULL | 0.000 |
| FRONTIER | 0.950000 | 0.680 | 0.000 | NULL | 0.000 |

## Clean-Skin Ambiguity

| TIER | CASE_TYPE | N | MEAN_P |
|---|---|---|---|
| CHEAP | CLEAN (looks clean) | 9 | 0.533 |
| CHEAP | CLEAN_SKIN (dirty, looks clean) | 2 | 0.55 |
| FRONTIER | CLEAN (looks clean) | 100 | 0.472 |
| FRONTIER | CLEAN (looks dirty) | 2 | 0.55 |
| FRONTIER | CLEAN_SKIN (dirty, looks clean) | 12 | 0.488 |
| FRONTIER | DIRTY (looks dirty) | 36 | 0.608 |

## Frontier Top 3 Highest p_suspicious

| ALERT_ID | P | AGGRAVATING | MITIGATING |
|---|---|---|---|
| ALT-0004190 | 0.75 | Cash activity first appeared only 1 week ago despite the account having a 576-day history, yet immediately generated 43 prior alerts and now shows 60% of funds transferred out within days—a classic red flag for a compromised or newly repurposed account being used for rapid layering. | The customer is a declared Scrap Dealer in a genuinely cash-intensive trade, cash activity has occurred every single week (100% consistency), the weekly volume (0.36× monthly income) is proportionate to declared turnover of INR 42 million annually, and only 8.3% of deposits sit suspiciously near round thresholds—all hallmarks of legitimate business rhythm. |
| ALT-0000473 | 0.72 | The cash volume is 49.63 times declared monthly income for a retired individual with zero cash activity in the preceding 6 months, then suddenly INR 1.2 million appears in a single week with 53% transferred out within days—a textbook structuring burst-and-exit pattern inconsistent with any legitimate retirement income source. | The customer may have received a large one-time cash inflow from a legitimate source not reflected in their declared income (property sale, family gift, insurance payout, or maturity of investment), and the 53% outward transfer could represent planned expenses like medical bills, family support, or reinvestment—explaining both the sudden appearance and the rapid movement of funds. |
| ALT-0002417 | 0.72 | Cash activity first appeared only 1 week ago despite the account being mature (KYC 1568 days old), yet immediately triggered an alert with 6 deposits totaling INR 852,481—this sudden onset of high-volume cash in an established account is the hallmark of a compromised or repurposed account being used for short-term layering. | The customer is a jeweller—one of the most cash-intensive legitimate trades in India—and the weekly cash volume (0.56× monthly declared income) is entirely proportionate to the stated INR 18.2M annual turnover; jewellery businesses routinely handle large, lumpy cash receipts from customer sales and this pattern fits normal commercial activity for the sector. |

## Frontier Top 3 Lowest p_suspicious

| ALERT_ID | P | AGGRAVATING | MITIGATING |
|---|---|---|---|
| ALT-0000426 | 0.25 | The cash activity in this single week (INR 1,275,216) equals 91% of the customer's declared monthly income, creating a significant proportionality mismatch. Even for a cash-intensive petrol pump business, receiving nearly an entire month's revenue in one week suggests either underdeclared income or funds from an external source. | The customer shows a highly consistent 6-month pattern with cash activity in 96.2% of weeks, low week-to-week volatility (0.17), and 26 weeks of established history. Critically, only 5% of deposited cash is transferred out within days—the funds are retained in the account, which is the hallmark of legitimate working capital for a business that must pay suppliers and operating expenses. The occupation (Petrol Pump Operator) fully explains large, regular cash deposits. |
| ALT-0002645 | 0.28 | KYC is severely outdated at 795 days (more than 2 years), combined with 16 prior alerts on this customer, suggesting a pattern of repeated flagging without adequate remediation or updated due diligence | Cash activity shows strong legitimacy markers for a scrap dealer: 85% of weeks have activity over 6 months (consistent regular business), low volatility of 0.17 (stable pattern), funds are largely retained (only 31% moved out quickly), and this week's cash is proportionate at just 0.4x monthly declared income for a cash-intensive trade |
| ALT-0003708 | 0.28 | KYC is severely outdated at 1028 days (nearly 3 years), combined with 29 prior alerts on this customer, suggesting either persistent suspicious behavior or a pattern of activity that repeatedly triggers monitoring systems without proper account maintenance or resolution. | The cash activity shows strong legitimacy markers: 84.6% of weeks show cash deposits over 6 months (highly consistent presence), very low volatility of 0.16 (regular, predictable amounts), the pattern extends back 26 weeks (established behavior, not sudden), and the weekly cash volume of 0.49x monthly declared income is proportionate for a Transport Operator in India's cash-heavy economy where daily collections from freight/passenger services naturally generate substantial cash. |
