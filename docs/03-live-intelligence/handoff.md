# Handoff — Milestone 03 (Live Intelligence) — CLOSED

## Start here next session

**M3 is closed and merged (2026-08-12).** PR [#2](https://github.com/ogngnaoh/macapy.io/pull/2) landed on `main` at merge commit `95f1490626fbe3efb46d9df9e5d26bda8739b382`. The next session should discuss and plan Milestone 04 — Memory & Context before implementation.

Decide these first:

1. M4 slice order across cross-meeting memory, approved EventKit actions, document RAG, and pre-meeting briefs.
2. Memory control: what is extracted, when the user reviews it, provenance/edit/delete behavior, and what survives meeting deletion.
3. Calendar and Reminders scope, including the unresolved v1 calendar-source choice in PRD FR-016.
4. Document ingestion and embedding policy: supported formats, local versus provider processing, indexing, deletion, and spend/privacy boundaries.
5. M4 acceptance oracles and budgets before build work begins.

## Current state

- M1, M2, and M3 are closed; M4 and M5 remain pending in `../milestones.md`.
- M3 ships proactive answers and commitment flags, rolling summary, 90-second Catch Up, one-shot meeting Ask, strict context budgets, task arbitration, spend reservations, recovery, and diagnostics.
- AgentKit owns the per-meeting copilot orchestrator; AppShell projects observable presentation state. Finalized transcript turns arrive through TranscribeKit's non-replaying turn stream.
- Live AI is DeepSeek-only for the MVP. Production ignores stored model overrides, uses explicit output ceilings, accepts only natural `stop`, and persists no live cards, summaries, or queries.
- Schema remains `v5-search`; M3 preferences use the existing settings table and add no migration.
- Repository visibility is public. Keep credentials, private transcripts, prompts, and retained live-test logs out of git.

## Final verification baseline

- Credential-free Swift matrix: **526 tests / 87 suites** green.
- Xcode Debug build: green.
- Frozen live holdout: **1/100** false positives, **20/20** directed-question recall, **19/20** commitment recall, zero retries.
- AppShell trigger-to-visible G2: **p95 1,953.036 ms**; classifier and generation stage gates also passed.
- One-hour workload: **$0.17462964** estimated. Three-hour fixture: **585 request checks**, max **43,171 characters**, zero hard failures.
- Final architecture, reliability/privacy/spend, evidence, criteria, and release audits: clear.
- Automated accessibility, focus, layout, shortcut, and native-build evidence was accepted for M3; no manual app walk remains as a closure gate.

## Non-gating carry-forward

- Conservative uncertain spend debits are intentionally in-memory and do not survive a full app restart; revisit only if M4 introduces retry behavior that makes persistence necessary.
- M4 owns memory/RAG, attached-document grounding, external actions, cross-meeting context, and pre-meeting briefs. None were partially shipped in M3.
- Keep the established build loop: define deterministic acceptance checks, build in bounded slices, integrate in dependency order, then use fresh read-only verification.

## Arrival check

```sh
source .envrc
swift test
xcodebuild -project macapy.xcodeproj -scheme macapy build -quiet
```

Live DeepSeek suites are opt-in and serialized. Run them only with explicit authorization and a declared call/cost bound.
