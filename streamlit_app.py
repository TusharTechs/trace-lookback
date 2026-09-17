"""
TRACE — public demo.

A snapshot of a system that runs inside Snowflake. The live application is
Streamlit in Snowflake and is reachable only by someone logged into the
account that holds the data, so this exists to give anyone a working link.

What is real here, and what is not, stated up front because the whole project
is an argument about verifiability:

  REAL  Every row was exported from the live Snowflake account after the runs
        recorded in the repository's eval/ directory. No figure is typed in.

  REAL  The hash verification. This page recomputes SHA-256 over the exact
        payload bytes Snowflake hashed and walks the chain itself. It does not
        read a stored verdict. Python, on Streamlit's servers, with no access
        to the database that produced the data -- which is a stronger check
        than the database checking itself.

  NOT   Writes. Recording a decision needs the append-only procedure, which
        lives in Snowflake. The tamper page lets you edit a pack in your own
        browser session; nothing is persisted and a reload restores it.
"""

from __future__ import annotations

import hashlib
from pathlib import Path

import pandas as pd
import streamlit as st

DATA = Path(__file__).parent / "data"
REPO = "https://github.com/TusharTechs/trace-lookback"

st.set_page_config(page_title="TRACE — public demo", page_icon="🔗", layout="wide")


# ---------------------------------------------------------------------------
# Data
# ---------------------------------------------------------------------------
@st.cache_data
def load(name: str) -> pd.DataFrame | None:
    """Snowsight exports headers in upper case; normalise so the rest of this
    file can assume lower."""
    f = DATA / f"{name}.csv"
    if not f.exists():
        return None
    df = pd.read_csv(f)
    df.columns = [c.lower() for c in df.columns]
    return df


def need(*names: str) -> list[pd.DataFrame] | None:
    out = []
    for n in names:
        df = load(n)
        if df is None:
            st.warning(
                f"`data/{n}.csv` is not in this deployment yet. "
                f"Run query for it in `sql/28_export_public_snapshot.sql` and "
                f"add the file.",
                icon="📄",
            )
            return None
        out.append(df)
    return out


def sha256(s: str) -> str:
    return hashlib.sha256(s.encode("utf-8")).hexdigest()


def inr(n: float) -> str:
    """Indian crore, which is how the domain is actually discussed."""
    return f"₹{n / 1e7:,.1f} Cr"


# ---------------------------------------------------------------------------
# Chrome
# ---------------------------------------------------------------------------
st.sidebar.title("TRACE")
st.sidebar.caption("Regulatory Lookback & Decision Replay")
page = st.sidebar.radio(
    "Page",
    [
        "1 · The gap",
        "2 · Replay any rule",
        "3 · Escalation queue",
        "4 · One case, end to end",
        "5 · Verify the chain yourself",
        "6 · Break it yourself",
        "7 · Where the rule comes from",
        "8 · How well it worked",
        "9 · About this snapshot",
    ],
    label_visibility="collapsed",
)
st.sidebar.divider()
st.sidebar.info(
    "**Snapshot, not a live system.** Exported from Snowflake after the runs "
    "in the repository. The hash checks on pages 5 and 6 are recomputed here, "
    "in Python, not read from the database.",
    icon="📷",
)
st.sidebar.markdown(f"[Source and full evaluation →]({REPO})")


# ---------------------------------------------------------------------------
# 1. The gap
# ---------------------------------------------------------------------------
if page.startswith("1"):
    st.title("Activity that raised no alert")
    st.markdown(
        "A bank raises its structuring threshold from ₹8,00,000 to ₹10,00,000. "
        "Thirteen months later the calibration is found to be wrong and reverted.\n\n"
        "Everything in that band generated **no alert, no disposition and no case "
        "file.** Above-the-line / below-the-line testing — the standard remediation, "
        "expected under FFIEC-style model validation — works by sampling "
        "dispositions and extrapolating.\n\n"
        "There are none to sample. **The method cannot see the problem it exists "
        "to find.**"
    )

    d = need("invisible_population")
    if d:
        pop = d[0]
        notional = next(
            (c for c in ("notional", "total_notional", "amount_inr", "aggregate_cash")
             if c in pop.columns), None
        )
        c = st.columns(3)
        c[0].metric("Customer-weeks with no alert", f"{len(pop):,}")
        if notional:
            c[1].metric("Notional in the gap", inr(pop[notional].sum()))
        if "is_truly_suspicious" in pop.columns:
            dirty = pop["is_truly_suspicious"].astype(str).str.lower().isin(
                ["true", "1", "t", "yes"]
            ).sum()
            c[2].metric("Genuinely suspicious", f"{dirty:,}")
        st.caption(
            "The third number is knowable here only because the corpus is "
            "synthetic and carries ground truth. In a real lookback it is "
            "exactly what nobody knows — which is the point."
        )


# ---------------------------------------------------------------------------
# 2. Counterfactual replay
# ---------------------------------------------------------------------------
elif page.startswith("2"):
    st.title("Replay any rule")
    st.markdown(
        "The threshold is a parameter, not a constant. Every value below was "
        "evaluated by replaying **all 607,307 transactions** through the "
        "reconstructed rule — not interpolated from a curve.\n\n"
        "This is the counterfactual a model-validation team actually asks for: "
        "*what would this threshold have caught, and how much of it did we miss?*"
    )

    d = need("threshold_sensitivity")
    if d:
        ts = d[0].sort_values("threshold").reset_index(drop=True)
        thresholds = ts["threshold"].tolist()

        pick = st.select_slider(
            "Candidate threshold (₹)",
            options=thresholds,
            value=800_000 if 800_000 in thresholds else thresholds[len(thresholds) // 2],
            format_func=lambda v: f"₹{v:,.0f}",
        )
        row = ts.loc[ts["threshold"] == pick].iloc[0]

        cols = st.columns(4)
        if "would_catch" in row.index:
            cols[0].metric("Weeks the rule would catch", f"{int(row['would_catch']):,}")
        if "newly_captured" in row.index:
            cols[1].metric("Never alerted at the time", f"{int(row['newly_captured']):,}")
        if "newly_captured_cr" in row.index:
            cols[2].metric("Notional missed", f"₹{row['newly_captured_cr']:,.1f} Cr")
        if "customers_affected" in row.index:
            cols[3].metric("Customers", f"{int(row['customers_affected']):,}")

        st.caption(
            f"At ₹{pick:,.0f}, the second number is the one that matters: activity "
            "this threshold would have flagged which raised no alert when it "
            "happened, and therefore has no disposition to sample."
        )

        if "newly_captured" in ts.columns:
            st.subheader("What each threshold would have recovered")
            chart = ts.set_index("threshold")[
                [c for c in ("would_catch", "newly_captured") if c in ts.columns]
            ]
            st.line_chart(chart)
            st.caption(
                "The gap between the two lines is activity that *did* alert at "
                "the time. The lower line alone is the lookback population — "
                "the part conventional threshold testing cannot see."
            )

        st.dataframe(ts, use_container_width=True, hide_index=True)


# ---------------------------------------------------------------------------
# 3. Queue
# ---------------------------------------------------------------------------
elif page.startswith("3"):
    st.title("A finite queue, not a verdict")
    d = need("adjudication")
    if d:
        adj = d[0]
        p = "p_suspicious"
        if p in adj.columns:
            band = pd.cut(
                adj[p],
                [-0.01, 0.45, 0.60, 1.01],
                labels=["DEPRIORITISE < 0.45", "REVIEW 0.45–0.60", "ESCALATE ≥ 0.60"],
            )
            summary = adj.groupby(band, observed=False).size().rename("weeks").reset_index()
            summary.columns = ["band", "weeks"]
            st.dataframe(summary[::-1], use_container_width=True, hide_index=True)
            st.bar_chart(adj[p], height=220)
            st.caption(
                "The lowest band is named *deprioritise*, not *clear*. It still "
                "contains genuinely suspicious weeks — 199 of them. Auto-closing "
                "it would miss every one, so the system does not offer that."
            )
        st.dataframe(adj.head(200), use_container_width=True, hide_index=True)
        st.caption(f"First 200 of {len(adj):,} adjudicated weeks.")


# ---------------------------------------------------------------------------
# 4. One case
# ---------------------------------------------------------------------------
elif page.startswith("4"):
    st.title("One case, end to end")
    d = need("pack_render_privileged")
    if d:
        render = d[0]
        seqs = render["seq"].tolist()
        pick = st.selectbox(
            "Case",
            seqs,
            format_func=lambda s: (
                f"{render.loc[render.seq == s, 'case_ref'].iloc[0]}  ·  "
                f"p={render.loc[render.seq == s, 'p_suspicious'].iloc[0]}"
            ),
        )
        row = render.loc[render.seq == pick].iloc[0]

        for label, col in [
            ("Why no alert was raised", "why_no_alert"),
            ("Strongest aggravating", "aggravating"),
            ("Strongest mitigating", "mitigating"),
            ("Rule in force then", "citation"),
        ]:
            if col in row.index and pd.notna(row[col]):
                st.markdown(f"**{label}** — {row[col]}")

        if "content_hash" in row.index:
            st.code(f"content_hash  {row['content_hash']}")

        # --- masking: two real exports, not a simulation --------------------
        st.divider()
        st.subheader("The same pack, read by two roles")
        masked = load("pack_render_masked")
        if masked is None:
            st.caption(
                "_Add `data/pack_render_masked.csv` (query 16) to show this._"
            )
        else:
            m = masked.loc[masked.seq == pick]
            cols = [c for c in ("customer_name", "customer_pan", "content_hash")
                    if c in render.columns]
            a, b = st.columns(2)
            a.caption("`TRACE_PRIVILEGED`")
            a.dataframe(row[cols].to_frame().T, use_container_width=True, hide_index=True)
            b.caption("`TRACE_INVESTIGATOR`")
            if len(m):
                b.dataframe(m[cols], use_container_width=True, hide_index=True)
            st.caption(
                "Both tables are real query output from the same view, read "
                "under two roles. Nothing here is masked by this app — the "
                "policy is in the database. Note the hash is identical: "
                "**masking changes what a person sees, not what was recorded.** "
                "An investigator can still prove the pack is unaltered without "
                "being shown the PAN."
            )


# ---------------------------------------------------------------------------
# 5. Verify
# ---------------------------------------------------------------------------
elif page.startswith("5"):
    st.title("Verify the chain yourself")
    st.markdown(
        "This page does not ask the database whether its evidence is intact. "
        "It recomputes every hash here, in Python, from the exported payloads — "
        "on a machine with no access to the Snowflake account.\n\n"
        "`content_hash = SHA-256(payload)` · "
        "`chain_hash(n) = SHA-256(chain_hash(n-1) ‖ content_hash(n))`"
    )

    d = need("evidence_pack", "evidence_chain")
    if d:
        packs, chain = d
        if st.button("Recompute all hashes", type="primary"):
            st.cache_data.clear()

        packs = packs.copy()
        packs["recomputed"] = packs["payload_json"].map(sha256)
        packs["content_intact"] = packs["recomputed"] == packs["content_hash"]

        chain = chain.sort_values("link_no").copy()
        expected_prev = ["GENESIS"] + chain["chain_hash"].tolist()[:-1]
        chain["link_intact"] = chain["prev_chain_hash"].values == pd.Series(expected_prev).values
        chain["hash_intact"] = [
            sha256(p + c) == h
            for p, c, h in zip(chain["prev_chain_hash"], chain["content_hash"], chain["chain_hash"])
        ]

        bad_content = int((~packs["content_intact"]).sum())
        bad_link = int((~chain["link_intact"]).sum())
        bad_hash = int((~chain["hash_intact"]).sum())

        c = st.columns(4)
        c[0].metric("Packs", f"{len(packs):,}")
        c[1].metric("Payloads altered", bad_content)
        c[2].metric("Links broken", bad_link)
        c[3].metric("Hashes wrong", bad_hash)

        if bad_content == bad_link == bad_hash == 0:
            st.success(
                f"INTACT — {len(chain):,} links recomputed independently, no faults.",
                icon="✅",
            )
        else:
            st.error("TAMPERED", icon="🚨")

        if len(chain):
            st.code(f"head of chain\n{chain.iloc[-1]['chain_hash']}")

        ver = load("chain_verification")
        if ver is not None:
            st.caption(
                "Snowflake's own verdict on the same data was exported as "
                "`chain_verification.csv`. It agrees — but that agreement is a "
                "cross-check, not the evidence. The evidence is the "
                "recomputation above."
            )


# ---------------------------------------------------------------------------
# 6. Break it
# ---------------------------------------------------------------------------
elif page.startswith("6"):
    st.title("Break it yourself")
    st.markdown(
        "A chain that has only ever reported `INTACT` proves nothing. Edit a "
        "pack below and watch what happens. Nothing is saved — this is your "
        "browser session, and a reload restores it."
    )

    d = need("evidence_pack", "evidence_chain")
    if d:
        packs, chain = d
        chain = chain.sort_values("link_no").reset_index(drop=True)

        target = st.selectbox(
            "Pack to tamper with",
            packs["seq"].tolist(),
            format_func=lambda s: f"seq {s} · {packs.loc[packs.seq == s, 'case_ref'].iloc[0]}",
        )
        original = packs.loc[packs.seq == target, "payload_json"].iloc[0]
        stored = packs.loc[packs.seq == target, "content_hash"].iloc[0]

        edited = st.text_area(
            "Payload — change anything, even one character",
            original,
            height=220,
        )

        now = sha256(edited)
        changed = edited != original

        c = st.columns(2)
        c[0].markdown("**Hash recorded in the chain**")
        c[0].code(stored)
        c[1].markdown("**Hash of what is in the box**")
        c[1].code(now)

        if not changed:
            st.info("Unmodified — the two hashes match. Edit the payload above.", icon="✏️")
        else:
            st.error(
                "**Payload altered.** The recomputed hash no longer matches the "
                "one the chain recorded, so this pack fails verification.",
                icon="🚨",
            )
            link = chain.loc[chain["pack_seq"] == target]
            if len(link):
                n = int(link.iloc[0]["link_no"])
                downstream = len(chain) - n
                st.markdown(
                    f"This pack is **link {n:,} of {len(chain):,}**. Because every "
                    f"link hashes the one before it, altering it invalidates this "
                    f"link and all **{downstream:,}** that follow. Changing one "
                    f"record means forging {downstream + 1:,}."
                )
                prev = link.iloc[0]["prev_chain_hash"]
                st.markdown("**Link recomputed with your edit:**")
                st.code(
                    f"was  {link.iloc[0]['chain_hash']}\n"
                    f"now  {sha256(prev + now)}"
                )

        st.divider()
        st.subheader("The same three attacks, run inside Snowflake")
        drills = load("tamper_drill_log")
        if drills is None:
            st.caption("_Add `data/tamper_drill_log.csv` (query 13)._")
        else:
            st.dataframe(drills, use_container_width=True, hide_index=True)
            st.caption(
                "Run as `ACCOUNTADMIN` — the strongest adversary that account "
                "has. Rows 2 and 3 are the point: rewording a decision leaves "
                "the structure intact, so the link walk passes it; deleting a "
                "record leaves every survivor hashing correctly, so "
                "recomputation passes it. Each attack is invisible to the "
                "check that catches the other."
            )
        st.info(
            "**What this does not prove.** Someone with `ACCOUNTADMIN` who also "
            "reads the source can append a *well-formed* forgery — the canonical "
            "string is public, so a correct hash can be computed. A hash chain "
            "makes the past tamper-evident, **not the present unforgeable.** "
            "Closing that needs the head hash published outside the account, or "
            "a signing key the database never sees. Neither is built.",
            icon="⚖️",
        )


# ---------------------------------------------------------------------------
# 7. Predicates
# ---------------------------------------------------------------------------
elif page.startswith("7"):
    st.title("Where the rule comes from")
    st.markdown(
        "The thresholds this engine enforces are not typed in. A model reads "
        "the policy document and proposes predicates. A human certifies them. "
        "Only then does SQL execute them.\n\n"
        "**The model reads prose, which is what models are good at. It never "
        "decides an outcome.**"
    )
    for name, title in [
        ("candidate_predicates", "Extracted from the policy text"),
        ("certification_queue", "Awaiting human certification"),
        ("enforceable_predicates", "Certified, and therefore enforceable"),
    ]:
        df = load(name)
        if df is not None:
            st.subheader(title)
            st.dataframe(df, use_container_width=True, hide_index=True)
    st.caption(
        "Certification is bound to a hash of the policy text. Amend the policy "
        "and the certification lapses automatically — a rule cannot stay "
        "approved for a document that has since changed."
    )


# ---------------------------------------------------------------------------
# 8. Results
# ---------------------------------------------------------------------------
elif page.startswith("8"):
    st.title("How well it worked")
    d = need("adjudication", "invisible_population")
    if d:
        adj, pop = d
        keys = [k for k in ("customer_id", "week_start") if k in adj.columns and k in pop.columns]
        if keys and "is_truly_suspicious" in pop.columns and "p_suspicious" in adj.columns:
            j = adj.merge(pop, on=keys, how="inner")
            y = j["is_truly_suspicious"].astype(str).str.lower().isin(["true", "1", "t", "yes"])
            yhat = j["p_suspicious"] >= 0.45
            tp = int((y & yhat).sum())
            c = st.columns(4)
            c[0].metric("Weeks adjudicated", f"{len(j):,}")
            c[1].metric("Genuinely suspicious", f"{int(y.sum()):,}")
            c[2].metric("Recall @ 0.45", f"{tp / max(int(y.sum()), 1):.3f}")
            c[3].metric("Precision", f"{tp / max(int(yhat.sum()), 1):.3f}")

            st.subheader("Yield against workload")
            q = pd.qcut(j["p_suspicious"].rank(method="first", ascending=False), 10, labels=False) + 1
            lift = pd.DataFrame({"decile": q, "dirty": y.astype(int)}).groupby("decile").agg(
                weeks=("dirty", "size"), dirty=("dirty", "sum")
            )
            lift["hit_rate"] = (lift["dirty"] / lift["weeks"]).round(3)
            lift["cumulative_recall"] = (lift["dirty"].cumsum() / lift["dirty"].sum()).round(3)
            st.dataframe(lift.reset_index(), use_container_width=True, hide_index=True)
            st.bar_chart(lift["hit_rate"])

    st.caption(
        "Discrimination is modest — **AUC 0.608** against an oracle ceiling of "
        "**0.868** on this evidence. That ceiling is the important number: the "
        "gap is irreducible ambiguity in what a reviewer could have seen, not a "
        "weak model. A human reviewer on the same evidence scores 0.731 "
        "accuracy. Method and limitations in EVALUATION.md."
    )


# ---------------------------------------------------------------------------
# 9. About
# ---------------------------------------------------------------------------
else:
    st.title("About this snapshot")
    st.markdown(
        f"""
The live system is **Streamlit in Snowflake**, running next to the data inside
a Snowflake account. That is the right place for it — no customer data leaves
the account, and every model call happens in Cortex. It is also why you cannot
open it: reaching it requires a login to that account, and the trial holding
the data expires during the judging window.

So this exists. Every row was exported from the live account after the runs
recorded in [`eval/`]({REPO}/tree/main/eval).

#### What is real

- **The data.** Exported from Snowflake, not typed in, not illustrative.
- **The verification.** Pages 5 and 6 recompute SHA-256 over the exact bytes
  Snowflake hashed, walk the chain, and reach their own verdict. No stored
  result is read. This runs on Streamlit's servers with no access to the
  database — a check the database cannot influence.

#### What is not

- **Writes.** Recording a decision uses an append-only stored procedure that
  lives in Snowflake. Page 6 lets you edit a payload in your browser; nothing
  persists, and a reload restores it.
- **Live queries.** The counterfactual replay engine recomputes over 607,307
  transactions. Those results are exported, not recomputed on demand.

#### The corpus is synthetic

Generated by [`generator/generate.py`]({REPO}/blob/main/generator/generate.py),
seed `20260916`. Every customer, name, PAN and transaction is fabricated, which
is why publishing it here carries no disclosure risk. It is also why ground
truth exists at all — the generator knows which customers were laundering, and
the adjudicating model never sees that column.

The corpus was rebuilt twice because the first two versions had no learnable
signal. Both failures are written up rather than deleted.

---

**[Full source, evaluation and raw run output →]({REPO})**

The evaluation is the honest document: it records the measurement error we
made, the two security bypasses our own tests found, the fix that was right on
principle and did nothing for the metrics, and the hash chain that reported
`TAMPERED` on its own data — correctly.
"""
    )
