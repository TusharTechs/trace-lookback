-- ============================================================================
-- 14_evidence_packs.sql — regulator-facing evidence for escalated cases.
--
-- The adjudication produces a ranked list. A ranked list is not something a
-- bank can act on: an examiner asks WHY this case, WHAT rule applied at the
-- time, WHAT was visible then, and HOW DO I KNOW this record has not been
-- edited since. An evidence pack answers all four.
--
-- Each pack contains:
--   case        who, which week, how much
--   finding     the model's probability, band, and both sides of its reasoning
--   rule        the policy version in force AT THE TIME (as-was) and TODAY
--               (as-now), each with its citation -- resolved through
--               POLICY.POLICY_AS_OF, never hardcoded
--   why_missed  the arithmetic of the gap, stated explicitly
--   evidence    the point-in-time feature snapshot exactly as the model saw it
--   provenance  model, thresholds, run timestamp
--
-- Packs are built for the ESCALATE band only. Generating evidence for cases you
-- are not escalating is noise, and it is not what a lookback produces.
--
-- Two-stage by design: content first (independent per row, cannot fail
-- partially), chaining second. If the chain step fails the packs still exist.
-- ============================================================================

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE COMPUTE_WH;
USE DATABASE TRACE_DB;

-- ---------------------------------------------------------------------------
-- 1. Storage. Append-only by intent; the PreToolUse hook will enforce it.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE TABLE AUDIT.EVIDENCE_PACK (
    seq             NUMBER          AUTOINCREMENT START 1 INCREMENT 1,
    case_ref        STRING          NOT NULL,
    customer_id     STRING          NOT NULL,
    week_start      DATE            NOT NULL,
    p_suspicious    FLOAT,
    payload         VARIANT         NOT NULL,
    content_hash    STRING          NOT NULL,   -- SHA2 of the payload alone
    prev_chain_hash STRING,                     -- filled by the chaining pass
    chain_hash      STRING,
    built_at        TIMESTAMP_NTZ   DEFAULT CURRENT_TIMESTAMP()
);

-- ---------------------------------------------------------------------------
-- 2. Build. One pack per escalated customer-week.
--
-- Note the policy resolution: as-was comes from POLICY_AS_OF(week_end), as-now
-- from POLICY_AS_OF(current date). The two differ by one argument. That is the
-- entire replay, made auditable.
-- ---------------------------------------------------------------------------

INSERT INTO AUDIT.EVIDENCE_PACK
    (case_ref, customer_id, week_start, p_suspicious, payload, content_hash)
WITH cases AS (
    SELECT
        a.customer_id, a.week_start, a.aggregate_amount,
        a.p_suspicious, a.aggravating, a.mitigating, a.model_name, a.ran_at,
        pit.week_end,
        pit.txn_count, pit.avg_deposit, pit.occupation, pit.occupation_is_cash_trade,
        pit.declared_annual_income, pit.cash_vs_monthly_income, pit.risk_rating,
        pit.is_pep, pit.days_since_kyc, pit.prior_alert_count,
        pit.weeks_with_cash_activity_pct, pit.weekly_volatility,
        pit.deposits_just_under_round_pct, pit.distinct_branches_used,
        pit.outward_transfer_ratio, pit.weeks_since_cash_activity_began,
        pit.history_weeks_available,
        c.full_name, c.pan, c.branch_id
    FROM EVAL.ADJUDICATION a
    JOIN CORE.V_POINT_IN_TIME_FEATURES pit
      ON pit.customer_id = a.customer_id AND pit.week_start = a.week_start
    JOIN CORE.CUSTOMERS c ON c.customer_id = a.customer_id
    WHERE a.p_suspicious >= 0.60
), enriched AS (
    -- Temporal join rather than POLICY_AS_OF(). The UDF wraps a scalar subquery
    -- and Snowflake cannot evaluate it per-row against a column:
    --   "Unsupported subquery type cannot be evaluated inside Function object"
    -- It remains correct for interactive scalar use with a literal date. For
    -- set-based replay, joining the validity interval directly is both required
    -- and the more honest formulation -- the temporal predicate is visible in
    -- the query rather than hidden inside a function.
    --
    -- as-was: the version whose interval contains the window end.
    -- as-now: the version with no end date, i.e. currently in force.
    SELECT
        cs.*,
        pw.policy_version_id AS pv_as_was,
        pw.version_no        AS was_version,  pw.para_anchor    AS was_para,
        pw.effective_from    AS was_from,     pw.effective_to   AS was_to,
        pw.change_summary    AS was_summary,  rw.threshold_value AS was_threshold,
        pn.policy_version_id AS pv_as_now,
        pn.version_no        AS now_version,  pn.para_anchor    AS now_para,
        pn.effective_from    AS now_from,     pn.change_summary AS now_summary,
        rn.threshold_value   AS now_threshold
    FROM cases cs
    JOIN POLICY.POLICY_VERSIONS pw
      ON pw.policy_code = 'TM-STRUCT'
     AND pw.effective_from <= cs.week_end
     AND (pw.effective_to IS NULL OR pw.effective_to > cs.week_end)
    JOIN POLICY.RULE_PREDICATES rw ON rw.policy_version_id = pw.policy_version_id
    JOIN POLICY.POLICY_VERSIONS pn
      ON pn.policy_code = 'TM-STRUCT'
     AND pn.effective_to IS NULL
    JOIN POLICY.RULE_PREDICATES rn ON rn.policy_version_id = pn.policy_version_id
), packed AS (
    SELECT
        e.customer_id || '|' || TO_VARCHAR(e.week_start, 'YYYY-MM-DD') AS case_ref,
        e.customer_id, e.week_start, e.p_suspicious,
        OBJECT_CONSTRUCT(
            'case', OBJECT_CONSTRUCT(
                'case_ref',          e.customer_id || '|' || TO_VARCHAR(e.week_start, 'YYYY-MM-DD'),
                'customer_id',       e.customer_id,
                'customer_name',     e.full_name,      -- masked for unprivileged roles
                'pan',               e.pan,            -- masked for unprivileged roles
                'branch_id',         e.branch_id,
                'window_start',      e.week_start,
                'window_end',        e.week_end,
                'aggregate_cash',    e.aggregate_amount,
                'deposit_count',     e.txn_count
            ),
            'finding', OBJECT_CONSTRUCT(
                'probability_suspicious', e.p_suspicious,
                'band',                   'ESCALATE',
                'strongest_aggravating',  e.aggravating,
                'strongest_mitigating',   e.mitigating
            ),
            'rule_as_was', OBJECT_CONSTRUCT(
                'policy_version_id', e.pv_as_was,
                'version_no',        e.was_version,
                'threshold_inr',     e.was_threshold,
                'effective_from',    e.was_from,
                'effective_to',      e.was_to,
                'citation',          e.was_para,
                'change_summary',    e.was_summary
            ),
            'rule_as_now', OBJECT_CONSTRUCT(
                'policy_version_id', e.pv_as_now,
                'version_no',        e.now_version,
                'threshold_inr',     e.now_threshold,
                'effective_from',    e.now_from,
                'citation',          e.now_para,
                'change_summary',    e.now_summary
            ),
            'why_no_alert_was_raised', OBJECT_CONSTRUCT(
                'aggregate_cash',        e.aggregate_amount,
                'threshold_then',        e.was_threshold,
                'threshold_now',         e.now_threshold,
                'shortfall_against_then', e.was_threshold - e.aggregate_amount,
                'excess_over_now',        e.aggregate_amount - e.now_threshold,
                'explanation',
                    'Aggregate cash of INR ' || TO_VARCHAR(e.aggregate_amount, '999,999,999')
                 || ' fell below the threshold of INR ' || TO_VARCHAR(e.was_threshold, '999,999,999')
                 || ' in force under ' || e.pv_as_was || ', so no alert was generated and no '
                 || 'disposition exists. Under ' || e.pv_as_now || ' (threshold INR '
                 || TO_VARCHAR(e.now_threshold, '999,999,999') || ') the same activity would alert.'
            ),
            'evidence_as_of_window_end', OBJECT_CONSTRUCT(
                'occupation',                    e.occupation,
                'occupation_is_cash_trade',      e.occupation_is_cash_trade,
                'declared_annual_income',        e.declared_annual_income,
                'cash_vs_monthly_income',        e.cash_vs_monthly_income,
                'avg_deposit',                   e.avg_deposit,
                'deposits_just_under_round_pct', e.deposits_just_under_round_pct,
                'weeks_with_cash_activity_pct',  e.weeks_with_cash_activity_pct,
                'weekly_volatility',             e.weekly_volatility,
                'weeks_since_cash_began',        e.weeks_since_cash_activity_began,
                'outward_transfer_ratio',        e.outward_transfer_ratio,
                'distinct_branches_used',        e.distinct_branches_used,
                'risk_rating',                   e.risk_rating,
                'is_pep',                        e.is_pep,
                'days_since_kyc',                e.days_since_kyc,
                'prior_alert_count',             e.prior_alert_count,
                'history_weeks_available',       e.history_weeks_available
            ),
            'provenance', OBJECT_CONSTRUCT(
                'adjudication_model',  e.model_name,
                'adjudicated_at',      e.ran_at,
                'review_threshold',    0.45,
                'escalate_threshold',  0.60,
                'feature_source',      'CORE.V_POINT_IN_TIME_FEATURES',
                'evidence_window_weeks', 26,
                'note', 'Rolling features computed over the 26 weeks strictly '
                     || 'preceding the window. Probabilities are model output; '
                     || 'the alert/no-alert determination is deterministic SQL.'
            )
        ) AS payload
    FROM enriched e
)
SELECT case_ref, customer_id, week_start, p_suspicious, payload,
       SHA2(TO_JSON(payload), 256) AS content_hash
FROM packed
ORDER BY p_suspicious DESC, customer_id, week_start;

SELECT COUNT(*) AS packs_built,
       COUNT(DISTINCT customer_id) AS customers,
       ROUND(MIN(p_suspicious), 2) AS min_p,
       ROUND(MAX(p_suspicious), 2) AS max_p
FROM AUDIT.EVIDENCE_PACK;

-- ---------------------------------------------------------------------------
-- 3. Chain. Each pack's hash incorporates the previous one, so removing,
--    reordering or editing any pack breaks every hash after it.
--
--    Done as a second pass over an existing table. In production the chain
--    would be extended at insert; here the whole set is built at once, which
--    is what a lookback does.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE PROCEDURE AUDIT.CHAIN_EVIDENCE_PACKS()
RETURNS STRING
LANGUAGE SQL
AS
$$
-- Snowflake Scripting will not resolve a cursor field (r.seq) inside embedded
-- SQL; values must pass through local variables and : bindings.
DECLARE
    prev STRING  DEFAULT 'GENESIS';
    cur  STRING;
    s    NUMBER;
    ch   STRING;
    n    INTEGER DEFAULT 0;
    c CURSOR FOR SELECT seq, content_hash FROM AUDIT.EVIDENCE_PACK ORDER BY seq;
BEGIN
    FOR r IN c DO
        s   := r.seq;
        ch  := r.content_hash;
        cur := SHA2(:prev || :ch, 256);
        UPDATE AUDIT.EVIDENCE_PACK
           SET prev_chain_hash = :prev, chain_hash = :cur
         WHERE seq = :s;
        prev := :cur;
        n := n + 1;
    END FOR;
    RETURN 'chained ' || n || ' packs, head=' || :prev;
END;
$$;

CALL AUDIT.CHAIN_EVIDENCE_PACKS();

-- ---------------------------------------------------------------------------
-- 4. Verification. Recomputes the chain from the payloads and reports any
--    pack whose stored hash disagrees. This is the query an examiner runs.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE VIEW AUDIT.V_CHAIN_VERIFICATION AS
SELECT
    p.seq,
    p.case_ref,
    SHA2(TO_JSON(p.payload), 256) = p.content_hash                           AS content_intact,
    COALESCE(LAG(p.chain_hash) OVER (ORDER BY p.seq), 'GENESIS')
        = p.prev_chain_hash                                                  AS link_intact,
    SHA2(p.prev_chain_hash || p.content_hash, 256) = p.chain_hash            AS hash_intact
FROM AUDIT.EVIDENCE_PACK p;

SELECT
    COUNT(*)                                                       AS packs,
    COALESCE(SUM(CASE WHEN content_intact THEN 0 ELSE 1 END), 0)   AS payload_tampered,
    COALESCE(SUM(CASE WHEN link_intact    THEN 0 ELSE 1 END), 0)   AS chain_broken,
    COALESCE(SUM(CASE WHEN hash_intact    THEN 0 ELSE 1 END), 0)   AS hash_mismatched,
    -- An empty table is not an intact chain; it is nothing to verify. Saying
    -- INTACT there would be a false assurance, which is the one thing an
    -- integrity check must never give.
    CASE WHEN COUNT(*) = 0 THEN 'EMPTY - NOTHING TO VERIFY'
         WHEN COALESCE(SUM(CASE WHEN content_intact AND link_intact AND hash_intact
                                THEN 0 ELSE 1 END), 0) = 0
         THEN 'INTACT' ELSE 'TAMPERED' END                         AS verdict
FROM AUDIT.V_CHAIN_VERIFICATION;

-- ---------------------------------------------------------------------------
-- 5. One rendered pack. This is what an investigator opens.
-- ---------------------------------------------------------------------------

SELECT
    seq,
    case_ref,
    ROUND(p_suspicious, 2)                              AS p,
    payload:case:customer_name::STRING                  AS customer_name,
    payload:case:pan::STRING                            AS pan,
    payload:why_no_alert_was_raised:explanation::STRING AS why_missed,
    payload:rule_as_was:policy_version_id::STRING       AS rule_then,
    payload:rule_as_was:citation::STRING                AS citation_then,
    payload:rule_as_now:policy_version_id::STRING       AS rule_now,
    payload:finding:strongest_aggravating::STRING       AS aggravating,
    payload:finding:strongest_mitigating::STRING        AS mitigating,
    LEFT(chain_hash, 16) || '...'                       AS chain_hash
FROM AUDIT.EVIDENCE_PACK
ORDER BY p_suspicious DESC, seq
LIMIT 1;

-- Full JSON of the same pack.
SELECT TO_JSON(payload) AS full_pack
FROM AUDIT.EVIDENCE_PACK
ORDER BY p_suspicious DESC, seq
LIMIT 1;

-- Portfolio view: what the escalation queue looks like as work.
SELECT
    COUNT(*)                                                  AS escalated_weeks,
    COUNT(DISTINCT customer_id)                               AS customers,
    ROUND(SUM(payload:case:aggregate_cash::FLOAT)/10000000, 1) AS notional_cr,
    ROUND(AVG(p_suspicious), 3)                               AS mean_p
FROM AUDIT.EVIDENCE_PACK;
