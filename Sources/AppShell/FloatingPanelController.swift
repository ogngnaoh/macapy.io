import AppKit
import SwiftUI

/// Owns the compact always-on-top floating panel shown while a session runs.
/// Non-activating: it never steals key/focus from the meeting app. No close
/// button — the session ends via ⌥⌘M or the menu bar, keeping panel
/// visibility and session state in lockstep.
@MainActor
final class FloatingPanelController {
    private var panel: NSPanel?
    private static let panelSize = NSSize(width: 320, height: 160)

    func show(session: SessionController) {
        if panel == nil {
            panel = makePanel(session: session)
        }
        panel?.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel(session: SessionController) -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.contentView = NSHostingView(rootView: PanelView().environment(session))
        position(panel)
        return panel
    }

    /// Top-right corner of the main screen, below the menu bar.
    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let margin: CGFloat = 16
        panel.setFrameOrigin(NSPoint(
            x: visible.maxX - Self.panelSize.width - margin,
            y: visible.maxY - Self.panelSize.height - margin
        ))
    }
}
