import AppKit
import SwiftUI

/// SwiftUI translation of `design/tokens.css` — the approved "Quiet
/// instrument" system (slice-01, direction record in the slice doc). Every
/// reskinned view draws its colors, spacing, and radii from here; hex values
/// match the mockups exactly. Light and dark are co-equal: role tokens adapt
/// via the window's effective appearance, `signal` is constant.
enum DesignTokens {
    // MARK: Role colors (light / dark)

    /// Window background — fog / near-carbon.
    static let bg = adaptive(light: 0xEEF0F2, dark: 0x1C2024)
    /// Panel and card surface — paper / carbon.
    static let surface = adaptive(light: 0xFBFBFC, dark: 0x23272C)
    /// Elevated cards (moments, artifacts).
    static let raised = adaptive(light: 0xFFFFFF, dark: 0x2B3036)
    /// Wells: the signal strip's bed, fields.
    static let sunken = adaptive(light: 0xE4E7EA, dark: 0x16191D)
    /// Primary text — ink / fog-white.
    static let text = adaptive(light: 0x16191D, dark: 0xE8EAED)
    /// Secondary text and volatile transcript — slate.
    static let textSecondary = adaptive(light: 0x6B7683, dark: 0x8B95A1)
    /// Tertiary: timestamps, hints, idle ticks.
    static let textTertiary = adaptive(light: 0x9AA3AD, dark: 0x5D6670)
    static let hairline = adaptive(light: 0x16191D, dark: 0xE8EAED, lightAlpha: 0.12, darkAlpha: 0.10)
    static let hairlineStrong = adaptive(light: 0x16191D, dark: 0xE8EAED, lightAlpha: 0.22, darkAlpha: 0.20)
    /// Live/capturing text and icons: darkened amber on light (AA), full
    /// signal amber on dark.
    static let live = adaptive(light: 0x8A5E12, dark: 0xF2A33C)
    /// VU amber — the one vivid thing. Strip ticks and primary marks only,
    /// never decoration. Constant across modes.
    static let signal = Color(srgbHex: 0xF2A33C)
    /// The amber wash behind an active chip (`--signal-soft`).
    static let signalSoft = Color(nsColor: NSColor(srgbHex: 0xF2A33C, alpha: 0.14))
    /// Review-state chips in meeting detail (`.chip.approved` /
    /// `.chip.rejected` — tokens.css keeps one value across modes).
    static let statusApproved = adaptive(light: 0x2E7D43, dark: 0x2E7D43)
    static let statusRejected = adaptive(light: 0xC93B32, dark: 0xC93B32)
    /// Text on an amber primary button (`.btn.primary`'s `#2a1d05`).
    static let textOnSignal = Color(srgbHex: 0x2A1D05)

    // MARK: Geometry

    static let radiusCard: CGFloat = 8
    static let radiusControl: CGFloat = 6
    static let radiusChip: CGFloat = 4

    enum Space {
        static let s1: CGFloat = 4
        static let s2: CGFloat = 8
        static let s3: CGFloat = 12
        static let s4: CGFloat = 16
        static let s5: CGFloat = 24
        static let s6: CGFloat = 32
    }

    // MARK: -

    private static func adaptive(
        light: UInt32, dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1
    ) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return isDark
                ? NSColor(srgbHex: dark, alpha: darkAlpha)
                : NSColor(srgbHex: light, alpha: lightAlpha)
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
