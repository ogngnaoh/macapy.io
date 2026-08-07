# Slice 5 — History & Search + Deletion + Rename (completes FR-013)

**Status:** pending (implements after slice 4 ships — passage rows and speaker counts consume its labels; migration order v4 → v5)
**Plan written:** 2026-07-17; **rewritten 2026-08-07** (joint re-plan of slices 4+5 per handoff; all checks are now deterministic automated oracles, user-reviewed at plan approval 2026-08-07)
**References:** ../../SPEC.md §6.2 (deletion-cascade invariant), §5 (scale: millions of segment rows); PRD FR-010, FR-013, Story 5 (search < 1 s); ./milestone.md exit criterion 5

The plan for this slice is also its record.

## Design

### Scope (grew at re-plan)

FTS5 search over titles/transcripts/artifacts + grouped search UI with passage deep-link; per-meeting delete with confirm; delete-everything with type-to-confirm; **inline title rename** (author ruling 2026-08-07 — auto-generated titles made the title-search surface near-meaningless); meeting-summary list rows (duration · speaker count · artifact count per design/04). Slice-3 fact folded in: schema v3's `artifacts` cascade means search and deletion must cover artifacts — they do (below).

### Decisions (re-plan, 2026-08-07; supersede the 2026-07-17 list)

1. **Three synchronized external-content FTS5 tables** — `meetings_fts(title)`, `segments_fts(text)`, `artifacts_fts(searchText)` via GRDB `synchronize(withTable:)` in migration `v5-search`. Rationale: the SQL triggers fire on FK-cascade deletes too, so per-meeting deletion scrubs the index with zero application code; GRDB backfills pre-existing rows at creation (`rebuild`, verified in the 7.11.1 checkout); the grouped UI wants three result sets anyway. `content_rowid` = implicit rowid (our UUID PKs are BLOBs); join back to recover UUIDs. Tokenizer: default unicode61, no stemming — literal-token semantics are predictable and assertable. Resolves the old decision 1's deferred external-content-vs-contentless question.
2. **Artifact text: derived `artifacts.searchText` column** (NOT NULL DEFAULT ''), maintained by `ArtifactStore.insertDrafts` and backfilled in-migration via one pure `ArtifactSearchText.derive(kind:payload:)` (summary/decision → text; action_item → title + owner + deadline). Raw-JSON indexing rejected (key noise: "title"/"owner" would match every row); SQL generated column rejected (per-kind knowledge belongs to the Swift payload types). `setStatus` never touches payload, so flips are index-inert (pinned by check 12).
3. **Ranking/snippets: FTS5 built-ins** — per-group `bm25()` ordering + deterministic tiebreaks; `snippet()` with ASCII-separator sentinels parsed into text + highlight ranges → AttributedString with `signalSoft` marks (tokenizer-consistent highlighting; hand-rolling would diverge on case/diacritics). The Meetings group aggregates per-surface hits by meeting in Swift → hitCount + matched-surface set ("3 hits", "matches in transcript and action items").
4. **API: new `SearchStore` actor in PersistKit** — `search(matching:) -> SearchResults {meetings, passages, artifacts}` in one read transaction; sanitization via `FTS5Pattern(matchingAllPrefixesIn:)` (hostile input can never throw; empty ⇒ empty). `MeetingStore` gains `meetingSummaries()` (duration/speakerCount/artifactCount) and `renameMeeting(id:title:)`. Coordinator memoizes `searchStore()`.
5. **Deep-link + minute dividers:** pure `TranscriptRows.build(segments:)` inserts `.minuteMark` rows on `floor(tStart/60)` change (the mockup's `.tx-time`); the same formatter feeds passage-row timestamps (`<meeting> · mm:ss`). Passage tap sets `(meetingID, targetSegmentID)` → History selection → `MeetingDetailView` adopts PanelView's proven ScrollViewReader/`.id()` pattern + brief `signalSoft` highlight on the target line.
6. **Custom `SearchField`** styled to tokens in the History toolbar (`.searchable` rejected — system chrome can't match the mockup's sunken/hairline treatment); ⌘F focuses, Esc clears; ~200 ms debounce with injectable delay (0 in tests, keeping oracles deterministic). Non-empty query swaps the sidebar list for the three grouped sections (promoted `SectionHead` as group headers). History stays one `NavigationSplitView` — the mockups' two-window presentation is presentation, not structure.
7. **Confirm UX:** per-meeting `Delete…` (subtle style, detail toolbar per design/05) = system `.confirmationDialog` with a destructive-role button (native furniture stays system-styled). Delete-everything (`Delete all meeting data…`, destructive style, Settings General per design/06) = custom type-to-confirm sheet composed purely from existing tokens/components; gate logic in a unit-tested `DeleteEverythingModel` (`canDelete` only on exact `DELETE`). Guards: per-meeting Delete hidden while the meeting is active; delete-everything disabled while capturing. No /design-sync round (nothing new beyond approved tokens); the sheet gets added to design/06-settings.html as the design record.
8. **`deleteAllUserData()` mechanics:** one transaction — `DELETE FROM meetings` (cascades segments/artifacts/spend/speakers; the FTS `_ad` triggers scrub all three indexes) then `DELETE FROM spend_ledger` (catches NULL-meetingID rows the cascade misses); settings survive. Afterwards, off the main actor: `PRAGMA wal_checkpoint(TRUNCATE)` + `VACUUM` so deleted content doesn't linger in free pages or the WAL — that is what makes the byte-grep residue oracle possible (FR-013's spirit). Drop-and-recreate rejected (kills settings; invalidates every memoized store's live connection). **Scope (author ruling 2026-08-07): meeting data only** — Keychain credentials and settings survive; `coordinator.deleteAllMeetingData()` is the one-line hook if keys are ever ruled in (`KeychainCredentialStore.deleteAll()` exists).
9. **Rename:** `renameMeeting` UPDATE → the `_au` trigger re-indexes the title for free; click-to-edit toolbar title in meeting detail (Return/blur commits, empty rejected → revert). Every mutation path calls an explicit `reload()` — History is fetch-on-appear by design, nothing observes the DB.
10. **Performance authority = in-test measurement, no release CLI** (amends old check 2's escalation default): the timed path is precompiled SQLite C and the < 1 s budget is ~3 orders above FTS5 reality; M1's release-harness split existed for Swift-compute-heavy paths and remains the *documented escalation* if debug timing ever flakes. Fixture: `SearchFixtureSeeder` in PersistKit (deterministic seeded RNG + word bank; ≥ 50 meetings, two ≥ 3 h, ≥ 1.2×10⁵ segments, ~150 artifacts, planted needle phrases) writing raw prepared statements in chunked transactions (bypasses row-by-row `append`), cached at a version-keyed temp path and rebuilt only on version bump; `MACAPY_SEARCH_SCALE` env knob reaches the 10⁶ band ad hoc.
11. **"Searchable immediately after finalization" defined:** FTS triggers run inside the segment-INSERT transaction ⇒ searchable == committed. Contract: after `MeetingPipeline.stop()` returns (awaits `flushAndStop()`), every final segment is searchable; mid-meeting, a batch is searchable the moment its flush commits (25-row threshold or 1 s debounce).
12. **Ephemeral meetings** live in a separate per-meeting in-memory DB ⇒ structurally never in the on-disk index (old decision 1's guarantee holds by construction — asserted anyway by check 15). Stated plainly: an ephemeral meeting is not searchable at all, live or after.

## Acceptance checks (rewritten 2026-08-07; user-reviewed at plan approval — all deterministic automated oracles)

Former user-live checks 8/9 are re-expressed by 9, 10, 15, 16; their "feels right on real data" residue folds into dogfooding + the app-complete walk (2026-08-06 ruling).

1. Migration v5: double-migration no-op; extended exact-set column pins (`artifacts` + `searchText`); three FTS tables + the new `meetings.startedAt` index exist; a v4 DB with pre-existing rows (incl. legacy artifacts of every kind) migrates with every pre-existing row searchable and `searchText` correctly backfilled per kind.
2. Correctness across surfaces: seeded queries hit title / passage (correct segmentID, tStart, meeting title) / every artifact payload field (summary text, decision text, action-item title/owner/deadline); an absent term returns three empty groups; the meetings group aggregates cross-surface hits with exact hitCount + matched-surface set; group order pinned (bm25 then tiebreak) against an exact expected sequence.
3. Query robustness: `"`, `((`, `NEAR(a,b)`, `*`, emoji, empty, whitespace-only never throw; empty/whitespace ⇒ empty results; multi-token = all-prefixes AND (positive + negative assert).
4. Snippet fidelity: sentinel parse round-trips into text + ranges; every highlight range, applied to the snippet text, equals a case-folded token of the query (self-verifying against a planted needle with known surrounding text).
5. Summaries + rename: `meetingSummaries()` exact duration/speakerCount/artifactCount on a hand-built DB (incl. zero-artifact meeting, ephemeral absent); rename ⇒ new title searchable, old title zero hits, summary reflects it; empty title rejected.
6. Performance at seeded scale: against the cached fixture (counts asserted ≥ floors and logged), a planted-needle search and a common-token search each complete < 1 s in-test, elapsed logged as evidence. (Decision 10 records why there is no release harness.)
7. Fixture economics: warm-cache suite cost < 5 s wall; cold build < 60 s; version-keyed cache name proves staleness safety.
8. Incremental index: (a) store-level — a 25-row batch appended to the seeded 10⁵-row DB is searchable in the same test with no wait; batch append < 250 ms (tripwire); (b) end-to-end — fake-engine meeting with a distinctive tail phrase ⇒ searchable the moment `stop()` returns.
9. Deep-link derivation: minute-mark insertion table-driven (0 s, 59→60 s, > 1 h); passage selection sets `(meetingID, targetSegmentID)` and the target id is present in that meeting's built rows; timestamp format pinned ("00:14", "01:07").
10. Search-to-detail flow: real in-memory DB ⇒ model search → select passage → detail's loaded segments contain the target id at the expected index (the scroll gesture is the shipped PanelView mechanism; pixels fold into dogfooding).
11. Per-meeting delete — zero orphans, zero stale FTS: whole-DB row-diff proves deleting meeting A removes exactly A's rows across meetings/segments/artifacts/spend/speakers, B untouched; every pre-delete search hit for A's content returns empty across all three groups; B's hits survive; FTS `_docsize` row counts drop by exactly A's contribution.
12. Status flip stays payload-inert: `setStatus` leaves `searchText` and search hits byte-identical (row-diff), extending the existing flip oracle.
13. Delete-everything: temp **on-disk** DB seeded with canary strings in title/segment/artifact + a NULL-meetingID spend row ⇒ after `deleteAllUserData()`: all user-data tables and all three FTS `_docsize` tables empty; `settings` rows survive; byte-grep of `.sqlite`/`-wal`/`-shm` finds no canary (checkpoint + VACUUM proven); DB functional after (begin/append/search work).
14. Type-to-confirm gate: `canDelete` false for ""/"delete"/"DELETE "/near-misses, true only for exact `DELETE`; `confirm()` invokes deletion exactly once; coordinator refuses while capturing.
15. Ephemeral non-residue: extend the existing on-disk oracle — after an ephemeral run, on-disk row counts, file size, search results, and FTS `_docsize` all show nothing.
16. Post-delete UI state: `HistorySearchModel` after `deleteMeeting` reloads the list without the meeting, clears selection, and re-runs the active query with the meeting's hits gone.
17. Full `swift test` green (incl. live suites); `xcodebuild` clean; no pre-existing test modified except the disclosed dump-helper promotion and column-pin extensions.

## Checklist

- [x] Acceptance checks user-reviewed (original set at M2 kickoff gate 2026-07-24; **rewritten set reviewed at joint re-plan approval 2026-08-07**)
- [ ] Migration `v5-search` (+ `searchText` backfill + 3 FTS tables + `startedAt` index) + `ArtifactSearchText` + `ArtifactStore` maintenance (TDD: checks 1, 12)
- [ ] Row-diff `dump()` helper promoted to shared `DatabaseDump.swift`, filter extended for FTS shadow tables; existing row-diff tests green
- [ ] `SearchStore` + query layer (checks 2, 3, 4)
- [ ] `MeetingStore.meetingSummaries()/renameMeeting`; `deleteAllUserData()` (checks 5, 11, 13)
- [ ] `SearchFixtureSeeder` + `SearchScaleTests` (checks 6, 7, 8)
- [ ] UI: `HistorySearchModel`, `SearchComponents` (SearchField/HistoryRow/PassageRow/SnippetTextView/SubtleButtonStyle/DestructiveButtonStyle; promote SectionHead), HistoryView search + summary rows, MeetingDetailView dividers/scroll-to/meta line/rename/Delete… (checks 9, 10)
- [ ] Deletion wiring: coordinator methods + guards, Settings destructive row + `DeleteEverythingSheet`/`DeleteEverythingModel`, confirmation dialog, post-delete refresh; design/06 sheet card added (checks 14, 16)
- [ ] End-to-end: finalize-then-search; ephemeral FTS non-residue (checks 8b, 15)
- [ ] Verifier re-runs checks 1–17 with evidence
- [ ] Ship rituals: slice table, integration notes, handoff, commit — and milestone close-out follows

## Notes / dead ends

(append as work proceeds)
