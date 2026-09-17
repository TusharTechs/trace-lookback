-- ============================================================================
-- 19_semantic_view_and_agent.sql — the copilot.
--
-- The challenge is "Risk, Fraud and Regulatory Intelligence Copilot" and until
-- now there was no copilot: everything went through hand-written SQL.
--
-- Three pieces:
--
--   1. CORE.V_CASE_LEDGER    operational model output, without ground truth
--   2. CORE.CASE_ANALYTICS   a semantic view -- governed vocabulary, so a
--                            natural-language question resolves against
--                            definitions a human approved rather than against
--                            whatever SQL a model invents
--   3. TRACE_COPILOT         a Cortex Agent joining that semantic view to a
--                            Cortex Search service over the policy corpus
--
-- WHY THE LEDGER EXISTS
-- EVAL.ADJUDICATION holds probabilities and reasoning -- model OUTPUT, not
-- ground truth -- but it sits in the schema TRACE_INVESTIGATOR is barred from.
-- An investigator-facing agent built on it would be unusable by investigators.
-- A view owned by ACCOUNTADMIN runs with the owner's rights, so the ledger
-- exposes case data while GROUND_TRUTH and is_truly_suspicious stay sealed.
-- That is the pattern, not a workaround: curate what the operator needs, keep
-- the answer key out of reach.
-- ============================================================================

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE COMPUTE_WH;
USE DATABASE TRACE_DB;

-- ---------------------------------------------------------------------------
-- 1. The case ledger. Everything an investigator works from, nothing they
--    should not see. No is_truly_suspicious, no archetype, no evidence_score.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE VIEW CORE.V_CASE_LEDGER AS
SELECT
    a.customer_id || '|' || TO_VARCHAR(a.week_start, 'YYYY-MM-DD') AS case_ref,
    a.customer_id,
    a.week_start,
    DATEADD(day, 6, a.week_start)                       AS week_end,
    a.aggregate_amount,
    ROUND(a.p_suspicious, 3)                            AS p_suspicious,
    CASE WHEN a.p_suspicious >= 0.60 THEN 'ESCALATE'
         WHEN a.p_suspicious >= 0.45 THEN 'REVIEW'
         ELSE 'DEPRIORITISE' END                        AS triage_band,
    a.aggravating,
    a.mitigating,
    a.model_name,
    c.occupation,
    c.risk_rating,
    c.is_pep,
    c.declared_annual_income,
    c.branch_id,
    b.branch_name,
    b.city,
    b.state,
    b.region
FROM EVAL.ADJUDICATION a
JOIN CORE.CUSTOMERS c ON c.customer_id = a.customer_id
JOIN CORE.BRANCHES  b ON b.branch_id   = c.branch_id
WHERE a.p_suspicious IS NOT NULL;

GRANT SELECT ON VIEW CORE.V_CASE_LEDGER TO ROLE TRACE_INVESTIGATOR;

-- ---------------------------------------------------------------------------
-- 2. Semantic view.
--
--    This is what makes natural language GOVERNED rather than text-to-SQL
--    guesswork. "Exposure" means one thing here, defined once, and a question
--    asked twice returns the same number.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE SEMANTIC VIEW CORE.CASE_ANALYTICS

  TABLES (
    cases AS CORE.V_CASE_LEDGER
      PRIMARY KEY (case_ref)
      WITH SYNONYMS = ('cases', 'escalations', 'lookback cases', 'alerts')
      COMMENT = 'Customer-weeks recovered by the lookback and adjudicated. One row per case.',

    customers AS CORE.CUSTOMERS
      PRIMARY KEY (customer_id)
      WITH SYNONYMS = ('customers', 'account holders', 'clients')
      COMMENT = 'Retail banking customers. Name and PAN are masked by policy.',

    branches AS CORE.BRANCHES
      PRIMARY KEY (branch_id)
      WITH SYNONYMS = ('branches', 'locations')
      COMMENT = 'Branch network.'
  )

  RELATIONSHIPS (
    cases (customer_id) REFERENCES customers (customer_id),
    customers (branch_id) REFERENCES branches (branch_id)
  )

  FACTS (
    cases.cash_in_window AS aggregate_amount
      WITH SYNONYMS = ('cash', 'deposit value', 'amount')
      COMMENT = 'Aggregate cash credited in the seven-day window, in rupees.',
    cases.risk_probability AS p_suspicious
      WITH SYNONYMS = ('score', 'probability', 'risk score')
      COMMENT = 'Model-assigned probability the activity is laundering. NOT a finding of fact.'
  )

  DIMENSIONS (
    cases.week AS week_start
      WITH SYNONYMS = ('week', 'period')
      COMMENT = 'Monday of the seven-day window.',
    cases.band AS triage_band
      WITH SYNONYMS = ('band', 'triage', 'priority')
      COMMENT = 'ESCALATE >= 0.60, REVIEW 0.45-0.60, DEPRIORITISE < 0.45. Never "cleared".',
    customers.occupation AS occupation
      WITH SYNONYMS = ('job', 'profession', 'trade')
      COMMENT = 'Declared occupation.',
    customers.risk_rating AS risk_rating
      WITH SYNONYMS = ('kyc risk', 'customer risk')
      COMMENT = 'Internal KYC risk rating: LOW, MEDIUM or HIGH.',
    branches.branch AS branch_name
      WITH SYNONYMS = ('branch', 'office')
      COMMENT = 'Branch name.',
    branches.city AS city
      WITH SYNONYMS = ('city', 'location')
      COMMENT = 'Branch city.',
    branches.region AS region
      WITH SYNONYMS = ('region', 'zone')
      COMMENT = 'NORTH, SOUTH, EAST or WEST.'
  )

  METRICS (
    cases.case_count AS COUNT(cases.case_ref)
      WITH SYNONYMS = ('number of cases', 'how many')
      COMMENT = 'Count of adjudicated customer-weeks.',
    cases.total_exposure AS SUM(cases.cash_in_window)
      WITH SYNONYMS = ('exposure', 'total cash', 'notional')
      COMMENT = 'Total cash across matching cases, in rupees.',
    cases.mean_risk AS AVG(cases.risk_probability)
      WITH SYNONYMS = ('average score', 'mean probability')
      COMMENT = 'Mean model probability across matching cases.',
    cases.customers_affected AS COUNT(DISTINCT cases.customer_id)
      WITH SYNONYMS = ('customers', 'distinct customers')
      COMMENT = 'Distinct customers across matching cases.'
  )

  COMMENT = 'Governed vocabulary for the AML lookback. Contains no ground truth.'

  AI_SQL_GENERATION
    'Cases are customer-weeks that raised NO alert when they occurred; they were
     recovered by replaying the corrected threshold. Never describe a case as
     confirmed laundering. risk_probability is model output, so phrase results
     as "scored" or "ranked", never "is suspicious". Default to the ESCALATE
     band when a user asks about cases without qualifying, and say that you
     have done so.'
;

GRANT SELECT ON SEMANTIC VIEW CORE.CASE_ANALYTICS TO ROLE TRACE_INVESTIGATOR;

-- ---------------------------------------------------------------------------
-- 3. Policy corpus + Cortex Search.
--
--    The text below is the BANK'S OWN internal AML policy -- synthetic, written
--    for this project -- which cites RBI Master Direction paragraph numbers the
--    way a real internal policy would. No regulator text is reproduced.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE TABLE POLICY.POLICY_DOCUMENTS (
    doc_id       STRING NOT NULL,
    title        STRING NOT NULL,
    issuer       STRING NOT NULL,
    published_on DATE,
    para_anchor  STRING,
    source_url   STRING,
    raw_text     STRING
);

INSERT INTO POLICY.POLICY_DOCUMENTS
    (doc_id, title, issuer, published_on, para_anchor, raw_text)
VALUES
('AML-POL-001', 'Internal AML Policy — Cash Transaction Monitoring', 'INTERNAL', '2023-01-01', 'Para 4.2.1',
 'Aggregate cash credits to a single customer account exceeding the prescribed threshold within any rolling seven-day period shall generate a transaction monitoring alert under scenario TM-STRUCT-01. The threshold is set by the Financial Crime Committee and reviewed annually. Any change to the threshold requires a documented rationale, an impact assessment against the preceding twelve months of activity, and approval minuted by the Committee. Implements RBI Master Direction on KYC, cash reporting obligations.'),

('AML-POL-002', 'Internal AML Policy — Structuring Indicators', 'INTERNAL', '2023-01-01', 'Para 4.3',
 'Deposits arranged so that individual amounts fall below a reporting threshold, while the aggregate exceeds it, are treated as indicative of structuring. Relevant indicators include: deposits clustered immediately below round numbers; activity across multiple branches within a single window; cash volume disproportionate to declared income; and rapid onward transfer of deposited funds. No single indicator is determinative. Cash-intensive trades, including jewellers, petrol pump operators and transport operators, generate high cash volumes lawfully and shall not be escalated on volume alone.'),

('AML-POL-003', 'Internal AML Policy — Threshold Calibration and Validation', 'INTERNAL', '2024-04-01', 'Para 7.1',
 'Transaction monitoring thresholds shall be validated at least annually by a function independent of the first line. Validation shall include above-the-line and below-the-line testing to establish whether the threshold is set at a level that captures reportable activity. Where a threshold is found to have been mis-calibrated, a lookback shall be performed over the full period during which the incorrect threshold was in force. The lookback shall cover the entire affected population and not a sample where the population is machine-reconstructable.'),

('AML-POL-004', 'Internal AML Policy — Lookback Reviews', 'INTERNAL', '2024-04-01', 'Para 7.4',
 'A lookback review reconstructs decisions as they would have been made under the corrected control. Each reconstructed case shall record: the rule in force at the time of the activity, the rule in force at the time of review, the evidence available at the time of the original decision, and the reason no alert or disposition exists. Evidence shall be retained in a form that cannot be amended after creation. Corrections are made by appending a superseding record, never by editing an existing one.'),

('AML-POL-005', 'Internal AML Policy — Model-Assisted Adjudication', 'INTERNAL', '2026-02-01', 'Para 9.2',
 'Where a statistical or language model assists in adjudicating alerts, its output is advisory and shall be recorded as a probability rather than a determination. The operating threshold applied to that probability shall be selected by a human, documented, and re-selectable without re-running the model. Model agreement with human reviewers shall be measured on a held-out sample and published. The model shall not have access to any dataset used to evaluate it.'),

('AML-POL-006', 'Internal AML Policy — Suspicious Transaction Reporting', 'INTERNAL', '2023-01-01', 'Para 5.1',
 'Where review establishes reasonable grounds to suspect that funds are the proceeds of crime, a Suspicious Transaction Report shall be filed with FIU-IND within the prescribed period. The absence of a monitoring alert does not remove the reporting obligation where suspicion arises by other means, including a lookback review. Reports shall cite the evidence relied upon and the date on which suspicion was formed.'),

('AML-POL-007', 'Internal AML Policy — Customer Due Diligence Refresh', 'INTERNAL', '2023-01-01', 'Para 3.6',
 'Customer due diligence shall be refreshed periodically according to risk rating: high risk annually, medium risk every two years, low risk every five years. A significant change in transaction behaviour inconsistent with the customer profile shall trigger an out-of-cycle refresh irrespective of rating. Cash activity materially disproportionate to declared income constitutes such a change.'),

('AML-POL-008', 'Internal AML Policy — Evidence and Audit Trail', 'INTERNAL', '2024-04-01', 'Para 11.3',
 'Records supporting a regulatory decision shall be held in an append-only store. Each record shall carry a cryptographic hash of its contents, chained to the preceding record, so that alteration, deletion or reordering is detectable by recomputation. Access to identifying customer data within evidence records shall follow role-based entitlement; redaction of identity shall not alter the integrity hash.');

CREATE OR REPLACE CORTEX SEARCH SERVICE POLICY.POLICY_SEARCH
  ON raw_text
  ATTRIBUTES doc_id, title, para_anchor, issuer
  WAREHOUSE = COMPUTE_WH
  TARGET_LAG = '365 days'
  COMMENT = 'Internal AML policy corpus. Static: a long TARGET_LAG avoids needless refresh cost.'
  AS SELECT doc_id, title, issuer, para_anchor, raw_text FROM POLICY.POLICY_DOCUMENTS;

GRANT USAGE ON CORTEX SEARCH SERVICE POLICY.POLICY_SEARCH TO ROLE TRACE_INVESTIGATOR;

-- ---------------------------------------------------------------------------
-- 4. The agent.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE AGENT CORE.TRACE_COPILOT
  COMMENT = 'AML lookback copilot. Answers case questions over a governed semantic view and policy questions over the internal corpus.'
  PROFILE = '{"display_name": "TRACE Copilot"}'
  FROM SPECIFICATION
  $$
  models:
    orchestration: auto

  orchestration:
    capabilities:
      analytical_search: true
    tool_not_accessible: reject
    budget:
      seconds: 60
      tokens: 16000

  instructions:
    response: |
      You support investigators working an AML lookback. Be precise and brief.

      Every case here is a customer-week that raised NO alert when it happened.
      There is no file and no prior disposition. Say so when it is relevant --
      it is the reason the case exists.

      Risk probability is MODEL OUTPUT. Say "scored 0.78" or "ranked in the
      escalation band". Never "is money laundering" or "was found suspicious".

      Never state or imply whether a case is confirmed. You have no access to
      any confirmation and must not speculate about one.

      When you cite policy, give the paragraph anchor and the document title.
      When you report a number, say which metric produced it.

    orchestration: |
      Use CaseAnalytics for anything about cases, customers, branches, amounts,
      bands or counts. Use PolicySearch for questions about rules, obligations,
      thresholds, or what the policy requires. Many questions need both: answer
      the number from CaseAnalytics, then ground it in the policy paragraph.

      If a question asks whether a case is genuinely suspicious, explain that
      confirmation is not available to you and offer the evidence instead.

    sample_questions:
      - question: 'Which branches have the most escalated cases?'
      - question: 'What is the total exposure in the escalate band?'
      - question: 'What does our policy require after a threshold is found to be mis-calibrated?'
      - question: 'Show escalated cases for customers whose occupation is not a cash trade'

  tools:
    - tool_spec:
        type: 'cortex_analyst_text_to_sql'
        name: 'CaseAnalytics'
        description: 'Counts, exposure and breakdowns over adjudicated lookback cases, customers and branches. Contains no confirmation of whether a case is genuinely suspicious.'
    - tool_spec:
        type: 'cortex_search'
        name: 'PolicySearch'
        description: 'Internal AML policy: monitoring thresholds, structuring indicators, lookback obligations, evidence and reporting requirements.'

  tool_resources:
    CaseAnalytics:
      semantic_view: 'TRACE_DB.CORE.CASE_ANALYTICS'
    PolicySearch:
      search_service: 'TRACE_DB.POLICY.POLICY_SEARCH'
      max_results: '4'
      id_column: 'doc_id'
      title_column: 'title'
  $$;

GRANT USAGE ON AGENT CORE.TRACE_COPILOT TO ROLE TRACE_INVESTIGATOR;

-- ---------------------------------------------------------------------------
-- 5. Verify
-- ---------------------------------------------------------------------------

SELECT COUNT(*) AS ledger_rows FROM CORE.V_CASE_LEDGER;
SHOW SEMANTIC VIEWS IN SCHEMA CORE;
SHOW CORTEX SEARCH SERVICES IN SCHEMA POLICY;
SHOW AGENTS IN SCHEMA CORE;

-- The semantic view answers directly in SQL, without the agent.
SELECT * FROM SEMANTIC_VIEW(
    CORE.CASE_ANALYTICS
    METRICS cases.case_count, cases.total_exposure
    DIMENSIONS branches.branch, cases.band
) ORDER BY 3 DESC LIMIT 10;
