import AppKit
import CoreText
import SwiftUI
import os

/// Registers the bundled Martian Mono variable font (OFL — license alongside
/// the file) with the process once, so its named instances resolve by
/// PostScript name. Idempotent; safe to call from any view or scene init.
enum FontRegistrar {
    private static let registered: Bool = {
        guard let url = Bundle.module.url(
            forResource: "MartianMono-VF", withExtension: "ttf", subdirectory: "Fonts"
        ) else {
            Logger(subsystem: "io.macapy.app", category: "AppShell")
                .error("Martian Mono resource missing from bundle")
            return false
        }
        var cfError: Unmanaged<CFError>?
        let ok = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &cfError)
        if !ok {
            // Already-registered (e.g. repeated test runs in one process) is
            // success for our purposes; anything else is logged and false.
            let code = (cfError?.takeRetainedValue()).map { CFErrorGetCode($0) }
            if code == CTFontManagerError.alreadyRegistered.rawValue
                || code == CTFontManagerError.duplicatedName.rawValue {
                return true
            }
            Logger(subsystem: "io.macapy.app", category: "AppShell")
                .error("Martian Mono registration failed (code \(code ?? -1))")
            return false
        }
        return ok
    }()

    /// True once the face is available to the process.
    @discardableResult
    static func registerIfNeeded() -> Bool { registered }
}

/// Human-voice roles (SF, the system face): UI chrome and transcript text.
/// Sizes come from the approved scale (design/tokens.css --text-*).
enum UIType {
    /// 13pt — transcript lines, controls, row titles (semibold variant).
    static let body = Font.system(size: 13)
    static let bodySemibold = Font.system(size: 13, weight: .semibold)
    /// 11pt — captions, hints, secondary rows.
    static let small = Font.system(size: 11)
}

/// Type roles from the approved system: **machine speaks mono, humans speak
/// SF.** SF (the system face) carries UI chrome and transcript text; Martian
/// Mono is reserved for the machine's own voice — state labels, timers,
/// timestamps, speaker gutters, diagnostics numerals.
enum MachineType {
    /// Micro label: state words, speaker gutters, eyebrows. Pair with
    /// `.textCase(.uppercase)` and `.tracking(0.5)` at the use site when the
    /// mockup shows uppercase tracking.
    static func label(_ size: CGFloat = 9.5) -> Font {
        FontRegistrar.registerIfNeeded()
        return .custom("MartianMono-SemiBold", size: size)
    }

    /// Numerals and running values: timers, timestamps, percentiles.
    static func number(_ size: CGFloat = 9.5) -> Font {
        FontRegistrar.registerIfNeeded()
        return .custom("MartianMono-Regular", size: size)
    }

    /// Brand-weight mono (wordmark lockup moments).
    static func brand(_ size: CGFloat) -> Font {
        FontRegistrar.registerIfNeeded()
        return .custom("MartianMono-Bold", size: size)
    }
}
