# Handoff — Milestone 01 (Spine)

## Start here next session

Run the M1 implementation-planning session for **slice 1** (app skeleton): read PRD.md, SPEC.md §5–6, and this milestone's doc, then write the slice plan before any Swift code. Before or alongside: settle the v0 archival decision (legacy branch) so the Swift project can start clean at repo root.

## Current state

- PRD.md and SPEC.md approved and committed at repo root (2026-07-16); milestone docs derived.
- No Swift code exists. The repo still contains the dead v0 stack (backend/, frontend/, old docs/, root CLAUDE.md) — archival to a `legacy` branch proposed but not yet confirmed by the user.
- CLAUDE.md regeneration is queued for after the repo reshape (current one describes v0).
- A dedicated frontend design session (screen/state inventory for menu bar + panel + window shell) is planned; M1 UI stays functional-minimal until then.

## Open concerns

- 7 [NEEDS CLARIFICATION] markers across PRD/SPEC (locale scope, calendar sources, dual-meeting audio, SQLCipher-vs-FileVault) — none block M1.
- SpeechAnalyzer real-world accuracy on meeting audio is unvalidated by us — slice 2 is the earliest proof point; if it disappoints, the STTEngine protocol is the escape hatch.
- Process-tap permission UX (TCC) needs hands-on validation early in slice 3.
