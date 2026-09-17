"""
TRACE — Streamlit in Snowflake.

The investigator-facing surface. Deliberately not a dashboard: it walks the
argument in the order the argument is made.

  1. The gap        activity that raised no alert and has no file
  2. Replay         any candidate rule, recomputed over the full record
  3. The queue      what the lookback produced, as work
  4. A case         one evidence pack, with the rule then and now
  5. Provenance     where the rule came from, and who signed for it
  6. Integrity      the chain, verified rather than asserted
  7. Evaluation     how well it worked -- requires privileged access, by design

Runs entirely inside Snowflake. No data leaves the account; there is no
external service and no API key.
"""

import streamlit as st

st.set_page_config(page_title="TRACE", page_icon="🔍", layout="wide")


def _session():
    """Snowsight Workspaces hands out a session via st.connection; a deployed
    Streamlit-in-Snowflake object exposes get_active_session. Support both so
    the same file runs in either place."""
    try:
        from snowflake.snowpark.context import get_active_session
        return get_active_session()
    except Exception:
        return st.connection("snowflake").session()


session = _session()


@st.cache_data(ttl=300)
def q(sql: str):
    return session.sql(sql).to_pandas()


def try_q(sql: str):
    """EVAL holds ground truth and most roles cannot read it. A failure here is
    the isolation working, not an outage, so it is reported as such."""
    try:
        return q(sql), None
    except Exception as e:
        return None, str(e)


ROLE = q("SELECT CURRENT_ROLE() AS r").iloc[0]["R"]

st.sidebar.title("TRACE")
st.sidebar.caption("Regulatory Lookback & Decision Replay")
page = st.sidebar.radio(
    "",
    ["1 · The gap", "2 · Replay any rule", "3 · Escalation queue",
     "4 · Evidence pack", "5 · Where the rule comes from",
     "6 · Chain integrity", "7 · Evaluation"],
    label_visibility="collapsed",
)
st.sidebar.divider()
st.sidebar.metric("Acting role", ROLE)
st.sidebar.caption(
    "Masking and row access follow the session role. The same screens viewed "
    "as TRACE_INVESTIGATOR redact customer name and PAN while leaving every "
    "hash unchanged."
)

# ---------------------------------------------------------------------------
# 1. The gap
# ---------------------------------------------------------------------------
if page.startswith("1"):
    st.title("Activity that raised no alert")
    st.markdown(
        "Between **1 July 2025 and 13 August 2026** the structuring threshold "
        "was raised from ₹8,00,000 to ₹10,00,000 as an alert-efficiency "
        "measure. It was reverted after a supervisory observation.\n\n"
        "Cash activity in the **₹8L–₹10L band** during those thirteen months "
        "generated **no alert, no disposition and no case file**. "
        "Below-the-line testing samples closed alerts and extrapolates — so "
        "when the gap produces no alerts at all, there is nothing in the "
        "sample frame. The method cannot see the problem it exists to find."
    )

    pol = q("""
        SELECT v.version_no, v.effective_from, v.effective_to,
               p.threshold_value AS threshold, v.change_summary
        FROM TRACE_DB.POLICY.POLICY_VERSIONS v
        JOIN TRACE_DB.POLICY.RULE_PREDICATES p USING (policy_version_id)
        ORDER BY v.version_no
    """)
    st.subheader("Policy timeline")
    st.dataframe(pol, use_container_width=True, hide_index=True)

    gap = q("""
        SELECT COUNT(*) AS weeks,
               ROUND(SUM(aggregate_amount)/10000000, 1) AS notional_cr,
               COUNT(DISTINCT customer_id) AS customers
        FROM TRACE_DB.EVAL.INVISIBLE_POPULATION
    """)
    c1, c2, c3 = st.columns(3)
    c1.metric("Customer-weeks with no alert", f"{int(gap.iloc[0]['WEEKS']):,}")
    c2.metric("Notional", f"₹{gap.iloc[0]['NOTIONAL_CR']} Cr")
    c3.metric("Distinct customers", f"{int(gap.iloc[0]['CUSTOMERS']):,}")

    st.info(
        "Deterministic SQL scans every transaction and reconstructs, for each "
        "customer-week, the evidence a reviewer would have seen. Cortex then "
        "adjudicates each one — inside Snowflake, next to the data.",
        icon="ℹ️",
    )

# ---------------------------------------------------------------------------
# 2. Counterfactual replay
# ---------------------------------------------------------------------------
elif page.startswith("2"):
    st.title("Replay any rule")
    st.markdown(
        "The case study is one policy change. The engine is general: give it "
        "any threshold and it reconstructs, across **607,307 transactions**, "
        "which customer-weeks that rule would have caught and which the bank "
        "actually alerted on.\n\n"
        "No model is involved. This is deterministic SQL, so a regulator can "
        "re-derive every number on this page."
    )

    thr = st.slider(
        "Candidate threshold (₹)",
        min_value=500_000, max_value=1_200_000, value=800_000, step=50_000,
        format="₹%d",
    )

    r = q(f"""
        SELECT * FROM TABLE(TRACE_DB.POLICY.REPLAY_SUMMARY(
            {thr}::FLOAT, '2025-07-01'::DATE, '2026-08-13'::DATE))
    """).iloc[0]

    c1, c2, c3, c4 = st.columns(4)
    c1.metric("Would be caught", f"{int(r['WOULD_CATCH']):,}")
    c2.metric("Actually alerted", f"{int(r['ALREADY_ALERTED']):,}")
    c3.metric("Never alerted", f"{int(r['NEWLY_CAPTURED']):,}",
              delta=f"{int(r['NEWLY_CAPTURED']):,} missed", delta_color="inverse")
    c4.metric("Unreviewed notional", f"₹{r['NEWLY_CAPTURED_CR']} Cr")

    if int(r["NEWLY_CAPTURED"]) == 0:
        st.success(
            "At ₹10,00,000 nothing is newly captured — that was the rule in "
            "force, so by definition it missed nothing relative to itself. "
            "Move the slider down and the cost of the calibration appears.",
            icon="✅",
        )
    else:
        st.error(
            f"**{int(r['NEWLY_CAPTURED']):,} customer-weeks** across "
            f"**{int(r['DISTINCT_CUSTOMERS'])} customers** would have alerted "
            f"under a ₹{thr:,} threshold and did not. No alert, no "
            f"disposition, no file — nothing for a sampling review to find.",
            icon="🚨",
        )

    st.subheader("The whole decision surface")
    curve = q("SELECT * FROM TRACE_DB.POLICY.V_THRESHOLD_SENSITIVITY")
    st.line_chart(curve.set_index("THRESHOLD")["NEWLY_CAPTURED"])
    st.dataframe(curve, use_container_width=True, hide_index=True, height=260)
    st.caption(
        "A threshold-tuning exercise produces this after weeks of consultant "
        "time on a sample of a few hundred alerts. Here it is computed over "
        "the full transaction record, in seconds, at every candidate value."
    )

# ---------------------------------------------------------------------------
# 3. Escalation queue
# ---------------------------------------------------------------------------
elif page.startswith("3"):
    st.title("The queue, as work")

    bands = q("""
        SELECT CASE WHEN p_suspicious >= 0.60 THEN '3 · Escalate (≥0.60)'
                    WHEN p_suspicious >= 0.45 THEN '2 · Review (0.45–0.60)'
                    ELSE '1 · Deprioritise (<0.45)' END AS band,
               COUNT(*) AS weeks,
               ROUND(SUM(aggregate_amount)/10000000, 1) AS notional_cr,
               COUNT(DISTINCT customer_id) AS customers
        FROM TRACE_DB.EVAL.ADJUDICATION
        WHERE p_suspicious IS NOT NULL
        GROUP BY 1 ORDER BY 1 DESC
    """)
    st.dataframe(bands, use_container_width=True, hide_index=True)
    st.caption(
        "The lowest band is *deprioritise*, never *clear*. It still contains "
        "genuinely suspicious weeks; it is a ranking, not a dismissal."
    )

    st.subheader("Escalated cases")
    cases = q("""
        SELECT case_ref, customer_id, week_start,
               payload:case:aggregate_cash::FLOAT AS aggregate_cash,
               ROUND(p_suspicious, 2) AS p,
               LEFT(content_hash, 12) || '…' AS content_hash
        FROM TRACE_DB.AUDIT.EVIDENCE_PACK
        ORDER BY p_suspicious DESC, seq
    """)
    st.dataframe(cases, use_container_width=True, hide_index=True, height=420)
    st.caption(
        f"{len(cases):,} evidence packs. Each carries the rule in force at the "
        "time and today, the arithmetic of why no alert fired, and a hash."
    )

# ---------------------------------------------------------------------------
# 4. Evidence pack
# ---------------------------------------------------------------------------
elif page.startswith("4"):
    st.title("One case")

    refs = q("""
        SELECT case_ref FROM TRACE_DB.AUDIT.EVIDENCE_PACK
        ORDER BY p_suspicious DESC, seq
    """)["CASE_REF"].tolist()
    ref = st.selectbox("Case", refs)

    pack = q(f"""
        SELECT * FROM TRACE_DB.AUDIT.V_EVIDENCE_PACK_RENDER
        WHERE case_ref = '{ref}'
    """).iloc[0]

    c1, c2, c3, c4 = st.columns(4)
    c1.metric("Probability suspicious", f"{pack['P_SUSPICIOUS']:.2f}")
    c2.metric("Cash in window", f"₹{pack['AGGREGATE_CASH']:,.0f}")
    c3.metric("Customer", pack["CUSTOMER_NAME"])
    c4.metric("PAN", pack["CUSTOMER_PAN"])
    if pack["CUSTOMER_NAME"] == "REDACTED":
        st.caption(
            "Identity is masked for this role. The content hash below is "
            "unchanged — a reviewer who cannot read the subject can still "
            "verify the record was not altered."
        )

    st.subheader("Why no alert was raised")
    st.warning(pack["WHY_NO_ALERT"], icon="⚠️")

    a, b = st.columns(2)
    a.markdown(f"**Rule then** · `{pack['RULE_THEN']}` · {pack['CITATION']}")
    a.metric("Threshold in force", f"₹{pack['THRESHOLD_THEN']:,.0f}")
    b.markdown(f"**Rule now** · `{pack['RULE_NOW']}`")
    b.metric("Threshold today", f"₹{pack['THRESHOLD_NOW']:,.0f}")

    st.subheader("Adjudication")
    st.markdown("**Strongest factor pointing to laundering**")
    st.error(pack["AGGRAVATING"], icon="🔺")
    st.markdown("**Strongest innocent explanation**")
    st.success(pack["MITIGATING"], icon="🔻")
    st.caption(
        "The model is required to argue both sides before scoring. The "
        "probability is model output; the alert/no-alert determination is "
        "deterministic SQL."
    )

    st.subheader("Evidence as of the window end")
    st.json(pack["EVIDENCE"], expanded=False)
    st.caption(
        "Reconstructed from the transaction record over the 26 weeks strictly "
        "preceding this one. Nothing the reviewer could not have seen."
    )

    st.code(f"content_hash  {pack['CONTENT_HASH']}\nchain_hash    {pack['CHAIN_HASH']}")

    # ---- Record a decision -------------------------------------------------
    st.divider()
    st.subheader("Record a decision")
    st.caption(
        "Appended to an immutable log and hash-chained. Nothing here can be "
        "edited afterwards — a decision made in error is corrected by "
        "recording a superseding one, the way a paper case file works."
    )

    history = try_q(f"""
        SELECT event_ts, actor, action, note
        FROM TRACE_DB.AUDIT.V_CASE_HISTORY
        WHERE case_ref = '{ref}' ORDER BY link_no
    """)[0]
    if history is not None and len(history):
        st.dataframe(history, use_container_width=True, hide_index=True)
    else:
        st.caption("_No actions recorded on this case yet._")

    c1, c2 = st.columns([1, 2])
    act = c1.selectbox("Action", ["ASSIGNED", "ESCALATED_TO_FIU",
                                  "REQUESTED_INFORMATION", "CLOSED_NO_ACTION",
                                  "SUPERSEDED"])
    note = c2.text_input("Note", placeholder="Reason for this decision")

    if st.button("Record", type="primary", disabled=not note.strip()):
        safe_note = note.replace("'", "''")
        who = q("SELECT CURRENT_USER() AS u").iloc[0]["U"]
        res, err = try_q(
            f"CALL TRACE_DB.AUDIT.RECORD_CASE_ACTION("
            f"'{ref}', '{who}', '{act}', '{safe_note}')")
        if err:
            st.error(err, icon="🚫")
        else:
            outcome = res.iloc[0, 0]
            (st.success if outcome.startswith("RECORDED") else st.warning)(
                outcome, icon="✅" if outcome.startswith("RECORDED") else "⚠️")
            st.cache_data.clear()
            st.rerun()

# ---------------------------------------------------------------------------
# 5. Where the rule comes from
# ---------------------------------------------------------------------------
elif page.startswith("5"):
    st.title("Where the rule comes from")
    st.markdown(
        "The thresholds this engine enforces are not typed in. They are "
        "extracted from the policy document by a model, **certified by a "
        "human**, and only then executed — by SQL, never by the model.\n\n"
        "The model reads prose, which is what models are good at. It never "
        "decides an outcome."
    )

    st.subheader("1 · What the model proposed")
    queue = q("""
        SELECT threshold_value, effective_from, effective_to, window_days,
               threshold_provenance, effective_to_provenance, source_quote
        FROM TRACE_DB.POLICY.V_CERTIFICATION_QUEUE
        ORDER BY effective_from
    """)
    st.dataframe(queue, use_container_width=True, hide_index=True)
    st.caption(
        "Each field is marked by whether the quoted sentence supports it. The "
        "model derived two `effective_to` dates from the following period's "
        "start — correct, but not stated in the document. A value read from "
        "the text and a value worked out are different things to a regulator, "
        "so the certifier sees which is which."
    )

    st.subheader("2 · Did it agree with the rule we enforce?")
    ver = q("""
        SELECT v.effective_from,
               r.threshold_value AS hand_declared,
               c.threshold_value AS extracted,
               CASE WHEN c.threshold_value IS NULL THEN 'NOT EXTRACTED'
                    WHEN r.threshold_value = c.threshold_value THEN 'MATCH'
                    ELSE 'DISAGREES' END AS verdict
        FROM TRACE_DB.POLICY.POLICY_VERSIONS v
        JOIN TRACE_DB.POLICY.RULE_PREDICATES r USING (policy_version_id)
        LEFT JOIN TRACE_DB.POLICY.CANDIDATE_PREDICATES c
               ON c.effective_from = v.effective_from
        ORDER BY 1
    """)
    st.dataframe(ver, use_container_width=True, hide_index=True)
    st.caption(
        "The compiler was never told the answer. It read the policy and "
        "independently reproduced all three thresholds the replay engine "
        "already enforced. A disagreement here would mean one of the two "
        "is wrong."
    )

    st.subheader("3 · What is actually enforceable")
    enf = q("SELECT COUNT(*) AS n FROM TRACE_DB.POLICY.V_ENFORCEABLE_PREDICATES")
    n_enf = int(enf.iloc[0]["N"])
    cert = q("""
        SELECT threshold_value, effective_from, certified_by,
               certification_still_valid
        FROM TRACE_DB.POLICY.V_CERTIFIED_PREDICATES ORDER BY effective_from
    """)

    if n_enf == 0 and len(cert):
        st.warning(
            "**Nothing is currently enforceable.** A predicate was certified, "
            "then the source document was amended. Nobody revoked the "
            "approval — it lapsed, because certification binds to a hash of "
            "the text rather than to a row. The rule cannot be enforced again "
            "until someone re-reads the amended policy and re-signs.",
            icon="🔒",
        )
    elif n_enf == 0:
        st.info("Nothing certified yet. The model proposed; nobody has signed.",
                icon="ℹ️")
    else:
        st.success(f"{n_enf} predicate(s) certified and enforceable.", icon="✅")

    if len(cert):
        st.dataframe(cert, use_container_width=True, hide_index=True)

    st.caption(
        "Approval attaches to a specific text, not to a database row. That is "
        "what a supervisor expects and what software almost never does."
    )

# ---------------------------------------------------------------------------
# 6. Chain integrity
# ---------------------------------------------------------------------------
elif page.startswith("6"):
    st.title("Integrity, verified not asserted")
    st.markdown(
        "Each pack's hash incorporates the previous one. Editing, removing or "
        "reordering any pack breaks every hash after it. The check below "
        "recomputes the chain from the payloads — it does not read a stored "
        "verdict."
    )

    if st.button("Verify chain", type="primary"):
        st.cache_data.clear()

    v = q("""
        SELECT (SELECT COUNT(*) FROM TRACE_DB.AUDIT.EVIDENCE_PACK)  AS packs,
               (SELECT COUNT(*) FROM TRACE_DB.AUDIT.EVIDENCE_CHAIN) AS links,
               COALESCE(SUM(CASE WHEN content_intact THEN 0 ELSE 1 END), 0) AS payload_tampered,
               COALESCE(SUM(CASE WHEN link_intact    THEN 0 ELSE 1 END), 0) AS chain_broken,
               COALESCE(SUM(CASE WHEN hash_intact    THEN 0 ELSE 1 END), 0) AS hash_mismatched,
               COALESCE(SUM(CASE WHEN pack_present   THEN 0 ELSE 1 END), 0) AS orphan_links
        FROM TRACE_DB.AUDIT.V_CHAIN_VERIFICATION
    """).iloc[0]

    ok = (v["PAYLOAD_TAMPERED"] == 0 and v["CHAIN_BROKEN"] == 0
          and v["HASH_MISMATCHED"] == 0 and v["ORPHAN_LINKS"] == 0
          and v["PACKS"] == v["LINKS"] and v["LINKS"] > 0)

    if ok:
        st.success(f"INTACT — {int(v['LINKS']):,} links verified", icon="✅")
    elif v["LINKS"] == 0:
        st.info("EMPTY — nothing to verify", icon="ℹ️")
    else:
        st.error("TAMPERED", icon="🚨")

    c = st.columns(4)
    c[0].metric("Payloads altered", int(v["PAYLOAD_TAMPERED"]))
    c[1].metric("Links broken", int(v["CHAIN_BROKEN"]))
    c[2].metric("Hashes mismatched", int(v["HASH_MISMATCHED"]))
    c[3].metric("Packs missing from chain", int(v["ORPHAN_LINKS"]))

    st.caption(
        "Four checks, not one. A chain that silently omits packs would pass a "
        "naive verification — that is the tamper a hash chain alone misses."
    )

    head = q("""
        SELECT chain_hash FROM TRACE_DB.AUDIT.EVIDENCE_CHAIN
        ORDER BY link_no DESC LIMIT 1
    """)
    if len(head):
        st.code(f"head of chain\n{head.iloc[0]['CHAIN_HASH']}")

    st.divider()
    st.subheader("Case action log")
    # The same view sql/27's tamper drills are judged by. If the app rolled the
    # verdict up itself there would be two definitions of "verified", and the
    # drills could pass against one while the app showed the other.
    al, al_err = try_q("""
        SELECT actions, broken_links AS broken, hash_mismatches AS mismatched,
               forked_rows AS forked
        FROM TRACE_DB.AUDIT.V_ACTION_LOG_VERDICT
    """)
    if al_err:
        st.caption("_Action log views not yet created — run sql/26 and sql/27 in Snowsight._")
    else:
        r = al.iloc[0]
        n = int(r["ACTIONS"])
        faults = {"broken links": int(r["BROKEN"]),
                  "hashes that do not recompute": int(r["MISMATCHED"]),
                  "rows sharing a predecessor": int(r["FORKED"])}
        bad = {k: v for k, v in faults.items() if v}
        if n and not bad:
            st.success(f"INTACT — {n} recorded actions, chain unbroken", icon="✅")
        elif not n:
            st.info("No actions recorded yet", icon="ℹ️")
        else:
            st.error("TAMPERED — " + ", ".join(f"{v} {k}" for k, v in bad.items()),
                     icon="🚨")
        st.caption(
            "Three checks, not one: each row links to its predecessor, each "
            "row's hash recomputes from what is stored, and no two rows claim "
            "the same predecessor. The second is what makes this verifiable "
            "by someone other than the code that wrote it; the third holds "
            "even if the ordering key is wrong, which is how the fork fixed "
            "in sql/26 was found."
        )

    # ---- Evidence that the detector detects --------------------------------
    st.divider()
    st.subheader("Was the detector ever tested?")
    st.markdown(
        "A verification that has only ever reported `INTACT` is "
        "indistinguishable from `SELECT 'INTACT'`. These are real attacks, "
        "run against the real action log as `ACCOUNTADMIN` — the strongest "
        "adversary this account has — and reseeded afterwards."
    )
    drills, d_err = try_q("""
        SELECT drill, attack, broken_links AS "broken links",
               hash_mismatches AS "hashes not recomputing",
               verdict, caught_by AS "caught by"
        FROM TRACE_DB.AUDIT.TAMPER_DRILL_LOG ORDER BY ord
    """)
    if d_err:
        st.caption("_Drill log not present — run sql/27 in Snowsight._")
    else:
        st.dataframe(drills, use_container_width=True, hide_index=True)
        st.caption(
            "The two middle rows are the point. A reworded decision changes "
            "nothing structural, so walking the chain reports it as fine. A "
            "deleted record leaves every surviving row hashing correctly, so "
            "recomputation reports it as fine. Each attack is invisible to "
            "the check that catches the other — which is why there are three."
        )
        st.info(
            "**What this does not prove.** Someone with ACCOUNTADMIN who also "
            "reads the source can append a *well-formed* forgery: the "
            "canonical string is public, so a correct hash can be computed. A "
            "hash chain makes the past tamper-evident, not the present "
            "unforgeable. Closing that needs the head hash published outside "
            "the account, or a signing key Snowflake never sees. Neither is "
            "built here.", icon="⚖️"
        )

    st.divider()
    st.markdown(
        "**The audit schema is append-only.** No role in this system holds "
        "`UPDATE` or `DELETE` on it, and a `PreToolUse` hook refuses those "
        "statements client-side before they reach Snowflake. Attempting the "
        "write as an investigator returns an access-control error from the "
        "database, not from the hook."
    )

# ---------------------------------------------------------------------------
# 7. Evaluation — needs EVAL, which most roles cannot read
# ---------------------------------------------------------------------------
else:
    st.title("How well it worked")

    df, err = try_q("""
        SELECT COUNT(*) AS n,
               SUM(CASE WHEN ip.is_truly_suspicious THEN 1 ELSE 0 END) AS dirty,
               ROUND(AVG(CASE WHEN (a.p_suspicious >= 0.45) = ip.is_truly_suspicious
                              THEN 1 ELSE 0 END), 3) AS accuracy,
               ROUND(AVG(CASE WHEN ip.is_truly_suspicious AND a.p_suspicious >= 0.45 THEN 1.0
                              WHEN ip.is_truly_suspicious THEN 0.0 END), 3) AS recall,
               ROUND(AVG(CASE WHEN a.p_suspicious >= 0.45 AND ip.is_truly_suspicious THEN 1.0
                              WHEN a.p_suspicious >= 0.45 THEN 0.0 END), 3) AS precision
        FROM TRACE_DB.EVAL.ADJUDICATION a
        JOIN TRACE_DB.EVAL.INVISIBLE_POPULATION ip
          ON ip.customer_id = a.customer_id AND ip.week_start = a.week_start
        WHERE a.p_suspicious IS NOT NULL
    """)

    if err:
        st.error(
            f"**{ROLE} cannot read TRACE_DB.EVAL.**\n\n"
            "This is the isolation working. Ground truth is held in a schema "
            "no adjudicating role has any grant on — an accuracy figure the "
            "scoring role could have read would not be a figure.\n\n"
            f"`{err.splitlines()[0]}`",
            icon="🔒",
        )
        st.stop()

    r = df.iloc[0]
    c = st.columns(4)
    c[0].metric("Weeks adjudicated", f"{int(r['N']):,}")
    c[1].metric("Genuinely suspicious", f"{int(r['DIRTY']):,}")
    c[2].metric("Recall @ 0.45", f"{r['RECALL']:.3f}")
    c[3].metric("Precision", f"{r['PRECISION']:.3f}")

    st.subheader("Yield against workload")
    lift = q("""
        WITH s AS (
            SELECT a.p_suspicious p,
                   CASE WHEN ip.is_truly_suspicious THEN 1 ELSE 0 END y
            FROM TRACE_DB.EVAL.ADJUDICATION a
            JOIN TRACE_DB.EVAL.INVISIBLE_POPULATION ip
              ON ip.customer_id = a.customer_id AND ip.week_start = a.week_start
            WHERE a.p_suspicious IS NOT NULL
        ), r AS (
            SELECT s.*, NTILE(10) OVER (ORDER BY p DESC) d, SUM(y) OVER () tot FROM s
        )
        SELECT d AS risk_decile, COUNT(*) AS weeks, SUM(y) AS dirty_found,
               ROUND(AVG(y), 3) AS hit_rate,
               ROUND(SUM(SUM(y)) OVER (ORDER BY d) / MAX(tot), 3) AS cumulative_recall
        FROM r GROUP BY d, tot ORDER BY d
    """)
    st.dataframe(lift, use_container_width=True, hide_index=True)
    st.bar_chart(lift.set_index("RISK_DECILE")["HIT_RATE"])

    st.caption(
        "Discrimination is modest — AUC 0.608 against an oracle ceiling of "
        "0.868 on this evidence. The head of the queue is materially richer "
        "than the population, which is what makes the work finite. Full "
        "method and limitations are in EVALUATION.md."
    )
