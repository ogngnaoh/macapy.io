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
    /// This instance's own hot-key id, checked against each dispatched event
    /// (see the gotcha in `init` below — every `HotKey` installs its own
    /// event handler, so with 2+ instances registered, an unfiltered handler
    /// would fire for whichever key the *other* instance's handler runs on).
    private let id: UInt32
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

    /// ⌥⌘P — pause/resume the running meeting (slice 4).
    static func pauseResumeMeeting(handler: @escaping @MainActor () -> Void) -> HotKey {
        HotKey(
            keyCode: UInt32(kVK_ANSI_P),
            carbonModifiers: UInt32(optionKey | cmdKey),
            id: 2,
            handler: handler
        )
    }

    init(keyCode: UInt32, carbonModifiers: UInt32, id: UInt32, handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        self.id = id

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let installStatus = InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, event, userData -> OSStatus in
                guard let userData else { return noErr }
                let hotKey = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
                // GOTCHA: each `HotKey` instance installs its own event
                // handler on the shared dispatcher target, and Carbon's
                // handler chain runs the most-recently-installed handler
                // first. Without filtering by id here, registering a second
                // hotkey would make ITS handler unconditionally fire for
                // BOTH keys (it never checks which one was actually
                // pressed) — the first-installed handler would never run
                // again. Extract the event's own hot-key id and only
                // handle a match; otherwise decline so Carbon calls the
                // next handler in the chain.
                var pressedID = EventHotKeyID()
                let paramStatus = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &pressedID
                )
                guard paramStatus == noErr, pressedID.id == hotKey.id else {
                    return OSStatus(eventNotHandledErr)
                }
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
