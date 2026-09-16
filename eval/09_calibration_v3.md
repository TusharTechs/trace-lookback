# 09_calibration_v3.sql — Results

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

Name the single strongest factor pointing to laundering and the single strongest innocent explanation, then give your verdict. Some accounts are deliberately operated to look like ordinary businesses and cannot be resolved from this evidence -- use LOW confidence for those rather than guessing.
```

## Tier Comparison

| TIER | N | KAPPA_VS_HUMAN | ACCURACY_VS_TRUTH | RECALL_VS_TRUTH | PRECISION_VS_TRUTH | PCT_CALLED_SUSPICIOUS |
|---|---|---|---|---|---|---|
| FRONTIER | 100 | 0.173 | 0.480 | 0.935 | 0.367 | 0.790 |

## HUMAN Baseline (same 100 alerts)

| TIER | N | ACCURACY_VS_TRUTH | RECALL_VS_TRUTH | PRECISION_VS_TRUTH |
|---|---|---|---|---|
| HUMAN | 100 | 0.770 | 0.677 | 0.618 |

## Confidence-Band Accuracy

| TIER | CONFIDENCE_BAND | N | ACCURACY_VS_TRUTH | MEAN_EVIDENCE |
|---|---|---|---|---|
| FRONTIER | HIGH | 19 | 0.632 | 0.578 |
| FRONTIER | MEDIUM | 81 | 0.444 | 0.362 |

## Clean-Skin Abstention

| TIER | CONFIDENCE_BAND | N | CLEAN_SKIN_CASES |
|---|---|---|---|
| FRONTIER | HIGH | 19 | 0 |
| FRONTIER | MEDIUM | 81 | 5 |

## Frontier LOW-Confidence Cases

0 rows returned.
