import CaptureKit
import Foundation
import PersistKit
import ProviderKit
import os

/// The resolved "who do I call" for one generation: a metered provider (cap +
/// ledger already wrapped in — V5) and the deep-tier model id. Built per
/// meeting by the app shell, because metering is keyed to the meeting.
public struct PostMeetingProviderContext: Sendable {
    public var provider: any LLMProvider
    public var model: String

    public init(provider: any LLMProvider, model: String) {
        self.provider = provider
        self.model = model
    }
}

/// AgentKit's first real component (slice-03 decision 1): turns an ended
/// meeting's transcript into draft artifact rows. One entry point serves both
/// triggers — automatic on meeting end and the meeting-detail "Generate
/// artifacts" button — so the retroactive path is the same code path by
/// construction (decision 5).
public actor PostMeetingAgent {
    /// What one generation attempt came to. Every case is a terminal,
    /// reportable state: the agent never throws, because a failed extraction
    /// is a normal outcome the UI must render (pending + retry), not an
    /// exception to propagate.
    public enum Outcome: Sendable, Equatable {
        case drafted([ArtifactRecord])
        /// No provider configured (or no key): the meeting stays
        /// artifacts-pending — the quiet setup prompt's territory, never an
        /// error (PRD edge case).
        case skippedNoProvider
        /// Ephemeral meetings never produce artifacts (check 7).
        case skippedEphemeral
        /// Nothing was said, so there is nothing to extract.
        case skippedEmptyTranscript
        /// Artifacts already exist — regeneration over a reviewed set is not
        /// a thing this agent does silently.
        case skippedExistingArtifacts
        /// Another generation for this meeting is mid-flight. Actors are
        /// reentrant across `await`s, so without this the automatic trigger
        /// racing the detail pane's Generate button would pass the
        /// existing-artifacts guard twice and insert two sets of rows.
        case skippedGenerationInFlight
        /// Generation was intentionally cancelled (AI-off or teardown). This
        /// is a quiet outcome. A write cancelled before its transaction starts
        /// persists nothing; an already-uninterruptible transaction is drained
        /// atomically, and a later retry observes its complete draft set.
        case cancelled
        /// The per-meeting cap is spent: no request was issued (FR-015).
        case halted(spentUSD: Double, capUSD: Double)
        /// Extraction failed; the typed cause when it was a provider failure.
        /// The meeting stays artifacts-pending and can be retried.
        case failed(ProviderError?)
    }

    private let meetings: MeetingStore
    private let artifacts: ArtifactStore
    private let chunkBudgetCharacters: Int
    /// One owned persistence boundary for all artifact writes. The production
    /// closure calls `ArtifactStore.insertDrafts`; the injected form gives the
    /// lifecycle tests a deterministic way to hold that transaction boundary.
    private let persistDrafts: @Sendable ([DraftArtifact], UUID) async throws -> [ArtifactRecord]
    /// `nil` means "not configured" — the same quiet non-answer
    /// `ProviderRegistry.client(for:)` gives (SPEC G6: no object, no call).
    private let makeContext: @Sendable (UUID) async throws -> PostMeetingProviderContext?
    /// Wall time of the last successful generation, trigger to last row —
    /// the G3 number, surfaced in diagnostics (slice-03 decision 7).
    public private(set) var lastDraftedInSeconds: Double?
    /// Meetings with a generation currently in flight (reentrancy guard).
    private var generatingMeetingIDs: Set<UUID> = []
    /// Extraction runs in tracked child tasks so a global AI-off transition
    /// can cancel both automatic and detail-pane/manual callers. The caller's
    /// task alone is not sufficient: actor calls are reentrant and may be
    /// awaited by an unrelated presentation task.
    private var extractionTasks: [UUID: Task<MeetingExtraction, Error>] = [:]
    /// Persistence is tracked separately from extraction because cancellation
    /// cannot roll back a database transaction that has already started. The
    /// kill switch drains these tasks before returning, which makes its return
    /// the fence after which no admitted artifact write can still commit.
    private var persistenceTasks: [UUID: Task<[ArtifactRecord], Error>] = [:]
    /// False while the global AI kill switch is off. This is checked both at
    /// admission and immediately before persistence so an already-completed
    /// provider reply cannot start a new write after cancellation.
    private var generationEnabled = true
    /// Monotonic kill-switch generation. Disabling AI advances it, so an
    /// attempt admitted before an off -> on transition can never resume just
    /// because generation is enabled again by the time an earlier await
    /// returns.
    private var generationEpoch: UInt64 = 0
    private let log = Logger(subsystem: "io.macapy.app", category: "AgentKit")

    public init(
        meetings: MeetingStore,
        artifacts: ArtifactStore,
        chunkBudgetCharacters: Int = 60_000,
        generationEnabled: Bool = true,
        makeContext: @escaping @Sendable (UUID) async throws -> PostMeetingProviderContext?
    ) {
        self.meetings = meetings
        self.artifacts = artifacts
        self.chunkBudgetCharacters = chunkBudgetCharacters
        self.generationEnabled = generationEnabled
        self.makeContext = makeContext
        self.persistDrafts = { drafts, meetingID in
            try await artifacts.insertDrafts(drafts, meetingID: meetingID)
        }
    }

    /// Test-only persistence injection. Keeping the seam at the agent's owned
    /// transaction boundary avoids weakening `ArtifactStore`'s all-or-nothing
    /// write contract in production.
    init(
        meetings: MeetingStore,
        artifacts: ArtifactStore,
        chunkBudgetCharacters: Int = 60_000,
        generationEnabled: Bool = true,
        makeContext: @escaping @Sendable (UUID) async throws -> PostMeetingProviderContext?,
        persistDrafts: @escaping @Sendable ([DraftArtifact], UUID) async throws -> [ArtifactRecord]
    ) {
        self.meetings = meetings
        self.artifacts = artifacts
        self.chunkBudgetCharacters = chunkBudgetCharacters
        self.generationEnabled = generationEnabled
        self.makeContext = makeContext
        self.persistDrafts = persistDrafts
    }

    @discardableResult
    public func generateArtifacts(meetingID: UUID) async -> Outcome {
        guard generationEnabled, !Task.isCancelled else { return .cancelled }
        let admittedEpoch = generationEpoch
        guard !generatingMeetingIDs.contains(meetingID) else { return .skippedGenerationInFlight }
        generatingMeetingIDs.insert(meetingID)
        defer {
            generatingMeetingIDs.remove(meetingID)
            extractionTasks[meetingID] = nil
            persistenceTasks[meetingID] = nil
        }
        do {
            try Task.checkCancellation()
            guard let meeting = try await meetings.meeting(id: meetingID) else {
                log.error("generate for unknown meeting \(meetingID)")
                return .failed(nil)
            }
            guard !meeting.ephemeral else { return .skippedEphemeral }
            guard try await artifacts.artifacts(for: meetingID).isEmpty else {
                return .skippedExistingArtifacts
            }
            guard let context = try await makeContext(meetingID) else { return .skippedNoProvider }

            // Diarized labels (S1/S2, slice 4) where attribution landed;
            // source-based "You"/"Them" otherwise.
            let transcript = try await meetings.attributedSegments(for: meetingID).map { attributed in
                TranscriptLine(
                    speaker: attributed.speakerLabel
                        ?? (attributed.segment.source == .mic ? "You" : "Them"),
                    text: attributed.segment.text)
            }
            guard !transcript.isEmpty else { return .skippedEmptyTranscript }

            let startedAt = Date()
            let extractor = PostMeetingExtractor(
                provider: context.provider,
                model: context.model,
                chunkBudgetCharacters: chunkBudgetCharacters
            )
            // `makeContext`, transcript loading, and every store access above
            // are suspension points where AI-off can interleave. Revalidate
            // in this actor stretch immediately before creating *and*
            // registering provider work.
            guard generationEnabled,
                  generationEpoch == admittedEpoch,
                  !Task.isCancelled
            else { return .cancelled }
            let extractionTask = Task { try await extractor.extract(transcript) }
            extractionTasks[meetingID] = extractionTask
            let extraction = try await extractionTask.value
            // The kill switch can interleave at every await above. Keep this
            // checkpoint adjacent to the one transactional persistence call.
            guard generationEnabled,
                  generationEpoch == admittedEpoch,
                  !Task.isCancelled
            else { return .cancelled }
            let drafts = try extraction.drafts()
            let persistDrafts = persistDrafts
            let persistenceTask = Task {
                // If AI-off wins before this task crosses the persistence
                // boundary, cancellation guarantees a zero-write attempt.
                try Task.checkCancellation()
                return try await persistDrafts(drafts, meetingID)
            }
            persistenceTasks[meetingID] = persistenceTask
            let rows = try await persistenceTask.value
            // A transaction which had already started may have been
            // uninterruptible. Its rows are now fully committed, but the old
            // generation must still remain cancelled across off -> on.
            guard generationEnabled,
                  generationEpoch == admittedEpoch,
                  !Task.isCancelled
            else { return .cancelled }
            let elapsed = Date().timeIntervalSince(startedAt)
            lastDraftedInSeconds = elapsed
            log.info("drafted \(rows.count) artifacts in \(String(format: "%.1f", elapsed))s")
            return .drafted(rows)
        } catch is CancellationError {
            return .cancelled
        } catch let error as ProviderError {
            if case .capReached(let spent, let cap) = error {
                log.info("extraction halted at cap: \(spent, format: .fixed(precision: 4)) of \(cap, format: .fixed(precision: 4)) USD")
                return .halted(spentUSD: spent, capUSD: cap)
            }
            // Kind only, never the endpoint's message — a provider may echo
            // request content (transcript text) into error strings, and that
            // must not land in the log (critic finding; same rule as
            // ProviderLog).
            log.error("extraction failed: \(error.logDescription, privacy: .public)")
            return .failed(error)
        } catch {
            log.error("extraction failed: \(String(describing: type(of: error)), privacy: .public)")
            return .failed(nil)
        }
    }

    /// Applies the global AI kill switch and, when disabling, drains every
    /// tracked extraction and persistence task before returning. A later
    /// enable makes generation retryable; it never resumes a cancelled call
    /// automatically. Persistence which already crossed its transaction
    /// boundary may finish atomically while this method drains it, but can
    /// never commit after this method returns.
    public func setGenerationEnabled(_ enabled: Bool) async {
        generationEnabled = enabled
        guard !enabled else { return }
        generationEpoch &+= 1
        let extraction = Array(extractionTasks.values)
        let persistence = Array(persistenceTasks.values)
        for task in extraction { task.cancel() }
        for task in persistence { task.cancel() }
        for task in extraction { _ = await task.result }
        for task in persistence { _ = await task.result }
    }

    /// Teardown-only cancellation that does not latch the global switch.
    public func cancelInFlightGeneration() async {
        let extraction = Array(extractionTasks.values)
        let persistence = Array(persistenceTasks.values)
        for task in extraction { task.cancel() }
        for task in persistence { task.cancel() }
        for task in extraction { _ = await task.result }
        for task in persistence { _ = await task.result }
    }
}
