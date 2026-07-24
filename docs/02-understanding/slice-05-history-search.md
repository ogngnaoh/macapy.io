# Slice 5 — History & Search + Deletion (completes FR-013)

**Status:** pending
**Plan written:** 2026-07-17 (M2 planning session; acceptance checks precede implementation)
**References:** ../../SPEC.md §6.2 (invariants: deletion cascade), §5 (scale: millions of segment rows); PRD FR-010, FR-013, Story 5 (search < 1s); ./milestone.md exit criterion 5.

The plan for this slice is also its record.

## Design

### Decisions (planning, 2026-07-17)

1. **SQLite FTS5** (via GRDB) over meeting titles, segment text, and artifact payload text. Index maintained incrementally on write (external-content vs. contentless decided at build against GRDB's FTS support; decision recorded here). Ephemeral meetings live in the in-memory DB and are therefore never indexed on disk by construction — asserted anyway.
2. **Search UI in the History window** per the slice-1 design: query field; grouped results (meetings / transcript passages / artifacts); selecting a passage opens meeting detail scrolled to it.
3. **Deletion (completes FR-013):** per-meeting delete with confirmation — cascade removes segments, artifacts, spend rows, speakers, and FTS entries (SPEC §6.2 invariant); delete-everything in Settings with a type-to-confirm guard. (`memory_facts` nulling is M4 — table doesn't exist yet.)
4. **Performance is a machine check, not a vibe:** a seeding generator builds a realistic-scale fixture DB (≥ 50 meetings including multi-hour transcripts; on the order of 10⁵–10⁶ segment rows) and the search path is timed against it.

## Acceptance checks (written before implementation)

Machine-verifiable:

1. Correctness: seeded queries return expected matches from each of the three surfaces (title, passage, artifact), ranked sanely; no matches from deleted meetings.
2. Performance: against the seeded realistic-scale DB, search completes in **< 1s** (measured in the test, generous margin expected; if debug-config timing is untrustworthy, a release-config harness run is the authority — M1 slice-5 precedent).
3. Incremental index: segments/artifacts written during a live meeting are searchable immediately after finalization.
4. Per-meeting delete leaves zero orphan rows in segments/artifacts/spend/speakers and zero stale FTS hits.
5. Delete-everything empties all user-data tables (settings may survive); app remains functional after.
6. Ephemeral meeting: after the meeting, disk DB contains no rows and no FTS entries from it (M1 row-count technique).
7. Full `swift test` green; `xcodebuild` clean.

User-live:

8. Author searches their real accumulated history (topic from a past meeting) — results feel instant (< 1s), passage tap lands in the right spot in meeting detail.
9. Author deletes one real meeting (confirm dialog) → gone from history and search; delete-everything walked on a scratch copy of the DB, not the real one.

## Checklist

- [x] Acceptance checks user-reviewed (M2 kickoff gate — approved 2026-07-24, amendments in ./milestone.md Integration notes)
- [ ] FTS5 migration + incremental index maintenance (TDD)
- [ ] Seeding generator + realistic-scale fixture DB
- [ ] Search query layer + ranking
- [ ] Search UI in History + passage deep-link into meeting detail (to slice-1 design)
- [ ] Per-meeting delete cascade + confirm UI
- [ ] Delete-everything + type-to-confirm guard
- [ ] Verifier re-runs checks 1–7 with evidence
- [ ] Live checks 8–9 walked with author
- [ ] Ship rituals: slice table, integration notes, handoff, commit — and milestone close-out follows

## Notes / dead ends

(append as work proceeds)
