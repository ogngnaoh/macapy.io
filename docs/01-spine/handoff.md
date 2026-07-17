# Handoff — Milestone 01 (Spine)

## Start here next session

One thing stands between here and shipping milestone 01: the **close-out pass**. Walk the three remaining exit-criteria checks with the user, in one sitting if possible:

1. **Cold start < 2s** — launch to menu-bar-ready (~10s to check).
2. **Real-meeting dogfood** — a genuine call end-to-end: dual-source transcript live in the panel, persisted, reopened from History (exit criterion 2, deferred since slice 3).
3. **Zero-network during that meeting** — `lsof -i -a -p $(pgrep -x macapy)` stays empty (speech model already installed; no download traffic expected).

On pass, run the ship ritual in one commit: `docs/milestones.md` 01 → shipped / 02-understanding → active; mark the close-out in `milestone.md`; replace this handoff with a one-line pointer to `../02-understanding/handoff.md`. **Do not plan M2 — it is already fully planned and committed** (17defbd, 2026-07-17: milestone doc, five front-loaded slice docs, SPEC §6.5 amendments). M2 kickoff = user reviews the slice-doc acceptance checks, then slice 1's aesthetic-direction interview (frontend-design skill) — no mockups before that interview.

## Current state

- M1 slices 1–5 all shipped 2026-07-16/17; full trail in this folder's slice docs.
- **G1 proven**: release harness p95 **85.36ms** speech-to-visible (p50 32.97ms, 775 volatiles, 0 excluded, passG1 true); JSON verbatim in slice-05 Notes. Headphones (criterion 3) and pause/ephemeral (criterion 5 parts) proven in slices 3–4.
- App: dual-stream You/Them live transcript (volatile italic-secondary → final solid), GRDB persistence + History window, ephemeral mode, ⌥⌘M start/stop + ⌥⌘P pause, Settings diagnostics with live percentiles. 74/74 tests, 14 suites, zero flakes; sole dep GRDB 7.11.1; unsandboxed (confirmed hands-on).
- **M2 planned** (docs/02-understanding/): design-first — slice 1 is a whole-product design pass (all primary screens through M5, generated → reviewed in a Claude Design project via /design-sync → hand-translated to SwiftUI `AppShell/Design/` + reskin), then ProviderKit → post-meeting agent → diarization (+G4 memory watch) → history & search. DeepSeek is the only live-verified provider. M1 backlog dispositioned: SPEC amendments folded into §6.5; memory watch pulled into M2 slice 4; format listener + diagnostics fed-clock stay backlog (recorded in 02's Integration notes).
- Execution model to reuse (recorded in 02's planning): builder subagent (TDD, model tiered) → critic on risky slices → fresh-context verifier with evidence → user-walked live checks → ship ritual; handoff rewritten at every role boundary.
- Commands: `swift test`; `xcodebuild -project macapy.xcodeproj -scheme macapy build`; harness: `swift run -c release macapy-latency Tests/TranscribeKitTests/Fixtures/long-meeting.wav`.

## Open concerns

- The three close-out checks above are M1's only unproven exit-criteria claims.
- Before M2 slice 2's live checks the author needs a DeepSeek key with a small balance (slice 1 needs no credentials); before slice 4, FluidAudio must be vetted (license/size/maintenance) — first new dep since GRDB.
- Clean-machine model-download path never exercised (matters for M5 clone-and-run).
- 7 NEEDS-CLARIFICATION markers in PRD/SPEC stand (locale, calendar sources, dual-meeting audio, SQLCipher); none block M2 as planned.
