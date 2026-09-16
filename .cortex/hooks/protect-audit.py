#!/usr/bin/env python3
"""
PreToolUse guard: the AUDIT schema is append-only.

Evidence packs and their hash chain are what a bank would hand an examiner. A
hash chain proves tampering happened; it does not prevent it. This hook is the
prevention half — it refuses to let the agent issue any statement that could
modify or remove audit records, before the statement reaches Snowflake.

Blocked against AUDIT.*:  UPDATE, DELETE, MERGE, TRUNCATE, DROP, ALTER,
                          CREATE OR REPLACE, GRANT/REVOKE on audit objects
Allowed against AUDIT.*:  SELECT, INSERT, CALL, SHOW, DESCRIBE

WHAT THIS DOES NOT COVER -- stated plainly, because a control whose boundary is
undocumented is worse than no control:

  1. It inspects the SQL text the agent submits. A stored procedure can do
     anything server-side and this hook only sees `CALL X()`. AUDIT.BUILD_
     EVIDENCE_CHAIN is INSERT-only for exactly this reason; nothing in the
     schema requires an UPDATE, so no exception is carved out here.
  2. Snowflake's Restricted Session Scope covers the agent's SQL tool but not
     Bash, Python or MCP tools opening their own connection. This hook covers
     the same surface, so both share that gap. Closing it needs a Snowflake-side
     role that simply lacks UPDATE/DELETE on AUDIT -- which is the real control;
     this is defence in depth, not a substitute.
  3. Statement splitting is naive: semicolons inside string literals will split
     wrongly. That biases toward blocking, which is the safe direction.

Protocol: exit 0 allows, exit 2 blocks. A JSON decision is emitted on stdout and
the human-readable reason on stderr.
"""

import json
import re
import sys

AUDIT_SCHEMA = "AUDIT"

MUTATING = re.compile(
    r"\b("
    r"UPDATE"
    r"|DELETE\s+FROM"
    r"|MERGE\s+INTO"
    r"|TRUNCATE(\s+TABLE)?"
    r"|DROP\s+(TABLE|VIEW|SCHEMA|PROCEDURE|STAGE)"
    r"|ALTER\s+(TABLE|VIEW|SCHEMA)"
    r"|CREATE\s+OR\s+REPLACE\s+(TABLE|VIEW)"
    r"|GRANT|REVOKE"
    r")\b",
    re.IGNORECASE,
)

# AUDIT.OBJECT, TRACE_DB.AUDIT.OBJECT, "AUDIT"."OBJECT"
AUDIT_REF = re.compile(
    r"(?<![A-Z0-9_])\"?" + AUDIT_SCHEMA + r"\"?\s*\.\s*\"?[A-Z0-9_]+",
    re.IGNORECASE,
)


def strip_noise(sql: str) -> str:
    sql = re.sub(r"--[^\n]*", " ", sql)
    sql = re.sub(r"/\*.*?\*/", " ", sql, flags=re.S)
    return re.sub(r"\s+", " ", sql).strip()


def extract_sql(payload: dict) -> str:
    """CoCo's sql_execute input schema is not documented here, so rather than
    guess a field name and silently miss the statement, serialise the whole
    tool_input and scan it. Over-inclusive by design."""
    ti = payload.get("tool_input", payload)
    return ti if isinstance(ti, str) else json.dumps(ti)


def offending_statements(sql: str):
    hits = []
    for stmt in strip_noise(sql).split(";"):
        stmt = stmt.strip()
        if not stmt:
            continue
        m = MUTATING.search(stmt)
        if m and AUDIT_REF.search(stmt):
            hits.append((m.group(0).upper(), stmt[:200]))
    return hits


def main() -> int:
    try:
        payload = json.load(sys.stdin)
    except Exception:
        # Unparseable input must not silently disable the guard, but it also
        # must not brick the session on an unexpected payload shape.
        print(json.dumps({"decision": "allow"}))
        print("protect-audit: could not parse hook payload; allowing", file=sys.stderr)
        return 0

    sql = extract_sql(payload)
    hits = offending_statements(sql)

    if not hits:
        print(json.dumps({"decision": "allow"}))
        return 0

    verb, snippet = hits[0]
    reason = (
        f"BLOCKED: {verb} against the {AUDIT_SCHEMA} schema.\n"
        f"  {snippet}\n\n"
        f"{AUDIT_SCHEMA} is append-only. It holds the evidence packs and hash chain "
        f"that would be handed to an examiner; a record that can be edited is not "
        f"evidence.\n"
        f"Permitted: SELECT, INSERT, CALL. To rebuild the chain use "
        f"CALL AUDIT.BUILD_EVIDENCE_CHAIN(), which only inserts."
    )

    print(json.dumps({"decision": "block", "reason": reason}))
    print(reason, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
