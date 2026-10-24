# Synthetic retrieval benchmarks

On one Apple M2 Pro Mac, the Release build searched a synthetic database containing **146,458 transcript segments and 10,000 document chunks** with warm p95 latency of **53.25 ms for history search** and **11.31 ms for local memory retrieval**. Both passed the declared one-second gate. These measurements describe local search, not speech recognition or generated answers.

The frozen source-retrieval checks passed. An exact-vector experiment recovered fewer expected sources than the lexical baseline, while reciprocal-rank fusion added no recall benefit and returned unrelated candidates in several empty-evidence cases. Production retrieval remains lexical.

[Machine-readable result](evidence/retrieval-v1.json) · [Frozen 40-question corpus](../Tests/PersistKitTests/Fixtures/RetrievalEvidence/v1.json) · [Harness](../Tests/PersistKitTests/RetrievalEvidenceTests.swift)

## Environment and method

| Item | Recorded value |
|---|---|
| Measurement | October 23, 2026, 22:35 UTC |
| Machine | Apple M2 Pro, Mac14,9, 10 logical CPUs, 16 GiB physical memory |
| OS | macOS 26.6.2, build 25G83, arm64 |
| Toolchain | Apple Swift 6.3.3; Release configuration |
| History fixture | 146,458 segments; `SearchFixtureSeeder` version 1, scale 1 |
| Document fixture | 10,000 chunks; chunker version 1 |
| Quality corpus | 20 answerable, 10 temporal/conflicting, 10 insufficient/adversarial questions; 10 held out before the first run |
| Provider calls | Zero |

All text is original synthetic material. The corpus contains 34 named sources, including one deleted source and one source denied AI access. The harness exercises the product deletion API, then adds deterministic filler chunks in bounded batches. History and document retrieval run against the same database, through their production store APIs. The quality questions retrieve document evidence; this run does not measure reviewed-memory-fact ranking quality.

There was one warm-up pass through the 40 retrieval questions, followed by five measured passes: **200 retrieval samples**. Four history queries—rare transcript token, common transcript token, meeting-title token, and artifact token—were warmed once and repeated 25 times: **100 history samples**. Percentiles use the nearest-rank method. Repetitions measure timing variability; they do not turn 40 questions into 200 independent quality cases.

## Results

| Warm operation | Samples | p50 | p95 | Maximum | Gate |
|---|---:|---:|---:|---:|---|
| Local memory retrieval | 200 | 0.66 ms | 11.31 ms | 12.51 ms | Pass: p95 <1,000 ms |
| History search | 100 | 0.83 ms | 53.25 ms | 54.85 ms | Pass: p95 <1,000 ms |

| Frozen lexical check | Result | Meaning |
|---|---:|---|
| Answerable Recall@8 | 20/20 expected sources | At least the expected source appeared among up to eight excerpts. The declared gate was ≥90%. |
| Temporal/conflicting Recall@8 | 15/15 expected sources across 10 questions | Expected evidence survived the recorded chronology and source filters. |
| Source-reference validity | 100% across 200 retrievals | Returned references passed current source, revision, and permission validation. Empty results also satisfy this structural check. |
| Prohibited-source exclusion | 40/40 recorded scale cases | No recorded returned source matched the case's prohibited-source list. |
| Expected-empty cases | 8/8, all five passes | The lexical baseline returned no excerpts for these specific cases. |

The held-out subset includes five answerable questions; all five recovered their expected source. This is a small synthetic result, not a general accuracy estimate. Citation validity checks that a reference resolves to eligible source text; it does not establish that a generated claim follows from that text.

Peak resident memory for the **Release test process** was **146,407,424 bytes (139.625 MiB)**. It includes fixture preparation and the optional embedding comparison. It is not active-app memory, a capture workload, or evidence for the app's separate memory budget.

## Optional vector comparison

The experiment used the already-available English platform sentence embedding, model revision 1, dimension 512. It requested no download and made no provider call. After the initial model probe, it embedded **9,999 eligible chunks** in **81.46 seconds**, within the fixed 120-second indexing budget; the one denied chunk was excluded. Source and date filters were applied before ranking.

| Candidate ranking | Answerable Recall@8 | Expected-empty cases returning no candidates | Query p50 | Query p95 |
|---|---:|---:|---:|---:|
| Lexical baseline | 20/20 | 8/8 | 0.66 ms | 11.31 ms |
| Exact cosine | 13/20 | 2/8 | 16.22 ms | 19.68 ms |
| Lexical + exact cosine, reciprocal-rank fusion | 20/20 | 2/8 | 16.92 ms | 27.82 ms |

Exact-vector timing includes query embedding and ranking, with 40 query samples. Fusion uses a fixed rank constant of 60 and the top eight candidates from each ranking. Its reported timings are sums of separately measured lexical, vector, and fusion components, not an end-to-end production pipeline. The lexical row summarizes the 200-sample baseline, so the timing sample counts differ.

Neither vector ranking improved recall here. Both returned candidates for six cases where the lexical baseline returned the expected empty result. These are retrieval-candidate observations, not generated-answer abstention scores. No ranking threshold or corpus expectation was tuned after measurement, and semantic ranking remains disabled in the product.

## Reproduce and interpret

On the supported Mac/toolchain with dependencies already resolved:

```bash
scripts/measure-retrieval.sh /tmp/macapy-retrieval-evidence-new
```

Use a new output directory. The script records source provenance, runs the bounded Release lane, and verifies that public sources stayed unchanged. If local embeddings are unavailable or indexing exceeds its budget, the report records a disabled or incomplete experiment instead of a quality claim. Ordinary `swift test` skips this scale lane and still checks the small frozen corpus. See [Development](development.md#synthetic-retrieval-evidence).

The frozen corpus SHA-256 is `c5da243216ce654272af03c8f3fe0568f36c571d9b17a81943ac4abc88cfe6b2`. The measured public-source snapshot SHA-256 is `b5bf4b44e3fcec15ab2aa0aac05da3d1dd03d87626d859c61240ecd5b7ebee5a`. The harness verified that snapshot before publishing this report. Adding this report and its README link necessarily changes the later public tree; a release archive records its own fresh source snapshot. The digest identifies the measured working tree, not a published Git tag.

This run does **not** measure generated-answer correctness, prompt-injection resistance, real meeting speech or speaker quality, provider latency, cold startup, active-app footprint, or a one/three-hour capture soak. No private meeting data, billable calls, or field telemetry were used. The small English corpus and synthetic filler limit generalization; retain the complete per-query result, including empty and unsuccessful vector results, when comparing a future version.
