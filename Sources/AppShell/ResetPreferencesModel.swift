import Observation

/// An allowlisted result keeps Keychain, storage, and platform error payloads
/// out of the review UI. The coordinator enforces content/activity boundaries.
enum ResetPreferencesOutcome: Equatable, Sendable {
    case completed, requiresContentDeletion, busy, failed
}

@MainActor @Observable
final class ResetPreferencesModel: Identifiable {
    static let requiredToken = "RESET"
    static let accountingDisclosure = "Clearing local budget counters does not refund or cancel provider charges. Uncertain requests may already have incurred charges. Future requests start fresh local budget accounting."

    var entry = ""
    private(set) var isResetting = false
    private(set) var outcome: ResetPreferencesOutcome?
    @ObservationIgnored private let performReset: @MainActor () async -> ResetPreferencesOutcome

    init(performReset: @escaping @MainActor () async -> ResetPreferencesOutcome) {
        self.performReset = performReset
    }

    var didComplete: Bool { outcome == .completed }
    var canReset: Bool { entry == Self.requiredToken && !isResetting && !didComplete }
    var message: String? {
        switch outcome {
        case .none: nil
        case .completed: "Retained preferences and local budget counters were reset. Open Setup before your next meeting."
        case .requiresContentDeletion: "Use Delete all meeting data first, then return here to reset retained preferences."
        case .busy: "Finish the current meeting, setup download, or pending operation, then try again."
        case .failed: "Reset could not finish. Some settings may already be reset. Check available storage and Login Items, then type RESET again to retry."
        }
    }

    func confirm() async {
        guard canReset else { return }
        isResetting = true
        entry = ""
        outcome = nil
        outcome = await performReset()
        // A refusal or partial failure requires a new explicit confirmation,
        // including if another caller changed the entry during the await.
        entry = ""
        isResetting = false
    }
}
