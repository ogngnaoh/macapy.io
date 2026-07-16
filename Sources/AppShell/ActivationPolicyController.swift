import AppKit

/// macapy is an accessory app (no Dock icon). While at least one regular
/// window (history, settings) is open, the app flips to `.regular` so those
/// windows behave normally (Cmd-Tab, Dock); it flips back when the last one
/// closes. The floating panel is not a regular window and never triggers this.
@MainActor
final class ActivationPolicyController {
    private var regularWindowCount = 0

    func regularWindowAppeared() {
        regularWindowCount += 1
        if regularWindowCount == 1 {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate()
    }

    func regularWindowDisappeared() {
        regularWindowCount = max(0, regularWindowCount - 1)
        if regularWindowCount == 0 {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
