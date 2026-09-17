# 19_semantic_view_and_agent.sql results

## Errors

None.

## Statement 1 — CREATE VIEW CORE.V_CASE_LEDGER

View created successfully.

## Statement 2 — GRANT SELECT ON VIEW CORE.V_CASE_LEDGER

Statement executed successfully.

## Statement 3 — CREATE SEMANTIC VIEW CORE.CASE_ANALYTICS

Semantic view created successfully.

## Statement 4 — GRANT SELECT ON SEMANTIC VIEW CORE.CASE_ANALYTICS

Statement executed successfully.

## Statement 5 — CREATE TABLE POLICY.POLICY_DOCUMENTS

Table created successfully.

## Statement 6 — INSERT INTO POLICY.POLICY_DOCUMENTS

8 rows inserted.

## Statement 7 — CREATE CORTEX SEARCH SERVICE POLICY.POLICY_SEARCH

Cortex search service created successfully.

## Statement 8 — GRANT USAGE ON CORTEX SEARCH SERVICE POLICY.POLICY_SEARCH

Statement executed successfully.

## Statement 9 — CREATE AGENT CORE.TRACE_COPILOT

Agent created successfully.

## Statement 10 — GRANT USAGE ON AGENT CORE.TRACE_COPILOT

Statement executed successfully.

## Statement 11 — SELECT COUNT(*) AS ledger_rows FROM CORE.V_CASE_LEDGER

| LEDGER_ROWS |
|-------------|
| 2759 |

## Statement 12 — SHOW SEMANTIC VIEWS IN SCHEMA CORE

| created_on | name | database_name | schema_name | comment | owner | owner_role_type | extension | max_staleness |
|---|---|---|---|---|---|---|---|---|
| 2026-09-17 10:37:52.708 -0700 | CASE_ANALYTICS | TRACE_DB | CORE | Governed vocabulary for the AML lookback. Contains no ground truth. | ACCOUNTADMIN | ROLE | ["AI"] | |

## Statement 13 — SHOW CORTEX SEARCH SERVICES IN SCHEMA POLICY

| created_on | name | database_name | schema_name | target_lag | warehouse | search_column | attribute_columns | source_data_num_rows | indexing_state | serving_state | embedding_model | comment |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 2026-09-17 10:38:39.293 -0700 | POLICY_SEARCH | TRACE_DB | POLICY | 365 days | COMPUTE_WH | RAW_TEXT | DOC_ID,TITLE,ISSUER,PARA_ANCHOR | 8 | ACTIVE | ACTIVE | snowflake-arctic-embed-m-v1.5 | Internal AML policy corpus. Static: a long TARGET_LAG avoids needless refresh cost. |

## Statement 14 — SHOW AGENTS IN SCHEMA CORE

| created_on | name | database_name | schema_name | owner | comment | profile | is_secure |
|---|---|---|---|---|---|---|---|
| 2026-09-17 10:39:22.399 -0700 | TRACE_COPILOT | TRACE_DB | CORE | ACCOUNTADMIN | AML lookback copilot. Answers case questions over a governed semantic view and policy questions over the internal corpus. | {"display_name": "TRACE Copilot"} | false |

## Statement 15 — SEMANTIC_VIEW query (top 10 by total_exposure DESC)

| CASE_COUNT | TOTAL_EXPOSURE | BRANCH | BAND |
|------------|----------------|--------|------|
| 38 | 33924980.19 | T Nagar | ESCALATE |
| 40 | 35619768.34 | T Nagar | DEPRIORITISE |
| 89 | 79300567.05 | T Nagar | REVIEW |
| 168 | 148596085.01 | Surat Ring Road | DEPRIORITISE |
| 242 | 216862646.84 | Surat Ring Road | REVIEW |
| 139 | 124073488.40 | Surat Ring Road | ESCALATE |
| 121 | 108847398.91 | Salt Lake | DEPRIORITISE |
| 133 | 118748637.86 | Salt Lake | REVIEW |
| 52 | 46049860.42 | Salt Lake | ESCALATE |
| 38 | 33675118.13 | Koramangala | ESCALATE |
