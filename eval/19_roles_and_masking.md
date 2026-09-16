# 19 — Roles and Masking

Results of running `sql/17_roles_and_masking.sql`.

---

## Section 1 — Role Creation and Grants

| Statement | Result |
|---|---|
| `CREATE ROLE IF NOT EXISTS TRACE_INVESTIGATOR` | Role TRACE_INVESTIGATOR successfully created. |
| `CREATE ROLE IF NOT EXISTS TRACE_PRIVILEGED` | Role TRACE_PRIVILEGED successfully created. |
| `GRANT USAGE ON DATABASE TRACE_DB TO ROLE TRACE_INVESTIGATOR` | Statement executed successfully. |
| `GRANT USAGE ON SCHEMA TRACE_DB.CORE TO ROLE TRACE_INVESTIGATOR` | Statement executed successfully. |
| `GRANT USAGE ON SCHEMA TRACE_DB.POLICY TO ROLE TRACE_INVESTIGATOR` | Statement executed successfully. |
| `GRANT USAGE ON SCHEMA TRACE_DB.AUDIT TO ROLE TRACE_INVESTIGATOR` | Statement executed successfully. |
| `GRANT USAGE ON WAREHOUSE COMPUTE_WH TO ROLE TRACE_INVESTIGATOR` | Statement executed successfully. |
| `GRANT SELECT ON ALL TABLES IN SCHEMA TRACE_DB.CORE TO ROLE TRACE_INVESTIGATOR` | Statement executed successfully. 6 objects affected. |
| `GRANT SELECT ON ALL VIEWS IN SCHEMA TRACE_DB.CORE TO ROLE TRACE_INVESTIGATOR` | Statement executed successfully. 5 objects affected. |
| `GRANT SELECT ON ALL TABLES IN SCHEMA TRACE_DB.POLICY TO ROLE TRACE_INVESTIGATOR` | Statement executed successfully. 3 objects affected. |
| `GRANT SELECT ON ALL TABLES IN SCHEMA TRACE_DB.AUDIT TO ROLE TRACE_INVESTIGATOR` | Statement executed successfully. 3 objects affected. |
| `GRANT SELECT ON ALL VIEWS IN SCHEMA TRACE_DB.AUDIT TO ROLE TRACE_INVESTIGATOR` | Statement executed successfully. 1 objects affected. |
| `GRANT INSERT ON TABLE TRACE_DB.AUDIT.AUDIT_LOG TO ROLE TRACE_INVESTIGATOR` | **ERROR (hook):** BLOCKED: GRANT against the AUDIT schema. AUDIT is append-only. It holds the evidence packs and hash chain that would be handed to an examiner; a record that can be edited is not evidence. Permitted: SELECT, INSERT, CALL. To rebuild the chain use CALL AUDIT.BUILD_EVIDENCE_CHAIN(), which only inserts. |
| `GRANT ROLE TRACE_INVESTIGATOR TO ROLE TRACE_PRIVILEGED` | Statement executed successfully. |
| `GRANT ROLE TRACE_PRIVILEGED TO ROLE ACCOUNTADMIN` | Statement executed successfully. |
| `SET me = CURRENT_USER()` | Statement executed successfully. |
| `GRANT ROLE TRACE_INVESTIGATOR TO USER IDENTIFIER($me)` | Statement executed successfully. |
| `GRANT ROLE TRACE_PRIVILEGED TO USER IDENTIFIER($me)` | Statement executed successfully. |

---

## Section 2 — Masking Policies

| Statement | Result |
|---|---|
| `CREATE OR REPLACE MASKING POLICY TRACE_DB.PUBLIC.MASK_NAME` | Masking policy MASK_NAME successfully created. |
| `CREATE OR REPLACE MASKING POLICY TRACE_DB.PUBLIC.MASK_PAN` | Masking policy MASK_PAN successfully created. |
| `ALTER TABLE CORE.CUSTOMERS MODIFY COLUMN full_name SET MASKING POLICY TRACE_DB.PUBLIC.MASK_NAME` | Statement executed successfully. |
| `ALTER TABLE CORE.CUSTOMERS MODIFY COLUMN pan SET MASKING POLICY TRACE_DB.PUBLIC.MASK_PAN` | Statement executed successfully. |
| `ALTER TABLE CORE.CUSTOMERS MODIFY COLUMN date_of_birth SET MASKING POLICY TRACE_DB.PUBLIC.MASK_NAME` | **ERROR:** SQL compilation error: COLUMN data type DATE does not match with masking policy data type TEXT. |

---

## Section 3 — Render View

| Statement | Result |
|---|---|
| `CREATE OR REPLACE VIEW AUDIT.V_EVIDENCE_PACK_RENDER AS ...` | **ERROR (hook):** BLOCKED: CREATE OR REPLACE VIEW against the AUDIT schema. AUDIT is append-only. It holds the evidence packs and hash chain that would be handed to an examiner; a record that can be edited is not evidence. Permitted: SELECT, INSERT, CALL. To rebuild the chain use CALL AUDIT.BUILD_EVIDENCE_CHAIN(), which only inserts. |
| `GRANT SELECT ON VIEW AUDIT.V_EVIDENCE_PACK_RENDER TO ROLE TRACE_INVESTIGATOR` | Not executed (view does not exist). |

---

## Section 4 — Demonstration

### (a) Privileged: identity visible (ACCOUNTADMIN)

```
SELECT 'ACCOUNTADMIN' AS acting_role, case_ref, customer_name, customer_pan,
       p_suspicious, LEFT(chain_hash, 12) || '...' AS chain_hash
FROM AUDIT.V_EVIDENCE_PACK_RENDER
ORDER BY p_suspicious DESC, seq LIMIT 3;
```

**ERROR:** SQL compilation error: Object 'TRACE_DB.AUDIT.V_EVIDENCE_PACK_RENDER' does not exist or not authorized.

### (b) Investigator: same rows, identity redacted (TRACE_INVESTIGATOR)

```
USE ROLE TRACE_INVESTIGATOR;
```

**ERROR:** Role 'TRACE_INVESTIGATOR' is not permitted by the restricted session scope active on this session (allowed roles: [ACCOUNTADMIN]; blocked roles: []). Choose a role in the allowed set and not in the blocked set, or if you applied it, recreate a session with a new scope, or contact an account administrator if this was applied as part of admin managed policy.

```
SELECT 'TRACE_INVESTIGATOR' AS acting_role, case_ref, customer_name, customer_pan,
       p_suspicious, LEFT(chain_hash, 12) || '...' AS chain_hash
FROM AUDIT.V_EVIDENCE_PACK_RENDER
ORDER BY p_suspicious DESC, seq LIMIT 3;
```

**ERROR:** SQL compilation error: Object 'TRACE_DB.AUDIT.V_EVIDENCE_PACK_RENDER' does not exist or not authorized.

### (c) Investigator verifies the chain (ran as ACCOUNTADMIN due to role switch failure)

| LINKS_VISIBLE |
|---|
| 687 |

### (d) Investigator cannot read the answer key (EXPECTED FAILURE)

Query ran as ACCOUNTADMIN (role switch to TRACE_INVESTIGATOR failed), so it succeeded instead of failing:

| SHOULD_NOT_BE_READABLE |
|---|
| 4856 |

**Expected error (not triggered because session scope blocked USE ROLE TRACE_INVESTIGATOR):**
The script expects this query to fail with "Object does not exist or not authorized" when run as TRACE_INVESTIGATOR, since that role has no grants on EVAL.

### (e) Grant surface for TRACE_INVESTIGATOR

| created_on | privilege | granted_on | name | granted_to | grantee_name | grant_option | granted_by |
|---|---|---|---|---|---|---|---|
| 2026-09-16 11:48:44.271 -0700 | USAGE | DATABASE | TRACE_DB | ROLE | TRACE_INVESTIGATOR | false | ACCOUNTADMIN |
| 2026-09-16 11:48:46.082 -0700 | USAGE | SCHEMA | TRACE_DB.AUDIT | ROLE | TRACE_INVESTIGATOR | false | ACCOUNTADMIN |
| 2026-09-16 11:48:45.110 -0700 | USAGE | SCHEMA | TRACE_DB.CORE | ROLE | TRACE_INVESTIGATOR | false | ACCOUNTADMIN |
| 2026-09-16 11:48:45.575 -0700 | USAGE | SCHEMA | TRACE_DB.POLICY | ROLE | TRACE_INVESTIGATOR | false | ACCOUNTADMIN |
| 2026-09-16 11:49:00.835 -0700 | SELECT | TABLE | TRACE_DB.AUDIT.AUDIT_LOG | ROLE | TRACE_INVESTIGATOR | false | ACCOUNTADMIN |
| 2026-09-16 11:49:00.850 -0700 | SELECT | TABLE | TRACE_DB.AUDIT.EVIDENCE_CHAIN | ROLE | TRACE_INVESTIGATOR | false | ACCOUNTADMIN |
| 2026-09-16 11:49:00.869 -0700 | SELECT | TABLE | TRACE_DB.AUDIT.EVIDENCE_PACK | ROLE | TRACE_INVESTIGATOR | false | ACCOUNTADMIN |
| 2026-09-16 11:48:59.583 -0700 | SELECT | TABLE | TRACE_DB.CORE.ALERTS | ROLE | TRACE_INVESTIGATOR | false | ACCOUNTADMIN |
| 2026-09-16 11:48:59.598 -0700 | SELECT | TABLE | TRACE_DB.CORE.BRANCHES | ROLE | TRACE_INVESTIGATOR | false | ACCOUNTADMIN |
| 2026-09-16 11:48:59.609 -0700 | SELECT | TABLE | TRACE_DB.CORE.CUSTOMERS | ROLE | TRACE_INVESTIGATOR | false | ACCOUNTADMIN |
| 2026-09-16 11:48:59.631 -0700 | SELECT | TABLE | TRACE_DB.CORE.DECISION_FEATURES | ROLE | TRACE_INVESTIGATOR | false | ACCOUNTADMIN |
| 2026-09-16 11:48:59.657 -0700 | SELECT | TABLE | TRACE_DB.CORE.DISPOSITIONS | ROLE | TRACE_INVESTIGATOR | false | ACCOUNTADMIN |
| 2026-09-16 11:48:59.674 -0700 | SELECT | TABLE | TRACE_DB.CORE.TRANSACTIONS | ROLE | TRACE_INVESTIGATOR | false | ACCOUNTADMIN |
| 2026-09-16 11:48:59.556 -0700 | SELECT | TABLE | TRACE_DB.POLICY.POLICY_DOCUMENTS | ROLE | TRACE_INVESTIGATOR | false | ACCOUNTADMIN |
| 2026-09-16 11:48:59.572 -0700 | SELECT | TABLE | TRACE_DB.POLICY.POLICY_VERSIONS | ROLE | TRACE_INVESTIGATOR | false | ACCOUNTADMIN |
| 2026-09-16 11:48:59.584 -0700 | SELECT | TABLE | TRACE_DB.POLICY.RULE_PREDICATES | ROLE | TRACE_INVESTIGATOR | false | ACCOUNTADMIN |
| 2026-09-16 11:49:00.807 -0700 | SELECT | VIEW | TRACE_DB.AUDIT.V_CHAIN_VERIFICATION | ROLE | TRACE_INVESTIGATOR | false | ACCOUNTADMIN |
| 2026-09-16 11:49:01.194 -0700 | SELECT | VIEW | TRACE_DB.CORE.V_CUSTOMER_WEEK | ROLE | TRACE_INVESTIGATOR | false | ACCOUNTADMIN |
| 2026-09-16 11:49:01.214 -0700 | SELECT | VIEW | TRACE_DB.CORE.V_POINT_IN_TIME_FEATURES | ROLE | TRACE_INVESTIGATOR | false | ACCOUNTADMIN |
| 2026-09-16 11:49:01.235 -0700 | SELECT | VIEW | TRACE_DB.CORE.V_WEEKLY_ALERTS | ROLE | TRACE_INVESTIGATOR | false | ACCOUNTADMIN |
| 2026-09-16 11:49:01.262 -0700 | SELECT | VIEW | TRACE_DB.CORE.V_WEEKLY_CASH | ROLE | TRACE_INVESTIGATOR | false | ACCOUNTADMIN |
| 2026-09-16 11:49:01.278 -0700 | SELECT | VIEW | TRACE_DB.CORE.V_WEEKLY_OUTFLOW | ROLE | TRACE_INVESTIGATOR | false | ACCOUNTADMIN |
| 2026-09-16 11:48:46.514 -0700 | USAGE | WAREHOUSE | COMPUTE_WH | ROLE | TRACE_INVESTIGATOR | false | ACCOUNTADMIN |

No UPDATE or DELETE grants appear in this list.
