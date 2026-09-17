-- ============================================================================
-- TRACE — Regulatory Lookback & Decision Replay Engine
-- 01_foundation.sql — bitemporal schema
--
-- Two time axes, kept strictly separate. Conflating them is the single most
-- common way decision-replay systems produce indefensible results:
--
--   event_time      when something happened in the world
--                   (TRANSACTIONS.txn_ts, ALERTS.generated_at)
--   knowledge_time  when we learned it or acted on it
--                   (DECISION_FEATURES.captured_at, DISPOSITIONS.disposed_at)
--
-- Policy carries its own validity interval (effective_from / effective_to).
-- A replay joins a decision to the policy version valid at its event_time
-- (as-was) and to the version valid today (as-now). We never reconstruct a
-- feature after the fact -- DECISION_FEATURES is the frozen snapshot, and it
-- is the reason this holds up under examination.
--
-- Deliberately NOT using Time Travel: retention is 1-90 days and our lookback
-- window is three years.
-- ============================================================================

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE COMPUTE_WH;
USE DATABASE TRACE_DB;

CREATE SCHEMA IF NOT EXISTS CORE    COMMENT = 'Operational: customers, transactions, alerts, dispositions';
CREATE SCHEMA IF NOT EXISTS POLICY  COMMENT = 'Versioned policy documents and compiled rule predicates';
CREATE SCHEMA IF NOT EXISTS EVAL    COMMENT = 'Ground truth and golden cases. Never readable by the agent role.';
CREATE SCHEMA IF NOT EXISTS AUDIT   COMMENT = 'Append-only, hash-chained evidence log';

-- ============================================================================
-- CORE
-- ============================================================================

CREATE OR REPLACE TABLE CORE.BRANCHES (
    branch_id       STRING        NOT NULL PRIMARY KEY,
    branch_name     STRING        NOT NULL,
    city            STRING        NOT NULL,
    state           STRING        NOT NULL,
    region          STRING        NOT NULL,   -- NORTH | SOUTH | EAST | WEST
    opened_on       DATE          NOT NULL
);

CREATE OR REPLACE TABLE CORE.CUSTOMERS (
    customer_id             STRING      NOT NULL PRIMARY KEY,
    full_name               STRING      NOT NULL,   -- PII, masked
    pan                     STRING,                 -- PII, masked
    date_of_birth           DATE,                   -- PII, masked
    occupation              STRING,
    declared_annual_income  NUMBER(15,2),
    risk_rating             STRING,                 -- LOW | MEDIUM | HIGH
    is_pep                  BOOLEAN     DEFAULT FALSE,
    kyc_completed_on        DATE,
    branch_id               STRING      NOT NULL REFERENCES CORE.BRANCHES(branch_id),
    onboarded_on            DATE        NOT NULL
);

CREATE OR REPLACE TABLE CORE.TRANSACTIONS (
    txn_id              STRING          NOT NULL PRIMARY KEY,
    customer_id         STRING          NOT NULL REFERENCES CORE.CUSTOMERS(customer_id),
    txn_ts              TIMESTAMP_NTZ   NOT NULL,   -- EVENT TIME
    value_date          DATE            NOT NULL,
    amount              NUMBER(15,2)    NOT NULL,
    direction           STRING          NOT NULL,   -- CR | DR
    mode                STRING          NOT NULL,   -- CASH | NEFT | RTGS | UPI | IMPS
    channel             STRING,                     -- BRANCH | ATM | ONLINE | MOBILE
    counterparty_name   STRING,
    counterparty_bank   STRING,
    branch_id           STRING          REFERENCES CORE.BRANCHES(branch_id)
);

-- One row per alert raised by a monitoring scenario.
-- policy_version_id records which rule version was in force when it fired --
-- this is what makes "as-was" reconstructable without inference.
CREATE OR REPLACE TABLE CORE.ALERTS (
    alert_id            STRING          NOT NULL PRIMARY KEY,
    scenario_code       STRING          NOT NULL,   -- e.g. TM-STRUCT-01
    customer_id         STRING          NOT NULL REFERENCES CORE.CUSTOMERS(customer_id),
    generated_at        TIMESTAMP_NTZ   NOT NULL,   -- EVENT TIME
    window_start        DATE            NOT NULL,
    window_end          DATE            NOT NULL,
    aggregate_amount    NUMBER(15,2)    NOT NULL,
    txn_count           NUMBER(10,0)    NOT NULL,
    policy_version_id   STRING          NOT NULL,   -- version in force at generated_at
    branch_id           STRING          REFERENCES CORE.BRANCHES(branch_id)
);

-- The frozen evidence. Whatever the reviewer could see at decision time and
-- nothing else. Never recomputed; recomputing it would silently import
-- knowledge the reviewer did not have, which is exactly the failure mode a
-- regulator looks for.
CREATE OR REPLACE TABLE CORE.DECISION_FEATURES (
    alert_id        STRING          NOT NULL PRIMARY KEY REFERENCES CORE.ALERTS(alert_id),
    captured_at     TIMESTAMP_NTZ   NOT NULL,   -- KNOWLEDGE TIME
    features        VARIANT         NOT NULL,
    feature_hash    STRING          NOT NULL
);

-- Human adjudications. This is the ground truth the model is calibrated
-- against, so the realism of its inconsistency matters more than its accuracy.
CREATE OR REPLACE TABLE CORE.DISPOSITIONS (
    disposition_id              STRING          NOT NULL PRIMARY KEY,
    alert_id                    STRING          NOT NULL REFERENCES CORE.ALERTS(alert_id),
    reviewer_id                 STRING          NOT NULL,
    disposed_at                 TIMESTAMP_NTZ   NOT NULL,   -- KNOWLEDGE TIME
    outcome                     STRING          NOT NULL,   -- CLOSED_FP | ESCALATED | STR_FILED
    rationale                   STRING,
    review_minutes              NUMBER(6,1),
    reviewer_experience_months  NUMBER(5,0),
    was_qa_reviewed             BOOLEAN         DEFAULT FALSE
);

-- ============================================================================
-- POLICY
-- ============================================================================

CREATE OR REPLACE TABLE POLICY.POLICY_DOCUMENTS (
    doc_id          STRING      NOT NULL PRIMARY KEY,
    title           STRING      NOT NULL,
    issuer          STRING      NOT NULL,   -- RBI | FIU-IND | INTERNAL
    published_on    DATE        NOT NULL,
    source_url      STRING,
    raw_text        STRING
);

-- Bitemporal spine. effective_to IS NULL means "currently in force".
-- Versions are immutable: a changed threshold creates a new row, never an
-- UPDATE. Rewriting a version would relabel history.
CREATE OR REPLACE TABLE POLICY.POLICY_VERSIONS (
    policy_version_id   STRING      NOT NULL PRIMARY KEY,
    policy_code         STRING      NOT NULL,   -- e.g. TM-STRUCT
    version_no          NUMBER(4,0) NOT NULL,
    effective_from      DATE        NOT NULL,
    effective_to        DATE,                   -- NULL = in force
    doc_id              STRING      REFERENCES POLICY.POLICY_DOCUMENTS(doc_id),
    para_anchor         STRING,                 -- cited paragraph, e.g. "Para 4.2.1"
    change_summary      STRING,
    superseded_by       STRING
);

-- Machine-checkable predicates compiled from policy text.
-- The LLM proposes these; a human certifies them; deterministic SQL executes
-- them. certified_by NULL means the predicate is a candidate and must not be
-- used in a replay.
CREATE OR REPLACE TABLE POLICY.RULE_PREDICATES (
    predicate_id            STRING          NOT NULL PRIMARY KEY,
    policy_version_id       STRING          NOT NULL REFERENCES POLICY.POLICY_VERSIONS(policy_version_id),
    scenario_code           STRING          NOT NULL,
    subject                 STRING          NOT NULL,   -- e.g. aggregate_cash_credit
    field                   STRING          NOT NULL,
    operator                STRING          NOT NULL,   -- >= | > | <= | < | =
    threshold_value         NUMBER(18,2)    NOT NULL,
    threshold_unit          STRING,                     -- INR | COUNT | DAYS
    window_days             NUMBER(5,0),
    scope_filter            STRING,                     -- optional SQL-safe scope
    source_para             STRING,
    extraction_confidence   FLOAT,                      -- model confidence at proposal
    certified_by            STRING,                     -- NULL until a human signs off
    certified_at            TIMESTAMP_NTZ
);

-- ============================================================================
-- AUDIT — append-only, hash-chained
-- ============================================================================

-- link_no is assigned by AUDIT.RECORD_CASE_ACTION, deliberately NOT by
-- AUTOINCREMENT. Snowflake allocates autoincrement values in per-session
-- ranges and does not guarantee they follow insertion order; an earlier
-- version of this table used one as the chain's ordering key and forked the
-- chain the first time two sessions appended to it. See sql/26.
--
-- event_ts has no DEFAULT for the same class of reason: the procedure reads
-- the clock once and writes that same value into both the hash and this
-- column, so the hash can be recomputed from the stored row by anyone.
CREATE OR REPLACE TABLE AUDIT.AUDIT_LOG (
    link_no     NUMBER          NOT NULL,
    event_ts    TIMESTAMP_NTZ   NOT NULL,
    actor       STRING          NOT NULL,
    action      STRING          NOT NULL,
    object_ref  STRING,
    payload     VARIANT,
    prev_hash   STRING          NOT NULL,
    row_hash    STRING          NOT NULL
);

-- ============================================================================
-- EVAL — ground truth. Isolated so the agent cannot read the answer key.
-- ============================================================================

CREATE OR REPLACE TABLE EVAL.CALIBRATION_SET (
    alert_id        STRING  NOT NULL PRIMARY KEY REFERENCES CORE.ALERTS(alert_id),
    human_outcome   STRING  NOT NULL,
    split           STRING  NOT NULL   -- CALIBRATION | HOLDOUT
);

CREATE OR REPLACE TABLE EVAL.GOLDEN_CASES (
    case_id             STRING  NOT NULL PRIMARY KEY,
    alert_id            STRING  NOT NULL REFERENCES CORE.ALERTS(alert_id),
    expected_as_was     STRING  NOT NULL,
    expected_as_now     STRING  NOT NULL,
    notes               STRING
);

-- ============================================================================
-- Point-in-time policy resolution. Every replay goes through this.
-- ============================================================================

CREATE OR REPLACE FUNCTION POLICY.POLICY_AS_OF(p_policy_code STRING, p_at DATE)
RETURNS STRING
AS
$$
    SELECT policy_version_id
    FROM TRACE_DB.POLICY.POLICY_VERSIONS
    WHERE policy_code = p_policy_code
      AND effective_from <= p_at
      AND (effective_to IS NULL OR effective_to > p_at)
    ORDER BY version_no DESC
    LIMIT 1
$$;

SHOW SCHEMAS IN DATABASE TRACE_DB;
