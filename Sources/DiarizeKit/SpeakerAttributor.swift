import Foundation

/// Pure max-time-overlap attribution (slice-4 decision on §6.4's "attributes
/// speaker ids to final segments by time overlap"): a segment takes the
/// speaker whose turns cover the largest share of it, provided that share
/// clears a minimum — a grazing overlap from a neighboring turn must not
/// mislabel a segment diarization mostly missed.
public enum SpeakerAttributor {
    /// A final STT segment's time window, decoupled from `TranscribeKit` so
    /// this stays a pure function over values.
    public struct SegmentWindow: Sendable, Equatable {
        public let id: UUID
        public let tStart: TimeInterval
        public let tEnd: TimeInterval

        public init(id: UUID, tStart: TimeInterval, tEnd: TimeInterval) {
            self.id = id
            self.tStart = tStart
            self.tEnd = tEnd
        }
    }

    /// The winning speaker must cover at least this fraction of the segment.
    public static let defaultMinimumOverlapFraction = 0.3

    /// segmentID → speakerKey for every segment whose best-covering speaker
    /// clears the threshold; segments below it are simply absent (render
    /// unattributed).
    public static func assign(
        turns: [SpeakerTurn],
        segments: [SegmentWindow],
        minimumOverlapFraction: Double = defaultMinimumOverlapFraction
    ) -> [UUID: String] {
        guard !turns.isEmpty else { return [:] }
        var assignments: [UUID: String] = [:]
        for segment in segments {
            let duration = segment.tEnd - segment.tStart
            guard duration > 0 else { continue }
            var overlapByKey: [String: TimeInterval] = [:]
            for turn in turns {
                let overlap = min(segment.tEnd, turn.tEnd) - max(segment.tStart, turn.tStart)
                if overlap > 0 {
                    overlapByKey[turn.speakerKey, default: 0] += overlap
                }
            }
            guard let best = overlapByKey.max(by: { lhs, rhs in
                (lhs.value, rhs.key) < (rhs.value, lhs.key)  // deterministic tie-break
            }) else { continue }
            if best.value / duration >= minimumOverlapFraction {
                assignments[segment.id] = best.key
            }
        }
        return assignments
    }
}
