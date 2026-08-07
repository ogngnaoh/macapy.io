# Handoff — Milestone 02 (Understanding)

## Start here next session

Slices 4+5 were **jointly re-planned and slice 4 shipped 2026-08-07** (same session; the re-plan's author-approved plan carries both slices' rewritten all-automated-oracle checks — the user review the verification convention requires already happened at plan approval). **Next session implements slice 5** (history & search + deletion + rename) directly from its rewritten doc: `./slice-05-history-search.md` — decisions D1–D12 and checks 1–17 are final, no further planning discussion owed. Build order is in the doc's checklist (migration `v5-search` first; the row-diff `dump()` helper promotion second — it unblocks every deletion oracle).

1. Sanity on arrival: `source .envrc && swift test` → **290 tests / 60 suites** green (live suites skip-not-fail without the DeepSeek key; the model-gated diarization suites skip-not-fail without the FluidAudio models — on the author's machine both run, including a 75 s real-time e2e), clean tree, no unpushed commits.
2. Slice-5 specifics settled at re-plan worth having in head before coding: three synchronized external-content FTS5 tables (cascade deletes scrub the index via SQL triggers for free); derived `artifacts.searchText` column (payload JSON is never indexed raw); `SearchStore` actor in PersistKit; seeded-scale perf is in-test (no release CLI — documented escalation only); delete-everything = per-table DELETE + `wal_checkpoint(TRUNCATE)` + VACUUM proven by byte-grep canary oracle, **meeting data only** (Keychain survives — author ruling); title rename is in scope (author ruling); type-to-confirm token is `DELETE`; the confirm sheet composes existing tokens and gets added to design/06 as a card (no /design-sync round).
3. Slice-4 facts slice 5 consumes: `speakers` table + `segments.speakerId` exist (schema v4); `MeetingStore.attributedSegments(for:)`/`speakers(for:)` are the read APIs; passage rows render diarized labels inline ("S2 — …") and history rows show a speaker count via the planned `meetingSummaries()`.
4. Slice 5 ends with **M2 close-out** (all seven exit criteria; check the milestone doc's mapping line in the re-plan integration note).

**Verification model (author ruling 2026-08-06, unchanged):** no manual checks during development — deterministic automated oracles only; one manual walk of the whole app at app-complete. Key seeded once via `security add-generic-password -s io.macapy.dev -a deepseek -w`.

## Current state

- **Slice 4 shipped.** Diarization end-to-end: FluidAudio (new dep, vetted; models ~129 MB via **consent-gated download in Settings General** — the documented G6 exception, author ruling 2026-08-07) in a new `DiarizeKit` target; them-stream fan-out branch → 10 s-window chunked engine → post-hoc attribution (live observable labels in the panel; one batched DB sweep at `stop()`); S1/S2 labels in panel, meeting detail, and agent prompts. Memory-watch: `BoundedAudioFanOut` bounds every capture path (~10 s/branch, exact surfaced drop counters). Signal strip renders real per-source RMS at 10 Hz. Diagnostics is now the design/06 stat-grid (latency p50/p95, Memory via `phys_footprint`, Dropped chunks; G3/STT tiles reserved — still M3 debt).
- **Numbers at ship:** G1 with diarization active (release `--diarize`, 175 s fixture): p50 40.7 ms / p95 88.9 ms / passG1. Gated e2e (real SpeechAnalyzer + real FluidAudio, real-time playback): 2 them-voices separated, mic NULL, stop < 15 s. Phase-0 gate: `say` voices separate cleanly; windowed == whole-file attribution.
- Schema at **v4** (`speakers`, `segments.speakerId` FK `.setNull`); v5 is slice 5's.
- Fresh-context critic pass done at ship; its one should-fix (stop-during-model-load session orphan) fixed + mutation-proven. Pre-existing narrower stop-vs-start window on the writer side left as-is (recorded in slice-04 Notes 3) — a structural fix would be a deliberate pipeline-lifecycle change, not a slice tail.
- Everything committed on `main`; **push over SSH only** (`origin` push URL is SSH; HTTPS throttles to ~3 KB/s on this network).
- Production DB untouched by tests (slice-4 tests all in-memory or temp-dir).

## Open concerns

- **Check 11 of slice 2 (still pending, author-owned):** real full-length no-key meeting with `lsof -i -a -p $(pgrep -x macapy)` empty throughout — runs at the author's next real meeting; passing retires M1 exit criterion 4. That same meeting now also doubles as slice-4 dogfooding (speaker labels on real voices, Memory tile < 400 MB over the hour).
- **App-complete manual walk (one, at the end):** pixels only — now also includes the diagnostics stat-grid, the live signal strip, speaker gutters in both surfaces, and the Settings download affordance, on top of the earlier list.
- Standing M3 debts (unchanged): in-flight spend reservation; streaming consumers' non-stop `finish_reason` policy beyond structured calls; wiring G3 + STT-error tiles in diagnostics; diagnostics fed-clock (backlog).
- Backlog flags from the re-plan: design/06's "AI features" global toggle drawn but unimplemented; speaker-roster surface deferred (no mockup).
- 7 NEEDS-CLARIFICATION markers in PRD/SPEC stand; none block M2.
