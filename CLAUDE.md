# CLAUDE.md

macapy — local-first, invisible, agentic meeting assistant for macOS. Native Swift rebuild; the v0 Electron/FastAPI app is archived on the `legacy` branch and is the negative example, never guidance.

Responses: concise, ADHD-friendly — lead with the action, cut preamble and caveats.

## Pointers

- @PRD.md / @SPEC.md — approved product and architecture docs

## Commands

- Build app: `xcodebuild -project macapy.xcodeproj -scheme macapy build`
- Run tests: `swift test` (swift-testing; package-level, covers all modules)
- Run app: build, then `open` the product from DerivedData, or run the `macapy` scheme in Xcode
- Requires Xcode 26+ selected: `xcode-select -p` → `/Applications/Xcode.app/Contents/Developer`

## Stack & structure

Swift 6 (strict concurrency), SwiftUI, macOS 26+, Apple Silicon only. One local SPM package (root `Package.swift`, zero dependencies so far) with six targets; `macapy.xcodeproj` holds only a thin app target over a synchronized `App/` folder (shim, Info.plist, entitlements).

- `Sources/AppShell/` — menu bar extra, floating panel, session state machine, hotkey; the only module importing SwiftUI app plumbing
- `Sources/CaptureKit|TranscribeKit|PersistKit/` — empty until their M1 slice
- `Sources/AgentKit|ProviderKit/` — stubs through M1
- `Tests/AppShellTests/` — swift-testing

## Conventions & gotchas

- Acceptance checks are written and user-reviewed before implementation begins.
- Accessory app (`LSUIElement`): no Dock icon; regular windows flip activation policy via `ActivationPolicyController`. The floating panel is a non-activating `NSPanel` (`hidesOnDeactivate` must stay false) with no close button — panel visibility stays in lockstep with `SessionController` state.
- Global hotkey is hand-rolled Carbon `RegisterEventHotKey` (only no-Accessibility-permission option); Carbon refs are `nonisolated(unsafe)` because Swift 6.3 forbids @MainActor storage access from nonisolated deinit.
- Logging: `os.Logger`, subsystem `io.macapy.app`, one category per module. No swift-log.
- Never persist or transmit raw audio; zero network traffic outside the user-configured LLM endpoint (PRD G4) — there is no networking code at all until M2 ProviderKit.
