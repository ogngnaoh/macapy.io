import AppKit
import SwiftUI

/// Native adaptation of the owner's stored Acne-inspired design system.
/// Neutral surfaces, square geometry and a restrained color layer are shared
/// across the app. The source defines light mode; dark mode deliberately
/// inverts the neutral roles and raises semantic text contrast. Brand fills
/// keep their source colors in both appearances.
enum DesignTokens {
    // MARK: Surfaces and text

    static let bg = adaptive(light: 0xFFFFFF, dark: 0x121212)
    static let surface = adaptive(light: 0xFFFFFF, dark: 0x181818)
    /// A distinct flat surface, with no shadow or implied elevation.
    static let raised = adaptive(light: 0xFFFFFF, dark: 0x202020)
    static let sunken = adaptive(light: 0xF7F7F7, dark: 0x252525)
    static let text = adaptive(light: 0x000000, dark: 0xFFFFFF)
    static let textSecondary = adaptive(light: 0x6B6B6B, dark: 0xC2C2C2)
    /// Small labels remain readable; tertiary hierarchy also uses spacing.
    static let textTertiary = adaptive(light: 0x6B6B6B, dark: 0xA3A3A3)
    static let hairline = adaptive(light: 0xF2F2F2, dark: 0x333333)
    static let hairlineStrong = adaptive(light: 0xC2C2C2, dark: 0x6B6B6B)

    // MARK: Brand and selection

    /// Neutral navigation and primary actions. Blue is reserved for links and
    /// focus rather than painting every selected surface with brand color.
    static let selection = text
    static let textOnSelection = adaptive(light: 0xFFFFFF, dark: 0x000000)
    /// Structural accent: links and keyboard focus. The lighter dark-mode
    /// counterpart is a native accessibility adaptation, not a source token.
    static let accent = adaptive(light: 0x0018A8, dark: 0xA9CAFF)
    static let live = adaptive(light: 0x0047AB, dark: 0xA9CAFF)
    /// Primary fills retain cobalt in either appearance, with white text.
    static let signal = Color(srgbHex: 0x0047AB)
    static let signalSoft = adaptive(light: 0xEAEDFB, dark: 0x1A2C46)
    static let textOnSignal = Color(srgbHex: 0xFFFFFF)
    /// Expressive fills only. Pink/orange are never used as reading text.
    static let brandPink = Color(srgbHex: 0xF7CAC9)
    static let brandOrange = Color(srgbHex: 0xFF5C00)
    static let textOnBrand = Color(srgbHex: 0x000000)
    static let cream = adaptive(light: 0xF5F1EA, dark: 0x292621)

    // MARK: Semantic status

    static let statusApproved = adaptive(light: 0x007701, dark: 0xA6DEA5)
    static let statusApprovedSurface = adaptive(light: 0xE5F5E0, dark: 0x19341A)
    /// Source warning amber is darkened for small text on its tinted surface
    /// (the original pairing is only 3.93:1; this pairing exceeds 4.5:1).
    static let statusWarning = adaptive(light: 0x985300, dark: 0xF3BE76)
    static let statusWarningSurface = adaptive(light: 0xFBEED9, dark: 0x382B17)
    static let statusRejected = adaptive(light: 0xC4271C, dark: 0xFFB4AB)
    static let statusRejectedSurface = adaptive(light: 0xFBE4E1, dark: 0x3E2220)

    // MARK: Geometry

    // Kept as named roles so existing page-level components share the square
    // treatment without separate literals. Native window chrome stays native.
    static let radiusCard: CGFloat = 0
    static let radiusControl: CGFloat = 0
    static let radiusChip: CGFloat = 0
    static let tracking: CGFloat = 0.3

    enum Space {
        static let s1: CGFloat = 5
        static let s2: CGFloat = 10
        static let s3: CGFloat = 15
        static let s4: CGFloat = 20
        static let s5: CGFloat = 30
        static let s6: CGFloat = 45
    }

    // MARK: -

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(srgbHex: isDark ? dark : light)
        })
    }
}

extension NSColor {
    fileprivate convenience init(srgbHex hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

extension Color {
    fileprivate init(srgbHex hex: UInt32) {
        self.init(nsColor: NSColor(srgbHex: hex))
    }
}
