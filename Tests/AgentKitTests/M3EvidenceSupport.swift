import CaptureKit
import Foundation
import ProviderKit

@testable import AgentKit

enum M3ExpectedAction: String, Codable, Sendable {
    case none
    case suggestAnswer = "suggest_answer"
    case flagCommitment = "flag_commitment"

    var copilotAction: CopilotAction? {
        switch self {
        case .none: nil
        case .suggestAnswer: .suggestAnswer
        case .flagCommitment: .flagCommitment
        }
    }
}

struct M3CorpusEntry: Codable, Sendable, Equatable {
    let id: String
    let category: String
    let source: String
    let text: String
    let expected: M3ExpectedAction

    var audioSource: AudioSource {
        source == "mic" ? .mic : .system
    }

    var turn: CopilotTurn {
        CopilotTurn(
            id: Self.stableUUID(id),
            source: audioSource,
            text: text,
            segmentIDs: [Self.stableUUID("segment-\(id)")],
            tStart: 0,
            tEnd: 1
        )
    }

    /// Corpus IDs become deterministic UUIDs so repeated evidence runs drive
    /// byte-identical AgentKit values without depending on randomized hashes.
    private static func stableUUID(_ value: String) -> UUID {
        let bytes = Array(value.utf8)
        var output = [UInt8](repeating: 0, count: 16)
        for (index, byte) in bytes.enumerated() {
            output[index % 16] = output[index % 16] &+ byte &+ UInt8(index % 251)
        }
        output[6] = (output[6] & 0x0f) | 0x40
        output[8] = (output[8] & 0x3f) | 0x80
        return UUID(uuid: (
            output[0], output[1], output[2], output[3],
            output[4], output[5], output[6], output[7],
            output[8], output[9], output[10], output[11],
            output[12], output[13], output[14], output[15]
        ))
    }
}

enum M3Corpus {
    static func load() throws -> [M3CorpusEntry] {
        let url = try requiredFixtureURL()
        return try String(contentsOf: url, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .map { line in
                try JSONDecoder().decode(M3CorpusEntry.self, from: Data(line.utf8))
            }
    }

    private static func requiredFixtureURL() throws -> URL {
        guard let url = Bundle.module.url(
            forResource: "m3-english-proactive-corpus",
            withExtension: "jsonl",
            subdirectory: "Fixtures"
        ) ?? Bundle.module.url(
            forResource: "m3-english-proactive-corpus",
            withExtension: "jsonl"
        ) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return url
    }
}

struct M3ObservedDecision: Sendable {
    let id: String
    let expected: M3ExpectedAction
    let observed: CopilotAction?
}

struct M3QualityScore: Codable, Sendable, Equatable {
    let negativeCount: Int
    let falsePositiveCount: Int
    let questionCount: Int
    let questionRecallCount: Int
    let commitmentCount: Int
    let commitmentRecallCount: Int
    let wrongActionIDs: [String]
    let falsePositiveIDs: [String]

    var passesQuietGuarantee: Bool {
        negativeCount == 100
            && falsePositiveCount <= 2
            && questionCount == 20
            && questionRecallCount >= 15
            && commitmentCount == 20
            && commitmentRecallCount >= 15
    }

    static func score(_ observations: [M3ObservedDecision]) -> M3QualityScore {
        let negatives = observations.filter { $0.expected == .none }
        let questions = observations.filter { $0.expected == .suggestAnswer }
        let commitments = observations.filter { $0.expected == .flagCommitment }
        return M3QualityScore(
            negativeCount: negatives.count,
            falsePositiveCount: negatives.count { $0.observed != nil },
            questionCount: questions.count,
            questionRecallCount: questions.count { $0.observed == .suggestAnswer },
            commitmentCount: commitments.count,
            commitmentRecallCount: commitments.count { $0.observed == .flagCommitment },
            wrongActionIDs: observations
                .filter { $0.expected.copilotAction != $0.observed && $0.expected != .none }
                .map(\.id)
                .sorted(),
            falsePositiveIDs: negatives.filter { $0.observed != nil }.map(\.id).sorted()
        )
    }
}

struct M3LatencyReport: Codable, Sendable, Equatable {
    let classifierSamples: Int
    let classifierP95Milliseconds: Double
    let generationSamples: Int
    let generationFirstTokenP95Milliseconds: Double
    let g2Samples: Int
    let g2P95Milliseconds: Double
    let catchUpSamples: Int
    let catchUpFirstTokenMaximumMilliseconds: Double
    let transientRetries: Int

    var passes: Bool {
        classifierSamples >= 20
            && classifierP95Milliseconds <= 1_000
            && generationSamples >= 20
            && generationFirstTokenP95Milliseconds <= 1_500
            && g2Samples >= 20
            && g2P95Milliseconds < 3_000
            && catchUpSamples >= 5
            && catchUpFirstTokenMaximumMilliseconds < 2_000
    }
}

enum M3Evidence {
    static let quietThreshold = 0.90

    static func admittedAction(_ decision: ClassifierDecision) -> CopilotAction? {
        decision.meetsThreshold(quietThreshold) ? decision.action : nil
    }

    static func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1e15
    }

    static func nearestRankP95(_ samples: [Double]) -> Double {
        guard !samples.isEmpty else { return 0 }
        let sorted = samples.sorted()
        let rank = Int((0.95 * Double(sorted.count)).rounded(.up))
        return sorted[min(max(rank, 1), sorted.count) - 1]
    }

    static func printJSON<T: Encodable>(_ kind: String, _ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        print("M3_EVIDENCE_\(kind.uppercased())=\(String(decoding: data, as: UTF8.self))")
    }

    static func estimatedCostUSD(
        model: String,
        promptTokens: Int,
        completionTokens: Int,
        calls: Int
    ) -> Double {
        let perCall = PricingTable.defaults.estimatedCostUSD(
            model: model,
            usage: TokenUsage(
                promptTokens: promptTokens,
                cachedTokens: 0,
                completionTokens: completionTokens
            )
        )!
        return perCall * Double(calls)
    }

    static func isTransient(_ error: any Error) -> Bool {
        guard let provider = error as? ProviderError else { return false }
        switch provider {
        case .transport, .rateLimited, .server, .inStreamError:
            return true
        case .http, .malformedResponse, .decodingFailed, .truncated,
             .missingCredentials, .capReached:
            return false
        }
    }
}
