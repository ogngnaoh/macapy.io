# Handoff — Milestone 02 (Understanding)

## Start here next session

Kickoff gate **passed 2026-07-24**: all five slice docs' acceptance checks reviewed and approved by the author, four amendments folded in (record in ./milestone.md Integration notes). First act now: **fix the test-pollution defect** (below) — hard precondition from the gate: no slice's machine checks count as evidence until it lands. Then begin slice 1 with the aesthetic-direction interview (frontend-design skill) — do not generate mockups before that interview.

## Current state

- Milestone fully planned 2026-07-17; kickoff gate passed 2026-07-24. Design-first, five slices — 1 whole-product design pass (Claude Design → SwiftUI reskin), 2 ProviderKit, 3 post-meeting agent, 4 diarization + memory watch, 5 history & search + deletion. All pending; nothing built.
- Exit criteria (7) in milestone.md; per-slice acceptance checks front-loaded in slice docs 01–05 and now user-approved as amended.
- M1 criterion 4 (zero-network during a full meeting) remains owner-attested; slice-2 live check 11 (amended: real full-length no-key meeting, monitor running throughout) is now the designated check that retires it.
- Key planning decisions: DeepSeek is the only live-verified provider (author's key; quirkiest profile — good stress test); no EventKit in M2 (approve = status flip only); speaker labels automatic, no renaming; memory watch folded into slice 4; format listener + diagnostics fed-clock stay backlog.

## Open concerns

- **Test-pollution defect (found at M1 close-out, proven 85→87 rows across one test run):** `AppShellCoordinator`'s default `makePersistentStore` falls through to `productionMeetingStore` (AppShellCoordinator.swift:47,83), so some AppShellTests write real rows into `~/Library/Application Support/macapy/macapy.sqlite`. Fix = route tests to `.inMemory()`/temp path. Junk rows were cleaned 2026-07-17 (86 deleted; the one real meeting kept) — but every `swift test` run re-pollutes until the fix lands.
- Author needs a working DeepSeek key + small balance before slice 2's live checks (slice 1 needs none).
- FluidAudio must be vetted before slice 4 adds it — license/size/maintenance **plus** (gate amendment) an empirical two-voice `say`-fixture separation run before committing to that fixture design.
- Slice-1 scope risk: "whole product" mockups can balloon — M4/M5 screens are directional only; the design *system* is the durable artifact. Timebox iteration rounds.
- Claude Design → SwiftUI is a hand-translation; side-by-side sign-off (slice-1 check 4) is the honesty check.
- 7 NEEDS-CLARIFICATION markers in PRD/SPEC still stand; none block M2 as planned.
