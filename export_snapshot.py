#!/usr/bin/env python3
"""
Export the public demo snapshot straight from Snowflake.

Replaces running sql/28_export_public_snapshot.sql by hand in Snowsight and
downloading fifteen result panes one at a time.

    uv run --with 'snowflake-connector-python[pandas]' --with truststore \
        python3 export_snapshot.py

The connection profile uses browser authentication, so a login window will
open. Complete it and the rest is automatic.

Two reasons this beats the manual route beyond saving clicks:

  * The payload round-trip is verified in the same run. payload_json carries
    commas, quotes and newlines; if writing and re-reading the CSV is not
    byte-exact, every hash fails and the demo's central page reports TAMPERED
    on untouched data. This writes each file, reads it back off disk, and
    recomputes all 687 hashes before declaring success.

  * Nothing passes through a spreadsheet, which is where that corruption
    would otherwise come from.

Read-only apart from the role switch for the masked export, which is
restored in a finally block.
"""

from __future__ import annotations

import hashlib
import os
import sys
from pathlib import Path

DATA = Path(__file__).parent / "data"
CONNECTION = "BDB66691"

# (filename, sql). Mirrors sql/28. SELECT * wherever a whole object is wanted;
# the three explicit column lists were each checked against their CREATE
# statement, because guessing them cost three failed runs already.
QUERIES: list[tuple[str, str]] = [
    ("evidence_pack", """
        SELECT seq, case_ref, customer_id, week_start, p_suspicious,
               TO_JSON(payload) AS payload_json, content_hash
        FROM AUDIT.EVIDENCE_PACK ORDER BY seq"""),
    ("evidence_chain", """
        SELECT link_no, pack_seq, case_ref, content_hash,
               prev_chain_hash, chain_hash
        FROM AUDIT.EVIDENCE_CHAIN ORDER BY link_no"""),
    ("pack_render_privileged",
     "SELECT * FROM AUDIT.V_EVIDENCE_PACK_RENDER ORDER BY seq"),
    ("adjudication",
     "SELECT * FROM EVAL.ADJUDICATION ORDER BY customer_id, week_start"),
    ("invisible_population",
     "SELECT * FROM EVAL.INVISIBLE_POPULATION ORDER BY customer_id, week_start"),
    ("threshold_sensitivity",
     "SELECT * FROM POLICY.V_THRESHOLD_SENSITIVITY ORDER BY 1"),
    ("policy_versions",      "SELECT * FROM POLICY.POLICY_VERSIONS ORDER BY 1"),
    ("rule_predicates",      "SELECT * FROM POLICY.RULE_PREDICATES ORDER BY 1"),
    ("candidate_predicates", "SELECT * FROM POLICY.CANDIDATE_PREDICATES ORDER BY 1"),
    ("certification_queue",  "SELECT * FROM POLICY.V_CERTIFICATION_QUEUE ORDER BY 1"),
    ("enforceable_predicates",
     "SELECT * FROM POLICY.V_ENFORCEABLE_PREDICATES ORDER BY 1"),
    ("tamper_drill_log", """
        SELECT ord, drill, attack, actions, broken_links, hash_mismatches,
               forked_rows, verdict, caught_by
        FROM AUDIT.TAMPER_DRILL_LOG ORDER BY ord"""),
    ("case_history",       "SELECT * FROM AUDIT.V_CASE_HISTORY ORDER BY link_no"),
    ("chain_verification", "SELECT * FROM AUDIT.V_CHAIN_VERIFICATION ORDER BY link_no"),
]

MASKED = ("pack_render_masked",
          "SELECT * FROM TRACE_DB.AUDIT.V_EVIDENCE_PACK_RENDER ORDER BY seq")


def sha256(s: str) -> str:
    return hashlib.sha256(s.encode("utf-8")).hexdigest()


def main() -> int:
    # This endpoint runs Netskope, whose roots are installed in the macOS
    # System keychain. Chrome and CoCo CLI therefore connect fine. The
    # Snowflake connector does not: it routes TLS through
    # vendored/urllib3/contrib/pyopenssl, and pyOpenSSL reads a CA bundle file
    # rather than the OS trust store -- which is also why `truststore` never
    # helped here, since that patches Python's ssl module and this path
    # bypasses it. The failure is `certificate verify failed` at
    # /oauth/token-request.
    #
    # Fix: hand it a bundle that contains both certifi's roots and the
    # keychain's. Build it with:
    #
    #   security find-certificate -a -p \
    #     /System/Library/Keychains/SystemRootCertificates.keychain  > /tmp/r.pem
    #   security find-certificate -a -p /Library/Keychains/System.keychain \
    #     >> /tmp/r.pem
    #   cat "$(python3 -c 'import certifi;print(certifi.where())')" /tmp/r.pem \
    #     > ~/.snowflake/ca-bundle.pem
    #
    # Must be set before snowflake.connector is imported.
    bundle = Path.home() / ".snowflake" / "ca-bundle.pem"
    if bundle.exists():
        os.environ.setdefault("REQUESTS_CA_BUNDLE", str(bundle))
        os.environ.setdefault("SSL_CERT_FILE", str(bundle))
        os.environ.setdefault("CURL_CA_BUNDLE", str(bundle))
        print(f"using CA bundle {bundle}")

    try:
        import truststore
        truststore.inject_into_ssl()
    except Exception:
        pass

    import pandas as pd
    import snowflake.connector as sc

    DATA.mkdir(exist_ok=True)
    print("connecting (a browser window will open for login)...")
    cx = sc.connect(connection_name=CONNECTION)

    written: dict[str, int] = {}
    try:
        cur = cx.cursor()
        cur.execute("USE ROLE ACCOUNTADMIN")
        cur.execute("USE WAREHOUSE COMPUTE_WH")
        cur.execute("USE DATABASE TRACE_DB")

        for name, sql in QUERIES:
            df = cur.execute(sql).fetch_pandas_all()
            df.to_csv(DATA / f"{name}.csv", index=False)
            written[name] = len(df)
            print(f"  {name:<24} {len(df):>7,} rows")

        # The same view under the investigator role. USE SECONDARY ROLES NONE
        # matters: without it the session keeps every role granted to the user
        # and the masking policy never engages.
        print("  switching role for the masked export...")
        try:
            cur.execute("USE SECONDARY ROLES NONE")
            cur.execute("USE ROLE TRACE_INVESTIGATOR")
            name, sql = MASKED
            df = cur.execute(sql).fetch_pandas_all()
            df.to_csv(DATA / f"{name}.csv", index=False)
            written[name] = len(df)
            print(f"  {name:<24} {len(df):>7,} rows")
        finally:
            cur.execute("USE ROLE ACCOUNTADMIN")
            cur.execute("USE SECONDARY ROLES ALL")
    finally:
        cx.close()

    # Re-read from disk. Verifying the DataFrame in memory would prove nothing
    # about the file, and the file is what gets deployed.
    print("\nverifying the written files")
    packs = pd.read_csv(DATA / "evidence_pack.csv")
    chain = pd.read_csv(DATA / "evidence_chain.csv")
    packs.columns = [c.lower() for c in packs.columns]
    chain.columns = [c.lower() for c in chain.columns]

    bad = int((packs["payload_json"].map(sha256) != packs["content_hash"]).sum())
    chain = chain.sort_values("link_no").reset_index(drop=True)
    expected_prev = ["GENESIS"] + chain["chain_hash"].tolist()[:-1]
    broken = int((chain["prev_chain_hash"].values
                  != pd.Series(expected_prev).values).sum())
    wrong = sum(sha256(p + c) != h for p, c, h
                in zip(chain["prev_chain_hash"], chain["content_hash"],
                       chain["chain_hash"]))

    print(f"  payload hashes   {len(packs):>7,} checked, {bad} mismatched")
    print(f"  chain links      {len(chain):>7,} checked, {broken} broken")
    print(f"  link hashes      {len(chain):>7,} checked, {wrong} wrong")

    if bad or broken or wrong:
        print("\nFAIL — the CSV round-trip is not byte-exact. Do not deploy.")
        return 1

    print(f"\nhead of chain\n  {chain.iloc[-1]['chain_hash']}")
    print(f"\nPASS — {len(written)} files in data/, hashes recompute from disk.")
    print("Next:  python3 verify_snapshot.py   (independent re-check)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
