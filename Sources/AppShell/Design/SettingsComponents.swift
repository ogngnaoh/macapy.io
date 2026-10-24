import SwiftUI

// Shared settings surfaces follow the stored editorial design language:
// square controls, lowercase labels, hairlines, and restrained status color.

/// A square, text-labelled status badge. Color reinforces the written state
/// and semantic fills keep every label legible in both appearances.
struct Chip: View {
    enum Style { case quiet, active, approved, rejected }

    let text: String
    var style: Style = .quiet

    var body: some View {
        Text(text)
            .font(MachineType.label())
            .textCase(.lowercase)
            .foregroundStyle(foreground)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(background)
    }

    private var background: Color {
        switch style {
        case .quiet: DesignTokens.sunken
        case .active: DesignTokens.sunken
        case .approved: DesignTokens.statusApprovedSurface
        case .rejected: DesignTokens.statusRejectedSurface
        }
    }

    private var foreground: Color {
        switch style {
        case .quiet: DesignTokens.textSecondary
        case .active: DesignTokens.text
        case .approved: DesignTokens.statusApproved
        case .rejected: DesignTokens.statusRejected
        }
    }
}

/// A right-aligned label beside its native control.
struct FormRow<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.s3) {
            Text(label)
                .font(UIType.small)
                .textCase(.lowercase)
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
            .font(UIType.body)
            .foregroundStyle(DesignTokens.textTertiary)
            .lineSpacing(3)
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
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: DesignTokens.Space.s3) {
                VStack(alignment: .leading, spacing: DesignTokens.Space.s1) {
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
            .padding(.vertical, DesignTokens.Space.s3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isHovered ? DesignTokens.sunken : DesignTokens.surface)
            .overlay(Rectangle().stroke(
                isActive ? DesignTokens.selection : DesignTokens.hairlineStrong,
                lineWidth: isActive ? 2 : 1
            ))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel("\(name), \(isActive ? "active" : "not configured")")
    }
}

/// Spend against the per-meeting cap: a flat ink bar on a neutral bed.
/// The adjacent text supplies the accessible amount and cap.
struct CapMeter: View {
    /// 0...1, clamped.
    let fraction: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Rectangle().fill(DesignTokens.sunken)
                Rectangle()
                    .fill(DesignTokens.selection)
                    .frame(width: geometry.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }
}

/// Quiet column labels with right-aligned values and hairline rules.
struct DataTableHeader: View {
    let columns: [String]
    let numericFrom: Int

    var body: some View {
        HStack(spacing: DesignTokens.Space.s3) {
            ForEach(Array(columns.enumerated()), id: \.offset) { index, title in
                Text(title)
                    .font(MachineType.label())
                    .textCase(.lowercase)
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

// MARK: - Stat tile (diagnostics grid)

/// A flat diagnostics tile: restrained label, aligned value, subtle unit.
struct StatTile: View {
    let label: String
    let value: String
    var unit: String?

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s2) {
            Text(label)
                .font(MachineType.label())
                .textCase(.lowercase)
                .foregroundStyle(DesignTokens.textSecondary)
                .lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(MachineType.number(24))
                    .foregroundStyle(DesignTokens.text)
                if let unit {
                    Text(unit)
                        .font(MachineType.number(11))
                        .foregroundStyle(DesignTokens.textSecondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DesignTokens.Space.s3)
        .background(DesignTokens.surface)
        .overlay(Rectangle().stroke(DesignTokens.hairlineStrong, lineWidth: 1))
    }
}
