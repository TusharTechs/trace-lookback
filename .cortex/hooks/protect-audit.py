#!/usr/bin/env python3
"""
PreToolUse guard: the AUDIT schema is append-only.

Evidence packs and their hash chain are what a bank would hand an examiner. A
hash chain proves tampering happened; it does not prevent it. This hook is the
prevention half — it refuses to let the agent issue any statement that could
modify or remove audit records, before the statement reaches Snowflake.

Blocked against AUDIT.*:  UPDATE, DELETE, MERGE, TRUNCATE, DROP, ALTER,
                          CREATE of any object, GRANT/REVOKE, and CALL of any
                          procedure not on CALL_ALLOWLIST
Allowed against AUDIT.*:  SELECT, INSERT, SHOW, DESCRIBE, and CALL of the two
                          append-only procedures

WHAT THIS DOES NOT COVER -- stated plainly, because a control whose boundary is
undocumented is worse than no control:

  1. It inspects the SQL text the agent submits, so a stored procedure is
     opaque to it -- `CALL X()` reveals nothing about what X does. That is why
     CREATE PROCEDURE and CREATE FUNCTION in AUDIT are refused: an agent that
     can mint a procedure can put an UPDATE inside it and then call it, which
     turns a documented limitation into a working bypass. New ones are a
     human operation in Snowsight.

     Blanket permission to call EXISTING procedures was the remaining half of
     that hole, and it was a real one: sql/27's tamper drill needs a procedure
     in AUDIT that deletes rows, created by a human in Snowsight, and once it
     existed the agent could simply CALL it. Calls into AUDIT are therefore
     allowlisted by procedure name. A human adding a procedure to AUDIT does
     not thereby hand the agent a new capability -- adding it here is a second,
     deliberate act.

     AUDIT.BUILD_EVIDENCE_CHAIN and AUDIT.RECORD_CASE_ACTION are INSERT-only,
     which is why they are on the list. Nothing in the schema requires an
     UPDATE, so no exception is carved out.
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
    r"|CREATE(\s+OR\s+REPLACE)?\s+(TABLE|VIEW|PROCEDURE|FUNCTION|TASK|STREAM)"
    r"|GRANT|REVOKE"
    r")\b",
    re.IGNORECASE,
)

# The only procedures in AUDIT the agent may call. Both append and nothing
# else. Anything a human creates in AUDIT is unreachable from the agent until
# it is added here on purpose.
CALL_ALLOWLIST = frozenset({"BUILD_EVIDENCE_CHAIN", "RECORD_CASE_ACTION"})

# CALL AUDIT.X(...), CALL TRACE_DB.AUDIT.X(...), CALL "AUDIT"."X"(...)
AUDIT_CALL = re.compile(
    r"\bCALL\s+(?:\"?[A-Z0-9_]+\"?\s*\.\s*)?"
    r"\"?" + AUDIT_SCHEMA + r"\"?\s*\.\s*\"?([A-Z0-9_]+)",
    re.IGNORECASE,
)

# AUDIT.OBJECT, TRACE_DB.AUDIT.OBJECT, "AUDIT"."OBJECT"
AUDIT_REF = re.compile(
    r"(?<![A-Z0-9_])\"?" + AUDIT_SCHEMA + r"\"?\s*\.\s*\"?[A-Z0-9_]+",
    re.IGNORECASE,
)


def strip_noise(sql: str) -> str:
    # A line comment ends at a real newline OR at a literal backslash-n, so an
    # already-escaped payload cannot hide a statement behind a comment.
    sql = re.sub(r"--(?:(?!\\n)[^\n])*", " ", sql)
    sql = re.sub(r"/\*.*?\*/", " ", sql, flags=re.S)
    sql = sql.replace("\\n", " ")
    return re.sub(r"\s+", " ", sql).strip()


def _strings(node):
    """Yield every string value anywhere in the payload."""
    if isinstance(node, str):
        yield node
    elif isinstance(node, dict):
        for v in node.values():
            yield from _strings(v)
    elif isinstance(node, (list, tuple)):
        for v in node:
            yield from _strings(v)


def extract_sql(payload: dict) -> str:
    """CoCo's sql_execute input schema is not documented here, so rather than
    guess a field name and silently miss the statement, collect every string in
    tool_input. Over-inclusive by design.

    This walks the structure instead of calling json.dumps, and that is a
    security fix rather than a style choice. Serialising escapes newlines into
    the two characters backslash-n, after which the comment-stripping regex
    `--[^\\n]*` finds no real newline to stop at and swallows the rest of the
    statement. A line comment followed by a newline therefore hid everything
    after it:

        -- routine
        DELETE FROM AUDIT.EVIDENCE_CHAIN

    was reported as safe. Caught by tests/test_hook.py::test_blocked."""
    ti = payload.get("tool_input", payload)
    if isinstance(ti, str):
        return ti
    return "\n".join(_strings(ti))


def offending_statements(sql: str):
    hits = []
    for stmt in strip_noise(sql).split(";"):
        stmt = stmt.strip()
        if not stmt:
            continue
        m = MUTATING.search(stmt)
        if m and AUDIT_REF.search(stmt):
            hits.append((m.group(0).upper(), stmt[:200]))
            continue
        c = AUDIT_CALL.search(stmt)
        if c and c.group(1).upper() not in CALL_ALLOWLIST:
            hits.append((f"CALL AUDIT.{c.group(1).upper()}", stmt[:200]))
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
        f"Permitted: SELECT, INSERT, and CALL of "
        f"{', '.join(sorted(CALL_ALLOWLIST))} -- the only procedures here that "
        f"exclusively append. To rebuild the chain use "
        f"CALL AUDIT.BUILD_EVIDENCE_CHAIN(), which only inserts."
    )

    print(json.dumps({"decision": "block", "reason": reason}))
    print(reason, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
