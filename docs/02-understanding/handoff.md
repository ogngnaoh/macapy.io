# Handoff — Milestone 02 (Understanding)

## Start here next session

Slice 1 **shipped 2026-07-25**; slice 2 (ProviderKit) is **active**. First act: build the fake OpenAI-compatible server fixture in the test target (slice-02 doc decision 6), then TDD `LLMProvider`/`OpenAICompatibleClient` SSE streaming against it — the slice doc's front-loaded checks 1–8 are the machine gate, and the fake server is reused by slice 3 and M3. The Providers/Spend settings tabs are built to the approved mockups (`design/06-settings.html`). Before live checks 9–11: the author needs a working DeepSeek key + small balance. Live check 11 (as amended at the kickoff gate) is a real full-length no-key meeting with the network monitor running — passing it retires M1 exit criterion 4.

## Current state

- Slice 1 shipped: "Quiet instrument" design system approved and translated. Sources of truth: `design/` (HTML mockups + tokens.css, synced to Claude Design project "macapy — Quiet instrument") and `Sources/AppShell/Design/` (adaptive tokens, bundled Martian Mono/OFL + FontRegistrar, SignalStripView/TranscriptLineView/MeetingTimerText/EmptyStateView/SignalMark). Panel/History/menu bar/Settings reskinned; all six acceptance checks passed (record in slice-01 doc).
- Deferred by design: signal strip is session-state-driven — wire to real capture RMS in slice 4 (same audio path as memory watch); app icon asset → M5; menu bar glyph stays template-monochrome.
- DB clean as of 2026-07-25: 1 real meeting + 50 segments, zero orphans (junk deleted by id; backup `macapy.sqlite.backup-20260725-precleanup` beside the DB).
- Kickoff gate passed and test-pollution fix landed 2026-07-24 — machine checks count as evidence; `makePersistentStore` has no default (compile-time guard).
- Slices 3–5 pending. Key decisions: DeepSeek only live-verified provider (quirkiest profile — good stress test); no EventKit in M2; auto speaker labels; memory watch in slice 4.

## Open concerns

- DeepSeek key + small balance required before slice-2 live checks (machine checks 1–8 need none).
- FluidAudio vetting before slice 4: license/size/maintenance **plus** empirical two-voice `say`-fixture separation run (gate amendment).
- M1 exit criterion 4 (zero-network) still owner-attested — slice-2 live check 11 is its designated retirement.
- 7 NEEDS-CLARIFICATION markers in PRD/SPEC stand; none block M2 as planned.
