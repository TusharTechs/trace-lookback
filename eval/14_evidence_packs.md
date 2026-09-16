# 14_evidence_packs.sql — Results

## Packs Built Summary

| PACKS_BUILT | CUSTOMERS | MIN_P | MAX_P |
|---|---|---|---|
| 671 | 114 | 0.62 | 0.78 |

## CALL CHAIN_EVIDENCE_PACKS

```
chained 671 packs, head=d1a060e477aab8b2770c4150b46ccc397a15867cdb80c192b3955a14539c9f8d
```

## Chain Verification

| PACKS | PAYLOAD_TAMPERED | CHAIN_BROKEN | HASH_MISMATCHED | VERDICT |
|---|---|---|---|---|
| 671 | 0 | 0 | 0 | INTACT |

## Rendered Pack (top 1)

| SEQ | CASE_REF | P | CUSTOMER_NAME | PAN | WHY_MISSED | RULE_THEN | CITATION_THEN | RULE_NOW | AGGRAVATING | MITIGATING | CHAIN_HASH |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 1101 | CU-100120\|2026-01-19 | 0.78 | Customer 100120 | RSGNG1775I | Aggregate cash of INR      941,871 fell below the threshold of INR    1,000,000 in force under PV-TM-STRUCT-002, so no alert was generated and no disposition exists. Under PV-TM-STRUCT-003 (threshold INR      800,000) the same activity would alert. | PV-TM-STRUCT-002 | Para 4.2.1 | PV-TM-STRUCT-003 | The cash volume is 20.89 times declared monthly income for a Government Employee—an occupation with fixed, traceable salary payments that generate virtually no legitimate cash. The sudden burst of 941k in cash after 26 weeks of zero cash activity, combined with 85.7% of deposits sitting just below round numbers, is the textbook signature of structured placement attempting to avoid reporting thresholds. | The funds have not been moved out via electronic transfer (0% NEFT/RTGS/IMPS), which breaks the classic layering step of money laundering. Launderers typically need to move cash quickly into the financial system and then disperse it; retention of funds could indicate the customer is genuinely accumulating savings or preparing for a large planned expense, though this would be highly unusual given the occupation and income mismatch. | 5b48f8b72002089f... |

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
    "strongest_aggravating": "The cash volume is 20.89 times declared monthly income for a Government Employee—an occupation with fixed, traceable salary payments that generate virtually no legitimate cash. The sudden burst of 941k in cash after 26 weeks of zero cash activity, combined with 85.7% of deposits sitting just below round numbers, is the textbook signature of structured placement attempting to avoid reporting thresholds.",
    "strongest_mitigating": "The funds have not been moved out via electronic transfer (0% NEFT/RTGS/IMPS), which breaks the classic layering step of money laundering. Launderers typically need to move cash quickly into the financial system and then disperse it; retention of funds could indicate the customer is genuinely accumulating savings or preparing for a large planned expense, though this would be highly unusual given the occupation and income mismatch."
  },
  "provenance": {
    "adjudicated_at": "2026-09-16 09:34:50.091",
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
| 671 | 114 | 60 | 0.672 |
