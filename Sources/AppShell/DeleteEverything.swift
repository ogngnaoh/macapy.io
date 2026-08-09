import Observation
import SwiftUI

/// The type-to-confirm gate for delete-everything (FR-013; slice-05 doc
/// decision 7). Pure state — the sheet renders it, the unit tests drive it.
/// `canDelete` only on the exact token `DELETE`; `confirm()` can invoke the
/// deletion at most once per model instance.
@MainActor
@Observable
final class DeleteEverythingModel: Identifiable {
    static let requiredToken = "DELETE"

    var entry = ""
    private(set) var isDeleting = false
    /// Deletion ran and reported success.
    private(set) var didComplete = false
    /// Deletion was refused (a meeting is capturing) or failed.
    private(set) var didFail = false
    @ObservationIgnored private var invoked = false
    @ObservationIgnored private let performDelete: () async -> Bool

    /// `performDelete` returns whether deletion actually ran — the
    /// coordinator refuses while capturing.
    init(performDelete: @escaping () async -> Bool) {
        self.performDelete = performDelete
    }

    /// Exact match only: "delete", "DELETE ", and every near-miss stay
    /// disabled (check 14).
    var canDelete: Bool {
        entry == Self.requiredToken && !invoked
    }

    func confirm() async {
        guard canDelete else { return }
        invoked = true
        isDeleting = true
        let ran = await performDelete()
        isDeleting = false
        didComplete = ran
        didFail = !ran
        // A refused run (meeting still capturing) may be retried once the
        // meeting stops; a completed one stays terminal for this instance.
        if !ran {
            invoked = false
        }
    }
}

/// The custom type-to-confirm sheet (slice-05 doc decision 7) — composed
/// purely from existing tokens/components; the design record is the sheet
/// card in design/06-settings.html.
struct DeleteEverythingSheet: View {
    @Bindable var model: DeleteEverythingModel
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s3) {
            Text("Delete all meeting data?")
                .font(UIType.bodySemibold)
                .foregroundStyle(DesignTokens.text)
            Text(
                "Every meeting, transcript, artifact, and spend record is removed from this Mac, "
                    + "including its search index. Settings and API keys are kept. This can't be undone."
            )
            .font(UIType.small)
            .foregroundStyle(DesignTokens.textSecondary)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)

            if model.didComplete {
                Chip(text: "Deleted", style: .quiet)
                HStack {
                    Spacer()
                    Button("Done") { onDismiss() }
                        .keyboardShortcut(.defaultAction)
                }
            } else {
                Text("Type DELETE to confirm.")
                    .font(MachineType.label())
                    .textCase(.uppercase)
                    .tracking(0.5)
                    .foregroundStyle(DesignTokens.textTertiary)
                TextField("", text: $model.entry, prompt: Text(verbatim: "DELETE"))
                    .textFieldStyle(.plain)
                    .font(MachineType.number(12))
                    .foregroundStyle(DesignTokens.text)
                    .padding(.horizontal, DesignTokens.Space.s2)
                    .padding(.vertical, 5)
                    .background(DesignTokens.sunken)
                    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.radiusControl))
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignTokens.radiusControl)
                            .stroke(DesignTokens.hairline)
                    )
                    .frame(maxWidth: 200)
                    .accessibilityLabel("Type DELETE to confirm")

                if model.didFail {
                    Text("Deletion didn't run — stop the current meeting first, then try again.")
                        .font(UIType.small)
                        .foregroundStyle(DesignTokens.statusRejected)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: DesignTokens.Space.s2) {
                    Spacer()
                    Button("Cancel") { onDismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button(model.isDeleting ? "Deleting…" : "Delete everything") {
                        Task { await model.confirm() }
                    }
                    .buttonStyle(DestructiveButtonStyle())
                    .disabled(!model.canDelete || model.isDeleting)
                    .accessibilityLabel("Delete all meeting data")
                }
            }
        }
        .padding(DesignTokens.Space.s5)
        .frame(width: 380)
        .background(DesignTokens.surface)
    }
}
