# Slice 1 — App Skeleton

**Status:** in progress
**Plan approved:** 2026-07-16 (decisions made interactively; acceptance checks reviewed before implementation)
**References:** ../../SPEC.md §5–6, ./milestone.md

The plan for this slice is also its record (working-doc convention). Checklist below is current state.

## Design

### Decisions (made with the user, 2026-07-16)

1. **Scaffolding:** committed `macapy.xcodeproj` containing only a thin app target; all six modules (`AppShell`, `CaptureKit`, `TranscribeKit`, `PersistKit`, `AgentKit`, `ProviderKit`) are targets of one local SPM package at repo root that the app target imports. No xcodegen/Tuist — clone → open → run.
2. **App presence:** accessory app (`LSUIElement`, no Dock icon) with dynamic activation policy — flips to `.regular` while the history/settings window is open, back to `.accessory` when it closes. The floating panel is non-activating and never steals focus.
3. **Hotkey:** hand-rolled Carbon `RegisterEventHotKey` wrapper in AppShell, fixed default ⌥⌘M, zero dependencies, no Accessibility permission. User-configurable shortcuts deferred to M5 settings UI.
4. **Dependencies:** none in this slice. Logging via native `os.Logger` with per-module categories — SPEC §5 lists swift-log, but os_log satisfies SPEC §8 observability with zero deps; treat swift-log as a SPEC amendment candidate if no need materializes.
5. **Sandbox:** debug builds unsandboxed; the App Sandbox decision is deferred to slice 3 when process-tap TCC behavior is validated hands-on.
6. **Identity:** bundle id `io.macapy.app`, app name **macapy**, deployment target macOS 26.0, Swift language mode 6, strict concurrency.

### Layout

```
macapy.xcodeproj    thin app target only (synchronized App/ folder + local package ref)
App/                @main shim importing AppShell; Info.plist (LSUIElement); entitlements; assets
Package.swift       local package, six targets
Sources/AppShell/   all slice-1 logic
Sources/<others>/   empty placeholders (one file each so targets compile — no speculative types)
Tests/AppShellTests swift-testing
```

### AppShell components

- **`SessionController`** — `@MainActor @Observable`; `SessionState` enum `.idle` / `.capturing(startedAt:)` (`.paused` arrives in slice 4). API: `start()`, `stop()`, `toggle()`. Pure state transitions; this is the seam slices 2–4 hook their pipelines into. Written test-first.
- **`FloatingPanelController`** — `NSPanel`: `.nonactivatingPanel`, level `.floating`, `[.canJoinAllSpaces, .fullScreenAuxiliary]`, hosting `PanelView` (functional-minimal placeholder — no design investment per milestone non-goals).
- **`HotKey`** — Carbon `RegisterEventHotKey` wrapper, ⌥⌘M → `SessionController.toggle()`.
- **`ActivationPolicyController`** — `.accessory` ⇄ `.regular` keyed on history-window visibility.
- **Scenes** — `MenuBarExtra` (Start/Stop Meeting ⌥⌘M, Open History, Settings…, Quit) + `Window` with `HistoryPlaceholderView` (real list is slice 4).

## Acceptance checks (written before implementation; user-reviewed 2026-07-16)

1. `xcodebuild -project macapy.xcodeproj -scheme macapy build` succeeds from a clean clone with stock Xcode 26.
2. `swift test` passes; state-machine transition tests exist and predate the controller implementation (TDD).
3. Launching the app shows a menu bar item and no Dock icon; no windows appear at launch.
4. Start via menu item or ⌥⌘M → floating panel appears, always-on-top, does not steal focus from the frontmost app; stop → panel disappears. Rapid repeated toggles don't wedge the state machine.
5. Opening the history window flips the app into Cmd-Tab/Dock; closing it removes it again.
6. Zero network traffic, zero credentials involved (nothing in the skeleton can emit either).

## Checklist

- [x] Slice plan written and user-reviewed (this doc)
- [ ] Slice doc committed before any Swift code
- [ ] Package.swift with six targets + test target
- [ ] App/ shim, Info.plist, entitlements, assets
- [ ] Hand-authored macapy.xcodeproj + shared scheme
- [ ] SessionController tests (before implementation)
- [ ] SessionController
- [ ] FloatingPanelController + PanelView placeholder
- [ ] HotKey wrapper (⌥⌘M)
- [ ] ActivationPolicyController + scenes (MenuBarExtra, history Window)
- [ ] Build + tests green (needs Xcode 26 — install pending)
- [ ] Live acceptance checks 3–5 walked with the user
- [ ] Ship rituals: milestone/handoff/CLAUDE.md updated, final commit

## Notes / dead ends

(append as work proceeds)

- Xcode 26 not installed at session start (CLT-only, Swift 6.0.3, no macOS 26 SDK) — file scaffolding proceeds; build verification blocked until install completes.
- pbxproj is hand-authored; fallbacks agreed in plan: (a) move package into `MacapyKit/` if root-level Package.swift + sibling xcodeproj misbehaves, (b) one-shot local xcodegen generation, committed, no repo dependency.
