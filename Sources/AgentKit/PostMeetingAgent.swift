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
        /// The per-meeting cap is spent: no request was issued (FR-015).
        case halted(spentUSD: Double, capUSD: Double)
        /// Extraction failed; the typed cause when it was a provider failure.
        /// The meeting stays artifacts-pending and can be retried.
        case failed(ProviderError?)
    }

    private let meetings: MeetingStore
    private let artifacts: ArtifactStore
    private let chunkBudgetCharacters: Int
    /// `nil` means "not configured" — the same quiet non-answer
    /// `ProviderRegistry.client(for:)` gives (SPEC G6: no object, no call).
    private let makeContext: @Sendable (UUID) async throws -> PostMeetingProviderContext?
    /// Wall time of the last successful generation, trigger to last row —
    /// the G3 number, surfaced in diagnostics (slice-03 decision 7).
    public private(set) var lastDraftedInSeconds: Double?
    /// Meetings with a generation currently in flight (reentrancy guard).
    private var generatingMeetingIDs: Set<UUID> = []
    private let log = Logger(subsystem: "io.macapy.app", category: "AgentKit")

    public init(
        meetings: MeetingStore,
        artifacts: ArtifactStore,
        chunkBudgetCharacters: Int = 60_000,
        makeContext: @escaping @Sendable (UUID) async throws -> PostMeetingProviderContext?
    ) {
        self.meetings = meetings
        self.artifacts = artifacts
        self.chunkBudgetCharacters = chunkBudgetCharacters
        self.makeContext = makeContext
    }

    @discardableResult
    public func generateArtifacts(meetingID: UUID) async -> Outcome {
        guard !generatingMeetingIDs.contains(meetingID) else { return .skippedGenerationInFlight }
        generatingMeetingIDs.insert(meetingID)
        defer { generatingMeetingIDs.remove(meetingID) }
        do {
            guard let meeting = try await meetings.meeting(id: meetingID) else {
                log.error("generate for unknown meeting \(meetingID)")
                return .failed(nil)
            }
            guard !meeting.ephemeral else { return .skippedEphemeral }
            guard try await artifacts.artifacts(for: meetingID).isEmpty else {
                return .skippedExistingArtifacts
            }
            guard let context = try await makeContext(meetingID) else { return .skippedNoProvider }

            // "You"/"Them" until diarization (M2 slice 4) refines the labels.
            let transcript = try await meetings.segments(for: meetingID).map { segment in
                TranscriptLine(speaker: segment.source == .mic ? "You" : "Them", text: segment.text)
            }
            guard !transcript.isEmpty else { return .skippedEmptyTranscript }

            let startedAt = Date()
            let extractor = PostMeetingExtractor(
                provider: context.provider,
                model: context.model,
                chunkBudgetCharacters: chunkBudgetCharacters
            )
            let extraction = try await extractor.extract(transcript)
            let rows = try await artifacts.insertDrafts(try extraction.drafts(), meetingID: meetingID)
            let elapsed = Date().timeIntervalSince(startedAt)
            lastDraftedInSeconds = elapsed
            log.info("drafted \(rows.count) artifacts in \(String(format: "%.1f", elapsed))s")
            return .drafted(rows)
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
}
