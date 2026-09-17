"""
The corpus underpins every number in EVALUATION.md. Two properties have to
hold or the evaluation is not reproducible and the comparisons are not fair.

Run:  uv run --with pytest --with numpy --with pandas pytest -q
"""

import importlib.util
import sys
from pathlib import Path

import numpy as np
import pytest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("gen", ROOT / "generator" / "generate.py")
gen = importlib.util.module_from_spec(spec)
sys.modules["gen"] = gen
spec.loader.exec_module(gen)


@pytest.fixture(scope="module")
def corpus():
    """A small deterministic slice. Not the full corpus -- these are property
    tests, not a re-run of the evaluation."""
    rng = np.random.default_rng(gen.SEED)
    customers = gen.gen_customers(rng, 300, gen.SCALES["slice"]["start"])
    txns, alerts, hist = gen.gen_transactions_and_alerts(rng, customers, gen.SCALES["slice"]["start"])
    feats, evidence = gen.build_features(alerts, customers, hist)
    disp, truth = gen.gen_dispositions(rng, alerts, evidence)
    return dict(customers=customers, txns=txns, alerts=alerts,
                feats=feats, evidence=evidence, disp=disp, truth=truth)


def test_seed_is_deterministic():
    """Same seed, same corpus. EVALUATION.md cites exact counts; if the
    generator drifts, none of those numbers can be reproduced."""
    def build():
        rng = np.random.default_rng(gen.SEED)
        c = gen.gen_customers(rng, 200, gen.SCALES["slice"]["start"])
        t, a, _ = gen.gen_transactions_and_alerts(rng, c, gen.SCALES["slice"]["start"])
        return len(t), len(a), float(t["amount"].sum())

    assert build() == build()


def test_policy_in_force_is_a_total_function():
    """Every date in the observation window resolves to exactly one version.
    A gap or an overlap would make 'the rule at the time' ambiguous, which is
    the one thing a replay cannot tolerate."""
    from datetime import date, timedelta
    d = date(2023, 1, 1)
    while d < gen.TODAY:
        matches = [p for p in gen.POLICY_TIMELINE
                   if p["effective_from"] <= d
                   and (p["effective_to"] is None or d < p["effective_to"])]
        assert len(matches) == 1, f"{d} resolves to {len(matches)} policy versions"
        d += timedelta(days=7)


def test_alerts_fire_against_the_threshold_of_their_own_time(corpus):
    """An alert must clear the threshold in force when it fired -- not today's.
    This is the bitemporal invariant the whole project rests on."""
    for a in corpus["alerts"].itertuples():
        pol = gen.policy_in_force(a.window_end)
        assert a.aggregate_amount >= pol["threshold"]
        assert a.policy_version_id == pol["policy_version_id"]


def test_no_alert_without_minimum_history(corpus):
    """Rolling features are undefined below MIN_HISTORY_WEEKS. Alerts raised
    before then produced contradictions the model was asked to reconcile."""
    assert (corpus["alerts"]["week_index"] >= gen.MIN_HISTORY_WEEKS).all()


def test_classes_overlap(corpus):
    """Behavioural mimicry must actually produce overlap. Cleanly separated
    classes gave an oracle ceiling of 0.998 and left a model nothing to earn."""
    t = corpus["truth"]
    dirty = t[t.is_truly_suspicious]["evidence_score"]
    clean = t[~t.is_truly_suspicious]["evidence_score"]
    assert len(dirty) and len(clean)
    assert dirty.mean() > clean.mean(), "no signal at all"
    assert dirty.min() < clean.max(), "classes are separable -- corpus is too easy"


def test_human_labels_are_not_the_archetype(corpus):
    """Reviewers read the evidence, not the label. If dispositions matched
    truth exactly, every model/human comparison would be rigged."""
    called = corpus["disp"]["outcome"].ne("CLOSED_FP").to_numpy()
    actual = corpus["truth"]["is_truly_suspicious"].to_numpy()
    agreement = (called == actual).mean()
    assert agreement < 0.95, "human labels track truth too closely to be a fair baseline"
    assert agreement > 0.55, "human labels are noise, not a baseline"


def test_eval_columns_never_leak_into_features(corpus):
    """DECISION_FEATURES is what the model sees. Ground truth must not be in it."""
    import json
    blob = json.loads(corpus["feats"].iloc[0]["features"])
    forbidden = {"is_truly_suspicious", "archetype", "evidence_score", "behaviour"}
    assert not (forbidden & set(blob)), f"ground truth leaked: {forbidden & set(blob)}"


def test_invisible_population_is_mixed(corpus):
    """The defect band must contain legitimate businesses as well as mules.
    If everything in it were dirty, re-applying the threshold would be the
    whole answer and adjudication would be pointless."""
    missed = gen.find_invisible_population(corpus["txns"], corpus["customers"])
    if missed.empty:
        pytest.skip("slice too small to produce an invisible population")
    rate = missed["is_truly_suspicious"].mean()
    assert 0.1 < rate < 0.9, f"band is {rate:.0%} suspicious -- not a judgement problem"
