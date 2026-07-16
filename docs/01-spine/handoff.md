# Handoff — Milestone 01 (Spine)

## Start here next session

Install Xcode 26 if not done (`sudo xcode-select -s /Applications/Xcode.app`, accept license), then run slice-1 verification per docs/01-spine/slice-01-app-skeleton.md: (1) `swift test` at commit 2dc5dbf must FAIL (retroactive TDD red), (2) `swift test` at HEAD must pass, (3) `xcodebuild -project macapy.xcodeproj -scheme macapy build`, (4) walk acceptance checks 3–5 live with the user. Then ship rituals.

## Current state

- Slice 1 (app skeleton) is **code-complete, unverified** — nothing has ever been built (no Xcode 26 on the machine at authoring time; CLT-only).
- Committed: slice doc (53f6c1e) → scaffolding (7055263) → tests-only red commit (2dc5dbf) → AppShell implementation (aec10af).
- Structure: root Package.swift (six module targets, zero deps), thin hand-authored macapy.xcodeproj (synchronized App/ folder, local package ref "."), App/ shim with LSUIElement Info.plist.
- AppShell: SessionController (idle ⇄ capturing, tested), non-activating floating NSPanel, Carbon ⌥⌘M hotkey, dynamic activation policy, MenuBarExtra + history/settings scenes.
- Decisions logged in the slice doc: no swift-log (os.Logger; SPEC amendment candidate), sandbox deferred to slice 3, no panel close button, bundle id io.macapy.app.

## Open concerns

- **Hand-authored pbxproj is unproven.** First Xcode open may reject the root-level local package ref ("."). Agreed fallbacks in slice doc: move package to MacapyKit/, or one-shot xcodegen. Same for the scheme's `PACKAGE-TARGET:AppShellTests` testable reference — `swift test` is the authoritative check.
- `.defaultLaunchBehavior(.suppressed)` / `.restorationBehavior(.disabled)` and SE-0411-dependent `@State` init isolation are untested against the real macOS 26 SDK — expect possible small compile fixes on first build.
- CLAUDE.md at root is still the interim pointer file — regenerate at slice ship (part of rituals, deliberately not done pre-verification).
- Prior concerns stand: SpeechAnalyzer accuracy unvalidated (slice 2), process-tap TCC UX (slice 3), 7 NEEDS-CLARIFICATION markers in PRD/SPEC (none block M1).
