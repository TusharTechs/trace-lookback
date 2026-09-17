# Architecture

## The pipeline

```mermaid
flowchart TB
    subgraph POLICY["POLICY — versioned rules"]
        DOC["POLICY_DOCUMENTS<br/>internal AML policy"]
        CAND["CANDIDATE_PREDICATES<br/>model-proposed, uncertified"]
        CERT["V_ENFORCEABLE_PREDICATES<br/>human-certified, hash-bound"]
        PV["POLICY_VERSIONS<br/>immutable, validity intervals"]
    end

    subgraph CORE["CORE — the record"]
        TX["TRANSACTIONS<br/>607,307 rows"]
        AL["ALERTS + DISPOSITIONS<br/>what the bank actually did"]
        PIT["V_POINT_IN_TIME_FEATURES<br/>replay engine"]
        LED["V_CASE_LEDGER<br/>model output, no ground truth"]
        SEM["CASE_ANALYTICS<br/>semantic view"]
    end

    subgraph AUDIT["AUDIT — append-only"]
        PACK["EVIDENCE_PACK"]
        CHAIN["EVIDENCE_CHAIN<br/>hash-chained"]
        LOG["CASE_ACTION_LOG<br/>who did what"]
    end

    subgraph EVAL["EVAL — sealed"]
        GT["GROUND_TRUTH<br/>no role reads this"]
    end

    DOC -->|"AI_COMPLETE<br/>extract"| CAND
    CAND -->|"human certifies<br/>bound to text hash"| CERT
    CERT -.->|"enforces"| PV

    TX --> PIT
    PV -->|"threshold as-was"| PIT
    PIT -->|"candidates the rule missed"| ADJ["AI_COMPLETE<br/>adjudication"]
    ADJ --> LED
    LED --> SEM
    LED -->|"p ≥ 0.60"| PACK
    PACK --> CHAIN
    DOC -->|"Cortex Search"| AGENT["TRACE_COPILOT<br/>Cortex Agent"]
    SEM --> AGENT
    AGENT --> LOG

    GT -.->|"measures only"| ADJ

    classDef sealed fill:#fee,stroke:#c33,stroke-dasharray:4
    classDef append fill:#eef,stroke:#36c
    class GT sealed
    class PACK,CHAIN,LOG append
```

## Where the model is, and is not

```mermaid
flowchart LR
    A["Policy prose"] -->|"model reads"| B["Candidate predicate"]
    B -->|"human signs"| C["Certified rule"]
    C -->|"SQL only"| D["Alert / no alert<br/>deterministic"]
    D --> E["Candidate population"]
    E -->|"model scores"| F["Probability"]
    F -->|"human-chosen threshold"| G["Triage band"]
    G --> H["Evidence pack"]

    style B fill:#ffd,stroke:#a80
    style F fill:#ffd,stroke:#a80
    style D fill:#dfd,stroke:#282
    style G fill:#dfd,stroke:#282
```

Amber is probabilistic. Green is deterministic. **The model never decides an
outcome** — it reads prose and it scores evidence. Every gate between those two
steps is SQL a regulator can re-derive, or a human signature.

## Controls

```mermaid
flowchart TB
    Q["Agent issues SQL"] --> H{"PreToolUse hook"}
    H -->|"mutating AUDIT.*"| X["refused before Snowflake"]
    H -->|"otherwise"| R{"Restricted Session Scope"}
    R --> P{"Role privileges"}
    P -->|"no UPDATE on AUDIT"| Y["refused by Snowflake"]
    P -->|"no grant on EVAL"| Z["schema does not resolve"]
    P -->|"permitted"| OK["executes, masked per role"]

    style X fill:#fdd,stroke:#c33
    style Y fill:#fdd,stroke:#c33
    style Z fill:#fdd,stroke:#c33
    style OK fill:#dfd,stroke:#282
```

Three independent layers. The hook is client-side and covers only the agent's
SQL tool; the role privileges are the real control and hold regardless of what
connects. Each was verified by attempting the thing it forbids — see
[`EVALUATION.md`](../EVALUATION.md) §8.
