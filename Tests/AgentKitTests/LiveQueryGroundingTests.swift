import Foundation
import MemoryKit
import Testing
@testable import AgentKit

struct LiveQueryGroundingTests {
    @Test func recentSnapshotIsBoundedLiteralAndRejectsForgedTurns() async throws {
        let domain = try CopilotMeetingOrchestrator(meetingID: UUID(), configuration: .init(aiFeaturesEnabled: false), provider: nil,
            models: .init(fast: "synthetic", deep: "synthetic"))
        for index in 0..<20 {
            await domain.receive(.init(source: .mic, text: String(repeating: "word ", count: 300), tStart: Double(index * 10), tEnd: Double(index * 10 + 5)), userSpeaking: false)
        }
        let evidence = await domain.recentTranscriptEvidence()
        #expect(evidence.count == 4)
        #expect(evidence.reduce(0) { $0 + $1.text.count } == 4_000)
        #expect(evidence.allSatisfy { $0.tStart >= 160 })
        #expect(await domain.validateTranscriptEvidence(evidence))
        let forged = LiveTranscriptEvidence(turnID: UUID(), title: "forged", text: "word", tStart: 180)
        #expect(await domain.validateTranscriptEvidence([forged]) == false)
        await domain.stop()
        #expect(await domain.validateTranscriptEvidence(evidence) == false)
        #expect(await domain.recentTranscriptEvidence().isEmpty)
    }

    @Test func selectionLimitsAndCitationUniquenessAreEnforcedBeforeAdmission() throws {
        let source = SourceReference(kind: .documentChunk, sourceID: UUID(), revision: 0, documentID: UUID(), startCharacter: 0, endCharacter: 1)
        let external = (0..<5).map { index in RetrievedExcerpt(citationID: "doc-\(index)", title: "doc", text: "x", statedAt: .distantPast, sources: [source]) }
        #expect(throws: MemoryGenerationError.invalidEvidence) {
            try LiveQueryGrounding(external: .init(excerpts: external), recentTranscript: [], validateExternal: { true })
        }
        let live = LiveTranscriptEvidence(turnID: UUID(), title: "You", text: "literal", tStart: 1)
        #expect(throws: MemoryGenerationError.invalidEvidence) {
            try LiveQueryGrounding(external: .init(excerpts: []), recentTranscript: [live, live], validateExternal: { true })
        }
        let valid = try LiveQueryGrounding(external: .init(excerpts: Array(external.prefix(4))), recentTranscript: [live], validateExternal: { true })
        #expect(valid.bundle.excerpts.count == 5)
        #expect(valid.bundle.excerpts.first?.sources.isEmpty == true)
        #expect(valid.bundle.containsOnlyValidCitations([live.id, "doc-0"]))
        #expect(LiveQueryGrounding.limitedAnswer(String(repeating: "word ", count: 200)).split(separator: " ").count == 150)
    }
}
