# Handoff — Milestone 01 (Spine)

## Start here next session

Run the M1 implementation-planning session for **slice 1** (app skeleton): read PRD.md, SPEC.md §5–6, and this milestone's doc, then write the slice plan before any Swift code. The dedicated frontend design session (screen/state inventory for the menu bar + panel + window shell) can happen before or in parallel — M1 UI stays functional-minimal either way.

## Current state

- PRD.md and SPEC.md approved at repo root (2026-07-16); milestone map derived; M1 slice 1 active. No Swift code exists yet.
- v0 fully archived: the `legacy` branch preserves the Electron/FastAPI stack; main is documentation-only and was force-pushed over the stale Dec-2025 origin snapshot. Local v0 artifacts and v0-era project skills (frontend-design, llm-orchestration, realtime-transcription) are deleted.
- CLAUDE.md at root is an interim pointer file — regenerate with commands/stack/structure once the Swift skeleton exists.

## Open concerns

- 7 [NEEDS CLARIFICATION] markers across PRD/SPEC (locale scope, calendar sources, dual-meeting audio, SQLCipher-vs-FileVault) — none block M1.
- SpeechAnalyzer real-world accuracy on meeting audio is unvalidated by us — slice 2 is the earliest proof point; the STTEngine protocol is the escape hatch.
- Process-tap permission UX (TCC) needs hands-on validation early in slice 3.
- `.claude/skills/project-restructure` is Python-focused and likely irrelevant to the Swift repo — prune or rewrite when convenient.
