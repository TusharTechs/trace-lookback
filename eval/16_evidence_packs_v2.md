# 14_evidence_packs.sql — Results (v2)

## Packs Built Summary

| PACKS_BUILT | CUSTOMERS | MIN_P | MAX_P |
|---|---|---|---|
| 687 | 111 | 0.62 | 0.78 |

## CALL CHAIN_EVIDENCE_PACKS

```
chained 687 packs, head=a0d16fadeae3ba73350d22606eacf3b7b8efdf3b01a4fbf1b2e401496a916e3e
```

## Chain Verification

| PACKS | PAYLOAD_TAMPERED | CHAIN_BROKEN | HASH_MISMATCHED | VERDICT |
|---|---|---|---|---|
| 687 | 0 | 0 | 0 | INTACT |

## Rendered Pack (top 1)

| SEQ | CASE_REF | P | CUSTOMER_NAME | PAN | WHY_MISSED | RULE_THEN | CITATION_THEN | RULE_NOW | AGGRAVATING | MITIGATING | CHAIN_HASH |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 187 | CU-100120\|2026-01-19 | 0.78 | Customer 100120 | RSGNG1775I | Aggregate cash of INR      941,871 fell below the threshold of INR    1,000,000 in force under PV-TM-STRUCT-002, so no alert was generated and no disposition exists. Under PV-TM-STRUCT-003 (threshold INR      800,000) the same activity would alert. | PV-TM-STRUCT-002 | Para 4.2.1 | PV-TM-STRUCT-003 | The cash volume is 20.89 times declared monthly income for a Government Employee—an occupation with fixed, traceable salary payments that generate zero legitimate cash receipts—yet INR 941,871 in cash appeared across 7 deposits in a single week after 26 consecutive weeks of zero cash activity, with 85.7% of deposits sitting just below round numbers, creating a textbook burst pattern inconsistent with any plausible government employment scenario. | The customer carries a LOW internal risk rating and has maintained the account long enough to accumulate 740 days since KYC refresh, suggesting an established relationship; it is possible they operate an undeclared side business (retail trade, small-scale vending, or family agricultural sales) that genuinely generated a seasonal or one-time cash windfall, and the round-number clustering may reflect customer preference for even amounts rather than deliberate structuring, though this would require the business to be entirely unregistered and the income grossly under-declared. | 3d16d5eaff0a05a2... |

## Full JSON Pack (top 1)

```json
{
  "case": {
    "aggregate_cash": 941870.56,
    "branch_id": "BR-205",
    "case_ref": "CU-100120|2026-01-19",
    "customer_id": "CU-100120",
    "customer_name": "Customer 100120",
    "deposit_count": 7,
    "pan": "RSGNG1775I",
    "window_end": "2026-01-25",
    "window_start": "2026-01-19"
  },
  "evidence_as_of_window_end": {
    "avg_deposit": 134553,
    "cash_vs_monthly_income": 20.89,
    "days_since_kyc": 740,
    "declared_annual_income": 541000,
    "deposits_just_under_round_pct": 85.7,
    "distinct_branches_used": 1,
    "history_weeks_available": 26,
    "is_pep": false,
    "occupation": "Government Employee",
    "occupation_is_cash_trade": false,
    "prior_alert_count": 2,
    "risk_rating": "LOW",
    "weekly_volatility": 1.5,
    "weeks_since_cash_began": 0,
    "weeks_with_cash_activity_pct": 0
  },
  "finding": {
    "band": "ESCALATE",
    "probability_suspicious": 0.78,
    "strongest_aggravating": "The cash volume is 20.89 times declared monthly income for a Government Employee—an occupation with fixed, traceable salary payments that generate zero legitimate cash receipts—yet INR 941,871 in cash appeared across 7 deposits in a single week after 26 consecutive weeks of zero cash activity, with 85.7% of deposits sitting just below round numbers, creating a textbook burst pattern inconsistent with any plausible government employment scenario.",
    "strongest_mitigating": "The customer carries a LOW internal risk rating and has maintained the account long enough to accumulate 740 days since KYC refresh, suggesting an established relationship; it is possible they operate an undeclared side business (retail trade, small-scale vending, or family agricultural sales) that genuinely generated a seasonal or one-time cash windfall, and the round-number clustering may reflect customer preference for even amounts rather than deliberate structuring, though this would require the business to be entirely unregistered and the income grossly under-declared."
  },
  "provenance": {
    "adjudicated_at": "2026-09-16 11:12:09.364",
    "adjudication_model": "claude-sonnet-4-5",
    "escalate_threshold": 0.6,
    "evidence_window_weeks": 26,
    "feature_source": "CORE.V_POINT_IN_TIME_FEATURES",
    "note": "Rolling features computed over the 26 weeks strictly preceding the window. Probabilities are model output; the alert/no-alert determination is deterministic SQL.",
    "review_threshold": 0.45
  },
  "rule_as_now": {
    "change_summary": "Threshold reverted to 8,00,000 following supervisory observation.",
    "citation": "Para 4.2.1",
    "effective_from": "2026-08-14",
    "policy_version_id": "PV-TM-STRUCT-003",
    "threshold_inr": 800000,
    "version_no": 3
  },
  "rule_as_was": {
    "change_summary": "Threshold raised to 10,00,000 to reduce false positive volume.",
    "citation": "Para 4.2.1",
    "effective_from": "2025-07-01",
    "effective_to": "2026-08-14",
    "policy_version_id": "PV-TM-STRUCT-002",
    "threshold_inr": 1000000,
    "version_no": 2
  },
  "why_no_alert_was_raised": {
    "aggregate_cash": 941870.56,
    "excess_over_now": 141870.56,
    "explanation": "Aggregate cash of INR      941,871 fell below the threshold of INR    1,000,000 in force under PV-TM-STRUCT-002, so no alert was generated and no disposition exists. Under PV-TM-STRUCT-003 (threshold INR      800,000) the same activity would alert.",
    "shortfall_against_then": 58129.44,
    "threshold_now": 800000,
    "threshold_then": 1000000
  }
}
```

## Portfolio View

| ESCALATED_WEEKS | CUSTOMERS | NOTIONAL_CR | MEAN_P |
|---|---|---|---|
| 687 | 111 | 61.4 | 0.672 |
