import AppKit
import SwiftUI
import TranscribeKit

/// The panel surface the coordinator drives. Abstracted so AppShell tests can
/// substitute a no-op and never build an NSPanel/NSHostingView headlessly.
@MainActor
protocol PanelPresenting {
    func show(session: SessionController, store: TranscriptStore, copilot: LiveCopilotModel)
    func hide()
}

/// Owns the compact always-on-top floating panel shown while a session runs.
/// Non-activating: it never steals key/focus from the meeting app. No close
/// button — the session ends via ⌥⌘M or the menu bar, keeping panel
/// visibility and session state in lockstep.
@MainActor
final class FloatingPanelController: PanelPresenting {
    private var panel: NSPanel?
    private static let panelSize = NSSize(width: 340, height: 470)

    func show(session: SessionController, store: TranscriptStore, copilot: LiveCopilotModel) {
        if panel == nil {
            panel = makePanel(session: session, store: store, copilot: copilot)
        }
        panel?.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel(
        session: SessionController,
        store: TranscriptStore,
        copilot: LiveCopilotModel
    ) -> NSPanel {
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
        panel.contentView = NSHostingView(
            rootView: PanelView()
                .environment(session)
                .environment(store)
                .environment(copilot)
        )
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
