# Handoff — Milestone 01 (Spine)

## Start here next session

Run the M1 implementation-planning session for **slice 1** (app skeleton): read PRD.md, SPEC.md §5–6, and this milestone's doc, then write the slice plan before any Swift code. The dedicated frontend design session (screen/state inventory for the menu bar + panel + window shell) can happen before or in parallel — M1 UI stays functional-minimal either way.

## Current state

- PRD.md and SPEC.md approved and committed at repo root (2026-07-16); milestone docs derived; M1 slice 1 active.
- v0 archived: `legacy` branch preserves the full Electron/FastAPI stack; main now holds only the new docs and an interim CLAUDE.md. No Swift code exists yet.
- Untracked local v0 artifacts (node_modules/, .venv/, .pytest_cache/, .env) still sit on disk — safe to delete manually anytime.
- .claude/skills contains v0-era project skills (frontend-design, llm-orchestration, realtime-transcription) that now mislead — user decision pending on pruning/rewriting them.
- Full CLAUDE.md regeneration is queued for after the Swift skeleton exists.

## Open concerns

- Nothing is pushed: origin/main is a stale Dec-2025 v0 snapshot with divergent history. Publishing the rebuild requires the user to push `legacy` and force-push main (`--force-with-lease`) — user decision, not yet made.
- 7 [NEEDS CLARIFICATION] markers across PRD/SPEC (locale scope, calendar sources, dual-meeting audio, SQLCipher-vs-FileVault) — none block M1.
- SpeechAnalyzer real-world accuracy on meeting audio is unvalidated by us — slice 2 is the earliest proof point; the STTEngine protocol is the escape hatch.
- Process-tap permission UX (TCC) needs hands-on validation early in slice 3.
