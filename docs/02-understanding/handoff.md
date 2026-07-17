# Handoff — Milestone 02 (Understanding)

## Start here next session

M2 does not start until M1's close-out pass ships (see ../01-spine/handoff.md — cold start, real-meeting dogfood, zero-network). Once 01 is shipped and 02 flipped active: **first act is the kickoff gate** — walk the user through the five slice-doc acceptance checks for review (they were written 2026-07-17 during planning, before any implementation; the verification convention requires user review before work begins). Then begin slice 1 with the aesthetic-direction interview (frontend-design skill) — do not generate mockups before that interview.

## Current state

- Milestone fully planned 2026-07-17 (interview-driven, plan approved): design-first structure, five slices — 1 whole-product design pass (Claude Design → SwiftUI reskin), 2 ProviderKit, 3 post-meeting agent, 4 diarization + memory watch, 5 history & search + deletion. All pending; nothing built.
- Exit criteria (7) in milestone.md; per-slice acceptance checks front-loaded in slice docs 01–05.
- SPEC.md amended (§6.5) with the seven M1 findings; milestones.md carries the design-first note.
- Key planning decisions: DeepSeek is the only live-verified provider (author's key; quirkiest profile — good stress test); no EventKit in M2 (approve = status flip only); speaker labels automatic, no renaming; memory watch folded into slice 4; format listener + diagnostics fed-clock stay on backlog.

## Open concerns

- Author needs a working DeepSeek key + small balance before slice 2's live checks (slice 1 needs none).
- FluidAudio dep must be vetted (license/size/maintenance) before slice 4 adds it — first new dep since GRDB.
- Slice-1 scope risk: "whole product" mockups can balloon — M4/M5 screens are directional only; the design *system* is the durable artifact. Timebox iteration rounds.
- Claude Design → SwiftUI is a hand-translation; side-by-side sign-off (slice-1 check 4) is the honesty check.
- 7 NEEDS-CLARIFICATION markers in PRD/SPEC still stand; none block M2 slices as planned (SQLCipher/locale/calendar/dual-meeting are M5/M4 concerns).
