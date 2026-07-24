# Handoff — Milestone 02 (Understanding)

## Start here next session

Slice 1 is mid-flight at its review gate: the full mockup bundle is synced to the Claude Design project **"macapy — Quiet instrument"** (id 551c0adb-9714-4d9b-86aa-5b6ed268d78f) — the author reviews it in the browser, feedback gets folded into `design/` and re-synced, then approval unlocks the SwiftUI translation (`Sources/AppShell/Design/` tokens + components, then reskin). Do not start the SwiftUI translation before browser approval (slice-01 check 3).

## Current state

- Kickoff gate passed and test-pollution fix landed 2026-07-24 (records in ./milestone.md Integration notes). Machine checks may now count as evidence.
- Slice 1 active: aesthetic direction "Quiet instrument" interviewed, approved, and recorded in slice-01 Notes (graphite + VU-amber signal; machine-speaks-mono/humans-speak-SF; signal-strip signature; volatile = slate + dotted baseline). Mockups for every inventory screen (light + dark) live in `design/` — shared `tokens.css`, bundled Martian Mono — and are uploaded to the Claude Design project. Awaiting author browser review.
- Slices 2–5 pending. M1 criterion 4 retirement rides on slice-2 live check 11 (real full-length no-key meeting, monitor running).
- Key decisions: DeepSeek only live-verified provider; no EventKit in M2; auto speaker labels; memory watch in slice 4.

## Open concerns

- 2 junk rows (2026-07-24, sub-second, from the pollution-fix RED run) may still await owner deletion from the production DB (delete was permission-blocked for Claude; keep the one real 2026-07-17 meeting). Check count: 3 = pending, 1 = done.
- Claude Design pane rendering of shared-asset references (`tokens.css`, fonts) is unverified — if cards render unstyled in the pane, inline the CSS per file and re-sync.
- Author needs a working DeepSeek key + small balance before slice 2's live checks.
- FluidAudio vetting before slice 4: license/size/maintenance + empirical two-voice `say`-fixture separation run.
- Slice-1 scope: M4/M5 mockups are directional only; timebox iteration rounds. Claude Design → SwiftUI is a hand-translation; side-by-side sign-off (check 4) is the honesty check.
- 7 NEEDS-CLARIFICATION markers in PRD/SPEC still stand; none block M2.
