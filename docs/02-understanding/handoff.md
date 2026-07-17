# Handoff — Milestone 02 (Understanding)

## Start here next session

M2 is **active** (M1 shipped 2026-07-17). First act is the **kickoff gate**: walk the user through the five slice-doc acceptance checks for review (written 2026-07-17 during planning, before any implementation; the verification convention requires user review before work begins). Second act, before or alongside slice 1: **fix the test-pollution defect** (below) — it's small, and every `swift test` run until then keeps writing junk into the real DB. Then begin slice 1 with the aesthetic-direction interview (frontend-design skill) — do not generate mockups before that interview.

## Current state

- Milestone fully planned 2026-07-17 (interview-driven, plan approved): design-first, five slices — 1 whole-product design pass (Claude Design → SwiftUI reskin), 2 ProviderKit, 3 post-meeting agent, 4 diarization + memory watch, 5 history & search + deletion. All pending; nothing built.
- Exit criteria (7) in milestone.md; per-slice acceptance checks front-loaded in slice docs 01–05.
- M1 close-out record (../01-spine/milestone.md Integration notes, incl. same-day correction): cold start proven (0.417s launch→checkin cold, Debug); criterion 2 evidenced after all (real dual-source 2m14s meeting found persisted in the DB during cleanup); **criterion 4 (zero-network during a full meeting) remains owner-attested, not machine-observed** — monitor the first M2 dogfood meeting to retire it.
- Key planning decisions: DeepSeek is the only live-verified provider (author's key; quirkiest profile — good stress test); no EventKit in M2 (approve = status flip only); speaker labels automatic, no renaming; memory watch folded into slice 4; format listener + diagnostics fed-clock stay backlog.

## Open concerns

- **Test-pollution defect (found at M1 close-out, proven 85→87 rows across one test run):** `AppShellCoordinator`'s default `makePersistentStore` falls through to `productionMeetingStore` (AppShellCoordinator.swift:47,83), so some AppShellTests write real rows into `~/Library/Application Support/macapy/macapy.sqlite`. Fix = route tests to `.inMemory()`/temp path. Junk rows were cleaned with owner go-ahead 2026-07-17 (86 deleted; the one real meeting kept) — but every `swift test` run re-pollutes until the fix lands.
- Author needs a working DeepSeek key + small balance before slice 2's live checks (slice 1 needs none).
- FluidAudio must be vetted (license/size/maintenance) before slice 4 adds it — first new dep since GRDB.
- Slice-1 scope risk: "whole product" mockups can balloon — M4/M5 screens are directional only; the design *system* is the durable artifact. Timebox iteration rounds.
- Claude Design → SwiftUI is a hand-translation; side-by-side sign-off (slice-1 check 4) is the honesty check.
- 7 NEEDS-CLARIFICATION markers in PRD/SPEC still stand; none block M2 as planned.
