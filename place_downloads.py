#!/usr/bin/env python3
"""
Sort Snowsight downloads into data/ under the right names.

Snowsight names every download after the worksheet, so fifteen exports arrive
as "Untitled.sql - Results.csv", "... (1).csv" and so on. Renaming those by
hand means remembering which query produced which, and a single swap puts the
wrong table behind the wrong page.

This identifies each file by its column signature instead.

    python3 place_downloads.py              # ~/Downloads, last 24 hours
    python3 place_downloads.py --hours 72   # widen the window
    python3 place_downloads.py --all        # every CSV, however old
    python3 place_downloads.py ~/some/dir

Only files modified inside the window are considered, because a Downloads
folder accumulates: the first version of this scanned 748 unrelated CSVs and
printed a rejection line for every one, which buried the only message that
mattered. Unrelated files are now counted, not listed.

Nothing is overwritten without --force, and nothing is deleted: files are
copied, not moved, so a mistake here costs nothing.
"""

from __future__ import annotations

import shutil
import sys
import time
from pathlib import Path

import pandas as pd

DATA = Path(__file__).parent / "data"

# Column sets, taken from the CREATE statements and the 0b preflight rather
# than from memory. Matching is on set overlap, so trailing columns that
# Snowsight renders differently do not matter.
SIGNATURES: dict[str, set[str]] = {
    "evidence_pack": {"seq", "case_ref", "customer_id", "week_start",
                      "p_suspicious", "payload_json", "content_hash"},
    "evidence_chain": {"link_no", "pack_seq", "case_ref", "content_hash",
                       "prev_chain_hash", "chain_hash"},
    "pack_render": {"seq", "link_no", "case_ref", "customer_id",
                    "customer_name", "customer_pan", "content_hash"},
    "adjudication": {"customer_id", "week_start", "aggregate_amount",
                     "p_suspicious", "aggravating", "mitigating", "raw",
                     "model_name", "ran_at"},
    "invisible_population": {"customer_id", "week_start", "week_end",
                             "aggregate_amount", "txn_count", "archetype",
                             "is_truly_suspicious"},
    "threshold_sensitivity": {"threshold", "would_catch", "newly_captured",
                              "newly_captured_cr", "customers_affected"},
    "policy_versions": {"policy_version_id", "policy_code", "version_no",
                        "effective_from", "effective_to"},
    "rule_predicates": {"predicate_id", "policy_version_id", "scenario_code",
                        "subject", "field", "operator"},
    "candidate_predicates": {"candidate_id", "run_id", "source_doc_id",
                             "source_text_hash", "scenario_code"},
    "certification_queue": {"candidate_id", "source_doc_id", "threshold_value",
                            "effective_from", "effective_to"},
    "enforceable_predicates": {"threshold_value", "effective_from",
                               "effective_to", "window_days"},
    "tamper_drill_log": {"ord", "drill", "attack", "actions", "broken_links",
                         "hash_mismatches", "forked_rows", "verdict",
                         "caught_by"},
    "case_history": {"link_no", "case_ref", "event_ts", "actor", "action",
                     "note", "acting_role", "row_hash"},
    "chain_verification": {"link_no", "case_ref", "content_intact",
                           "link_intact", "hash_intact", "pack_present"},
}


def coverage(cols: set[str], sig: set[str]) -> float:
    """How much of the signature the file actually contains.

    This was Jaccard, which is wrong for wide tables: the
    V_EVIDENCE_PACK_RENDER exports carry 20 columns against a 7-column
    signature, giving 7/20 = 0.35 and a rejection. What matters is whether
    every column the signature names is present, not whether the file has
    extra ones. Ties are broken by signature size, so a specific match wins
    over a general one."""
    return len(cols & sig) / len(sig) if sig else 0.0


def looks_masked(df: pd.DataFrame) -> bool:
    """The privileged and masked exports of V_EVIDENCE_PACK_RENDER have
    identical columns, so they can only be told apart by their contents. A
    masking policy replaces characters; real generated PANs do not repeat a
    single character five times."""
    for col in ("customer_pan", "customer_name"):
        if col in df.columns and len(df):
            sample = df[col].dropna().astype(str).head(25)
            if any(any(ch * 4 in v for ch in "X*x•#") for v in sample):
                return True
    return False


def main() -> int:
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    src = Path(args[0]).expanduser() if args else Path.home() / "Downloads"
    force = "--force" in sys.argv

    hours = 24.0
    if "--all" in sys.argv:
        hours = float("inf")
    elif "--hours" in sys.argv:
        hours = float(sys.argv[sys.argv.index("--hours") + 1])

    if not src.is_dir():
        print(f"no such directory: {src}")
        return 1

    DATA.mkdir(exist_ok=True)
    every = sorted(src.glob("*.csv"), key=lambda p: p.stat().st_mtime,
                   reverse=True)
    cutoff = time.time() - hours * 3600
    candidates = [f for f in every if f.stat().st_mtime >= cutoff]
    older = len(every) - len(candidates)

    window = "any age" if hours == float("inf") else f"last {hours:g}h"
    print(f"{src}: {len(candidates)} CSV(s) in the {window}"
          + (f", {older} older ignored" if older else "") + "\n")
    if not candidates:
        print("Nothing recent to place. Download the exports first, or widen")
        print("the window with --hours N / --all.")
        return 1

    placed: dict[str, Path] = {}
    skipped: list[tuple[Path, str]] = []
    unrelated = 0

    for f in candidates:
        try:
            df = pd.read_csv(f, nrows=40)
        except Exception as e:
            skipped.append((f, f"unreadable ({type(e).__name__})"))
            continue
        # Normalise here, not just for matching. looks_masked() reads column
        # names too, and Snowsight exports them upper case -- so it silently
        # returned False for both role exports, filed the MASKED file as
        # privileged and dropped the real one as a duplicate. That would have
        # inverted the whole point of the two-role comparison.
        df.columns = [c.strip().lower() for c in df.columns]
        cols = set(df.columns)

        best, score = max(
            ((n, coverage(cols, sig)) for n, sig in SIGNATURES.items()),
            key=lambda t: (t[1], len(SIGNATURES[t[0]])),
        )
        if score < 0.60:
            unrelated += 1            # counted, not listed
            continue
        if score < 0.90:
            # Close enough to be worth naming: probably one of ours, exported
            # with the wrong query or truncated.
            skipped.append((f, f"looks like {best} but only {score:.0%} match"))
            continue

        name = best
        if best == "pack_render":
            name = "pack_render_masked" if looks_masked(df) \
                else "pack_render_privileged"

        if name in placed:                      # newest wins; list is sorted
            skipped.append((f, f"older duplicate of {name}"))
            continue

        dest = DATA / f"{name}.csv"
        if dest.exists() and not force:
            skipped.append((f, f"{dest.name} already present (use --force)"))
            continue

        shutil.copy2(f, dest)
        placed[name] = f
        print(f"  {name:<24} ← {f.name}   ({score:.0%} column match)")

    # pack_render is one signature but two files, one per role.
    expected = (set(SIGNATURES) - {"pack_render"}) | {
        "pack_render_privileged", "pack_render_masked"}
    # Count what is already on disk, not just what this run placed. The
    # first version listed all fifteen as missing after a run that placed
    # nothing, which read as catastrophic and was simply wrong.
    on_disk = {n for n in expected if (DATA / f"{n}.csv").exists()}
    missing = sorted(expected - on_disk)

    if skipped:
        print("\nneeds a look")
        for f, why in skipped:
            print(f"  {f.name}  —  {why}")
    if unrelated:
        print(f"\n{unrelated} unrelated CSV(s) ignored")

    print(f"\nplaced {len(placed)} file(s) this run; {len(on_disk)} of "
          f"{len(expected)} present in data/")
    if missing:
        print(f"still missing {len(missing)}:")
        for m in missing:
            print(f"  {m}.csv")
        return 1

    print("all 15 present. Next:  python3 verify_snapshot.py")
    return 0


if __name__ == "__main__":
    sys.exit(main())
