import SwiftUI

// Pieces the M2 settings screens need, transcribed from the approved mockups
// (design/06-settings.html + tokens.css). Same rule as the rest of the system:
// machine voice is mono, human voice is SF, and amber appears only where the
// mockup earns it.

/// `.chip` — a micro mono badge. `.active` is the amber "Active" state
/// (`.chip.you`), everything else is the quiet outline.
struct Chip: View {
    enum Style { case quiet, active }

    let text: String
    var style: Style = .quiet

    var body: some View {
        Text(text)
            .font(MachineType.label())
            .textCase(.uppercase)
            .tracking(0.5)
            .foregroundStyle(style == .active ? DesignTokens.live : DesignTokens.textSecondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(style == .active ? DesignTokens.signalSoft : DesignTokens.sunken)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.radiusChip))
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.radiusChip)
                    .stroke(style == .active ? .clear : DesignTokens.hairline)
            )
    }
}

/// `.form-row` — a right-aligned 170pt label beside its control.
struct FormRow<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.s3) {
            Text(label)
                .font(UIType.body)
                .foregroundStyle(DesignTokens.textSecondary)
                .frame(width: 120, alignment: .trailing)
            content
            Spacer(minLength: 0)
        }
        .padding(.vertical, DesignTokens.Space.s1)
    }
}

/// `.form-note` — the small tertiary explanation under a control.
struct FormNote: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(UIType.small)
            .foregroundStyle(DesignTokens.textTertiary)
            .lineSpacing(1.5)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// `.provider-row` — one selectable endpoint, with its data-policy note and a
/// state chip. The whole row is the control (a plain button), so the hit target
/// matches what the mockup implies.
struct ProviderRow: View {
    let name: String
    let note: String?
    let chip: String
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: DesignTokens.Space.s3) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(name)
                        .font(UIType.bodySemibold)
                        .foregroundStyle(DesignTokens.text)
                    if let note {
                        Text(note)
                            .font(UIType.small)
                            .foregroundStyle(DesignTokens.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: DesignTokens.Space.s2)
                Chip(text: chip, style: isActive ? .active : .quiet)
            }
            .padding(.horizontal, DesignTokens.Space.s3)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isActive ? DesignTokens.raised : DesignTokens.surface)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.radiusCard))
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.radiusCard)
                    .stroke(isActive ? DesignTokens.hairlineStrong : DesignTokens.hairline)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(name), \(isActive ? "active" : "not configured")")
    }
}

/// `.cap-meter` — spend against the per-meeting cap. Amber fill on a sunken
/// bed; it is a readout, not decoration.
struct CapMeter: View {
    /// 0...1, clamped.
    let fraction: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(DesignTokens.sunken)
                Capsule()
                    .fill(DesignTokens.signal)
                    .frame(width: geometry.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }
}

/// `.data-table` — mono, right-aligned numerals, hairline rules.
struct DataTableHeader: View {
    let columns: [String]
    let numericFrom: Int

    var body: some View {
        HStack(spacing: DesignTokens.Space.s3) {
            ForEach(Array(columns.enumerated()), id: \.offset) { index, title in
                Text(title)
                    .font(MachineType.label())
                    .textCase(.uppercase)
                    .tracking(0.6)
                    .foregroundStyle(DesignTokens.textTertiary)
                    .frame(maxWidth: .infinity, alignment: index >= numericFrom ? .trailing : .leading)
            }
        }
        .padding(.horizontal, DesignTokens.Space.s2)
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) { Divider().overlay(DesignTokens.hairlineStrong) }
    }
}

struct DataTableRow: View {
    let cells: [String]
    let numericFrom: Int

    var body: some View {
        HStack(spacing: DesignTokens.Space.s3) {
            ForEach(Array(cells.enumerated()), id: \.offset) { index, value in
                Text(value)
                    .font(MachineType.number())
                    .foregroundStyle(DesignTokens.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: index >= numericFrom ? .trailing : .leading)
            }
        }
        .padding(.horizontal, DesignTokens.Space.s2)
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) { Divider().overlay(DesignTokens.hairline) }
    }
}
