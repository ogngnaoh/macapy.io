# Milestone 02 — Understanding

**Status:** active (since 2026-07-17 — M1 shipped)
**Planned:** 2026-07-17 (interview-driven planning session; decisions in Integration notes)
**References:** ../../PRD.md (FR-008, FR-009 partial — review only, FR-010, FR-013 completes, FR-014, FR-015), ../../SPEC.md §6.3–6.4, G3, G5, G6

## Goal

The author's real meetings come out *understood*, not just transcribed — a speaker-separated transcript, and within 60 seconds of meeting end a reviewable draft of summary/decisions/action items generated on the author's own key, in an app that finally looks designed.

## Scope

- **Whole-product design pass** (the dedicated frontend design session M1 deferred): design system + every primary screen through M5, generated locally and reviewed in a Claude Design project; approved system translated to SwiftUI tokens/components (`Sources/AppShell/Design/`) and the existing surfaces reskinned.
- **ProviderKit becomes real:** `LLMProvider` / `OpenAICompatibleClient` (URLSession SSE streaming), endpoint profiles (OpenAI, OpenRouter, DeepSeek, Ollama) with quirks descriptors, Keychain-only key storage, spend ledger + per-meeting cap (FR-015), Providers/Spend settings screens, fake OpenAI-compatible server test harness.
- **Post-meeting agent v1:** meeting-end trigger → one structured-output extraction pass → `artifacts` rows in `draft` → review UI (approve/reject flips status only); retroactive generation after provider outage; G3 < 60s.
- **Diarization:** FluidAudio on the *them* stream, `speakers` schema, speaker labels in panel and meeting detail; you/them from M1 unchanged.
- **History & search:** FTS index over titles/transcripts/artifacts, < 1s at realistic scale (FR-010); per-meeting deletion with cascade + delete-everything (completes FR-013).
- **Memory-watch hardening (G4 pull-in from M1 backlog):** bounded buffering on the audio→analyzer path under stall, memory readout in diagnostics.

## Non-goals

- No EventKit writes — approving an action item only flips its status; Reminders/Calendar is M4.
- No live copilot: no cascade, no query box, no rolling summary, no catch-up (M3 — their panel states are *designed* now, built later).
- No memory, RAG, or briefs (M4); no onboarding UX build (M5 — designed only).
- No native Anthropic client (SPEC N2); no second STT engine (N1).
- No speaker renaming/persistence across meetings — auto labels ("Speaker 1/2") only; cross-meeting speaker identity is M4 territory.

## Slices

| # | Slice (end-to-end, independently shippable) | Status |
|---|---|---|
| 1 | Whole-product design pass in Claude Design + SwiftUI design system + reskin of existing surfaces ([plan/record](./slice-01-design-pass.md)) | pending |
| 2 | ProviderKit: OpenAI-compatible streaming client, endpoint profiles + quirks, Keychain, spend ledger + cap, Providers/Spend settings UI, fake-server tests ([plan/record](./slice-02-providerkit.md)) | pending |
| 3 | Post-meeting agent v1: meeting-end trigger → structured extraction → draft artifacts → review UI; G3 < 60s; retroactive generation ([plan/record](./slice-03-post-meeting-agent.md)) | pending |
| 4 | Diarization (FluidAudio, them-stream) + speakers schema + labels; memory-watch hardening ([plan/record](./slice-04-diarization.md)) | pending |
| 5 | History & search: FTS index, search UI, < 1s at seeded scale; per-meeting delete + delete-everything ([plan/record](./slice-05-history-search.md)) | pending |

## Integration notes

(Decisions and dead ends worth remembering — append as work proceeds.)

- 2026-07-24 (kickoff gate passed): author reviewed and approved all five slice docs' acceptance checks (verification convention satisfied — checks precede implementation and are now user-reviewed). Four amendments folded in at review: (1) slice-2 live check 11 upgraded to a real, full-length no-key meeting with the network monitor running throughout — passing it formally retires M1 exit criterion 4 (owner-attested until then); (2) **hard precondition: no slice's machine checks count as evidence until the test-pollution fix lands** (`AppShellCoordinator` default store falls through to the production DB; every `swift test` run writes junk rows and would contaminate slice-5's search/deletion evidence); (3) slice-4 FluidAudio vetting now includes an empirical two-voice `say`-fixture separation run before the slice commits to that fixture design; (4) slice-1 check 6 reworded "preserved" → "present" (the reskin completes any partial M1 accessibility coverage). Next: land the test-pollution fix, then slice 1's aesthetic-direction interview.
- 2026-07-24 (test-pollution fix landed — gate precondition cleared): TDD'd against the pre-existing close-out row-count check. RED: running `staleDrainFinalsDoNotLeakAcrossResetWithMultipleTeardowns` alone drove the production DB 1→3 meetings — the inline coordinator construction (MeetingPipelineTests.swift:301) injected a pipeline but not `makePersistentStore`, falling through to `productionMeetingStore`; P1+P3's persistent starts are exactly the 2 rows/run seen at close-out. GREEN: that call site now injects `MacapyDatabase.inMemory()`, and the defect *class* is dead at compile time — `makePersistentStore` lost its default value (AppShellCoordinator.swift), so every caller must choose a store; the app's composition root (AppShellScenes.swift) now passes `productionMeetingStore` explicitly. Evidence: filtered test and full suite (74 tests / 14 suites) green with meeting count unchanged (3→3); `xcodebuild` clean. Disclosures per verification convention: the fix edited the offending test's construction (assertions untouched) — part of what needs review; the RED run itself wrote 2 sub-second junk rows (2026-07-24) whose deletion was permission-blocked in-session — owner to run the one-liner cleanup. (docs land now; execution starts after 01 ships). Interview decisions: **design-first** — the design pass is slice 1 and covers the *whole product* (all primary screens through M5) so later milestones implement within a settled system; workflow is Claude-generates → user reviews in a Claude Design project (`/design-sync`) → approved system hand-translated to SwiftUI (no new SPM target; tokens/components live in `AppShell/Design/`). Slice order Provider → Agent → Diarization → Search (only hard dependency: agent needs provider; LLM value chain lands earliest). **DeepSeek is the only live-verified provider in M2** (the author's key); it is also the quirkiest profile (`reasoning_content` passback, thinking-mode sampling), so the quirks layer gets real exercise — other profiles are fake-server-tested only. Backlog pulls: SPEC amendments folded into SPEC.md §6.5 in the planning commit; memory watch (G4) folded into slice 4. Left on backlog: mid-capture format listener (unreproduced), diagnostics fed-clock.

## Exit criteria

Written before implementation (verification convention); slice-doc acceptance checks refine these.

1. Every primary screen (slice-01 inventory) exists as an approved mockup in the Claude Design project; panel, history, settings, and menu bar are reskinned in SwiftUI and the user signs off side-by-side against the mockups, in light and dark mode.
2. A real meeting ends → draft summary, decisions, and action items (owner/deadline where stated) appear as `artifacts` rows within 60s (G3), generated via DeepSeek on the author's key; approve/reject flips status; reject creates nothing anywhere.
3. Zero-credential run still fully works — capture, transcript, history, quiet setup prompt, zero network (G6 regression). API keys exist only in Keychain (DB + log inspection proves it). Fake-server suite covers streaming, structured output, `reasoning_content` passback, mid-stream disconnect, and 429/5xx degradation-and-recovery.
4. A real multi-party meeting shows ≥ 2 distinct them-speakers labeled consistently in panel and meeting detail; you/them attribution from M1 unchanged.
5. With seeded history at realistic scale (≥ 50 meetings incl. multi-hour transcripts), search over titles/transcript text/artifacts returns in < 1s; per-meeting deletion cascades (segments/artifacts/spend/speakers) and delete-everything empties all user-data tables.
6. Every LLM call writes a `spend_ledger` row (model, tokens, est. cost, purpose); per-meeting usage + estimated cost are visible; cap reached → agent halts with a visible notice, capture/transcription unaffected.
7. Active memory < 400MB during a 1-hour meeting (diagnostics readout); bounded-buffer behavior under simulated analyzer stall proven by test.
