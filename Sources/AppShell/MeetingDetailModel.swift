import AgentKit
import Foundation
import Observation
import PersistKit
import ProviderKit
import os

/// State behind the meeting-detail artifacts pane: which artifacts exist,
/// which review state the pane is in, and the generate/approve/reject actions
/// (slice-03 decisions 4–6).
///
/// "Artifacts-pending" is **derived**, not persisted: an ended, non-ephemeral
/// meeting with zero artifact rows *is* pending — one source of truth, no
/// state column to migrate or to drift (recorded in the slice doc).
@MainActor
@Observable
final class MeetingDetailModel {
    enum ArtifactsState: Equatable {
        case loading
        /// Artifacts exist — the review UI.
        case review
        /// Meeting still running; artifacts arrive when it ends.
        case meetingInProgress
        /// Ended, no artifacts, provider ready — offer "Generate artifacts"
        /// (the retroactive path, PRD edge case).
        case pending
        /// Ended, no artifacts, no provider — the quiet setup prompt,
        /// never an error (PRD edge case).
        case needsProvider
        /// The per-meeting cap is spent (FR-015's visible halt).
        case halted(spentUSD: Double, capUSD: Double)
        case generating
        /// Generation failed; the message is already user-voiced.
        case failed(String)
        /// The database couldn't be opened.
        case unavailable
    }

    let meeting: MeetingRecord
    private(set) var artifacts: [ArtifactRecord] = []
    private(set) var state: ArtifactsState = .loading
    /// The G3 readout ("drafted in 22s" in the mockup) — `nil` until this
    /// app run has drafted something.
    private(set) var lastDraftedInSeconds: Double?

    @ObservationIgnored private let artifactStore: ArtifactStore?
    @ObservationIgnored private let agent: PostMeetingAgent?
    @ObservationIgnored private let isProviderConfigured: @Sendable () async -> Bool
    /// Non-`nil` (spent, cap) when a cap is configured; the model derives
    /// `halted` from spent ≥ cap.
    @ObservationIgnored private let capStatus: @Sendable (UUID) async -> (spentUSD: Double, capUSD: Double)?
    @ObservationIgnored private let log = Logger(subsystem: "io.macapy.app", category: "AppShell")

    init(
        meeting: MeetingRecord,
        artifactStore: ArtifactStore?,
        agent: PostMeetingAgent?,
        isProviderConfigured: @escaping @Sendable () async -> Bool,
        capStatus: @escaping @Sendable (UUID) async -> (spentUSD: Double, capUSD: Double)?
    ) {
        self.meeting = meeting
        self.artifactStore = artifactStore
        self.agent = agent
        self.isProviderConfigured = isProviderConfigured
        self.capStatus = capStatus
    }

    // MARK: - Grouped rows the pane renders

    var summaries: [ArtifactRecord] { artifacts.filter { $0.artifactKind == .summary } }
    var decisions: [ArtifactRecord] { artifacts.filter { $0.artifactKind == .decision } }
    var actionItems: [ArtifactRecord] { artifacts.filter { $0.artifactKind == .actionItem } }

    // MARK: - Loading

    func load() async {
        guard let artifactStore else {
            state = .unavailable
            return
        }
        do {
            artifacts = try await artifactStore.artifacts(for: meeting.id)
        } catch {
            log.error("failed to load artifacts: \(error.localizedDescription)")
            state = .unavailable
            return
        }
        if let agent { lastDraftedInSeconds = await agent.lastDraftedInSeconds }
        state = await deriveState()
    }

    private func deriveState() async -> ArtifactsState {
        guard artifacts.isEmpty else { return .review }
        guard meeting.hasEnded else { return .meetingInProgress }
        if let capped = await capStatus(meeting.id), capped.spentUSD >= capped.capUSD {
            return .halted(spentUSD: capped.spentUSD, capUSD: capped.capUSD)
        }
        guard await isProviderConfigured() else { return .needsProvider }
        return .pending
    }

    // MARK: - Actions

    /// The retroactive "Generate artifacts" button — the same agent path the
    /// meeting-end trigger takes (decision 5: one code path).
    func generate() async {
        guard let agent else { return }
        state = .generating
        let outcome = await agent.generateArtifacts(meetingID: meeting.id)
        switch outcome {
        case .drafted(let rows):
            artifacts = rows
            lastDraftedInSeconds = await agent.lastDraftedInSeconds
            state = .review
        case .skippedExistingArtifacts:
            await load()
        case .skippedNoProvider:
            state = .needsProvider
        case .halted(let spentUSD, let capUSD):
            state = .halted(spentUSD: spentUSD, capUSD: capUSD)
        case .failed(let error):
            state = .failed(error?.userMessage ?? "Artifact generation failed. Try again.")
        case .skippedGenerationInFlight:
            // The other generation (the meeting-end trigger) is mid-flight;
            // stay in the progress state — its rows appear on the next load.
            state = .generating
        case .skippedEphemeral, .skippedEmptyTranscript:
            state = await deriveState()
        }
    }

    func approve(_ id: ArtifactRecord.ID) async {
        await setStatus(.approved, id: id)
    }

    func reject(_ id: ArtifactRecord.ID) async {
        await setStatus(.rejected, id: id)
    }

    /// FR-009 in M2: the flip is the whole effect — nothing external happens.
    private func setStatus(_ status: ArtifactStatus, id: ArtifactRecord.ID) async {
        guard let artifactStore else { return }
        do {
            try await artifactStore.setStatus(status, id: id)
            artifacts = try await artifactStore.artifacts(for: meeting.id)
        } catch {
            log.error("failed to set artifact status: \(error.localizedDescription)")
        }
    }
}
