"""
TRACE — load the generated corpus into Snowflake.

Reuses the CoCo connection in ~/.snowflake/connections.toml so there is one
set of credentials, not two.

Note: this opens its own Snowflake connection and is therefore NOT covered by
the agent Restricted Session Scope -- CoCo's own guardrails banner says as
much. That is deliberate here (loading is an ACCOUNTADMIN build step), but it
is exactly the gap the PreToolUse hook exists to close for the audit log.

NOT the path used to build this project, and the reason is worth stating
precisely because the obvious diagnosis is wrong.

This machine runs Netskope, installed as a managed endpoint agent with its
roots in the macOS System keychain (`eproxy.caadmin.netskope.com` and
`*.fra2.goskope.com`). It therefore intercepts TLS on **any** network, not
just a corporate one -- the same failure reproduces from a home connection.
Chrome, Snowsight and CoCo CLI all connect happily, because they consult the
OS trust store and that store trusts Netskope.

The Snowflake connector does not. It routes TLS through
`snowflake/connector/vendored/urllib3/contrib/pyopenssl.py`, and pyOpenSSL
reads a CA **bundle file** rather than the operating system's trust store.
The handshake fails at `/oauth/token-request` with `certificate verify
failed`.

Two fixes were tried and neither works, which is why they are recorded here
rather than left as folklore:

  * `truststore.inject_into_ssl()` patches Python's own `ssl` module. The
    pyOpenSSL path bypasses that module entirely, so the injection below has
    no effect on this connector. It is retained only because it is correct
    for other libraries in the same process.

  * `REQUESTS_CA_BUNDLE`, `SSL_CERT_FILE` and `CURL_CA_BUNDLE` pointed at a
    combined bundle -- certifi plus both keychains, 290 certificates
    including 6 Netskope roots -- change nothing either. The connector builds
    its own TLS parameters in
    `snowflake/connector/ssl_wrap_socket.ssl_wrap_socket_with_cert_revocation_checks`
    and never consults those variables.

What was used instead: CoCo CLI's `sql_execute` for the build (documented in
`sql/11_reload_and_score_v5.sql`), and Snowsight result downloads for the
public-demo export (`sql/28_export_public_snapshot.sql`).

This file is kept because it is the right tool on a machine without an
intercepting endpoint agent, and because the governance note above is worth
stating. It is the untested path here: if it fails for you the same way, the
CoCo and Snowsight routes both work.

Usage:
    uv run --with 'snowflake-connector-python[pandas]' --with truststore generator/load.py
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

# Routes Python's ssl module through the OS trust store, which helps where TLS
# is terminated by an inspecting proxy whose root the OS trusts.
#
# It does NOT rescue the Snowflake connector: that path goes through pyOpenSSL,
# which reads a CA bundle file instead of the ssl module this patches. See the
# module docstring. Kept because it is correct for other libraries here, and
# because deleting it would invite someone to re-add it as the fix.
try:
    import truststore

    truststore.inject_into_ssl()
except ImportError:  # not needed where nothing is intercepting TLS
    pass

import pandas as pd
import snowflake.connector
from snowflake.connector.pandas_tools import write_pandas

CONNECTION = os.environ.get("TRACE_SF_CONNECTION", "default")  # see ~/.snowflake/connections.toml
OUT = Path(__file__).parent / "out"

# csv stem -> (schema, table)
TARGETS = [
    ("branches",                  "CORE",   "BRANCHES"),
    ("customers",                 "CORE",   "CUSTOMERS"),
    ("transactions",              "CORE",   "TRANSACTIONS"),
    ("alerts",                    "CORE",   "ALERTS"),
    ("dispositions",              "CORE",   "DISPOSITIONS"),
    ("decision_features",         "CORE",   "DECISION_FEATURES_STG"),
    ("policy_versions",           "POLICY", "POLICY_VERSIONS"),
    ("rule_predicates",           "POLICY", "RULE_PREDICATES"),
    ("eval_ground_truth",         "EVAL",   "GROUND_TRUTH"),
    ("eval_calibration_split",    "EVAL",   "CALIBRATION_SET"),
    ("eval_invisible_population", "EVAL",   "INVISIBLE_POPULATION"),
]

# Columns the generator emits that the target table does not carry.
DROP_COLS = {"GROUND_TRUTH": [], "CALIBRATION_SET": []}


def main() -> int:
    if not OUT.exists():
        print(f"no corpus at {OUT} -- run generate.py first", file=sys.stderr)
        return 1

    conn = snowflake.connector.connect(connection_name=CONNECTION)
    print(f"connected: {conn.account} / {conn.role} / {conn.warehouse}")

    try:
        for stem, schema, table in TARGETS:
            path = OUT / f"{stem}.csv"
            if not path.exists():
                print(f"  skip {stem:<26} (not generated)")
                continue

            df = pd.read_csv(path)
            df.columns = [c.upper() for c in df.columns]
            for col in DROP_COLS.get(table, []):
                df = df.drop(columns=[col], errors="ignore")

            ok, nchunks, nrows, _ = write_pandas(
                conn, df,
                table_name=table, schema=schema, database="TRACE_DB",
                quote_identifiers=False,   # our identifiers are plain uppercase
                chunk_size=100_000,
                overwrite=True,
            )
            status = "ok" if ok else "FAILED"
            print(f"  {schema}.{table:<24} {nrows:>9,} rows  ({nchunks} chunks) {status}")

        # VARIANT cannot be written directly by write_pandas: parse on the way in.
        cur = conn.cursor()
        cur.execute("""
            INSERT INTO TRACE_DB.CORE.DECISION_FEATURES (alert_id, captured_at, features, feature_hash)
            SELECT alert_id, captured_at, PARSE_JSON(features), feature_hash
            FROM TRACE_DB.CORE.DECISION_FEATURES_STG
        """)
        print(f"  CORE.DECISION_FEATURES   {cur.rowcount:>9,} rows  (PARSE_JSON from staging)")
        cur.execute("DROP TABLE IF EXISTS TRACE_DB.CORE.DECISION_FEATURES_STG")

        # Sanity: the numbers the demo depends on, read back from Snowflake
        # rather than trusted from the generator's own summary.
        for label, sql in [
            ("alerts",              "SELECT COUNT(*) FROM TRACE_DB.CORE.ALERTS"),
            ("transactions",        "SELECT COUNT(*) FROM TRACE_DB.CORE.TRANSACTIONS"),
            ("invisible pop.",      "SELECT COUNT(*) FROM TRACE_DB.EVAL.INVISIBLE_POPULATION"),
            ("  of which dirty",    "SELECT COUNT(*) FROM TRACE_DB.EVAL.INVISIBLE_POPULATION WHERE is_truly_suspicious"),
            ("  notional (Rs)",     "SELECT TO_VARCHAR(SUM(aggregate_amount), '999,999,999,999') FROM TRACE_DB.EVAL.INVISIBLE_POPULATION"),
        ]:
            cur.execute(sql)
            print(f"  {label:<22} {cur.fetchone()[0]}")

    finally:
        conn.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
