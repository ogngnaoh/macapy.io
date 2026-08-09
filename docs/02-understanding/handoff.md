# Handoff — Milestone 02 (Understanding) — CLOSED

## Start here next session

**M2 is CLOSED (2026-08-09, all seven exit criteria green — verdicts with evidence in `./milestone.md`'s close-out note). Next session plans Milestone 03 — Live intelligence (the copilot cascade, SPEC §6.4).** That is a planning session, not a build session:

1. Create `docs/03-live-intelligence/` with `milestone.md` (goal, scope, non-goals, slices, exit criteria written *before* implementation) and per-slice docs whose acceptance checks are **deterministic automated oracles** (the standing verification model — see below) and are **user-reviewed at plan approval** before any build.
2. Interview the author first where the PRD/SPEC leave real choices open (the doc-system convention): copilot sensitivity/threshold defaults, cooldown values, which of the three actions (`.suggestAnswer`, `.catchUp`, `.flagCommitment`) land in which slice, rolling-summary cadence, and how M3's false-positive-rate exit criterion is measured hands-off (fixture-conversation corpus with planted trigger/non-trigger turns is the natural oracle).
3. SPEC §6.4 is the design authority: gates (≈0 ms local) → fast-tier classifier (≤1 s, strict JSON) → deep-tier streaming generation (first token ≤1.5 s); append-only context assembly with in-place compaction (property test: compaction never mutates the prompt prefix — SPEC §10 names it); panel copilot states already designed (design/01–03 mockups; built to, not redesigned).

**Debts M3 inherits (from M2, recorded at their slices):** in-flight spend reservation (cap can be overrun by concurrent calls); streaming consumers' non-stop `finish_reason` policy beyond structured calls; G3 + STT-error tiles in the diagnostics stat-grid (reserved slots exist); diagnostics fed-clock (backlog). Also natural M3 scope: design/06's "AI features" global toggle (drawn, unimplemented — it's the cascade's kill switch, PRD §9).

Sanity on arrival: `source .envrc && swift test` → **327 tests / 66 suites** green (live suites skip-not-fail without the DeepSeek key; model-gated diarization suites skip-not-fail without FluidAudio models — on the author's machine both run), `xcodebuild` clean, clean tree. The search scale fixture rebuilds itself (~4.5 s cold) at a version-keyed temp path if absent.

## Verification model (author rulings 2026-08-06 + 2026-08-09)

- No manual checks during development — deterministic automated oracles only.
- **No real-meeting halves, ever: where the suite replicates a check programmatically, the deterministic evidence is the evidence** (2026-08-09 ruling; it retired slice-2 check 11 and M1 criterion 4). Build full end-to-end, test hands-off. Real-meeting use is dogfooding — informative, never gating.
- One pixels-only manual walk when the app is complete (pixels aren't programmatically replicable). Accumulated walk list: History search results + passage deep-link + highlight, rename editor, both delete confirms, delete-everything sheet, diagnostics stat-grid, live signal strip, speaker gutters in both surfaces, Settings download affordance, Settings field→model wiring, Spend-tab rendering.
- DeepSeek key seeded once via `security add-generic-password -s io.macapy.dev -a deepseek -w`.

## Current state

- **M1 shipped; M2 closed** — five slices: design system ("Quiet instrument", `design/` HTML is source of truth), ProviderKit (DeepSeek-only wired; catalog in ProviderKit for the fast-follow), post-meeting agent (G3 2.5 s live), diarization (consent-gated FluidAudio download = the documented G6 exception; G1-with-diarize p95 88.9 ms), history & search (schema v5-search; FTS5; deletion; rename).
- Schema at **v5-search**. SQLite gotchas recorded in slice-05 Notes 1–2: bm25-in-aggregate needs a MATERIALIZED CTE; FTS5 cascade deletes leave dead tokens in `_fts_data` until `optimize` (delete-everything runs it in-transaction; the byte-grep oracle depends on it).
- Provider layer facts M3 will lean on: `LLMProvider` protocol + `OpenAICompatibleClient`; DeepSeek quirks (`reasoning_content` passback, `usesJSONObjectResponseFormat` — first-party V4 rejects `json_schema`); `SpendMeter` capped construction exists in exactly one place (`postMeetingAgent()`) — the classifier/generation tiers need their own metered wiring and the in-flight reservation fix.
- Transcript-side seams M3 will consume: `TranscriptEvent.turnEnded(source)` already flows through `TranscriptStore`; `finalsStream()` has no replay (BINDING: attach consumers before capture starts — see SegmentWriter/MeetingPipeline doc comments); panel is `PanelView` (copilot moment cards designed in design/03).
- Everything committed on `main`; **push over SSH only** (HTTPS throttles to ~3 KB/s on this network).
- Production DB untouched by tests (in-memory or temp-dir everywhere; scale fixture lives under system temp).

## Open concerns

- None gating. Dogfooding continues informally (search/rename/deep-link feel, Memory tile, speaker labels on real voices) but gates nothing.
- 7 NEEDS-CLARIFICATION markers in PRD/SPEC stand; the M3-relevant ones to settle at planning: locale scope (§8) only if the classifier prompt cares; none block the cascade design itself. SQLCipher-vs-FileVault is M5-facing.
- Backlog (non-M3 unless pulled): speaker-roster surface (no mockup); mid-capture format listener (unreproduced, M1-era).
