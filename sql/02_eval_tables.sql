-- ============================================================================
-- 02_eval_tables.sql
--
-- Additions to the EVAL schema that 01_foundation.sql did not anticipate.
-- Separate file so re-running does not wipe loaded data -- 01 uses
-- CREATE OR REPLACE throughout and is destructive by design.
--
-- Everything here is ground truth. The agent role must never be granted on
-- this schema: an accuracy number the agent could have read is not a number.
-- ============================================================================

USE DATABASE TRACE_DB;

-- Hidden truth. Only knowable because the corpus is synthetic.
-- Supports acc(model, truth) vs acc(human, truth); in production only
-- kappa(model, human) would be available.
CREATE OR REPLACE TABLE EVAL.GROUND_TRUTH (
    alert_id                STRING  NOT NULL PRIMARY KEY,
    is_truly_suspicious     BOOLEAN NOT NULL,
    archetype               STRING  NOT NULL,   -- CLEAN | CASH_BUSINESS | MULE | LAYERING
    ambiguity               FLOAT,              -- how hard the case honestly was
    reviewer_fatigue        FLOAT,              -- queue pressure on the reviewer that day
    p_correct               FLOAT               -- modelled P(reviewer got it right)
);

-- The defect population: customer-weeks that would have alerted under the
-- 8,00,000 threshold but did not, because PV-TM-STRUCT-002 had raised it to
-- 10,00,000. No alert, no disposition, no file. Unreachable by sampling.
--
-- Note the archetype mix: roughly 62% are legitimate cash businesses. The
-- band is not a proxy for guilt, which is precisely why re-applying the
-- threshold is not a solution and adjudication is required.
CREATE OR REPLACE TABLE EVAL.INVISIBLE_POPULATION (
    customer_id             STRING          NOT NULL,
    week_start              DATE            NOT NULL,
    week_end                DATE            NOT NULL,
    aggregate_amount        NUMBER(15,2)    NOT NULL,
    txn_count               NUMBER(10,0)    NOT NULL,
    archetype               STRING,
    is_truly_suspicious     BOOLEAN,
    PRIMARY KEY (customer_id, week_start)
);

-- Staging for DECISION_FEATURES. write_pandas cannot populate a VARIANT
-- column directly, so JSON lands here as text and is parsed on the way in.
CREATE OR REPLACE TABLE CORE.DECISION_FEATURES_STG (
    alert_id        STRING,
    captured_at     TIMESTAMP_NTZ,
    features        STRING,
    feature_hash    STRING
);
