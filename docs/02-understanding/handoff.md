# Handoff — Milestone 02 (Understanding)

## Start here next session

**Slice 5 shipped 2026-08-09 — all five M2 slices are done.** Next session runs **M2 close-out**: walk all seven exit criteria in `./milestone.md` against evidence, record the verdict in the milestone doc, and decide what (if anything) blocks calling M2 complete versus folds into dogfooding/the app-complete walk. The per-criterion picture going in:

1. Criterion 1 (design pass + reskin sign-off) — done at slice 1 (2026-07-25 author walk).
2. Criterion 2 (real meeting → artifacts < 60 s) — fixture half done (G3 measured 2.5 s, slice 3); the genuinely-real-meeting half folds into dogfooding per the no-manual-checks ruling.
3. Criterion 3 (zero-credential run, Keychain-only keys, fake-server coverage) — machine halves done (slices 2–3); **check 11 of slice 2 still pending, author-owned** (see Open concerns).
4. Criterion 4 (real multi-party diarization) — dev half done (slice 4 gated e2e); real-meeting half → dogfooding.
5. Criterion 5 (seeded-scale search < 1 s; cascade + delete-everything) — **fully satisfied by slice 5's machine oracles**, nothing residual.
6. Criterion 6 (spend ledger + cap halt visible) — done (slices 2–3; halt state test-pinned).
7. Criterion 7 (< 400 MB, bounded-buffer proof) — test halves done (slice 4); 1-hour real readout → dogfooding via the Memory tile.

Sanity on arrival: `source .envrc && swift test` → **327 tests / 66 suites** green (live suites skip-not-fail without the DeepSeek key; model-gated diarization suites skip-not-fail without the FluidAudio models — on the author's machine both run), `xcodebuild` clean, clean tree. The search scale fixture rebuilds itself (~4.5 s cold) at a version-keyed temp path if absent.

**Verification model (author ruling 2026-08-06, unchanged):** no manual checks during development — deterministic automated oracles only; one manual walk of the whole app at app-complete. Key seeded once via `security add-generic-password -s io.macapy.dev -a deepseek -w`.

## Current state

- **Slice 5 shipped.** Schema at **v5-search**: three synchronized external-content FTS5 tables + derived `artifacts.searchText` + `startedAt` index; `SearchStore` actor (sanitized all-prefixes-AND, bm25+rowid ordering, sentinel-parsed snippets, exact aggregated Meetings group); `MeetingStore.meetingSummaries()/renameMeeting/deleteAllUserData()`; `SearchFixtureSeeder` (deterministic, cached, `MACAPY_SEARCH_SCALE` knob); History search UI (⌘F/Esc, grouped sections, passage deep-link with minute-mark rows + brief highlight), click-to-edit rename, per-meeting Delete… confirm, Settings `DELETE` type-to-confirm sheet. Coordinator: memoized `searchStore()`/`historySearchModel()`, `deleteAllMeetingData()` refuses while capturing.
- Two SQLite dead-ends worth knowing before touching search internals (slice-05 doc Notes 1–2): bm25-in-aggregate requires a MATERIALIZED CTE; FTS5 cascade deletes leave dead tokens in `_fts_data` until `optimize` — `deleteAllUserData()` runs it inside the delete transaction, which is what makes the byte-grep oracle pass.
- **Slice 4 facts still current:** diarization via consent-gated FluidAudio download (Settings General, the documented G6 exception); G1 with diarization p50 40.7 ms / p95 88.9 ms; `BoundedAudioFanOut` bounds every capture path; diagnostics stat-grid live (G3/STT tiles reserved — M3 debt).
- Fresh-context verifier re-ran slice 5's checks 1–17 independently at ship: all PASS; sole note (measurement granularity on check 7's warm budget) accepted and recorded in the slice doc.
- Everything committed on `main`; **push over SSH only** (`origin` push URL is SSH; HTTPS throttles to ~3 KB/s on this network).
- Production DB untouched by tests (slice-5 tests are in-memory or temp-dir; the scale fixture lives under the system temp directory, never in Application Support).

## Open concerns

- **Check 11 of slice 2 (still pending, author-owned):** real full-length no-key meeting with `lsof -i -a -p $(pgrep -x macapy)` empty throughout — runs at the author's next real meeting; passing retires M1 exit criterion 4. That meeting also doubles as slice-4 dogfooding (speaker labels on real voices, Memory tile < 400 MB over the hour) and now slice-5 dogfooding (search over the real transcript, rename, passage deep-link feel).
- **App-complete manual walk (one, at the end):** pixels only — now also includes History search results + passage deep-link + highlight, the rename editor, both delete confirms, and the delete-everything sheet, on top of the earlier list (diagnostics stat-grid, signal strip, speaker gutters, Settings download affordance).
- Standing M3 debts (unchanged): in-flight spend reservation; streaming consumers' non-stop `finish_reason` policy beyond structured calls; wiring G3 + STT-error tiles in diagnostics; diagnostics fed-clock (backlog).
- Backlog flags: design/06's "AI features" global toggle drawn but unimplemented; speaker-roster surface deferred (no mockup).
- 7 NEEDS-CLARIFICATION markers in PRD/SPEC stand; none block M2 close-out (locale scope + SQLCipher are M5-facing).
