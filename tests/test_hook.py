"""
The PreToolUse guard is the only thing standing between the agent and the
evidence store at the client layer. It was verified once by hand; that is not
a test.

Run:  uv run --with pytest pytest -q
"""

import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
HOOK = ROOT / ".cortex" / "hooks" / "protect-audit.py"
SHIM = ROOT / ".cortex" / "hooks" / "run-guard.py"

BLOCK, ALLOW = 2, 0


def run(sql: str) -> int:
    payload = json.dumps({"tool_name": "sql_execute", "tool_input": {"statement": sql}})
    return subprocess.run(
        [sys.executable, str(HOOK)], input=payload, capture_output=True, text=True
    ).returncode


# --- must be refused --------------------------------------------------------

BLOCKED = [
    ("update pack",        "UPDATE AUDIT.EVIDENCE_PACK SET payload = NULL WHERE seq = 1"),
    ("update qualified",   "UPDATE TRACE_DB.AUDIT.EVIDENCE_PACK SET payload = NULL"),
    ("delete chain",       "DELETE FROM AUDIT.EVIDENCE_CHAIN"),
    ("truncate",           "TRUNCATE TABLE AUDIT.EVIDENCE_PACK"),
    ("truncate no table",  "TRUNCATE AUDIT.AUDIT_LOG"),
    ("drop table",         "DROP TABLE AUDIT.AUDIT_LOG"),
    ("drop view",          "DROP VIEW AUDIT.V_CHAIN_VERIFICATION"),
    ("merge",              "MERGE INTO AUDIT.EVIDENCE_PACK t USING x ON t.seq = x.seq"),
    ("alter",              "ALTER TABLE AUDIT.EVIDENCE_PACK ADD COLUMN x STRING"),
    # Redefining the verification view would let tampering report INTACT.
    ("replace view",       "CREATE OR REPLACE VIEW AUDIT.V_CHAIN_VERIFICATION AS SELECT 1"),
    # An agent that can grant on audit objects can grant itself write access.
    ("grant",              "GRANT UPDATE ON TABLE AUDIT.EVIDENCE_PACK TO ROLE PUBLIC"),
    # Evasion attempts.
    ("hidden in comment",  "/* harmless */ UPDATE AUDIT.EVIDENCE_PACK SET payload = NULL"),
    ("line comment",       "-- routine\nDELETE FROM AUDIT.EVIDENCE_CHAIN"),
    ("second in batch",    "SELECT 1; DELETE FROM AUDIT.EVIDENCE_CHAIN"),
    ("lowercase",          "update audit.evidence_pack set payload = null"),
    ("extra whitespace",   "UPDATE   AUDIT . EVIDENCE_PACK  SET payload = NULL"),
]

# --- must be permitted ------------------------------------------------------

ALLOWED = [
    ("select audit",       "SELECT * FROM AUDIT.EVIDENCE_PACK ORDER BY seq"),
    ("count audit",        "SELECT COUNT(*) FROM TRACE_DB.AUDIT.EVIDENCE_CHAIN"),
    ("insert audit",       "INSERT INTO AUDIT.AUDIT_LOG (actor, action) VALUES ('x','y')"),
    ("call procedure",     "CALL AUDIT.BUILD_EVIDENCE_CHAIN()"),
    ("update elsewhere",   "UPDATE CORE.CUSTOMERS SET risk_rating = 'LOW'"),
    ("delete elsewhere",   "DELETE FROM CORE.DECISION_FEATURES_STG"),
    ("drop elsewhere",     "DROP TABLE CORE.DECISION_FEATURES_STG"),
    ("replace view core",  "CREATE OR REPLACE VIEW CORE.V_CASE_LEDGER AS SELECT 1"),
    ("create audit table", "CREATE TABLE AUDIT.NEW_THING (x STRING)"),
]


def test_blocked():
    for name, sql in BLOCKED:
        assert run(sql) == BLOCK, f"{name!r} should have been blocked: {sql}"


def test_allowed():
    for name, sql in ALLOWED:
        assert run(sql) == ALLOW, f"{name!r} should have been allowed: {sql}"


def test_malformed_payload_does_not_brick_the_session():
    """An unparseable payload must not block every subsequent call. Failing
    open here is deliberate: the database-level grants are the real control,
    and a hook that bricks the agent on an unexpected shape is worse than one
    that defers."""
    r = subprocess.run(
        [sys.executable, str(HOOK)], input="not json", capture_output=True, text=True
    )
    assert r.returncode == ALLOW


def test_block_reason_is_actionable():
    """A refusal has to tell the agent what to do instead, or it just retries."""
    payload = json.dumps({"tool_name": "sql_execute",
                          "tool_input": {"statement": "UPDATE AUDIT.EVIDENCE_PACK SET payload = NULL"}})
    r = subprocess.run([sys.executable, str(HOOK)], input=payload,
                       capture_output=True, text=True)
    out = json.loads(r.stdout)
    assert out["decision"] == "block"
    assert "append-only" in out["reason"]
    assert "INSERT" in out["reason"]


def test_shim_matches_direct_invocation():
    """CoCo calls the shim, not the guard. If they ever diverge, the tests
    would be checking something the agent never runs."""
    for _, sql in BLOCKED[:4] + ALLOWED[:4]:
        payload = json.dumps({"tool_name": "sql_execute", "tool_input": {"statement": sql}})
        direct = subprocess.run([sys.executable, str(HOOK)], input=payload,
                                capture_output=True, text=True).returncode
        shim = subprocess.run([sys.executable, str(SHIM)], input=payload,
                              capture_output=True, text=True).returncode
        assert direct == shim, f"shim and guard disagree on: {sql}"
