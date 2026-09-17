#!/usr/bin/env python3
"""
Check the exported snapshot before deploying it.

The demo's central claim is that anyone can recompute the evidence hashes
without access to Snowflake. That only holds if the export round-tripped the
payloads byte-exactly -- and payload_json contains commas, quotes and
newlines, which is precisely where CSV goes wrong.

If it did go wrong, every hash fails and the most important page in the demo
shows TAMPERED on untouched data. Better to find that here than after a judge
opens the link.

    python verify_snapshot.py

Exits non-zero if anything is missing or does not verify.
"""

from __future__ import annotations

import hashlib
import sys
from pathlib import Path

import pandas as pd

DATA = Path(__file__).parent / "data"

# The app degrades gracefully, so a partial snapshot is a real deployment
# option rather than a broken one. These five carry the pages the demo is
# actually for: the gap, the replay, verification, and the tamper drill.
REQUIRED = [
    "evidence_pack", "evidence_chain", "tamper_drill_log",
    "invisible_population", "threshold_sensitivity",
]

# Each of these adds a page or a panel. Missing ones show a note in place of
# the content; nothing breaks.
OPTIONAL = [
    "adjudication", "pack_render_privileged", "pack_render_masked",
    "chain_verification", "policy_versions", "rule_predicates",
    "candidate_predicates", "certification_queue", "enforceable_predicates",
    "case_history",
]


def sha256(s: str) -> str:
    return hashlib.sha256(s.encode("utf-8")).hexdigest()


def read(name: str) -> pd.DataFrame | None:
    f = DATA / f"{name}.csv"
    if not f.exists():
        return None
    df = pd.read_csv(f)
    df.columns = [c.lower() for c in df.columns]
    return df


def main() -> int:
    failures: list[str] = []

    print("required")
    missing = []
    for name in REQUIRED:
        df = read(name)
        if df is None:
            missing.append(name)
            print(f"  MISSING  {name}.csv")
        else:
            print(f"  ok       {name}.csv  ({len(df):,} rows)")
    if missing:
        failures.append(f"{len(missing)} required file(s) missing")

    absent = [n for n in OPTIONAL if read(n) is None]
    present = [n for n in OPTIONAL if n not in absent]
    print(f"\noptional  {len(present)} of {len(OPTIONAL)} present")
    for name in present:
        print(f"  ok       {name}.csv  ({len(read(name)):,} rows)")
    if absent:
        print("  not yet: " + ", ".join(absent))
        print("  (those pages show a note instead of content -- nothing breaks)")

    packs, chain = read("evidence_pack"), read("evidence_chain")
    if packs is None or chain is None:
        print("\ncannot verify hashes without evidence_pack and evidence_chain")
        print("\nFAIL: " + "; ".join(failures))
        return 1

    # 1. Payload round-trip. This is the one that catches a mangled export.
    print("\npayload hashes")
    recomputed = packs["payload_json"].map(sha256)
    bad = packs.loc[recomputed != packs["content_hash"]]
    if len(bad) == 0:
        print(f"  ok       all {len(packs):,} payloads hash to their recorded content_hash")
    else:
        print(f"  FAILED   {len(bad):,} of {len(packs):,} payloads do not match")
        row = bad.iloc[0]
        print(f"           first failure: seq {row['seq']}")
        print(f"           recorded   {row['content_hash']}")
        print(f"           recomputed {sha256(row['payload_json'])}")
        print("\n           This is almost certainly the CSV export, not tampering.")
        print("           Re-export query 1 and do not open the file in a")
        print("           spreadsheet -- Excel rewrites quoting and line endings.")
        failures.append(f"{len(bad)} payload hash mismatches")

    # 2. Chain linkage and derivation.
    print("\nchain")
    chain = chain.sort_values("link_no").reset_index(drop=True)
    expected_prev = ["GENESIS"] + chain["chain_hash"].tolist()[:-1]
    broken = int((chain["prev_chain_hash"].values != pd.Series(expected_prev).values).sum())
    wrong = sum(
        sha256(p + c) != h
        for p, c, h in zip(chain["prev_chain_hash"], chain["content_hash"], chain["chain_hash"])
    )
    print(f"  {'ok      ' if not broken else 'FAILED  '} {len(chain):,} links, {broken} broken")
    print(f"  {'ok      ' if not wrong else 'FAILED  '} {len(chain):,} link hashes, {wrong} wrong")
    if broken:
        failures.append(f"{broken} broken links")
    if wrong:
        failures.append(f"{wrong} incorrect link hashes")

    # 3. Every pack in the chain, and nothing extra.
    only_pack = set(packs["seq"]) - set(chain["pack_seq"])
    only_chain = set(chain["pack_seq"]) - set(packs["seq"])
    if only_pack or only_chain:
        print(f"  FAILED   {len(only_pack)} packs unchained, {len(only_chain)} orphan links")
        failures.append("pack/chain membership mismatch")
    else:
        print(f"  ok       every pack is chained, no orphan links")

    if len(chain):
        print(f"\nhead of chain\n  {chain.iloc[-1]['chain_hash']}")

    print()
    if failures:
        print("FAIL: " + "; ".join(failures))
        return 1
    print("PASS — the snapshot verifies independently of Snowflake. Safe to deploy.")
    if absent:
        print(f"      {len(absent)} optional file(s) still to add; the app "
              f"handles their absence.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
