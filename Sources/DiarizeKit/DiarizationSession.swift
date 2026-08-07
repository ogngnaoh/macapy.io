import CaptureKit
import Foundation

/// One meeting's diarization outcome, ready for persistence: speakers in
/// first-appearance order with their `S1`/`S2`… labels, and the full
/// segment → speaker-key assignment map.
public struct MeetingDiarization: Sendable, Equatable {
    public struct Speaker: Sendable, Equatable {
        public let key: String
        public let label: String
        public let embedding: Data?

        public init(key: String, label: String, embedding: Data?) {
            self.key = key
            self.label = label
            self.embedding = embedding
        }
    }

    public let speakers: [Speaker]
    /// segmentID → speaker key (join through `speakers` for the label).
    public let assignments: [UUID: String]

    public init(speakers: [Speaker], assignments: [UUID: String]) {
        self.speakers = speakers
        self.assignments = assignments
    }
}

/// A newly attributed live segment (slice-4 decision 3's live channel): the
/// pipeline pushes these into `TranscriptStore.speakerLabels` as they land.
public struct LiveAttribution: Sendable, Equatable {
    public let segmentID: UUID
    public let label: String

    public init(segmentID: UUID, label: String) {
        self.segmentID = segmentID
        self.label = label
    }
}

/// Bridges one meeting's them-stream to a `DiarizationEngine` (slice-4
/// decision 3). Audio chunks and them-finals arrive as they happen; live
/// attributions come back incrementally (best-effort — a final that precedes
/// its window's turns attributes when the window flushes); `finalize()`
/// recomputes the full assignment over everything for the authoritative DB
/// sweep, so the persisted result never depends on incremental ordering.
public actor DiarizationSession {
    private let engine: any DiarizationEngine
    private var turns: [SpeakerTurn] = []
    private var segments: [SpeakerAttributor.SegmentWindow] = []
    /// Keys in first-appearance order (turn arrival order, which follows the
    /// meeting timeline) — the source of `S1`/`S2`… labels.
    private var keyOrder: [String] = []
    private var liveAssignments: [UUID: String] = [:]

    public init(engine: any DiarizationEngine) {
        self.engine = engine
    }

    /// Feed one them-stream chunk; returns any segments newly attributable
    /// because this chunk completed a window.
    public func ingest(_ chunk: AudioChunk) async throws -> [LiveAttribution] {
        let newTurns = try await engine.ingest(chunk)
        guard !newTurns.isEmpty else { return [] }
        note(newTurns)
        return reattribute()
    }

    /// Register a them-final; returns its attribution if existing turns
    /// already cover it.
    public func noteFinal(segmentID: UUID, tStart: TimeInterval, tEnd: TimeInterval) -> [LiveAttribution] {
        segments.append(.init(id: segmentID, tStart: tStart, tEnd: tEnd))
        return reattribute()
    }

    /// Flush the engine's tail and produce the authoritative result.
    public func finalize() async throws -> MeetingDiarization {
        let (tailTurns, embeddings) = try await engine.finish()
        note(tailTurns)
        let assignments = SpeakerAttributor.assign(turns: turns, segments: segments)
        let speakers = keyOrder.enumerated().map { index, key in
            MeetingDiarization.Speaker(
                key: key, label: "S\(index + 1)", embedding: embeddings[key])
        }
        return MeetingDiarization(speakers: speakers, assignments: assignments)
    }

    private func note(_ newTurns: [SpeakerTurn]) {
        turns.append(contentsOf: newTurns)
        for turn in newTurns where !keyOrder.contains(turn.speakerKey) {
            keyOrder.append(turn.speakerKey)
        }
    }

    private func label(forKey key: String) -> String? {
        keyOrder.firstIndex(of: key).map { "S\($0 + 1)" }
    }

    /// Live attribution over the still-unassigned segments only (a live label
    /// never flips once shown; `finalize()`'s full recompute is the authority
    /// the DB gets). Keeps the per-event cost proportional to the handful of
    /// recent unattributed segments, not the whole meeting.
    private func reattribute() -> [LiveAttribution] {
        let unassigned = segments.filter { liveAssignments[$0.id] == nil }
        guard !unassigned.isEmpty else { return [] }
        let assignments = SpeakerAttributor.assign(turns: turns, segments: unassigned)
        var fresh: [LiveAttribution] = []
        for (segmentID, key) in assignments {
            liveAssignments[segmentID] = key
            if let label = label(forKey: key) {
                fresh.append(LiveAttribution(segmentID: segmentID, label: label))
            }
        }
        return fresh.sorted { $0.segmentID.uuidString < $1.segmentID.uuidString }
    }
}
