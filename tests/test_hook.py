"""
The PreToolUse guard is the only thing standing between the agent and the
evidence store at the client layer. It was verified once by hand; that is not
a test.

Run:  uv run --with pytest pytest -q
"""

import json
import os
import pathlib
import re
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
    # Minting a procedure in AUDIT turns "the hook cannot see inside a stored
    # procedure" from a documented limitation into a working bypass: put an
    # UPDATE in the body, then CALL it. Both statements would otherwise pass.
    ("create procedure",   "CREATE OR REPLACE PROCEDURE AUDIT.SNEAKY() RETURNS STRING AS $$ BEGIN UPDATE AUDIT.EVIDENCE_PACK SET payload = NULL; END; $$"),
    ("create function",    "CREATE FUNCTION AUDIT.F() RETURNS STRING AS $$ 'x' $$"),
    ("create table audit", "CREATE TABLE AUDIT.SHADOW (x STRING)"),
    ("create task",        "CREATE TASK AUDIT.T SCHEDULE = '1 minute' AS SELECT 1"),
    # Blocking CREATE PROCEDURE only closes half the hole. sql/27's tamper
    # drill needs a human-created procedure in AUDIT that deletes rows; once
    # it exists, an unconditional CALL permission hands it straight back to
    # the agent. Calls into AUDIT are allowlisted by name.
    ("call drill reset",   "CALL AUDIT.RESET_ACTION_LOG_DEMO()"),
    ("call drill runner",  "CALL TRACE_DB.AUDIT.RUN_TAMPER_DRILLS()"),
    ("call unknown proc",  "CALL AUDIT.SOMETHING_A_HUMAN_ADDED_LATER()"),
    ("call quoted",        'CALL "AUDIT"."RESET_ACTION_LOG_DEMO"()'),
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
    ("call record action", "CALL AUDIT.RECORD_CASE_ACTION('CU-1|2026-01-01','a@b','VIEWED','x')"),
    ("call qualified ok",  "CALL TRACE_DB.AUDIT.RECORD_CASE_ACTION('CU-1|2026-01-01','a@b','VIEWED','x')"),
    ("call outside audit", "CALL CORE.REPLAY_AT_THRESHOLD(500000, '2026-01-01', '2026-09-16')"),
    ("update elsewhere",   "UPDATE CORE.CUSTOMERS SET risk_rating = 'LOW'"),
    ("delete elsewhere",   "DELETE FROM CORE.DECISION_FEATURES_STG"),
    ("drop elsewhere",     "DROP TABLE CORE.DECISION_FEATURES_STG"),
    ("replace view core",  "CREATE OR REPLACE VIEW CORE.V_CASE_LEDGER AS SELECT 1"),
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

def test_the_command_coco_actually_runs_is_wired_up():
    """The guard was dead in CoCo for two days and every test above passed.

    Those tests invoke the script with sys.executable. CoCo invokes whatever
    string sits in .cortex/settings.json, through a NON-interactive shell.
    Commit c4c3adb -- "Repo hardening: tests, cross-platform" -- changed that
    string from `python3` to `python`. On this machine `python` is an
    interactive-shell alias, so a non-interactive shell returns 127, CoCo sees
    an exit code that is not 2, and the statement is allowed through.

    A control that is present, tested and not wired up is worse than no
    control, because it is believed. This test runs the configured command the
    way CoCo does and asserts it still refuses.
    """
    settings = json.loads((ROOT / ".cortex" / "settings.json").read_text())
    entries = settings["hooks"]["PreToolUse"]
    commands = [h["command"] for e in entries for h in e["hooks"]]
    assert commands, "no PreToolUse hook command configured"

    payload = json.dumps({"tool_name": "sql_execute",
                          "tool_input": {"statement": "DELETE FROM AUDIT.EVIDENCE_CHAIN"}})

    # Run it the way CoCo does, NOT the way pytest happens to be running.
    #
    # The first version of this test passed against the broken `python`
    # command, because pytest runs through `uv`, which creates an ephemeral
    # virtualenv under ~/.cache/uv and puts its bin -- containing a `python`
    # -- first on PATH. Stripping only ".venv" missed it and the test still
    # passed. CoCo's hook gets no virtualenv at all. A test that passes
    # because of its own environment is exactly the failure this test exists
    # to catch, so every virtualenv directory is removed.
    venv = os.environ.get("VIRTUAL_ENV")
    uv_cache = str(pathlib.Path.home() / ".cache" / "uv")

    def from_a_virtualenv(d: str) -> bool:
        return (".venv" in d) or d.startswith(uv_cache) or (venv and d.startswith(venv))

    env = {k: v for k, v in os.environ.items() if k != "VIRTUAL_ENV"}
    env["PATH"] = os.pathsep.join(
        d for d in env.get("PATH", "").split(os.pathsep) if not from_a_virtualenv(d)
    )

    for cmd in commands:
        r = subprocess.run(cmd, shell=True, input=payload,
                           capture_output=True, text=True, cwd=ROOT, env=env)
        assert r.returncode == BLOCK, (
            f"configured hook command did not block: {cmd!r} "
            f"exited {r.returncode} (127 means the interpreter was not found "
            f"outside a virtualenv -- which is how CoCo runs it)"
        )


def test_hook_matcher_covers_the_sql_tool():
    """A correct command on the wrong matcher is the same silent failure."""
    settings = json.loads((ROOT / ".cortex" / "settings.json").read_text())
    matchers = [e.get("matcher") for e in settings["hooks"]["PreToolUse"]]
    assert "sql_execute" in matchers, (
        f"PreToolUse does not match sql_execute; matchers are {matchers}"
    )


def test_hook_command_does_not_rely_on_a_bare_python():
    """Environment-independent version of the check above.

    `python` is absent on many systems and, on this one, exists only as an
    interactive-shell alias -- so a non-interactive hook gets 127 and CoCo
    treats the statement as permitted. Requiring `python3` or an absolute
    path removes the trap regardless of who runs the tests and how.
    """
    settings = json.loads((ROOT / ".cortex" / "settings.json").read_text())
    for entry in settings["hooks"]["PreToolUse"]:
        for hook in entry["hooks"]:
            cmd = hook["command"]
            # The interpreter now sits inside an `sh -c` wrapper, so checking
            # only the first word would pass trivially and prove nothing.
            assert not re.search(r"(^|[\s;&|])python(?![0-9])", cmd), (
                f"hook invokes bare `python`: {cmd!r}\n"
                "Use `python3` or an absolute path. `python` is absent on many "
                "systems and, here, exists only as an interactive-shell alias, "
                "so a non-interactive hook gets 127 and the statement is "
                "silently permitted. (Windows: see README.)"
            )


def test_hook_resolves_from_a_subdirectory():
    """CoCo does not always run with the repo root as its working directory.

    The command was `python3 .cortex/hooks/run-guard.py` -- a relative path.
    Run from anywhere else the file is not found, python exits non-zero, and
    CoCo cannot tell "the guard says block" from "the guard crashed", so it
    blocks every statement including SELECTs. That happened for real: a
    session started in a sibling worktree bricked itself, and the agent
    reported the guard as missing.

    The command now walks up from $PWD to find the guard, so it works from
    any directory inside the repo.
    """
    settings = json.loads((ROOT / ".cortex" / "settings.json").read_text())
    cmd = settings["hooks"]["PreToolUse"][0]["hooks"][0]["command"]

    venv = os.environ.get("VIRTUAL_ENV")
    uv_cache = str(pathlib.Path.home() / ".cache" / "uv")
    env = {k: v for k, v in os.environ.items() if k != "VIRTUAL_ENV"}
    env["PATH"] = os.pathsep.join(
        d for d in env.get("PATH", "").split(os.pathsep)
        if ".venv" not in d and not d.startswith(uv_cache)
        and not (venv and d.startswith(venv))
    )

    def run(sql, cwd):
        return subprocess.run(
            cmd, shell=True, cwd=cwd, env=env, capture_output=True, text=True,
            input=json.dumps({"tool_name": "sql_execute",
                              "tool_input": {"statement": sql}}),
        ).returncode

    for sub in ("sql", "tests", ".cortex/hooks"):
        d = ROOT / sub
        if not d.is_dir():
            continue
        assert run("DELETE FROM AUDIT.EVIDENCE_CHAIN", d) == BLOCK, \
            f"destructive statement not blocked when run from {sub}/"
        assert run("SELECT * FROM AUDIT.EVIDENCE_PACK", d) == ALLOW, \
            f"harmless SELECT wrongly blocked when run from {sub}/"
