import Carbon.HIToolbox
import os

/// Minimal wrapper around Carbon's RegisterEventHotKey — the only macOS API
/// for global hotkeys that requires no Accessibility permission. Fixed
/// shortcuts only; user-configurable shortcuts are deferred to the M5
/// settings UI.
@MainActor
final class HotKey {
    // nonisolated(unsafe): set once in init, released in deinit; Carbon
    // hot-key registration lives on the main run loop, and Swift 6 deinits
    // are nonisolated so plain @MainActor storage can't be touched there.
    private nonisolated(unsafe) var hotKeyRef: EventHotKeyRef?
    private nonisolated(unsafe) var eventHandlerRef: EventHandlerRef?
    private let handler: @MainActor () -> Void
    private static let signature: OSType = 0x4D43_5059 // 'MCPY'
    private static let log = Logger(subsystem: "io.macapy.app", category: "HotKey")

    /// ⌥⌘M — start/stop meeting.
    static func startStopMeeting(handler: @escaping @MainActor () -> Void) -> HotKey {
        HotKey(
            keyCode: UInt32(kVK_ANSI_M),
            carbonModifiers: UInt32(optionKey | cmdKey),
            id: 1,
            handler: handler
        )
    }

    init(keyCode: UInt32, carbonModifiers: UInt32, id: UInt32, handler: @escaping @MainActor () -> Void) {
        self.handler = handler

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let installStatus = InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, _, userData -> OSStatus in
                guard let userData else { return noErr }
                let hotKey = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
                // Carbon dispatches hot-key events on the main run loop.
                MainActor.assumeIsolated {
                    hotKey.handler()
                }
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandlerRef
        )
        guard installStatus == noErr else {
            Self.log.error("InstallEventHandler failed: \(installStatus)")
            return
        }

        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        let registerStatus = RegisterEventHotKey(
            keyCode,
            carbonModifiers,
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &hotKeyRef
        )
        if registerStatus != noErr {
            Self.log.error("RegisterEventHotKey failed: \(registerStatus)")
        }
    }

    deinit {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }
    }
}
