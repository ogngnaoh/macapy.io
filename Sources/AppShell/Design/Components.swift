import AppKit
import CaptureKit
import SwiftUI

// Reusable pieces of the "Quiet instrument" system (slice-01). Only what the
// reskinned M1 surfaces need lives here; M2+ screens add their components in
// their own slices, to this design.

// MARK: - Signal strip (the signature)

/// The tick-meter along the panel's top edge — the one living element on an
/// otherwise still surface, and the app's recording indicator. Since slice 4
/// it renders real capture levels when a meter is supplied (per-source RMS,
/// polled at 100ms — G4's 60fps budget is untouched by a 10Hz redraw); with no
/// meter it keeps the slice-01 session-state animation, so previews and any
/// meterless call site degrade gracefully. Reduced motion (or a paused
/// session) collapses it to a steady dot.
struct SignalStripView: View {
    enum Mode {
        /// Capturing: animated amber/slate ticks.
        case live
        /// Paused: a still, dim dot — nothing is being heard.
        case quiet
    }

    let mode: Mode
    /// Live per-source levels; nil = slice-01 canned animation.
    var meter: SignalLevelMeter?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animating = false

    var body: some View {
        HStack(spacing: 0) {
            if mode == .live && !reduceMotion {
                if let meter {
                    TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                        let you = Self.displayScale(for: meter.level(for: .mic))
                        let them = Self.displayScale(for: meter.level(for: .system))
                        HStack(spacing: 0) {
                            ForEach(Self.ticks) { tick in
                                Capsule()
                                    .fill(tick.color)
                                    .frame(width: 3, height: tick.height)
                                    .scaleEffect(
                                        y: tick.scale(you: you, them: them),
                                        anchor: .center
                                    )
                                    .animation(.easeOut(duration: 0.12), value: you + them)
                                    .frame(maxWidth: .infinity)
                            }
                        }
                    }
                } else {
                    ForEach(Self.ticks) { tick in
                        Capsule()
                            .fill(tick.color)
                            .frame(width: 3, height: tick.height)
                            .scaleEffect(y: animating && tick.animates ? 1.6 : 0.7, anchor: .center)
                            .animation(
                                tick.animates
                                    ? .easeInOut(duration: tick.duration)
                                        .repeatForever(autoreverses: true)
                                        .delay(tick.delay)
                                    : nil,
                                value: animating
                            )
                            .frame(maxWidth: .infinity)
                    }
                }
            } else {
                Circle()
                    .fill(mode == .live ? DesignTokens.signal : DesignTokens.textTertiary)
                    .frame(width: 6, height: 6)
            }
        }
        .frame(height: 14)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, DesignTokens.Space.s3)
        .background(DesignTokens.sunken)
        .overlay(alignment: .bottom) { Divider().overlay(DesignTokens.hairline) }
        .onAppear { animating = true }
        .accessibilityLabel(mode == .live ? "Recording indicator: capturing" : "Recording indicator: paused")
    }

    /// RMS → tick scale. Speech RMS lives mostly in 0...0.35, so ×6 spreads it
    /// across the animation band; the floor keeps silent voices at the same
    /// resting height as the canned animation, the cap at its peak. Static
    /// tick heights still vary underneath (tokens.css: "a frozen frame still
    /// reads as a level meter").
    static func displayScale(for level: Float) -> CGFloat {
        let normalized = min(1, CGFloat(level) * 6)
        return 0.7 + normalized * 0.9
    }

    private enum Voice { case you, them, idle }

    private struct Tick: Identifiable {
        let id: Int
        let voice: Voice
        let color: Color
        let height: CGFloat
        let animates: Bool
        let duration: Double
        let delay: Double

        /// Meter-driven scale: each tick follows its own voice's level; idle
        /// ticks hold the resting height.
        func scale(you: CGFloat, them: CGFloat) -> CGFloat {
            switch voice {
            case .you: you
            case .them: them
            case .idle: 0.7
            }
        }
    }

    /// Tick pattern transcribed from the approved mockup (design/tokens.css
    /// nth-child rules): voice = amber (you) / slate (them) / faint (idle);
    /// heights and stagger match the CSS cascade exactly.
    private static let ticks: [Tick] = {
        let voices: [Voice] = [
            .them, .idle, .you, .them, .idle, .them, .you, .idle,
            .them, .idle, .you, .them, .idle, .them, .idle, .you,
            .them, .idle, .them, .you, .idle, .them, .idle, .them,
        ]
        return voices.enumerated().map { index, voice in
            let n = index + 1
            var height: CGFloat = 3
            if n.isMultiple(of: 2) { height = 5 }
            if n.isMultiple(of: 3) { height = 8 }
            if n.isMultiple(of: 5) { height = 4 }
            if n.isMultiple(of: 7) { height = 9 }
            let color: Color =
                switch voice {
                case .you: DesignTokens.signal
                case .them: DesignTokens.textTertiary
                case .idle: DesignTokens.hairlineStrong
                }
            return Tick(
                id: n,
                voice: voice,
                color: color,
                height: height,
                animates: voice != .idle,
                duration: n.isMultiple(of: 4) ? 1.15 : (n.isMultiple(of: 3) ? 0.7 : 0.9),
                delay: n.isMultiple(of: 4) ? 0.2 : (n.isMultiple(of: 5) ? 0.35 : 0)
            )
        }
    }()
}

// MARK: - Transcript line

/// One caption line: mono attribution gutter + SF text. Volatile lines carry
/// two cues — slate color and a dotted baseline — and settle to plain ink
/// (the M1 ".secondary alone" miss, retired by design).
struct TranscriptLineView: View {
    let speaker: String
    let isYou: Bool
    let text: String
    let isVolatile: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.s2) {
            Text(speaker)
                .font(MachineType.label())
                .textCase(.uppercase)
                .tracking(0.5)
                .foregroundStyle(isYou ? DesignTokens.live : DesignTokens.textTertiary)
                .frame(width: 34, alignment: .trailing)
            Text(text)
                .font(UIType.body)
                .lineSpacing(3)
                .foregroundStyle(isVolatile ? DesignTokens.textSecondary : DesignTokens.text)
                .underline(isVolatile, pattern: .dot, color: DesignTokens.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, DesignTokens.Space.s3)
        .padding(.vertical, 2)
    }
}

// MARK: - Meeting timer

enum ElapsedTimeFormat {
    /// HH:MM:SS from second zero, matching the mockups' 00:14:32 style.
    static func string(seconds: Int) -> String {
        let s = max(0, seconds)
        return String(format: "%02d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
    }
}

/// Ticking elapsed-time readout for the panel header (machine voice).
struct MeetingTimerText: View {
    let startedAt: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(ElapsedTimeFormat.string(
                seconds: Int(context.date.timeIntervalSince(startedAt))))
        }
        .font(MachineType.number())
        .foregroundStyle(DesignTokens.textSecondary)
        .accessibilityLabel("Meeting duration")
    }
}

// MARK: - Empty state

/// Quiet-confident empty/error state: short title, plain-fact body.
struct EmptyStateView: View {
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: DesignTokens.Space.s1) {
            Text(title)
                .font(UIType.bodySemibold)
                .foregroundStyle(DesignTokens.text)
            Text(message)
                .font(UIType.small)
                .foregroundStyle(DesignTokens.textSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(DesignTokens.Space.s5)
    }
}

// MARK: - Brand mark (variant A "Cluster")

/// The approved mark: five ticks frozen mid-word. `menuBarImage` is the
/// monochrome template glyph — it stays template in every session state
/// (decision recorded in the slice doc; the panel is the capture indicator).
enum SignalMark {
    /// Bar geometry from the brand card's 44×24 viewBox, scaled to a menu bar
    /// glyph. (x, y, height) in viewBox units; width 4, corner radius 2.
    private static let bars: [(x: CGFloat, y: CGFloat, h: CGFloat)] = [
        (0, 14, 10), (8, 8, 16), (16, 2, 22), (24, 12, 12), (32, 6, 18),
    ]

    static let menuBarImage: NSImage = {
        let scale: CGFloat = 0.45  // 44×24 → ~20×11pt glyph
        let size = NSSize(width: 44 * scale, height: 24 * scale)
        let image = NSImage(size: size, flipped: true) { _ in
            NSColor.black.setFill()
            for bar in bars {
                NSBezierPath(
                    roundedRect: NSRect(
                        x: bar.x * scale, y: bar.y * scale,
                        width: 4 * scale, height: bar.h * scale),
                    xRadius: 2 * scale, yRadius: 2 * scale
                ).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "macapy"
        return image
    }()
}
