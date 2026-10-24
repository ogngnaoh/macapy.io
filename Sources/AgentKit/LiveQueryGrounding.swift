import Foundation
import MemoryKit

/// Transient, literal finalized-turn evidence. Its identity belongs to the
/// active orchestrator, not a persisted memory fact or a model-created URL.
public struct LiveTranscriptEvidence: Sendable, Equatable, Identifiable {
    public var id: String { "live-" + turnID.uuidString.lowercased() }
    public let turnID: UUID
    public let title: String
    public let text: String
    public let tStart: TimeInterval
    public init(turnID: UUID, title: String, text: String, tStart: TimeInterval) {
        self.turnID = turnID; self.title = title; self.text = text; self.tStart = tStart
    }
    public var excerpt: RetrievedExcerpt {
        .init(citationID: id, title: title, text: text, statedAt: Date(timeIntervalSince1970: tStart), sources: [])
    }
}

/// One explicit reviewed selection. No store, provider, or UI object crosses
/// this boundary. The external validator must recheck consent and revisions.
public struct LiveQueryGrounding: Sendable {
    public let external: ContextBundle
    public let recentTranscript: [LiveTranscriptEvidence]
    public let validateExternal: @Sendable () async -> Bool
    public init(external: ContextBundle, recentTranscript: [LiveTranscriptEvidence],
                validateExternal: @escaping @Sendable () async -> Bool) throws {
        guard external.excerpts.count <= 4, recentTranscript.count <= 4,
              external.excerpts.reduce(0, { $0 + $1.text.count }) <= 4_000,
              recentTranscript.reduce(0, { $0 + $1.text.count }) <= 4_000,
              recentTranscript.allSatisfy({ !$0.text.isEmpty && $0.text.count <= 1_000 }),
              external.excerpts.allSatisfy({ !$0.sources.isEmpty }),
              Set(external.excerpts.map(\.citationID) + recentTranscript.map(\.id)).count == external.excerpts.count + recentTranscript.count else {
            throw MemoryGenerationError.invalidEvidence
        }
        self.external = external; self.recentTranscript = recentTranscript; self.validateExternal = validateExternal
    }
    public var bundle: ContextBundle { .init(excerpts: recentTranscript.map(\.excerpt) + external.excerpts) }
    static func limitedAnswer(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).prefix(150).joined(separator: " ")
    }
}
