# Handoff — Milestone 01 (Spine)

## Start here next session

Run the slice-2 planning-then-implementation session: mic capture (AVAudioEngine, 16kHz) → SpeechAnalyzer → live transcript in the panel (volatile grey / final solid). Read SPEC §6.3–6.4 (STTEngine protocol, TranscriptEvent, live-transcript flow) and slice-01's doc for conventions. Write the slice-2 working doc with acceptance checks before code, get user review, then implement. First technical step: validate SpeechAnalyzer's real API surface against the macOS 26 SDK — our docs describe intent, not verified signatures.

## Current state

- Slice 1 (app skeleton) **shipped 2026-07-16**, all 6 acceptance checks verified (see docs/01-spine/slice-01-app-skeleton.md): tests red→green across commits 2dc5dbf→HEAD, xcodebuild clean on Xcode 26.6, live checks walked by the user, 0 network connections.
- Working skeleton: menu bar accessory app, ⌥⌘M toggles a non-activating floating panel, dynamic activation policy for history/settings windows. `SessionController` (idle ⇄ capturing) is the seam slice 2 hooks the pipeline into; `AppShellCoordinator.syncPanel()` is where start/stop side effects live.
- Build: `xcodebuild -project macapy.xcodeproj -scheme macapy build`; tests: `swift test`. Requires Xcode 26 selected (`xcode-select -p` → /Applications/Xcode.app).
- Root CLAUDE.md regenerated with commands/stack/structure (no longer the interim pointer).

## Open concerns

- SpeechAnalyzer accuracy + exact API shape unvalidated — slice 2 is the proof point; STTEngine protocol is the escape hatch (SPEC N1).
- Mic TCC prompt UX: ad-hoc-signed debug builds may re-prompt after rebuilds; watch for it in slice 2, relevant to slice-3 process-tap TCC too.
- Panel is fixed-size/fixed-position functional-minimal; frontend design session still pending (fine per milestone non-goals).
- swift-log dropped in favor of os.Logger; sandbox decision deferred to slice 3 — both flagged as SPEC amendments to make when convenient.
- 7 NEEDS-CLARIFICATION markers in PRD/SPEC stand (locale, calendar sources, dual-meeting audio, SQLCipher) — none block M1.
