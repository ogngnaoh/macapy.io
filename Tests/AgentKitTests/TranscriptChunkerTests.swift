import Testing

@testable import AgentKit

/// The mechanism behind "no meeting length hard-fails" (slice-03 decision 2):
/// packing respects the budget, preserves order, and degrades — never dies —
/// on pathological input.
struct TranscriptChunkerTests {

    @Test func linesUnderTheBudgetPackIntoOneChunk() {
        let chunks = TranscriptChunker.chunks(["a: one", "b: two"], budgetCharacters: 100)
        #expect(chunks == ["a: one\nb: two"])
    }

    @Test func packingSplitsAtTheBudgetPreservingOrder() {
        let lines = ["aaaa", "bbbb", "cccc", "dddd"]
        let chunks = TranscriptChunker.chunks(lines, budgetCharacters: 9)

        #expect(chunks == ["aaaa\nbbbb", "cccc\ndddd"])
    }

    @Test func noChunkEverExceedsTheBudget() {
        let lines = (0..<200).map { String(repeating: "x", count: $0 % 37 + 1) }
        let chunks = TranscriptChunker.chunks(lines, budgetCharacters: 50)

        #expect(chunks.allSatisfy { $0.count <= 50 })
        #expect(chunks.joined(separator: "\n") == lines.joined(separator: "\n"))
    }

    @Test func aSingleLineLongerThanTheBudgetIsSplitNotDropped() {
        let monster = String(repeating: "m", count: 25)
        let chunks = TranscriptChunker.chunks(["short", monster, "tail"], budgetCharacters: 10)

        #expect(chunks.allSatisfy { $0.count <= 10 })
        #expect(chunks.joined() == "short" + monster + "tail")
    }

    @Test func emptyInputYieldsNoChunks() {
        #expect(TranscriptChunker.chunks([], budgetCharacters: 10).isEmpty)
    }
}
