"""
TRACE — synthetic AML corpus generator (v2).

WHY v2 EXISTS
-------------
v1 produced a corpus with no learnable signal. CASH_BUSINESS, MULE and
LAYERING customers all drew declared income from the same distribution, so the
"cash versus declared income" ratio -- the feature intended to discriminate --
was identical for guilty and innocent. Handed that feature, llama3.1-8b called
100/100 alerts suspicious and claude-sonnet-4-5 called 78/100. Neither was
wrong to; the evidence genuinely did not separate.

Worse, the human noise model derived its labels from the archetype directly.
Reviewers effectively saw ground truth through fog while the model saw only
features. Any model/human comparison built on that was rigged.

v2 fixes both:

  1. CLASSES DIFFER BY BEHAVIOUR, NOT BY LABEL. A legitimate cash business
     declares income that tracks turnover, deposits daily in consistent
     amounts at one branch, and pays money out slowly. A mule declares modest
     income, deposits in bursts clustered just under round numbers across
     several branches, and moves the money out within days. Every one of those
     is observable in the transaction record.

  2. OCCUPATION IS INFORMATIVE, NOT DETERMINISTIC. In v1 every cash trade was
     innocent and every professional was a mule, which made occupation a
     perfect label proxy. Here 30% of mules are recruited among shopkeepers and
     15% of genuine cash businesses are professionals with a cash sideline.

  3. HUMANS JUDGE THE SAME EVIDENCE THE MODEL DOES. Reviewer decisions are
     driven by an evidence score computed from the observable features, then
     degraded by skill, caseload and genuine ambiguity. Ground truth remains
     the archetype, so both human and model are measured against the same
     truth while reading the same evidence.

The distributions deliberately overlap. A jeweller who under-declares heavily
looks like a mule, and an affluent mule looks like a business. That overlap is
the point -- it is where reviewers disagree, where confidence should be low,
and where a model earns its keep.

Usage:
    uv run --with numpy --with pandas generator/generate.py --scale slice
    uv run --with numpy --with pandas generator/generate.py --scale full
"""

from __future__ import annotations

import argparse
import hashlib
import json
from datetime import date, datetime, timedelta
from pathlib import Path

import numpy as np
import pandas as pd

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

SEED = 20260916
TODAY = date(2026, 9, 16)
OUT = Path(__file__).parent / "out"

SCALES = {
    "slice": {"customers": 1200, "start": date(2025, 1, 1)},
    "full":  {"customers": 5000, "start": date(2023, 7, 1)},
}

# v2 is the defect: threshold raised for 13 months, then reverted.
POLICY_TIMELINE = [
    {"policy_version_id": "PV-TM-STRUCT-001", "version_no": 1,
     "effective_from": date(2023, 1, 1), "effective_to": date(2025, 7, 1),
     "threshold": 800_000, "window_days": 7, "para_anchor": "Para 4.2.1",
     "change_summary": "Baseline structuring threshold, aggregate cash credit over rolling 7 days."},
    {"policy_version_id": "PV-TM-STRUCT-002", "version_no": 2,
     "effective_from": date(2025, 7, 1), "effective_to": date(2026, 8, 14),
     "threshold": 1_000_000, "window_days": 7, "para_anchor": "Para 4.2.1",
     "change_summary": "Threshold raised to 10,00,000 to reduce false positive volume."},
    {"policy_version_id": "PV-TM-STRUCT-003", "version_no": 3,
     "effective_from": date(2026, 8, 14), "effective_to": None,
     "threshold": 800_000, "window_days": 7, "para_anchor": "Para 4.2.1",
     "change_summary": "Threshold reverted to 8,00,000 following supervisory observation."},
]

ARCHETYPES = {"CLEAN": 0.780, "CASH_BUSINESS": 0.120, "MULE": 0.070, "LAYERING": 0.030}
TRULY_SUSPICIOUS = {"MULE", "LAYERING"}

CASH_OCCUPATIONS = ["Jeweller", "Petrol Pump Operator", "Kirana Store Owner",
                    "Restaurant Owner", "Scrap Dealer", "Transport Operator"]
PROF_OCCUPATIONS = ["Salaried - IT", "Salaried - Banking", "Teacher", "Doctor",
                    "Government Employee", "Consultant", "Retired"]

# P(occupation is a cash trade | archetype). Informative, never determinative:
# mules are recruited among shopkeepers too, and some professionals genuinely
# run cash businesses on the side.
P_CASH_OCCUPATION = {"CLEAN": 0.12, "CASH_BUSINESS": 0.72, "MULE": 0.42, "LAYERING": 0.52}

BRANCHES = [
    ("BR-101", "Andheri East",    "Mumbai",    "Maharashtra", "WEST"),
    ("BR-102", "Bandra Kurla",    "Mumbai",    "Maharashtra", "WEST"),
    ("BR-114", "Surat Ring Road", "Surat",     "Gujarat",     "WEST"),
    ("BR-205", "Connaught Place", "New Delhi", "Delhi",       "NORTH"),
    ("BR-206", "Karol Bagh",      "New Delhi", "Delhi",       "NORTH"),
    ("BR-311", "Koramangala",     "Bengaluru", "Karnataka",   "SOUTH"),
    ("BR-312", "T Nagar",         "Chennai",   "Tamil Nadu",  "SOUTH"),
    ("BR-401", "Salt Lake",       "Kolkata",   "West Bengal", "EAST"),
]

# Reviewer identifiers are opaque codes, as they would be in a real case
# management system -- an analyst is an employee ID on a disposition, not a name.
REVIEWERS = [
    # id, skill (noise scale, lower = noisier), threshold bias, experience months
    ("RV-01", 0.91, +0.04, 84),
    ("RV-02", 0.88, -0.02, 61),
    ("RV-03", 0.84, +0.09, 47),
    ("RV-04", 0.79, -0.06, 30),
    ("RV-05", 0.77, +0.02, 26),
    ("RV-06", 0.72, -0.11, 14),
    ("RV-07", 0.69, +0.13,  9),
    ("RV-08", 0.66, -0.08,  6),
]

# Reviewer judgement = evidence score + noise, thresholded. Noise scale is set
# by skill; the constants are exposed so the evaluation write-up can state
# exactly how human labels were perturbed.
REVIEWER_NOISE_BASE = 0.70      # sd of the logit-space perturbation at median skill
MEDIAN_SKILL = 0.80
FATIGUE_NOISE_GAIN = 0.55       # extra noise at maximum caseload
FATIGUE_SATURATION = 12         # alerts/reviewer/day at which fatigue saturates
DECISION_THRESHOLD = 0.50

ROUND_NUMBERS = [50_000, 100_000, 200_000, 500_000]

# Weeks of history required before an alert is eligible. Below this the
# rolling behavioural features have denominators too small to mean anything.
MIN_HISTORY_WEEKS = 13


def policy_in_force(d: date) -> dict:
    for p in POLICY_TIMELINE:
        if p["effective_from"] <= d and (p["effective_to"] is None or d < p["effective_to"]):
            return p
    raise ValueError(f"no policy version covers {d}")


def sha(*parts) -> str:
    return hashlib.sha256("|".join(str(p) for p in parts).encode()).hexdigest()


def week_starts(start: date, end: date):
    d = start - timedelta(days=start.weekday())
    while d < end:
        yield d
        d += timedelta(days=7)


def sigmoid(x: float) -> float:
    return 1.0 / (1.0 + np.exp(-x))


# ---------------------------------------------------------------------------
# Customers
# ---------------------------------------------------------------------------

def gen_customers(rng, n, start) -> pd.DataFrame:
    archetypes = rng.choice(list(ARCHETYPES), size=n, p=list(ARCHETYPES.values()))
    rows = []
    for i, arch in enumerate(archetypes):
        # BEHAVIOURAL MIMICRY -- the source of irreducible error.
        #
        # Roughly a fifth of mules are "clean skins": accounts recruited
        # precisely because they behave like a genuine cash business, with
        # declared income that tracks turnover, steady deposits and patient
        # outflows. A smaller share of genuine businesses look like mules.
        #
        # These cases cannot be classified correctly from the record by ANY
        # reader, model or human. That is a property of real AML, not a defect
        # in the corpus, and it is what stops the oracle ceiling sitting at
        # 100%. It is also where a well-calibrated system should abstain
        # rather than guess.
        if arch == "MULE" and rng.random() < 0.22:
            behaviour = "CASH_BUSINESS"
        elif arch == "LAYERING" and rng.random() < 0.20:
            behaviour = "CASH_BUSINESS"
        elif arch == "CASH_BUSINESS" and rng.random() < 0.12:
            behaviour = "MULE"
        else:
            behaviour = arch

        cash_occ = rng.random() < P_CASH_OCCUPATION[behaviour]
        occupation = str(rng.choice(CASH_OCCUPATIONS if cash_occ else PROF_OCCUPATIONS))

        home = BRANCHES[rng.integers(len(BRANCHES))]
        # Mules cluster in a few branches. Never stated anywhere -- the
        # investigation agent is meant to find this.
        if behaviour in ("MULE", "LAYERING") and rng.random() < 0.50:
            home = BRANCHES[int(rng.choice([2, 4]))]

        # Weekly cash scale, and how much of it the customer declares.
        if behaviour == "CASH_BUSINESS":
            weekly_cash_mu = float(rng.uniform(450_000, 1_300_000))
            # Legitimate businesses declare income that tracks turnover -- but
            # under-declaration is common, and heavy under-declarers are
            # genuinely hard to tell from mules. That overlap is deliberate.
            declare_frac = float(rng.beta(1.7, 1.9) * 0.82 + 0.08)   # ~0.08-0.90, heavy tail
            declared = weekly_cash_mu * 52 * declare_frac
        elif behaviour == "MULE":
            weekly_cash_mu = float(rng.uniform(500_000, 1_500_000))
            declared = float(rng.lognormal(13.35, 0.85))            # some mules hold real jobs
        elif behaviour == "LAYERING":
            weekly_cash_mu = float(rng.uniform(700_000, 2_000_000))
            declared = float(rng.lognormal(13.8, 0.60))              # affluent, plausible
        else:
            weekly_cash_mu = float(rng.uniform(20_000, 180_000))
            declared = float(rng.lognormal(13.0, 0.50))

        rows.append({
            "customer_id": f"CU-{100000 + i}",
            "full_name": f"Customer {100000 + i}",
            "pan": f"{''.join(rng.choice(list('ABCDEFGHIJKLMNOPQRSTUVWXYZ'), 5))}"
                   f"{rng.integers(1000, 9999)}{rng.choice(list('ABCDEFGHIJ'))}",
            "date_of_birth": date(1960, 1, 1) + timedelta(days=int(rng.integers(0, 15000))),
            "occupation": occupation,
            "declared_annual_income": float(round(declared, -3)),
            "risk_rating": ("HIGH" if behaviour == "LAYERING" and rng.random() < 0.5 else
                            "MEDIUM" if rng.random() < 0.45 else "LOW"),
            "is_pep": bool(rng.random() < 0.01),
            "kyc_completed_on": start - timedelta(days=int(
                rng.integers(30, 400) if behaviour in ("MULE", "LAYERING") else rng.integers(200, 1600))),
            "branch_id": home[0],
            "onboarded_on": start - timedelta(days=int(rng.integers(30, 1500))),
            "archetype": arch,
            "behaviour": behaviour,
            # behaviour parameters, dropped before load
            "weekly_cash_mu": weekly_cash_mu,
            "outflow_ratio": float(
                rng.beta(3.0, 3.6) if behaviour == "CASH_BUSINESS" else
                rng.beta(4.2, 3.0) if behaviour == "MULE" else
                rng.beta(3.8, 3.0) if behaviour == "LAYERING" else rng.beta(2, 5)),
            "n_branches": int(
                rng.integers(1, 4) if (behaviour == "CASH_BUSINESS" and rng.random() < 0.45)
                else 1 if (behaviour in ("MULE", "LAYERING") and rng.random() < 0.40)
                else rng.integers(2, 4) if behaviour in ("MULE", "LAYERING")
                else 1),
            "structuring_tendency": float(
                rng.beta(2.6, 3.0) if behaviour == "MULE" else
                rng.beta(2.0, 3.6) if behaviour == "LAYERING" else
                rng.beta(1.8, 4.0) if behaviour == "CASH_BUSINESS" else rng.beta(1, 8)),
        })
    return pd.DataFrame(rows)


def active_weeks_for(rng, arch, weeks):
    """Which weeks carry cash activity.

    Businesses trade continuously. Mules run campaigns -- bursts of a few
    weeks, then nothing -- which is what makes their weekly series irregular
    and their onset recent.
    """
    n = len(weeks)
    if arch == "CASH_BUSINESS":
        # Seasonal trades and part-time operators are far from continuous.
        return rng.random(n) < float(rng.uniform(0.55, 0.95))
    if arch == "CLEAN":
        return rng.random(n) < 0.12
    # A third of mules run continuously rather than in bursts -- patient
    # operations are exactly the ones that evade pattern detection.
    if rng.random() < 0.33:
        return rng.random(n) < float(rng.uniform(0.55, 0.85))
    active = np.zeros(n, dtype=bool)
    for _ in range(int(rng.integers(2, 6))):
        if n < 4:
            break
        start_i = int(rng.integers(0, max(n - 3, 1)))
        active[start_i:start_i + int(rng.integers(4, 12))] = True
    return active


# ---------------------------------------------------------------------------
# Transactions, alerts
# ---------------------------------------------------------------------------

def gen_transactions_and_alerts(rng, customers, start):
    txns, alerts, weekly_hist = [], [], {}
    tx_n = al_n = 0
    weeks = list(week_starts(start, TODAY))

    for cust in customers.itertuples():
        arch = cust.archetype          # truth, for labelling only
        beh = cust.behaviour           # what the record actually shows
        active = active_weeks_for(rng, beh, weeks)
        branch_pool = [cust.branch_id]
        while len(branch_pool) < cust.n_branches:
            b = BRANCHES[rng.integers(len(BRANCHES))][0]
            if b not in branch_pool:
                branch_pool.append(b)

        hist = []
        for wi, wk in enumerate(weeks):
            wk_end = wk + timedelta(days=6)
            if wk_end > TODAY:
                break

            cash_total, deposits = 0.0, []
            if active[wi]:
                if beh == "CASH_BUSINESS":
                    # Steady trade: many small deposits, low week-to-week variance.
                    cash_total = float(rng.normal(cust.weekly_cash_mu, cust.weekly_cash_mu * 0.18))
                    n_dep = int(rng.integers(5, 13))
                elif beh == "MULE":
                    pol = policy_in_force(wk_end)
                    # Sits under whatever threshold is live -- during PV-002 that
                    # means landing in the invisible [8L, 10L) band.
                    cash_total = float(rng.uniform(0.80, 0.98) * pol["threshold"]
                                       if rng.random() < 0.65
                                       else rng.uniform(1.0, 1.7) * pol["threshold"])
                    n_dep = int(rng.integers(3, 8))
                elif beh == "LAYERING":
                    cash_total = float(rng.normal(cust.weekly_cash_mu, cust.weekly_cash_mu * 0.35))
                    n_dep = int(rng.integers(4, 11))
                else:
                    cash_total = float(rng.uniform(0.3, 1.4) * cust.weekly_cash_mu)
                    n_dep = int(rng.integers(1, 4))
                cash_total = max(cash_total, 0.0)

                # Deposit sizing. Structuring shows as amounts parked just under
                # a round number; ordinary trade does not cluster that way.
                if n_dep and cash_total > 0:
                    if rng.random() < cust.structuring_tendency:
                        target = float(rng.choice(ROUND_NUMBERS))
                        amts, left = [], cash_total
                        while left > 1000 and len(amts) < n_dep:
                            a = min(left, target * float(rng.uniform(0.90, 0.995)))
                            amts.append(a)
                            left -= a
                        if left > 1000:
                            amts.append(left)
                    else:
                        amts = list(rng.dirichlet(np.ones(n_dep) * 3.0) * cash_total)
                    deposits = [a for a in amts if a > 500]

            hist.append(cash_total)

            for amt in deposits:
                off = int(rng.integers(0, 6))
                ts = datetime.combine(wk + timedelta(days=off), datetime.min.time()) + timedelta(
                    hours=int(rng.integers(10, 19)), minutes=int(rng.integers(0, 60)))
                tx_n += 1
                txns.append({
                    "txn_id": f"TX-{tx_n:09d}", "customer_id": cust.customer_id,
                    "txn_ts": ts, "value_date": ts.date(), "amount": round(float(amt), 2),
                    "direction": "CR", "mode": "CASH", "channel": "BRANCH",
                    "counterparty_name": None, "counterparty_bank": None,
                    "branch_id": str(rng.choice(branch_pool)),
                })

            # Outward movement. The tell is speed: mules push money out within
            # days, businesses pay suppliers gradually.
            if cash_total > 0:
                out_total = cash_total * cust.outflow_ratio
                for _ in range(int(rng.integers(1, 5))):
                    off = int(rng.integers(1, 7))
                    ts = datetime.combine(wk + timedelta(days=off), datetime.min.time()) + timedelta(
                        hours=int(rng.integers(9, 21)))
                    tx_n += 1
                    txns.append({
                        "txn_id": f"TX-{tx_n:09d}", "customer_id": cust.customer_id,
                        "txn_ts": ts, "value_date": ts.date(),
                        "amount": round(float(out_total / 3), 2),
                        "direction": "DR",
                        "mode": str(rng.choice(["NEFT", "RTGS", "IMPS"], p=[.5, .3, .2])),
                        "channel": "ONLINE",
                        "counterparty_name": f"CP-{rng.integers(1000, 9999)}",
                        "counterparty_bank": str(rng.choice(["HDFC", "ICICI", "SBI", "AXIS", "KOTAK"])),
                        "branch_id": cust.branch_id,
                    })

            # Routine living expenses, so accounts are not pure cash conduits.
            for _ in range(int(rng.integers(2, 7))):
                off = int(rng.integers(0, 7))
                ts = datetime.combine(wk + timedelta(days=off), datetime.min.time()) + timedelta(
                    hours=int(rng.integers(8, 22)))
                tx_n += 1
                txns.append({
                    "txn_id": f"TX-{tx_n:09d}", "customer_id": cust.customer_id,
                    "txn_ts": ts, "value_date": ts.date(),
                    "amount": round(float(rng.lognormal(8.9, 1.0)), 2),
                    "direction": "DR", "mode": "UPI", "channel": "MOBILE",
                    "counterparty_name": f"MERCH-{rng.integers(100, 999)}",
                    "counterparty_bank": "NPCI", "branch_id": cust.branch_id,
                })

            pol = policy_in_force(wk_end)
            # MIN_HISTORY_WEEKS warm-up: rolling features are not yet defined.
            if cash_total >= pol["threshold"] and wi >= MIN_HISTORY_WEEKS:
                al_n += 1
                alerts.append({
                    "alert_id": f"ALT-{al_n:07d}", "scenario_code": "TM-STRUCT-01",
                    "customer_id": cust.customer_id,
                    "generated_at": datetime.combine(wk_end, datetime.min.time()) + timedelta(hours=23),
                    "window_start": wk, "window_end": wk_end,
                    "aggregate_amount": round(cash_total, 2), "txn_count": len(deposits),
                    "policy_version_id": pol["policy_version_id"],
                    "branch_id": cust.branch_id,
                    "archetype": arch,
                    "threshold_applied": pol["threshold"],
                    "week_index": wi,
                    "deposits": deposits,
                    "branch_pool_size": len(branch_pool),
                })

        weekly_hist[cust.customer_id] = hist

    return pd.DataFrame(txns), pd.DataFrame(alerts), weekly_hist


# ---------------------------------------------------------------------------
# Observable evidence + evidence score
# ---------------------------------------------------------------------------

def build_features(alerts, customers, weekly_hist):
    """The frozen snapshot: only what is observable from the record at the time.

    Also computes evidence_score -- a weighted read of those same features.
    Reviewers judge from this score plus noise, so humans and models are
    reading the same evidence. Ground truth stays the archetype.
    """
    if alerts.empty:
        return pd.DataFrame(), pd.DataFrame()
    cust = customers.set_index("customer_id")
    feat_rows, ev_rows = [], []

    # BUG FIX: cumcount() was computed on a time-sorted copy and then indexed
    # positionally against the UNSORTED frame, so every alert received some
    # other alert's prior-count. Caught by the SQL replay engine, which
    # correlated -0.014 with this feature. Map by alert_id instead.
    _srt = alerts.sort_values("generated_at")
    prior_by_alert = dict(zip(_srt["alert_id"], _srt.groupby("customer_id").cumcount()))

    for i, a in enumerate(alerts.itertuples()):
        c = cust.loc[a.customer_id]
        hist = weekly_hist[a.customer_id][:a.week_index]
        recent = [h for h in hist[-26:]]
        active = [h for h in recent if h > 0]

        active_ratio = len(active) / max(len(recent), 1)
        regularity = (float(np.std(active) / np.mean(active)) if len(active) >= 3 else 1.5)
        monthly_income = max(c.declared_annual_income / 12, 1.0)
        cash_vs_income = a.aggregate_amount / monthly_income

        deps = a.deposits or []
        just_under = sum(
            1 for d in deps if any(0.90 * r <= d < r for r in ROUND_NUMBERS)
        ) / max(len(deps), 1)

        occ_cash = c.occupation in CASH_OCCUPATIONS
        weeks_since_onset = len(recent) - next(
            (j for j, h in enumerate(recent) if h > 0), len(recent))

        feats = {
            "aggregate_amount": float(a.aggregate_amount),
            "txn_count": int(a.txn_count),
            "avg_deposit": round(float(a.aggregate_amount / max(a.txn_count, 1)), 0),
            "window_start": str(a.window_start), "window_end": str(a.window_end),
            "threshold_applied": float(a.threshold_applied),
            "occupation": c.occupation,
            "occupation_is_cash_trade": bool(occ_cash),
            "declared_annual_income": float(c.declared_annual_income),
            "cash_vs_monthly_income": round(float(cash_vs_income), 2),
            "risk_rating": c.risk_rating, "is_pep": bool(c.is_pep),
            "days_since_kyc": int((a.generated_at.date() - c.kyc_completed_on).days),
            "prior_alert_count": int(prior_by_alert[a.alert_id]),
            "weeks_with_cash_activity_pct": round(float(active_ratio * 100), 1),
            "weekly_volatility": round(float(regularity), 2),
            "deposits_just_under_round_pct": round(float(just_under * 100), 1),
            "distinct_branches_used": int(a.branch_pool_size),
            "outward_transfer_ratio": round(float(c.outflow_ratio), 2),
            "weeks_since_cash_activity_began": int(weeks_since_onset),
            "history_weeks_available": int(len(recent)),
        }
        feat_rows.append({
            "alert_id": a.alert_id, "captured_at": a.generated_at,
            "features": json.dumps(feats, default=str),
            "feature_hash": sha(a.alert_id, json.dumps(feats, sort_keys=True, default=str)),
        })

        # Evidence score. Weights chosen so the classes separate substantially
        # but not cleanly -- the overlap is where reviewers disagree.
        z = (
            0.39 * np.log1p(min(cash_vs_income, 60)) - 0.92
            + 0.32 * (0.0 if occ_cash else 1.0)
            + 0.52 * (c.outflow_ratio - 0.45)
            + 0.20 * (a.branch_pool_size - 1)
            + 0.41 * just_under
            + 0.26 * regularity
            - 0.45 * active_ratio
            - 0.15 * min(weeks_since_onset / 12, 1.0)
            + 0.22 * (1 if c.risk_rating == "HIGH" else 0)
        )
        ev_rows.append({"alert_id": a.alert_id, "evidence_score": float(sigmoid(z))})

    return pd.DataFrame(feat_rows), pd.DataFrame(ev_rows)


def gen_dispositions(rng, alerts, evidence):
    """Reviewers judge the evidence score, not the archetype.

    Skill sets how much noise corrupts their read; caseload adds more; personal
    bias shifts the threshold. Ground truth is never consulted here.
    """
    if alerts.empty:
        return pd.DataFrame(), pd.DataFrame()

    a = alerts.sort_values("generated_at").reset_index(drop=True)
    ev = evidence.set_index("alert_id")["evidence_score"]
    assigned = rng.integers(0, len(REVIEWERS), size=len(a))
    day_key = pd.to_datetime(a["generated_at"]).dt.date.astype(str) + "|" + assigned.astype(str)
    load = pd.Series(day_key).groupby(day_key).cumcount() + 1

    disp, truth = [], []
    for i, r in enumerate(a.itertuples()):
        rv_id, skill, bias, exp_m = REVIEWERS[assigned[i]]
        score = float(ev.loc[r.alert_id])
        fatigue = float(min(load.iloc[i] / FATIGUE_SATURATION, 1.0))

        noise_sd = REVIEWER_NOISE_BASE * (MEDIAN_SKILL / skill) * (1 + FATIGUE_NOISE_GAIN * fatigue)
        logit = float(np.log(np.clip(score, 1e-6, 1 - 1e-6) / (1 - np.clip(score, 1e-6, 1 - 1e-6))))
        perceived = sigmoid(logit + float(rng.normal(0, noise_sd)))
        called = perceived > (DECISION_THRESHOLD - bias)

        is_susp = r.archetype in TRULY_SUSPICIOUS
        outcome = ("CLOSED_FP" if not called
                   else "STR_FILED" if perceived > 0.80 and rng.random() < 0.6
                   else "ESCALATED")

        disp.append({
            "disposition_id": f"DP-{i+1:07d}", "alert_id": r.alert_id, "reviewer_id": rv_id,
            "disposed_at": r.generated_at + timedelta(hours=int(rng.integers(6, 120))),
            "outcome": outcome,
            "rationale": _rationale(rng, outcome, r.aggregate_amount),
            "review_minutes": round(float(np.clip(
                rng.lognormal(2.5 if called else 2.0, 0.5) * (1 - 0.35 * fatigue), 2, 180)), 1),
            "reviewer_experience_months": exp_m,
            "was_qa_reviewed": bool(rng.random() < 0.08),
        })
        truth.append({
            "alert_id": r.alert_id, "is_truly_suspicious": is_susp, "archetype": r.archetype,
            "evidence_score": round(score, 4),
            "reviewer_noise_sd": round(noise_sd, 3),
            "reviewer_fatigue": round(fatigue, 3),
        })

    return pd.DataFrame(disp), pd.DataFrame(truth)


def _rationale(rng, outcome, amount):
    if outcome == "CLOSED_FP":
        return str(rng.choice([
            f"Cash credits of {amount:,.0f} consistent with declared business activity. Closing as false positive.",
            "Deposit pattern stable and in line with prior months. No further action.",
            "Activity explained by customer profile. KYC current. Closed.",
        ]))
    if outcome == "ESCALATED":
        return str(rng.choice([
            f"Cash credits of {amount:,.0f} disproportionate to declared income. Escalating for enhanced review.",
            "Deposits across multiple branches with rapid outward transfer. Escalated.",
            "Activity not explained by profile. Referred to FIU desk.",
        ]))
    return str(rng.choice([
        f"Confirmed structuring: deposits below reporting threshold totalling {amount:,.0f}, moved out within days. STR filed.",
        "Layering indicators, no economic rationale. STR filed with FIU-IND.",
    ]))


def find_invisible_population(txns, customers):
    cash = txns[(txns["mode"] == "CASH") & (txns["direction"] == "CR")].copy()
    if cash.empty:
        return pd.DataFrame()
    cash["value_date"] = pd.to_datetime(cash["value_date"])
    cash["week_start"] = cash["value_date"] - pd.to_timedelta(cash["value_date"].dt.weekday, unit="D")
    wk = (cash.groupby(["customer_id", "week_start"])
              .agg(aggregate_amount=("amount", "sum"), txn_count=("amount", "size")).reset_index())
    wk["week_end"] = wk["week_start"] + pd.Timedelta(days=6)

    v2 = POLICY_TIMELINE[1]
    missed = wk[(wk["week_end"] >= pd.Timestamp(v2["effective_from"])) &
                (wk["week_end"] < pd.Timestamp(v2["effective_to"])) &
                (wk["aggregate_amount"] >= 800_000) &
                (wk["aggregate_amount"] < 1_000_000)].copy()
    arch = customers.set_index("customer_id")["archetype"]
    missed["archetype"] = missed["customer_id"].map(arch)
    missed["is_truly_suspicious"] = missed["archetype"].isin(TRULY_SUSPICIOUS)
    return missed


# ---------------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--scale", choices=list(SCALES), default="slice")
    args = ap.parse_args()
    cfg = SCALES[args.scale]
    rng = np.random.default_rng(SEED)
    OUT.mkdir(exist_ok=True)

    print(f"scale={args.scale}  customers={cfg['customers']}  from={cfg['start']}")
    customers = gen_customers(rng, cfg["customers"], cfg["start"])
    txns, alerts, weekly_hist = gen_transactions_and_alerts(rng, customers, cfg["start"])
    print(f"  transactions : {len(txns):,}\n  alerts       : {len(alerts):,}")

    feats, evidence = build_features(alerts, customers, weekly_hist)
    disp, truth = gen_dispositions(rng, alerts, evidence)
    missed = find_invisible_population(txns, customers)

    ids = alerts["alert_id"].to_numpy().copy()
    rng.shuffle(ids)
    cut = len(ids) // 2
    split = pd.DataFrame({"alert_id": ids,
                          "split": ["CALIBRATION"] * cut + ["HOLDOUT"] * (len(ids) - cut)}
                         ).merge(disp[["alert_id", "outcome"]], on="alert_id") \
                          .rename(columns={"outcome": "human_outcome"})

    branches = pd.DataFrame(BRANCHES, columns=["branch_id", "branch_name", "city", "state", "region"])
    branches["opened_on"] = date(2010, 1, 1)
    drop = {"threshold", "window_days"}
    policies = pd.DataFrame([{k: v for k, v in p.items() if k not in drop} |
                             {"policy_code": "TM-STRUCT", "doc_id": "DOC-RBI-MD-AML",
                              "superseded_by": None} for p in POLICY_TIMELINE])
    predicates = pd.DataFrame([{
        "predicate_id": f"PR-{p['version_no']:03d}", "policy_version_id": p["policy_version_id"],
        "scenario_code": "TM-STRUCT-01", "subject": "aggregate_cash_credit",
        "field": "aggregate_amount", "operator": ">=", "threshold_value": p["threshold"],
        "threshold_unit": "INR", "window_days": p["window_days"], "scope_filter": None,
        "source_para": p["para_anchor"], "extraction_confidence": None,
        "certified_by": None, "certified_at": None} for p in POLICY_TIMELINE])

    cust_out = customers.drop(columns=[
        "archetype", "behaviour", "weekly_cash_mu", "outflow_ratio",
        "n_branches", "structuring_tendency"])
    alerts_out = alerts.drop(columns=[
        "archetype", "threshold_applied", "week_index", "deposits", "branch_pool_size"])

    for name, df in {
        "branches": branches, "customers": cust_out, "transactions": txns,
        "alerts": alerts_out, "decision_features": feats, "dispositions": disp,
        "policy_versions": policies, "rule_predicates": predicates,
        "eval_ground_truth": truth, "eval_calibration_split": split,
        "eval_invisible_population": missed,
    }.items():
        df.to_csv(OUT / f"{name}.csv", index=False)
        print(f"  wrote {name+'.csv':<32} {len(df):>8,} rows")

    # --- diagnostics that decide whether this corpus is usable --------------
    called = disp["outcome"].ne("CLOSED_FP").to_numpy()
    actual = truth["is_truly_suspicious"].to_numpy()
    ev = truth["evidence_score"].to_numpy()
    base = actual.mean()

    # How well does the evidence alone separate? This is the ceiling any model
    # reading these features could reach. If it is near the base rate, the
    # corpus is unusable no matter how good the model is.
    best_acc = max(((ev > t) == actual).mean() for t in np.linspace(0.05, 0.95, 91))

    print(f"\n  alerts truly suspicious   : {base:.3f}  (close-everything acc = {1-base:.3f})")
    print(f"  EVIDENCE ceiling (oracle) : {best_acc:.3f}  <- target 0.85-0.95; "
          f"near {1-base:.3f} means no signal")
    print(f"  mean evidence | innocent  : {ev[~actual].mean():.3f}")
    print(f"  mean evidence | guilty    : {ev[actual].mean():.3f}")
    print(f"  human accuracy vs truth   : {(called == actual).mean():.3f}  (target 0.72-0.85)")
    print(f"  human recall  vs truth    : {called[actual].mean():.3f}  (target 0.55-0.78)")
    print(f"  human precision vs truth  : {actual[called].mean():.3f}")
    if not missed.empty:
        print(f"  invisible population      : {len(missed):,} customer-weeks, "
              f"{int(missed['is_truly_suspicious'].sum()):,} truly suspicious "
              f"({100*missed['is_truly_suspicious'].mean():.1f}%)")
        print(f"  notional                  : Rs {missed['aggregate_amount'].sum()/1e7:,.1f} Cr")


if __name__ == "__main__":
    main()
