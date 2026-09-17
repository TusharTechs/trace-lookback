# Raw run output

One file per execution against the live Snowflake account. Nothing in
`README.md` or `EVALUATION.md` is quoted from memory; it is quoted from here.

**The numbering does not line up with `sql/`.** These files are numbered by
run order, and two scripts were re-run after fixes, so the sequences diverge
from `eval/15` onward. Use this table.

| run output | script | what it records |
|---|---|---|
| [`08_verification.md`](08_verification.md) | `sql/08_reload_v2_corpus.sql` | corpus v2 load checks |
| [`09_calibration_v3.md`](09_calibration_v3.md) | `sql/09_calibration_v3.sql` | calibration, corpus v3 |
| [`10_calibration_v4.md`](10_calibration_v4.md) | `sql/10_calibration_v4.sql` | calibration, corpus v4 |
| [`11_score_v5.md`](11_score_v5.md) | `sql/11_reload_and_score_v5.sql` | final corpus load and scoring |
| [`12_replay_engine.md`](12_replay_engine.md) | `sql/12_replay_engine.sql` | point-in-time features + validation gate |
| [`13_adjudication.md`](13_adjudication.md) | `sql/13_adjudicate.sql` | first full adjudication |
| [`14_evidence_packs.md`](14_evidence_packs.md) | `sql/14_evidence_packs.sql` | first pack build |
| [`15_adjudication_v2.md`](15_adjudication_v2.md) | `sql/13_adjudicate.sql` *(re-run)* | after `outward_transfer_ratio` was made NULL when undefined |
| [`16_evidence_packs_v2.md`](16_evidence_packs_v2.md) | `sql/14_evidence_packs.sql` *(re-run)* | packs rebuilt on the corrected adjudication |
| [`17_final_metrics.md`](17_final_metrics.md) | `sql/15_final_metrics.sql` | AUC, lift curve, branch concentration |
| [`18_append_only_chain.md`](18_append_only_chain.md) | `sql/16_append_only_chain.sql` | hash chain over the 687 packs |
| [`19_roles_and_masking.md`](19_roles_and_masking.md) | `sql/17_roles_and_masking.sql` | RBAC, masking, isolation tests |
| [`20_counterfactual.md`](20_counterfactual.md) | `sql/18_counterfactual_replay.sql` | threshold sensitivity ₹5L–₹12L |
| [`21_semantic_agent.md`](21_semantic_agent.md) | `sql/19_semantic_view_and_agent.sql` | semantic view, Cortex Search, agent |
| [`22_predicate_compiler.md`](22_predicate_compiler.md) | `sql/20_predicate_compiler.sql` | first extraction attempt |
| [`23_extraction_debug.md`](23_extraction_debug.md) | `sql/21_extraction_debug.sql` | why it returned zero rows |
| [`24_extraction_staged.md`](24_extraction_staged.md) | `sql/22_extraction_staged.sql` | two-stage extraction that worked |
| [`25_certification_gate.md`](25_certification_gate.md) | `sql/23_certification_gate.sql` | human certification, lapse on amendment |
| [`26_case_action_log.md`](26_case_action_log.md) | `sql/24_case_action_log.sql` | action log v1 — reported `TAMPERED` |
| [`27_chain_diagnosis.md`](27_chain_diagnosis.md) | `sql/25_chain_diagnosis.sql` | diagnosis: forked chain, irreproducible hashes |
| [`28_action_log_rebuild.md`](28_action_log_rebuild.md) | `sql/26_action_log_rebuild.sql` | rebuilt log, `INTACT`, hashes recompute |
| [`29_tamper_drill.md`](29_tamper_drill.md) | `sql/27_tamper_drill.sql` | three attacks, all caught, each by a different check |

`sql/01`–`sql/07` have no run output here: they are the initial schema and the
first two corpus designs, both abandoned. What they were and why they failed is
in [`EVALUATION.md`](../EVALUATION.md#two-earlier-corpora-failed-and-the-failures-are-instructive).

## The failures are kept on purpose

Several of these files record runs that did not work — extraction returning
zero rows, a hash chain reporting `TAMPERED` on untouched data, a compilation
error, a drill whose results were unreadable because Snowsight shows one
result pane at a time.

They are here because a repository containing only successful runs tells you
nothing about how the successful ones were reached, and because at least five
results in this project initially passed for the wrong reason. Those are
catalogued in [`EVALUATION.md`](../EVALUATION.md).
