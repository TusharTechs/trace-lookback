"""
TRACE — load the generated corpus into Snowflake.

Reuses the CoCo connection in ~/.snowflake/connections.toml so there is one
set of credentials, not two.

Note: this opens its own Snowflake connection and is therefore NOT covered by
the agent Restricted Session Scope -- CoCo's own guardrails banner says as
much. That is deliberate here (loading is an ACCOUNTADMIN build step), but it
is exactly the gap the PreToolUse hook exists to close for the audit log.

Usage:
    uv run --with 'snowflake-connector-python[pandas]' --with truststore generator/load.py
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

# Some networks terminate TLS at an inspecting proxy, which re-signs the
# Snowflake certificate with a private root. The OS trust store carries that
# root -- browsers and CoCo CLI connect fine -- but Python's bundled certifi
# does not, and the handshake fails with "certificate verify failed". Route
# SSL through the OS trust store. Must run before snowflake.connector imports.
try:
    import truststore

    truststore.inject_into_ssl()
except ImportError:  # not needed on a network without TLS inspection
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
