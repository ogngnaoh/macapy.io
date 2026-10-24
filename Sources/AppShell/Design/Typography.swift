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

/// Restrained system-sans hierarchy from the stored design language. Native
/// fonts follow the source's system fallback and avoid a new font dependency.
/// Reading roles preserve source casing; authored chrome is lowercase.
enum UIType {
    static let body = Font.system(size: 12)
    /// Compatibility name; medium is the source system's subtle emphasis.
    static let bodySemibold = Font.system(size: 12, weight: .medium)
    static let small = Font.system(size: 11)
    /// Compact live captions retain a useful reading size in the small panel.
    static let compactReading = Font.system(size: 13)
    static let reading = Font.system(size: 16)
    static let heading = Font.system(size: 20, weight: .regular)
    static let title = Font.system(size: 28, weight: .regular)
}

/// Existing role names are retained for page-level call sites. Labels now use
/// quiet system sans; monospacing is reserved for values that benefit from
/// aligned numerals. No UI label drops below the source's 11pt minimum.
enum MachineType {
    static func label(_ size: CGFloat = 11) -> Font {
        .system(size: max(11, size), weight: .medium)
    }

    static func number(_ size: CGFloat = 11) -> Font {
        .system(size: max(11, size), weight: .regular, design: .monospaced)
    }

    static func brand(_ size: CGFloat) -> Font {
        .system(size: size, weight: .medium)
    }
}
